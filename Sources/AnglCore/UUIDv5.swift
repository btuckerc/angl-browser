import CryptoKit
import Foundation

extension UUID {
    /// Name-based UUID (RFC 9562 v5, SHA-1). Used to derive stable WKWebsiteDataStore
    /// identifiers from (profile, container) so profiles never share cookies.
    public static func v5(namespace: UUID, name: String) -> UUID {
        var bytes = withUnsafeBytes(of: namespace.uuid) { Array($0) }
        bytes.append(contentsOf: Array(name.utf8))
        var hash = Array(Insecure.SHA1.hash(data: bytes).prefix(16))
        hash[6] = (hash[6] & 0x0F) | 0x50
        hash[8] = (hash[8] & 0x3F) | 0x80
        return UUID(uuid: (hash[0], hash[1], hash[2], hash[3], hash[4], hash[5], hash[6], hash[7],
                           hash[8], hash[9], hash[10], hash[11], hash[12], hash[13], hash[14], hash[15]))
    }

    /// Fixed namespace for angl data stores.
    public static let anglNamespace = UUID(uuidString: "6A4E1C2B-7F0D-4C55-9B1E-0A2D3C4B5E6F")!

    /// The data-store identifier for a container in a profile.
    public static func dataStore(profile: String, container: UUID) -> UUID {
        v5(namespace: anglNamespace, name: "\(profile)/\(container.uuidString)")
    }
}
