import Foundation

public enum WorklogStoreError: LocalizedError, Sendable, Equatable {
    case invalidWebexConversationKind
    case missingWebexRoomID
    case invalidWebexAttachmentIdentifier
    case invalidWebexAttachmentIndex
    case attachmentOutsideWebexDirectory

    public var errorDescription: String? {
        switch self {
        case .invalidWebexConversationKind:
            return "Webex専用ストアにはWebex会話イベントだけを保存できます。"
        case .missingWebexRoomID:
            return "Webex会話にルームIDがありません。"
        case .invalidWebexAttachmentIdentifier:
            return "Webex添付ファイルのルームIDまたはメッセージIDが不正です。"
        case .invalidWebexAttachmentIndex:
            return "Webex添付ファイルの番号が不正です。"
        case .attachmentOutsideWebexDirectory:
            return "Webex添付ファイルの保存先が許可されたディレクトリ外です。"
        }
    }
}

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
        try makePrivateDirectory(webexDirectory)
        try makePrivateDirectory(webexAttachmentsDirectory)
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
        var files = try FileManager.default.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "jsonl" }
        files += try FileManager.default.contentsOfDirectory(
            at: webexDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "jsonl" }

        return try files.flatMap(readEvents)
            .filter { $0.timestamp >= start && $0.timestamp <= end }
            .sorted { $0.timestamp < $1.timestamp }
    }

    /// Atomically replaces all Webex room snapshots for one local calendar day.
    ///
    /// Webex conversations are kept outside the append-only worklog so an edit
    /// can replace the previous message text without leaving the stale body in
    /// the day's canonical Webex file.
    public func replaceWebexConversations(
        _ events: [WorklogEvent],
        on day: Date
    ) throws {
        try prepare()
        var eventByRoomID: [String: WorklogEvent] = [:]
        for event in events {
            guard event.kind == .webexConversation else {
                throw WorklogStoreError.invalidWebexConversationKind
            }
            guard let roomID = event.metadata["webex_room_id"]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !roomID.isEmpty else {
                throw WorklogStoreError.missingWebexRoomID
            }
            // The latest snapshot supplied for a room wins. This makes a retry
            // deterministic while preventing duplicate room/day records.
            eventByRoomID[roomID] = event
        }

        let url = webexLogFile(for: day)
        guard !eventByRoomID.isEmpty else {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            return
        }

        let snapshots = eventByRoomID.map { (roomID: $0.key, event: $0.value) }
            .sorted { lhs, rhs in
                if lhs.event.timestamp != rhs.event.timestamp {
                    return lhs.event.timestamp < rhs.event.timestamp
                }
                return lhs.roomID < rhs.roomID
            }
            .map(\.event)
        var data = Data()
        for event in snapshots {
            data.append(try encoder.encode(event))
            data.append(0x0A)
        }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Returns a deterministic private destination for a Webex attachment.
    /// Untrusted API identifiers and filenames are reduced to single safe path
    /// components with a stable hash, so they cannot traverse outside the store.
    public func webexAttachmentURL(
        on day: Date,
        roomID: String,
        messageID: String,
        filename: String? = nil,
        index: Int
    ) throws -> URL {
        let roomID = roomID.trimmingCharacters(in: .whitespacesAndNewlines)
        let messageID = messageID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !roomID.isEmpty, !messageID.isEmpty else {
            throw WorklogStoreError.invalidWebexAttachmentIdentifier
        }
        guard index >= 0 else {
            throw WorklogStoreError.invalidWebexAttachmentIndex
        }

        try prepare()
        let dayDirectory = webexAttachmentsDirectory.appendingPathComponent(
            Self.dayFormatter.string(from: day),
            isDirectory: true
        )
        let roomDirectory = dayDirectory.appendingPathComponent(
            Self.safePathComponent(roomID, fallback: "room"),
            isDirectory: true
        )
        let messageDirectory = roomDirectory.appendingPathComponent(
            Self.safePathComponent(messageID, fallback: "message"),
            isDirectory: true
        )
        try makePrivateDirectory(dayDirectory)
        try makePrivateDirectory(roomDirectory)
        try makePrivateDirectory(messageDirectory)

        let originalName = filename?.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedName = originalName.flatMap { $0.isEmpty ? nil : $0 } ?? "attachment"
        let requestedStem = (requestedName as NSString).deletingPathExtension
        let safeStem = Self.safePathComponent(
            requestedStem.isEmpty ? "attachment" : requestedStem,
            fallback: "attachment",
            maximumReadableCharacters: 72
        )
        var indexedName = String(format: "%04d", index) + "-" + safeStem
        if let pathExtension = Self.safeFilenameExtension(requestedName) {
            indexedName += ".\(pathExtension)"
        }
        return messageDirectory.appendingPathComponent(indexedName, isDirectory: false)
    }

    /// Applies the private file mode after the caller has downloaded an
    /// attachment. Refusing arbitrary URLs prevents this API from chmod'ing
    /// unrelated user files.
    public func finalizeWebexAttachment(at url: URL) throws {
        try prepare()
        let allowedRoot = webexAttachmentsDirectory
            .resolvingSymlinksInPath()
            .standardizedFileURL.path
        let candidate = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard candidate.hasPrefix(allowedRoot + "/") else {
            throw WorklogStoreError.attachmentOutsideWebexDirectory
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: candidate)
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

    public var webexDirectory: URL {
        rootDirectory.appendingPathComponent("webex", isDirectory: true)
    }

    public var webexAttachmentsDirectory: URL {
        rootDirectory.appendingPathComponent("webex-attachments", isDirectory: true)
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

    private func webexLogFile(for date: Date) -> URL {
        webexDirectory.appendingPathComponent("\(Self.dayFormatter.string(from: date)).jsonl")
    }

    private func makePrivateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private static func safePathComponent(
        _ value: String,
        fallback: String,
        maximumReadableCharacters: Int = 48
    ) -> String {
        var readable = ""
        var previousWasSeparator = false
        for scalar in value.unicodeScalars {
            let code = scalar.value
            let isAllowed = (48...57).contains(code) ||
                (65...90).contains(code) ||
                (97...122).contains(code) ||
                code == 45 || code == 46 || code == 95
            if isAllowed {
                readable.unicodeScalars.append(scalar)
                previousWasSeparator = false
            } else if !previousWasSeparator {
                readable.append("-")
                previousWasSeparator = true
            }
        }
        readable = String(readable.prefix(maximumReadableCharacters))
            .trimmingCharacters(in: CharacterSet(charactersIn: ".-_"))
        if readable.isEmpty { readable = fallback }
        return "\(readable)-\(stableHash(value))"
    }

    private static func stableHash(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }

    private static func safeFilenameExtension(_ value: String) -> String? {
        let pathExtension = (value as NSString).pathExtension.lowercased()
        guard !pathExtension.isEmpty, pathExtension.count <= 16 else { return nil }
        guard pathExtension.unicodeScalars.allSatisfy({ scalar in
            let code = scalar.value
            return (48...57).contains(code) ||
                (65...90).contains(code) ||
                (97...122).contains(code)
        }) else { return nil }
        return pathExtension
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
