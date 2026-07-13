import Foundation

public actor WorklogStore {
    public nonisolated let rootDirectory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(rootDirectory: URL? = nil) {
        self.rootDirectory = rootDirectory ?? Self.defaultRootDirectory
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    public static var defaultRootDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Desklog", isDirectory: true)
    }

    public func prepare() throws {
        try makePrivateDirectory(rootDirectory)
        try makePrivateDirectory(capturesDirectory)
        try makePrivateDirectory(summariesDirectory)
    }

    public func append(_ event: WorklogEvent) throws {
        try prepare()
        let url = logFile(for: event.timestamp)
        var data = try encoder.encode(event)
        data.append(0x0A)
        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: url, options: .atomic)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func events(from start: Date, to end: Date = Date()) throws -> [WorklogEvent] {
        try prepare()
        let files = try FileManager.default.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "jsonl" }

        return try files.flatMap(readEvents)
            .filter { $0.timestamp >= start && $0.timestamp <= end }
            .sorted { $0.timestamp < $1.timestamp }
    }

    public func captureURL(at date: Date) throws -> URL {
        try prepare()
        let dayDirectory = capturesDirectory.appendingPathComponent(Self.dayFormatter.string(from: date), isDirectory: true)
        try makePrivateDirectory(dayDirectory)
        let name = "\(Self.fileTimestampFormatter.string(from: date))-capture-\(UUID().uuidString.lowercased()).jpg"
        return dayDirectory.appendingPathComponent(name)
    }

    public func saveSummary(_ markdown: String, at date: Date = Date()) throws -> URL {
        try prepare()
        let url = summariesDirectory.appendingPathComponent("\(Self.fileTimestampFormatter.string(from: date)).md")
        try markdown.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }

    public var capturesDirectory: URL {
        rootDirectory.appendingPathComponent("captures", isDirectory: true)
    }

    public var summariesDirectory: URL {
        rootDirectory.appendingPathComponent("summaries", isDirectory: true)
    }

    private func readEvents(_ url: URL) throws -> [WorklogEvent] {
        let content = try String(contentsOf: url, encoding: .utf8)
        return content.split(separator: "\n").compactMap { line in
            try? decoder.decode(WorklogEvent.self, from: Data(line.utf8))
        }
    }

    private func logFile(for date: Date) -> URL {
        rootDirectory.appendingPathComponent("\(Self.dayFormatter.string(from: date)).jsonl")
    }

    private func makePrivateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let fileTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss-SSS"
        return formatter
    }()
}
