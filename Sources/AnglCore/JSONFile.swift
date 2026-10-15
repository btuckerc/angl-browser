import Foundation

/// JSON helpers shared by every file angl reads or writes.
public enum JSONFile {
    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    public static func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try decoder().decode(type, from: data)
    }

    /// Atomic write (temp file + rename), so editors watching the file and crashes never see half a file.
    public static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder().encode(value).write(to: url, options: .atomic)
    }

    /// Deep-merge `overlay` onto `base`: objects merge key by key, everything else replaces.
    /// Lets user files contain only the keys they change.
    public static func merge(_ base: Any, _ overlay: Any) -> Any {
        guard let b = base as? [String: Any], let o = overlay as? [String: Any] else { return overlay }
        var out = b
        for (k, v) in o where !k.hasPrefix("_") {
            out[k] = b[k].map { merge($0, v) } ?? v
        }
        return out
    }

    /// Decode `T` from a partial user file layered over `defaults`. Returns the defaults when
    /// the file is missing; throws with a readable message when it is malformed.
    public static func layered<T: Codable>(_ defaults: T, file: URL) throws -> T {
        guard let data = try? Data(contentsOf: file), !data.isEmpty else { return defaults }
        let user = try JSONSerialization.jsonObject(with: data)
        let base = try JSONSerialization.jsonObject(with: encoder().encode(defaults))
        let merged = try JSONSerialization.data(withJSONObject: merge(base, user))
        return try decoder().decode(T.self, from: merged)
    }
}
