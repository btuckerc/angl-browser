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
};

use bitwarden_api_api::models::{CipherDetailsResponseModel, DomainsResponseModel, ProfileResponseModel, UserDecryptionResponseModel};
use bitwarden_core::{
    Client, OrganizationId, UserId,
    key_management::{
        MasterPasswordUnlockData, V2UpgradeToken,
        account_cryptographic_state::WrappedAccountCryptographicState,
        crypto::{InitOrgCryptoRequest, InitUserCryptoMethod, InitUserCryptoRequest},
    },
};
use bitwarden_crypto::{EncString, HashPurpose, Kdf, MasterKey, SymmetricCryptoKey, UnsignedSharedKey};
use bitwarden_vault::{Cipher, CipherListViewType, CipherRepromptType, VaultClientExt};
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
