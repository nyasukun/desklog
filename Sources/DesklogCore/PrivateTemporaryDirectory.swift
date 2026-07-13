import Foundation

/// Creates and maintains an app-owned temporary directory for sensitive,
/// short-lived processing files.
public enum PrivateTemporaryDirectory {
    public static func prepare(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: url.path
        )
    }

    /// Removes leftovers from an interrupted prior run. The caller chooses an
    /// age that cannot overlap its active work; Desklog performs this at launch.
    @discardableResult
    public static func removeFiles(
        in url: URL,
        olderThan maximumAge: TimeInterval,
        now: Date = Date()
    ) throws -> Int {
        try prepare(at: url)
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey]
        let files = try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )
        var removed = 0
        for file in files {
            let values = try file.resourceValues(forKeys: keys)
            guard values.isRegularFile == true else { continue }
            let modifiedAt = values.contentModificationDate ?? .distantPast
            guard now.timeIntervalSince(modifiedAt) >= max(0, maximumAge) else { continue }
            try FileManager.default.removeItem(at: file)
            removed += 1
        }
        return removed
    }
}
