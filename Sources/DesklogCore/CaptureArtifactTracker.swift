import Foundation

/// Tracks locally written screenshots until the matching worklog event has
/// been persisted. Cancelling between those two steps must not leave an
/// unreferenced image containing private screen content on disk.
public struct CaptureArtifactTracker: Sendable {
    public private(set) var unpersistedURLs: Set<URL>

    public init(urls: [URL]) {
        unpersistedURLs = Set(urls)
    }

    public mutating func markPersisted(_ url: URL?) {
        guard let url else { return }
        unpersistedURLs.remove(url)
    }

    public mutating func discardUnpersisted(fileManager: FileManager = .default) {
        let urls = unpersistedURLs
        unpersistedURLs.removeAll()
        for url in urls where fileManager.fileExists(atPath: url.path) {
            try? fileManager.removeItem(at: url)
        }
    }
}
