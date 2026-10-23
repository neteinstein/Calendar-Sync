import Foundation

/// Hidden tag written at the end of every copy's notes. It ties a copy to the exact source
/// occurrence it came from, so matching never depends on title or start time.
///
/// Format: `calsync:v1:<source UUID>:<percent-encoded occurrence key>`
public struct CopyMarker: Hashable, Sendable {
    public static let prefix = "calsync:v1:"

    public var sourceID: UUID
    public var key: String

    public init(sourceID: UUID, key: String) {
        self.sourceID = sourceID
        self.key = key
    }

    private static let keyAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-_.")
        return set
    }()

    public var encoded: String {
        let key = key.addingPercentEncoding(withAllowedCharacters: Self.keyAllowed) ?? key
        return Self.prefix + sourceID.uuidString + ":" + key
    }

    /// Finds a marker anywhere in `notes`. Returns nil for events this app didn't create.
    public static func find(in notes: String?) -> CopyMarker? {
        guard let notes, let range = notes.range(of: prefix, options: .backwards) else { return nil }
        let rest = notes[range.upperBound...].prefix { !$0.isWhitespace }
        let parts = rest.split(separator: ":", maxSplits: 1)
        guard parts.count == 2,
              let sourceID = UUID(uuidString: String(parts[0])),
              let key = String(parts[1]).removingPercentEncoding,
              !key.isEmpty
        else { return nil }
        return CopyMarker(sourceID: sourceID, key: key)
    }

    public static func isCopy(_ notes: String?) -> Bool {
        notes?.contains(prefix) ?? false
    }
}
