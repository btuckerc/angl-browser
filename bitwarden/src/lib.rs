//! angl's bridge to the official Bitwarden SDK. One `Session` holds one account's encrypted vault
//! (from a `/api/sync` response) and, once unlocked, the SDK key store. Swift talks to it through
//! `angl_bw_call(session, method, json)`: JSON in, `{"ok": …}` or `{"error": {kind, message}}` out.
//! Callers serialize calls per session. All HTTP stays in Swift; this crate never touches the
//! network. Every heap buffer is zeroed on free (the SDK installs a zeroizing global allocator).

use std::{
    collections::HashMap,
    ffi::{CStr, c_char},
    num::NonZeroU32,
    panic::{AssertUnwindSafe, catch_unwind},
    sync::Mutex,
};

use bitwarden_api_api::models::{
    CipherDetailsResponseModel, CipherRequestModel, DomainsResponseModel, ProfileResponseModel, UserDecryptionResponseModel,
};
use bitwarden_core::{
    Client, OrganizationId, UserId,
    key_management::{
        MasterPasswordUnlockData, V2UpgradeToken,
        account_cryptographic_state::WrappedAccountCryptographicState,
        crypto::{InitOrgCryptoRequest, InitUserCryptoMethod, InitUserCryptoRequest},
    },
};
use bitwarden_crypto::{EncString, HashPurpose, Kdf, MasterKey, SymmetricCryptoKey, UnsignedSharedKey};
use bitwarden_fido::{
    CheckUserOptions, CheckUserResult, ClientData, ClientFido2Ext, Fido2CallbackError, Fido2ClientError, Fido2CredentialStore,
    Fido2UserInterface, Origin, UiHint, string_to_guid_bytes,
};
use bitwarden_vault::{
    Cipher, CipherListView, CipherListViewType, CipherRepromptType, CipherType, CipherView, EncryptionContext,
    Fido2CredentialNewView, LoginUriView, LoginView, VaultClientExt,
};
use passkey::{
    client::WebauthnError,
    types::{
        Bytes, crypto::sha256, encoding::base64url,
        webauthn::{ClientDataType, CollectedClientData},
    },
};
use serde::{Deserialize, de::IgnoredAny};
use serde_json::{Value, json, value::RawValue};

pub struct Session {
    client: Client,
    vault: Option<Vault>,
    /// Master key derived by `authHash` during login, reused by the first unlock (one KDF run).
    pending: Option<MasterKey>,
    unlocked: bool,
    /// The KDF the vault was unlocked with, for re-prompts on servers without `userDecryption`.
    kdf: Option<Kdf>,
}

struct Vault {
    user_id: Option<UserId>,
    email: String,
    premium: bool,
    unlock: Option<MasterPasswordUnlockData>,
    account: WrappedAccountCryptographicState,
    upgrade: Option<V2UpgradeToken>,
    /// Pre-`userDecryption` servers: the master-key-wrapped user key from the profile.
    profile_key: Option<EncString>,
    orgs: HashMap<OrganizationId, UnsignedSharedKey>,
    /// Live logins as the sync sent them (still encrypted, ~1 KB each): a parsed `Cipher` is
    /// several KB even when empty, so they're parsed per use — in batches for the index.
    ciphers: Vec<Box<str>>,
    by_id: HashMap<String, usize>,
}

struct Fail {
    kind: &'static str,
    message: String,
}

fn fail(kind: &'static str, e: impl std::fmt::Display) -> Fail {
    Fail { kind, message: e.to_string() }
}

type Out = Result<Value, Fail>;

/// The parts of `/api/sync` angl uses; folders, collections, policies and sends are skipped.
#[derive(Deserialize)]
struct SyncIn<'a> {
    #[serde(alias = "Profile")]
    profile: Option<Box<ProfileResponseModel>>,
    #[serde(borrow, alias = "Ciphers")]
    ciphers: Option<Vec<&'a RawValue>>,
    #[serde(alias = "Domains")]
    domains: Option<Box<DomainsResponseModel>>,
    #[serde(rename = "userDecryption", alias = "UserDecryption")]
    user_decryption: Option<Box<UserDecryptionResponseModel>>,
}

/// Enough of a cipher to keep or skip it without a full parse.
#[derive(Deserialize)]
struct CipherHead {
    #[serde(alias = "Id")]
    id: Option<String>,
    #[serde(rename = "type", alias = "Type")]
    kind: Option<u8>,
    #[serde(rename = "deletedDate", alias = "DeletedDate")]
    deleted: Option<IgnoredAny>,
    #[serde(rename = "archivedDate", alias = "ArchivedDate")]
    archived: Option<IgnoredAny>,
}

fn cipher(raw: &str) -> Result<Cipher, Fail> {
    let model: CipherDetailsResponseModel = serde_json::from_str(raw).map_err(|e| fail("parse", e))?;
    Cipher::try_from(model).map_err(|e| fail("parse", e))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct KdfIn {
    r#type: u8,
    iterations: u32,
    memory: Option<u32>,
    parallelism: Option<u32>,
}

impl KdfIn {
    fn kdf(&self) -> Result<Kdf, Fail> {
        let nz = |v: Option<u32>| v.and_then(NonZeroU32::new).ok_or_else(|| fail("input", "bad KDF parameters"));
        Ok(match self.r#type {
            0 => Kdf::PBKDF2 { iterations: nz(Some(self.iterations))? },
            1 => Kdf::Argon2id {
                iterations: nz(Some(self.iterations))?,
                memory: nz(self.memory)?,
                parallelism: nz(self.parallelism)?,
            },
            t => return Err(fail("input", format!("unknown KDF type {t}"))),
        })
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct AuthIn {
    salt: String,
    password: String,
    kdf: KdfIn,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct UnlockIn {
    password: Option<String>,
    user_key: Option<String>,
    #[serde(default)]
    pending: bool,
    /// Used only when the sync response carries no `userDecryption` (older servers).
    kdf: Option<KdfIn>,
}

#[derive(Deserialize)]
struct IdIn {
    id: String,
}

#[derive(Deserialize)]
struct PasswordIn {
    password: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PasskeysIn {
    rp_id: String,
    /// The request's allowCredentials; empty = any of the RP's passkeys.
    #[serde(default)]
    ids: Vec<Bytes>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Fido2In {
    /// "create" or "get".
    op: String,
    /// The requesting frame's origin as WebKit reports it, never as the page claims it.
    origin: String,
    /// `{"publicKey": …}` as the page passed it, byte fields base64url.
    request: Box<RawValue>,
    /// get: the passkey's item. create: the login to add the passkey to; none = a new login.
    cipher_id: Option<String>,
    /// The user passed Touch ID or the login password for this request.
    verified: bool,
}

/// Only the challenge, to build the client data the passkey client will sign over.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ChallengeIn {
    public_key: ChallengeOnly,
}

#[derive(Deserialize)]
struct ChallengeOnly {
    challenge: Bytes,
}

fn parse<'a, T: Deserialize<'a>>(input: &'a [u8]) -> Result<T, Fail> {
    serde_json::from_slice(input).map_err(|e| fail("input", e))
}

impl Session {
    fn new() -> Self {
        Session { client: Client::new(None), vault: None, pending: None, unlocked: false, kdf: None }
    }

    fn call(&mut self, method: &str, input: &[u8]) -> Out {
        match method {
            "authHash" => self.auth_hash(parse(input)?),
            "load" => self.load(input),
            "unlock" => self.unlock(parse(input)?),
            "index" => self.index(),
            "login" => self.login(parse(input)?),
            "verify" => self.verify(parse(input)?),
            "userKey" => self.user_key(),
            "passkeys" => self.passkeys(parse(input)?),
            "fido2" => self.fido2(parse(input)?),
            m => Err(fail("input", format!("unknown method {m}"))),
        }
    }

    /// Server authorization hash for the password grant; keeps the master key for `unlock`.
    fn auth_hash(&mut self, a: AuthIn) -> Out {
        let key = MasterKey::derive(&a.password, &a.salt, &a.kdf.kdf()?).map_err(|e| fail("crypto", e))?;
        let hash = key.derive_master_key_hash(a.password.as_bytes(), HashPurpose::ServerAuthorization);
        self.pending = Some(key);
        Ok(json!({ "hash": hash.to_string() }))
    }

    /// Takes a raw `/api/sync` body. Re-loading while unlocked swaps in the new ciphers.
    fn load(&mut self, body: &[u8]) -> Out {
        let sync: SyncIn = serde_json::from_slice(body).map_err(|e| fail("parse", e))?;
        let profile = sync.profile.ok_or_else(|| fail("parse", "sync has no profile"))?;
        let user_id = profile.id.map(UserId::new);
        if let Some(v) = &self.vault {
            if v.user_id != user_id {
                return Err(fail("input", "sync belongs to another account"));
            }
        }
        let private_key = || -> Result<WrappedAccountCryptographicState, Fail> {
            let pk = profile.private_key.as_deref().ok_or_else(|| fail("parse", "profile has no private key"))?;
            Ok(WrappedAccountCryptographicState::V1 { private_key: pk.parse().map_err(|e| fail("parse", e))? })
        };
        let account = match profile.account_keys.as_deref().map(WrappedAccountCryptographicState::try_from) {
            Some(Ok(state)) => state,
            _ => private_key()?,
        };
        let decryption = sync.user_decryption.as_deref();
        let unlock = decryption
            .and_then(|d| d.master_password_unlock.as_deref())
            .map(MasterPasswordUnlockData::try_from)
            .transpose()
            .map_err(|e| fail("parse", e))?;
        let upgrade = decryption
            .and_then(|d| d.v2_upgrade_token.as_deref())
            .map(V2UpgradeToken::try_from)
            .transpose()
            .map_err(|e| fail("parse", e))?;
        let orgs: HashMap<OrganizationId, UnsignedSharedKey> = profile
            .organizations
            .iter()
            .flatten()
            .filter_map(|o| Some((OrganizationId::new(o.id?), o.key.as_deref()?.parse().ok()?)))
            .collect();
        let mut ciphers = Vec::new();
        let mut by_id = HashMap::new();
        let mut skipped = 0usize;
        for raw in sync.ciphers.into_iter().flatten() {
            match serde_json::from_str::<CipherHead>(raw.get()) {
                Ok(CipherHead { id: Some(id), kind: Some(1), deleted: None, archived: None }) => {
                    by_id.insert(id.to_ascii_lowercase(), ciphers.len());
                    ciphers.push(Box::from(raw.get()));
                }
                Ok(_) => {}
                Err(_) => skipped += 1,
            }
        }
        let mut domains: Vec<Vec<String>> = Vec::new();
        if let Some(d) = sync.domains {
            domains.extend(d.equivalent_domains.into_iter().flatten());
            domains.extend(
                d.global_equivalent_domains
                    .into_iter()
                    .flatten()
                    .filter(|g| g.excluded != Some(true))
                    .filter_map(|g| g.domains),
            );
        }
        let premium = profile.premium == Some(true) || profile.premium_from_organization == Some(true);
        let email = profile.email.clone().unwrap_or_default();
        let out = json!({
            "userId": user_id.map(|u| u.to_string()),
            "email": email,
            "premium": premium,
            "logins": ciphers.len(),
            "skipped": skipped,
            "domains": domains,
        });
        let reinit_orgs = self.unlocked && self.vault.as_ref().is_some_and(|v| v.orgs != orgs);
        self.vault = Some(Vault {
            user_id,
            email,
            premium,
            unlock,
            account,
            upgrade,
            profile_key: profile.key.as_deref().and_then(|k| k.parse().ok()),
            orgs,
            ciphers,
            by_id,
        });
        if reinit_orgs {
            self.init_orgs()?;
        }
        Ok(out)
    }

    fn vault(&self) -> Result<&Vault, Fail> {
        self.vault.as_ref().ok_or_else(|| fail("input", "no vault loaded"))
    }

    fn unlocked_vault(&self) -> Result<&Vault, Fail> {
        if !self.unlocked {
            return Err(fail("locked", "vault is locked"));
        }
        self.vault()
    }

    /// The master-password unlock parameters: `userDecryption` when the server sends it, else
    /// the profile key, the email as salt and the caller's prelogin KDF.
    fn unlock_data(&self, kdf: Option<&KdfIn>) -> Result<MasterPasswordUnlockData, Fail> {
        let v = self.vault()?;
        if let Some(u) = &v.unlock {
            return Ok(u.clone());
        }
        Ok(MasterPasswordUnlockData {
            kdf: match kdf {
                Some(k) => k.kdf()?,
                None => self.kdf.clone().ok_or_else(|| fail("input", "KDF required"))?,
            },
            master_key_wrapped_user_key: v.profile_key.clone().ok_or_else(|| fail("parse", "profile has no key"))?,
            salt: v.email.trim().to_lowercase(),
            contained_key_id: None,
        })
    }

    fn unlock(&mut self, u: UnlockIn) -> Out {
        if self.unlocked {
            return Ok(json!({}));
        }
        let data = self.unlock_data(u.kdf.as_ref())?;
        let user_key = if let Some(key) = u.user_key {
            SymmetricCryptoKey::try_from(key).map_err(|e| fail("key", e))?
        } else {
            let master = match (u.pending, self.pending.take(), u.password) {
                (true, Some(key), _) => key,
                (_, _, Some(password)) => {
                    MasterKey::derive(&password, &data.salt, &data.kdf).map_err(|e| fail("crypto", e))?
                }
                _ => return Err(fail("input", "password required")),
            };
            master
                .decrypt_user_key(data.master_key_wrapped_user_key.clone())
                .map_err(|_| fail("wrongPassword", "wrong master password"))?
        };
        let kdf = data.kdf.clone();
        let v = self.vault()?;
        let request = InitUserCryptoRequest {
            user_id: v.user_id,
            kdf_params: data.kdf,
            email: v.email.clone(),
            account_cryptographic_state: v.account.clone(),
            method: InitUserCryptoMethod::DecryptedKey { decrypted_user_key: user_key.to_base64().to_string() },
            upgrade_token: v.upgrade.clone(),
        };
        pollster::block_on(self.client.crypto().initialize_user_crypto(request)).map_err(|e| fail("crypto", e))?;
        self.unlocked = true;
        self.kdf = Some(kdf);
        self.init_orgs()?;
        Ok(json!({}))
    }

    fn init_orgs(&self) -> Result<(), Fail> {
        let orgs = self.vault()?.orgs.clone();
        if orgs.is_empty() {
            return Ok(());
        }
        pollster::block_on(self.client.crypto().initialize_org_crypto(InitOrgCryptoRequest { organization_keys: orgs }))
            .map_err(|e| fail("crypto", e))
    }

    /// The fill index: names, usernames and URIs only. TOTP seeds and passwords never leave.
    /// Parsed and decrypted 256 at a time, so peak memory stays flat as vaults grow.
    fn index(&self) -> Out {
        let v = self.unlocked_vault()?;
        let mut items: Vec<Value> = Vec::with_capacity(v.ciphers.len());
        let mut failed = 0usize;
        for chunk in v.ciphers.chunks(256) {
            let mut batch = Vec::with_capacity(chunk.len());
            for raw in chunk {
                match cipher(raw) {
                    Ok(c) => batch.push(c),
                    Err(_) => failed += 1,
                }
            }
            let result = pollster::block_on(self.client.vault().ciphers().decrypt_list_with_failures(batch));
            failed += result.failures.len();
            items.extend(result.successes.into_iter().filter_map(|c| {
                let CipherListViewType::Login(login) = c.r#type else { return None };
                let uris: Vec<Value> = login
                    .uris
                    .into_iter()
                    .flatten()
                    .filter_map(|u| Some(json!({ "uri": u.uri?, "match": u.r#match.map(|m| m as u8) })))
                    .collect();
                Some(json!({
                    "id": c.id?.to_string(),
                    "name": c.name,
                    "username": login.username.unwrap_or_default(),
                    "uris": uris,
                    "totp": login.totp.is_some() && (v.premium || c.organization_use_totp),
                    "reprompt": c.reprompt == CipherRepromptType::Password,
                    "passkey": login.has_fido2,
                }))
            }));
        }
        Ok(json!({ "items": items, "failed": failed }))
    }

    /// One login's credentials, decrypted on demand, plus its current TOTP code.
    fn login(&self, i: IdIn) -> Out {
        let v = self.unlocked_vault()?;
        let raw = v.by_id.get(&i.id.to_ascii_lowercase()).map(|&n| &v.ciphers[n]).ok_or_else(|| fail("notFound", "no such login"))?;
        let cipher = cipher(raw)?;
        let use_totp = v.premium || cipher.organization_use_totp;
        let view = pollster::block_on(self.client.vault().ciphers().decrypt(cipher)).map_err(|e| fail("crypto", e))?;
        let login = view.login.ok_or_else(|| fail("notFound", "not a login"))?;
        let totp = login
            .totp
            .filter(|_| use_totp)
            .and_then(|key| self.client.vault().totp().generate_totp(key, None).ok())
            .map(|t| json!({ "code": t.code, "period": t.period }));
        Ok(json!({
            "username": login.username.unwrap_or_default(),
            "password": login.password.unwrap_or_default(),
            "totp": totp,
        }))
    }

    /// Master password re-prompt: true when `password` unwraps the user key.
    fn verify(&self, p: PasswordIn) -> Out {
        self.unlocked_vault()?;
        let data = self.unlock_data(None)?;
        let master = MasterKey::derive(&p.password, &data.salt, &data.kdf).map_err(|e| fail("crypto", e))?;
        Ok(json!({ "ok": master.decrypt_user_key(data.master_key_wrapped_user_key).is_ok() }))
    }

    /// The user key, for the keychain-backed "remember unlock" option.
    fn user_key(&self) -> Out {
        self.unlocked_vault()?;
        let key = pollster::block_on(self.client.crypto().get_user_encryption_key()).map_err(|e| fail("crypto", e))?;
        Ok(json!({ "key": key.to_string() }))
    }

    /// The RP's passkeys (narrowed to `ids` when the request lists some), one row per item.
    fn passkeys(&self, p: PasskeysIn) -> Out {
        let v = self.unlocked_vault()?;
        let ids: Vec<Vec<u8>> = p.ids.into_iter().map(Into::into).collect();
        let found = pollster::block_on(passkey_ciphers(&self.client, v, &p.rp_id, Some(&ids)));
        let items: Vec<Value> = found
            .into_iter()
            .filter_map(|(_, c)| {
                let CipherListViewType::Login(login) = &c.r#type else { return None };
                let cred = login.fido2_credentials.iter().flatten().find(|f| f.rp_id.eq_ignore_ascii_case(&p.rp_id))?;
                let user = cred.user_name.clone().or_else(|| cred.user_display_name.clone()).or_else(|| login.username.clone());
                Some(json!({
                    "id": c.id?.to_string(),
                    "name": c.name,
                    "userName": user.unwrap_or_default(),
                    "reprompt": c.reprompt == CipherRepromptType::Password,
                }))
            })
            .collect();
        Ok(json!({ "items": items }))
    }

    /// One WebAuthn ceremony through the SDK's passkey client (origin and RP ID checks,
    /// signing), with the user's choices already made in angl's UI. Returns the credential for
    /// the page and, when the vault item changed (a new passkey, a counter bump), the request
    /// that saves it; the caller sends that to the server.
    fn fido2(&self, f: Fido2In) -> Out {
        let v = self.unlocked_vault()?;
        let create = match f.op.as_str() {
            "create" => true,
            "get" => false,
            op => return Err(fail("input", format!("unknown op {op}"))),
        };
        let origin = url::Url::parse(&f.origin).map_err(|e| fail("input", e))?;
        let challenge: ChallengeIn = serde_json::from_str(f.request.get()).map_err(|e| fail("syntax", e))?;
        // The client data passkey-rs builds for this origin and challenge. The only web-shaped
        // mode the SDK offers takes the hash from the caller, so hash it here and check below
        // that the client returned these exact bytes.
        let client_data = CollectedClientData::<()> {
            ty: if create { ClientDataType::Create } else { ClientDataType::Get },
            challenge: base64url(&challenge.public_key.challenge),
            origin: origin.as_str().trim_end_matches('/').to_owned(),
            cross_origin: None,
            extra_data: (),
            unknown_keys: Default::default(),
        };
        let client_data_json = serde_json::to_vec(&client_data).map_err(|e| fail("input", e))?;
        let data = ClientData::DefaultWithCustomHash { hash: sha256(&client_data_json).to_vec() };
        let store = Store { client: &self.client, vault: v, saved: Mutex::new(None) };
        let ui = Ui {
            client: &self.client,
            vault: v,
            cipher_id: f.cipher_id.map(|id| id.to_ascii_lowercase()),
            origin: client_data.origin.clone(),
            verified: f.verified,
        };
        let fido2 = self.client.fido2();
        let mut client = fido2.create_client(&ui, &store);
        let web = Origin::Web(origin.to_string());
        let request = f.request.get().to_owned();
        let (credential, signed) = if create {
            let r = pollster::block_on(client.register(web, request, data)).map_err(webauthn_fail)?;
            let credential = json!({
                "id": r.id,
                "rawId": base64url(&r.raw_id),
                "type": r.ty,
                "authenticatorAttachment": r.authenticator_attachment,
                "clientExtensionResults": extension_results(r.client_extension_results.cred_props.and_then(|c| c.rk)),
                "response": {
                    "clientDataJSON": base64url(&r.response.client_data_json),
                    "attestationObject": base64url(&r.response.attestation_object),
                    "authenticatorData": base64url(&r.response.authenticator_data),
                    "publicKey": r.response.public_key.as_deref().map(base64url),
                    "publicKeyAlgorithm": r.response.public_key_algorithm,
                    "transports": r.response.transports,
                },
            });
            (credential, r.response.client_data_json)
        } else {
            let r = pollster::block_on(client.authenticate(web, request, data)).map_err(webauthn_fail)?;
            let credential = json!({
                "id": r.id,
                "rawId": base64url(&r.raw_id),
                "type": r.ty,
                "authenticatorAttachment": r.authenticator_attachment,
                "clientExtensionResults": extension_results(r.client_extension_results.cred_props.and_then(|c| c.rk)),
                "response": {
                    "clientDataJSON": base64url(&r.response.client_data_json),
                    "authenticatorData": base64url(&r.response.authenticator_data),
                    "signature": base64url(&r.response.signature),
                    "userHandle": base64url(&r.response.user_handle),
                },
            });
            (credential, r.response.client_data_json)
        };
        if signed != client_data_json {
            return Err(fail("internal", "passkey client data differs from what was signed"));
        }
        drop(client);
        let save = store.saved.into_inner().unwrap_or_else(|e| e.into_inner()).map(|ctx| {
            let id = ctx.cipher.id.map(|id| id.to_string());
            json!({ "cipherId": id, "request": CipherRequestModel::from(ctx) })
        });
        Ok(json!({ "credential": credential, "save": save }))
    }
}

fn extension_results(rk: Option<bool>) -> Value {
    match rk {
        Some(rk) => json!({ "credProps": { "rk": rk } }),
        None => json!({}),
    }
}

/// Error kinds Swift maps to the DOMException names WebAuthn specifies.
fn webauthn_fail(e: Fido2ClientError) -> Fail {
    use WebauthnError as W;
    let kind = match &e {
        // CTAP2_ERR_CREDENTIAL_EXCLUDED: the vault already holds one of excludeCredentials.
        Fido2ClientError::Webauthn(W::AuthenticatorError(0x19)) => "excluded",
        Fido2ClientError::Webauthn(
            W::OriginMissingDomain
            | W::OriginRpMissmatch
            | W::UnprotectedOrigin
            | W::InsecureLocalhostNotAllowed
            | W::InvalidRpId
            | W::RequiresRelatedOriginsSupport
            | W::ExceedsMaxLabelLimit,
        ) => "security",
        Fido2ClientError::Webauthn(W::NotSupportedError) => "notSupported",
        Fido2ClientError::InvalidOrigin(_) => "security",
        Fido2ClientError::Serde(_) | Fido2ClientError::Webauthn(W::SyntaxError | W::ValidationError) => "syntax",
        _ => "notAllowed",
    };
    fail(kind, e)
}

/// Logins holding a passkey for `rp_id` (and, when `ids` lists any, one of those credentials):
/// their index in `v.ciphers` and list view. Only items whose sync JSON carries passkeys are
/// decrypted, and of those only names and passkey metadata.
async fn passkey_ciphers(client: &Client, v: &Vault, rp_id: &str, ids: Option<&[Vec<u8>]>) -> Vec<(usize, CipherListView)> {
    #[derive(Deserialize)]
    struct Head {
        #[serde(alias = "Login")]
        login: Option<LoginHead>,
    }
    #[derive(Deserialize)]
    struct LoginHead {
        #[serde(rename = "fido2Credentials", alias = "Fido2Credentials")]
        fido2: Option<Vec<IgnoredAny>>,
    }
    let ids = ids.filter(|ids| !ids.is_empty());
    let wanted = |c: &CipherListView| {
        let CipherListViewType::Login(login) = &c.r#type else { return false };
        login.fido2_credentials.iter().flatten().any(|f| {
            f.rp_id.eq_ignore_ascii_case(rp_id)
                && ids.is_none_or(|ids| string_to_guid_bytes(&f.credential_id).is_ok_and(|id| ids.contains(&id)))
        })
    };
    let candidates: Vec<Cipher> = v
        .ciphers
        .iter()
        .filter(|raw| {
            serde_json::from_str::<Head>(raw).is_ok_and(|h| h.login.and_then(|l| l.fido2).is_some_and(|f| !f.is_empty()))
        })
        .filter_map(|raw| cipher(raw).ok())
        .collect();
    let result = client.vault().ciphers().decrypt_list_with_failures(candidates).await;
    result
        .successes
        .into_iter()
        .filter(wanted)
        .filter_map(|c| Some((*v.by_id.get(&c.id?.to_string())?, c)))
        .collect()
}

/// The vault as the SDK's authenticator sees it. A save is held for the caller to upload.
struct Store<'a> {
    client: &'a Client,
    vault: &'a Vault,
    saved: Mutex<Option<EncryptionContext>>,
}

fn callback_fail(e: impl std::fmt::Display) -> Fido2CallbackError {
    Fido2CallbackError::Unknown(e.to_string())
}

async fn decrypt(client: &Client, v: &Vault, n: usize) -> Result<CipherView, Fido2CallbackError> {
    let c = cipher(&v.ciphers[n]).map_err(|f| callback_fail(f.message))?;
    client.vault().ciphers().decrypt(c).await.map_err(callback_fail)
}

#[async_trait::async_trait]
impl Fido2CredentialStore for Store<'_> {
    async fn find_credentials(
        &self,
        ids: Option<Vec<Vec<u8>>>,
        rp_id: String,
        _user_handle: Option<Vec<u8>>,
    ) -> Result<Vec<CipherView>, Fido2CallbackError> {
        let mut views = Vec::new();
        for (n, _) in passkey_ciphers(self.client, self.vault, &rp_id, ids.as_deref()).await {
            views.push(decrypt(self.client, self.vault, n).await?);
        }
        Ok(views)
    }

    /// Only the OS credential-provider flows list everything; angl never asks.
    async fn all_credentials(&self) -> Result<Vec<CipherListView>, Fido2CallbackError> {
        Ok(Vec::new())
    }

    async fn save_credential(&self, cred: EncryptionContext) -> Result<(), Fido2CallbackError> {
        *self.saved.lock().unwrap_or_else(|e| e.into_inner()) = Some(cred);
        Ok(())
    }
}

/// angl's UI already ran: the picked item, and whether the user verified. Presence is the
/// click that started the ceremony.
struct Ui<'a> {
    client: &'a Client,
    vault: &'a Vault,
    cipher_id: Option<String>,
    origin: String,
    verified: bool,
}

impl Ui<'_> {
    fn result(&self) -> CheckUserResult {
        CheckUserResult { user_present: true, user_verified: self.verified }
    }
}

#[async_trait::async_trait]
impl Fido2UserInterface for Ui<'_> {
    async fn check_user<'a>(&self, _options: CheckUserOptions, _hint: UiHint<'a, CipherView>) -> Result<CheckUserResult, Fido2CallbackError> {
        Ok(self.result())
    }

    async fn pick_credential_for_authentication(&self, available: Vec<CipherView>) -> Result<CipherView, Fido2CallbackError> {
        let id = self.cipher_id.as_deref().ok_or(Fido2CallbackError::OperationCancelled)?;
        available
            .into_iter()
            .find(|c| c.id.is_some_and(|c| c.to_string() == id))
            .ok_or(Fido2CallbackError::OperationCancelled)
    }

    async fn check_user_and_pick_credential_for_creation(
        &self,
        _options: CheckUserOptions,
        new: Fido2CredentialNewView,
    ) -> Result<(CipherView, CheckUserResult), Fido2CallbackError> {
        let view = match &self.cipher_id {
            Some(id) => {
                let &n = self.vault.by_id.get(id).ok_or(Fido2CallbackError::OperationCancelled)?;
                let view = decrypt(self.client, self.vault, n).await?;
                // An item holds one passkey; never replace one.
                let taken = view.login.as_ref().is_none_or(|l| l.fido2_credentials.as_ref().is_some_and(|f| !f.is_empty()));
                if taken || !view.edit {
                    return Err(Fido2CallbackError::Unknown("that login can't take a passkey".into()));
                }
                view
            }
            None => new_login(&new, &self.origin),
        };
        Ok((view, self.result()))
    }

    fn is_verification_enabled(&self) -> bool {
        true
    }
}

/// A personal login for a passkey that goes in no existing item: named for the site, the
/// passkey's user name as username, the requesting origin as its URI.
fn new_login(new: &Fido2CredentialNewView, origin: &str) -> CipherView {
    let now = chrono::Utc::now();
    CipherView {
        id: None,
        organization_id: None,
        folder_id: None,
        collection_ids: Vec::new(),
        key: None,
        name: new.rp_name.clone().filter(|n| !n.trim().is_empty()).unwrap_or_else(|| new.rp_id.clone()),
        notes: None,
        r#type: CipherType::Login,
        login: Some(LoginView {
            username: new.user_name.clone(),
            password: None,
            password_revision_date: None,
            uris: Some(vec![LoginUriView { uri: Some(origin.to_owned()), r#match: None, uri_checksum: None }]),
            totp: None,
            autofill_on_page_load: None,
            fido2_credentials: None,
        }),
        identity: None,
        card: None,
        secure_note: None,
        ssh_key: None,
        bank_account: None,
        drivers_license: None,
        passport: None,
        favorite: false,
        reprompt: CipherRepromptType::None,
        organization_use_totp: false,
        edit: true,
        permissions: None,
        view_password: true,
        local_data: None,
        attachments: None,
        attachment_decryption_failures: None,
        fields: None,
        password_history: None,
        creation_date: now,
        deleted_date: None,
        revision_date: now,
        archived_date: None,
        partial: false,
    }
}

// MARK: C ABI

#[repr(C)]
pub struct AnglBwBuf {
    pub ptr: *mut u8,
    pub len: usize,
    pub cap: usize,
}

#[unsafe(no_mangle)]
pub extern "C" fn angl_bw_new() -> *mut Session {
    Box::into_raw(Box::new(Session::new()))
}

/// Drops the session and every key it holds.
///
/// # Safety
/// `session` comes from `angl_bw_new` and is not used afterwards.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn angl_bw_free(session: *mut Session) {
    if !session.is_null() {
        drop(unsafe { Box::from_raw(session) });
    }
}

/// # Safety
/// `session` from `angl_bw_new`, `method` a NUL-terminated string, `input` `len` readable bytes.
/// Not reentrant per session.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn angl_bw_call(session: *mut Session, method: *const c_char, input: *const u8, len: usize) -> AnglBwBuf {
    let result = catch_unwind(AssertUnwindSafe(|| {
        let session = unsafe { session.as_mut() }.ok_or_else(|| fail("input", "no session"))?;
        let method = unsafe { CStr::from_ptr(method) }.to_str().map_err(|e| fail("input", e))?;
        let input = if input.is_null() { &[][..] } else { unsafe { std::slice::from_raw_parts(input, len) } };
        session.call(method, input)
    }))
    .unwrap_or_else(|_| Err(fail("panic", "Bitwarden SDK panicked")));
    let value = match result {
        Ok(ok) => json!({ "ok": ok }),
        Err(f) => json!({ "error": { "kind": f.kind, "message": f.message } }),
    };
    let mut bytes = std::mem::ManuallyDrop::new(serde_json::to_vec(&value).unwrap_or_default());
    AnglBwBuf { ptr: bytes.as_mut_ptr(), len: bytes.len(), cap: bytes.capacity() }
}

/// # Safety
/// `buf` comes from `angl_bw_call` and is freed once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn angl_bw_buf_free(buf: AnglBwBuf) {
    if !buf.ptr.is_null() {
        drop(unsafe { Vec::from_raw_parts(buf.ptr, buf.len, buf.cap) });
    }
}

#[cfg(test)]
mod tests {
    use bitwarden_crypto::UserKey;
    use p256::{
        ecdsa::{Signature, VerifyingKey, signature::Verifier},
        pkcs8::DecodePublicKey,
    };

    use super::*;

    const EMAIL: &str = "passkeys@example.com";
    const PASSWORD: &str = "correct horse battery staple";
    const USER: &str = "8b4cfbd5-5f45-4b56-9b6b-6b1e2f0c1a11";

    /// A one-account sync body: the user key under the master key, an RSA key pair under the
    /// user key, and `ciphers` as the server lists them.
    fn sync(protected_key: &EncString, private_key: &EncString, ciphers: Vec<Value>) -> Value {
        json!({
            "profile": { "id": USER, "email": EMAIL, "key": protected_key.to_string(), "privateKey": private_key.to_string() },
            "ciphers": ciphers,
        })
    }

    fn call(s: &mut Session, method: &str, input: Value) -> Result<Value, String> {
        s.call(method, &serde_json::to_vec(&input).unwrap()).map_err(|f| format!("{}: {}", f.kind, f.message))
    }

    fn bytes(s: &Value) -> Vec<u8> {
        serde_json::from_value::<Bytes>(s.clone()).unwrap().into()
    }

    /// Register a passkey into a new login, list it back after a re-sync, sign in with it, and
    /// verify the assertion under the registered key over the client data the page receives.
    #[test]
    fn passkey_round_trip() {
        let kdf = Kdf::PBKDF2 { iterations: NonZeroU32::new(5_000).unwrap() };
        let master = MasterKey::derive(PASSWORD, EMAIL, &kdf).unwrap();
        let (user_key, protected_key) = master.make_user_key().unwrap();
        let private_key = UserKey::new(user_key.0.clone()).make_key_pair().unwrap().private;

        let mut s = Session::new();
        call(&mut s, "load", sync(&protected_key, &private_key, vec![])).unwrap();
        call(&mut s, "unlock", json!({ "password": PASSWORD, "kdf": { "type": 0, "iterations": 5_000 } })).unwrap();

        let origin = "https://login.example.com";
        let created = call(&mut s, "fido2", json!({
            "op": "create",
            "origin": origin,
            "verified": true,
            "request": { "publicKey": {
                "rp": { "id": "example.com", "name": "Example" },
                "user": { "id": base64url(b"user-1"), "name": "alice", "displayName": "Alice" },
                "challenge": base64url(b"create-challenge"),
                "pubKeyCredParams": [{ "type": "public-key", "alg": -7 }],
                "authenticatorSelection": { "residentKey": "required", "userVerification": "required" },
            } },
        }))
        .unwrap();
        let response = &created["credential"]["response"];
        let client_data: Value = serde_json::from_slice(&bytes(&response["clientDataJSON"])).unwrap();
        assert_eq!(client_data["type"], "webauthn.create");
        assert_eq!(client_data["origin"], origin);
        assert_eq!(client_data["challenge"], base64url(b"create-challenge"));
        let public_key = VerifyingKey::from_public_key_der(&bytes(&response["publicKey"])).unwrap();
        let save = &created["save"];
        assert!(save["cipherId"].is_null(), "saved as a new login");

        // The server's copy of the saved item, as the next sync lists it.
        let id = "0f8a3a4e-3f6d-4c1b-9a59-6d2b1f9e7c21";
        let now = "2026-11-04T12:00:00.000Z";
        let mut item = save["request"].clone();
        for (k, v) in [("id", json!(id)), ("object", json!("cipherDetails")), ("edit", json!(true)), ("viewPassword", json!(true)),
                       ("creationDate", json!(now)), ("revisionDate", json!(now))] {
            item[k] = v;
        }
        call(&mut s, "load", sync(&protected_key, &private_key, vec![item])).unwrap();

        let listed = call(&mut s, "passkeys", json!({ "rpId": "example.com" })).unwrap();
        assert_eq!(listed["items"], json!([{ "id": id, "name": "Example", "userName": "alice", "reprompt": false }]));
        let others = call(&mut s, "passkeys", json!({ "rpId": "example.com", "ids": [base64url(b"someone else")] })).unwrap();
        assert_eq!(others["items"], json!([]));
        let allowed = call(&mut s, "passkeys", json!({ "rpId": "example.com", "ids": [created["credential"]["rawId"]] })).unwrap();
        assert_eq!(allowed["items"].as_array().map(Vec::len), Some(1));

        let got = call(&mut s, "fido2", json!({
            "op": "get",
            "origin": origin,
            "verified": true,
            "cipherId": id,
            "request": { "publicKey": { "rpId": "example.com", "challenge": base64url(b"get-challenge"), "userVerification": "required" } },
        }))
        .unwrap();
        let response = &got["credential"]["response"];
        assert_eq!(got["credential"]["rawId"], created["credential"]["rawId"]);
        assert_eq!(bytes(&response["userHandle"]), b"user-1");
        let client_data_json = bytes(&response["clientDataJSON"]);
        let client_data: Value = serde_json::from_slice(&client_data_json).unwrap();
        assert_eq!(client_data["type"], "webauthn.get");
        assert_eq!(client_data["origin"], origin);
        assert_eq!(client_data["challenge"], base64url(b"get-challenge"));
        let mut signed = bytes(&response["authenticatorData"]);
        signed.extend_from_slice(&sha256(&client_data_json));
        let signature = Signature::from_der(&bytes(&response["signature"])).unwrap();
        public_key.verify(&signed, &signature).expect("the assertion verifies under the registered key");

        // A page can't claim an RP ID its origin doesn't belong to.
        let foreign = call(&mut s, "fido2", json!({
            "op": "get", "origin": "https://example.net", "verified": true, "cipherId": id,
            "request": { "publicKey": { "rpId": "example.com", "challenge": base64url(b"x") } },
        }));
        assert!(foreign.as_ref().is_err_and(|e| e.starts_with("security")), "{foreign:?}");
    }
}
