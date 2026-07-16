import Foundation

/// All Webex messages collected for one space or direct-message room.
///
/// A batch is emitted only when the authenticated user authored at least one
/// message in the requested day. Once selected, it intentionally contains
/// every in-range message from every participant so the surrounding
/// conversation is not lost.
public struct WebexRoomMessageBatch: Codable, Sendable, Equatable {
    public let room: WebexRoom
    public let messages: [WebexMessage]

    public init(room: WebexRoom, messages: [WebexMessage]) {
        self.room = room
        self.messages = messages
    }
}

/// Local attachment paths grouped first by message ID, then by the remote
/// Webex file URL found in that message's `files` array.
public typealias WebexMessageAttachmentPaths = [String: [String: String]]

/// Pure selection and normalization for daily Webex conversations.
public enum WebexConversationBuilder {
    /// Selects rooms in their input order and keeps all participants' messages
    /// in the half-open `[start, end)` interval.
    public static func build(
        identity: WebexIdentity,
        rooms: [WebexRoom],
        messagesByRoom: [String: [WebexMessage]],
        start: Date,
        end: Date
    ) -> [WebexRoomMessageBatch] {
        guard start < end else { return [] }

        return rooms.compactMap { room in
            let messages = normalizedMessages(
                messagesByRoom[room.id] ?? [],
                roomID: room.id,
                start: start,
                end: end
            )
            guard messages.contains(where: { isAuthoredByIdentity($0, identity: identity) }) else {
                return nil
            }
            return WebexRoomMessageBatch(room: room, messages: messages)
        }
    }

    /// Convenience overload for API clients that accumulate a flat message
    /// array before the room-selection pass.
    public static func build(
        identity: WebexIdentity,
        rooms: [WebexRoom],
        messages: [WebexMessage],
        start: Date,
        end: Date
    ) -> [WebexRoomMessageBatch] {
        build(
            identity: identity,
            rooms: rooms,
            messagesByRoom: Dictionary(grouping: messages, by: \.roomId),
            start: start,
            end: end
        )
    }

    /// A Webex person ID is authoritative when both sides provide one. Email
    /// matching is a fallback for payloads that omit a person ID.
    public static func isAuthoredByIdentity(
        _ message: WebexMessage,
        identity: WebexIdentity
    ) -> Bool {
        let identityID = normalizedNonempty(identity.id)
        let messageID = normalizedNonempty(message.personId)
        if let identityID, let messageID {
            return identityID == messageID
        }

        guard let email = normalizedEmail(message.personEmail) else { return false }
        return identity.emails.contains { normalizedEmail($0) == email }
    }

    private static func normalizedMessages(
        _ messages: [WebexMessage],
        roomID: String,
        start: Date,
        end: Date
    ) -> [WebexMessage] {
        var byID: [String: WebexMessage] = [:]
        for message in messages where message.roomId == roomID
            && message.created >= start && message.created < end {
            guard let current = byID[message.id] else {
                byID[message.id] = message
                continue
            }
            if freshness(of: message) >= freshness(of: current) {
                byID[message.id] = message
            }
        }
        return byID.values.sorted(by: messageOrder)
    }

    private static func freshness(of message: WebexMessage) -> Date {
        message.updated ?? message.created
    }

    fileprivate static func messageOrder(_ lhs: WebexMessage, _ rhs: WebexMessage) -> Bool {
        if lhs.created != rhs.created { return lhs.created < rhs.created }
        return lhs.id < rhs.id
    }

    private static func normalizedNonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalizedEmail(_ value: String?) -> String? {
        normalizedNonempty(value)?.lowercased()
    }
}

/// Deterministic Markdown rendering for selected Webex conversations.
public enum WebexConversationFormatter {
    /// Formats parent messages chronologically and places every reply directly
    /// below its in-range root. Replies whose root is not available are kept
    /// under a synthetic out-of-range-parent heading.
    public static func format(
        _ batches: [WebexRoomMessageBatch],
        identity: WebexIdentity? = nil,
        attachmentLocalPaths: WebexMessageAttachmentPaths = [:],
        timeZone: TimeZone = .current
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm:ss"

        return batches.map { batch in
            format(
                batch,
                identity: identity,
                attachmentLocalPaths: attachmentLocalPaths,
                dateFormatter: formatter
            )
        }.joined(separator: "\n\n")
    }

    private static func format(
        _ batch: WebexRoomMessageBatch,
        identity: WebexIdentity?,
        attachmentLocalPaths: WebexMessageAttachmentPaths,
        dateFormatter: DateFormatter
    ) -> String {
        let messages = deduplicated(batch.messages)
        let byID = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
        var roots: [WebexMessage] = []
        var repliesByRoot: [String: [WebexMessage]] = [:]
        var orphansByMissingParent: [String: [WebexMessage]] = [:]

        for message in messages {
            guard normalizedParentID(message.parentId) != nil else {
                roots.append(message)
                continue
            }
            switch rootResolution(for: message, messagesByID: byID) {
            case .root(let rootID):
                repliesByRoot[rootID, default: []].append(message)
            case .missing(let parentID):
                orphansByMissingParent[parentID, default: []].append(message)
            }
        }

        roots.sort(by: WebexConversationBuilder.messageOrder)
        let roomTitle = normalizedRoomTitle(batch.room.title) ?? batch.room.id
        let roomKind = batch.room.type.lowercased() == "direct" ? "DM" : "スペース"
        var lines = ["## Webex \(roomKind): \(roomTitle)"]
        if let identity {
            lines.append("> 記録ユーザー（自分）: \(identityDescription(identity))")
        }

        for root in roots {
            append(
                root,
                indentation: "",
                to: &lines,
                identity: identity,
                attachmentLocalPaths: attachmentLocalPaths,
                dateFormatter: dateFormatter
            )
            for reply in (repliesByRoot[root.id] ?? []).sorted(
                by: WebexConversationBuilder.messageOrder
            ) {
                append(
                    reply,
                    indentation: "  ",
                    to: &lines,
                    identity: identity,
                    attachmentLocalPaths: attachmentLocalPaths,
                    dateFormatter: dateFormatter
                )
            }
        }

        let orphanGroups = orphansByMissingParent.sorted { lhs, rhs in
            let lhsFirst = lhs.value.min(by: WebexConversationBuilder.messageOrder)
            let rhsFirst = rhs.value.min(by: WebexConversationBuilder.messageOrder)
            if let lhsFirst, let rhsFirst, lhsFirst.created != rhsFirst.created {
                return lhsFirst.created < rhsFirst.created
            }
            return lhs.key < rhs.key
        }
        for (parentID, replies) in orphanGroups {
            lines.append("### 対象期間外の親: \(parentID)")
            for reply in replies.sorted(by: WebexConversationBuilder.messageOrder) {
                append(
                    reply,
                    indentation: "  ",
                    to: &lines,
                    identity: identity,
                    attachmentLocalPaths: attachmentLocalPaths,
                    dateFormatter: dateFormatter
                )
            }
        }

        return lines.joined(separator: "\n")
    }

    private enum RootResolution {
        case root(String)
        case missing(String)
    }

    private static func rootResolution(
        for message: WebexMessage,
        messagesByID: [String: WebexMessage]
    ) -> RootResolution {
        var visited = Set([message.id])
        var parentID = normalizedParentID(message.parentId) ?? message.id

        while let parent = messagesByID[parentID] {
            guard visited.insert(parentID).inserted else {
                return .missing(parentID)
            }
            guard let next = normalizedParentID(parent.parentId) else {
                return .root(parent.id)
            }
            parentID = next
        }
        return .missing(parentID)
    }

    private static func deduplicated(_ messages: [WebexMessage]) -> [WebexMessage] {
        var byID: [String: WebexMessage] = [:]
        for message in messages {
            guard let current = byID[message.id] else {
                byID[message.id] = message
                continue
            }
            if (message.updated ?? message.created) >= (current.updated ?? current.created) {
                byID[message.id] = message
            }
        }
        return byID.values.sorted(by: WebexConversationBuilder.messageOrder)
    }

    private static func append(
        _ message: WebexMessage,
        indentation: String,
        to lines: inout [String],
        identity: WebexIdentity?,
        attachmentLocalPaths: WebexMessageAttachmentPaths,
        dateFormatter: DateFormatter
    ) {
        let author: String
        if let identity,
           WebexConversationBuilder.isAuthoredByIdentity(message, identity: identity) {
            author = "自分（\(identityDescription(identity))）"
        } else {
            author = displayAuthor(message)
        }
        let body = displayBody(message)
        let bodyLines = body.split(separator: "\n", omittingEmptySubsequences: false)
        let timestamp = dateFormatter.string(from: message.created)
        lines.append("\(indentation)- [\(timestamp)] \(author): \(bodyLines.first ?? "")")
        for continuation in bodyLines.dropFirst() {
            lines.append("\(indentation)  \(continuation)")
        }

        let paths = attachmentLocalPaths[message.id] ?? [:]
        for file in message.files {
            guard let path = paths[file.absoluteString] else { continue }
            let name = URL(fileURLWithPath: path).lastPathComponent
            lines.append("\(indentation)  - 添付: [\(name)](<\(escapedLinkPath(path))>)")
        }
    }

    private static func displayBody(_ message: WebexMessage) -> String {
        for candidate in [message.markdown, message.text] {
            let value = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !value.isEmpty { return value }
        }
        return message.files.isEmpty ? "（本文なし）" : "（添付ファイル）"
    }

    private static func displayAuthor(_ message: WebexMessage) -> String {
        for candidate in [message.personEmail, message.personId] {
            let value = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !value.isEmpty { return value }
        }
        return "不明なユーザ"
    }

    private static func identityDescription(_ identity: WebexIdentity) -> String {
        let displayName = singleLine(identity.displayName)
        let email = identity.emails.lazy.compactMap(singleLine).first
        switch (displayName, email) {
        case let (displayName?, email?):
            return "\(displayName) <\(email)>"
        case let (displayName?, nil):
            return displayName
        case let (nil, email?):
            return email
        case (nil, nil):
            return singleLine(identity.id) ?? "不明なWebexユーザー"
        }
    }

    private static func singleLine(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return normalized.isEmpty ? nil : normalized
    }

    private static func normalizedParentID(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalizedRoomTitle(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func escapedLinkPath(_ path: String) -> String {
        path.replacingOccurrences(of: ">", with: "%3E")
    }
}
