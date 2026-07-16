import DesklogCore
import Foundation
import Testing

@Suite struct WebexConversationTests {
    private let start = Date(timeIntervalSince1970: 1_000)
    private let end = Date(timeIntervalSince1970: 2_000)

    @Test func selectsGroupAndDirectRoomsWithSelfPostsAndRetainsEveryone() throws {
        let identity = WebexIdentity(
            id: "person-me",
            emails: ["Me@Example.com"],
            displayName: "Me"
        )
        let group = WebexRoom(id: "group", title: "Project", type: "group")
        let direct = WebexRoom(id: "direct", title: "Teammate", type: "direct")
        let unrelated = WebexRoom(id: "other", title: "Other", type: "group")
        let messages: [WebexMessage] = [
            message(id: "other-before-self", roomID: group.id, personID: "other", at: 1_100),
            message(id: "self-by-id", roomID: group.id, personID: identity.id, at: 1_200),
            message(
                id: "self-by-email",
                roomID: direct.id,
                personID: nil,
                email: "me@example.COM",
                at: 1_300,
                text: nil,
                files: [URL(string: "https://webexapis.com/v1/contents/file")!]
            ),
            message(id: "other-only", roomID: unrelated.id, personID: "other", at: 1_400),
            message(id: "at-end", roomID: group.id, personID: "other", at: 2_000),
            message(id: "before-start", roomID: group.id, personID: "other", at: 999)
        ]

        let batches = WebexConversationBuilder.build(
            identity: identity,
            rooms: [group, direct, unrelated],
            messages: messages,
            start: start,
            end: end
        )

        #expect(batches.map(\.room.id) == ["group", "direct"])
        #expect(batches[0].messages.map(\.id) == ["other-before-self", "self-by-id"])
        #expect(batches[1].messages.map(\.id) == ["self-by-email"])
        #expect(batches[1].messages[0].text == nil)
        #expect(batches[1].messages[0].files.count == 1)
    }

    @Test func personIDIsAuthoritativeBeforeEmailFallback() {
        let identity = WebexIdentity(id: "person-me", emails: ["me@example.com"])
        let room = WebexRoom(id: "room", title: "Room", type: "group")
        let spoofedEmail = message(
            id: "mismatch",
            roomID: room.id,
            personID: "someone-else",
            email: "me@example.com",
            at: 1_100
        )

        let batches = WebexConversationBuilder.build(
            identity: identity,
            rooms: [room],
            messages: [spoofedEmail],
            start: start,
            end: end
        )

        #expect(batches.isEmpty)
    }

    @Test func latestEditedDuplicateWinsWithoutChangingCreationOrder() throws {
        let identity = WebexIdentity(id: "me", emails: [])
        let room = WebexRoom(id: "room", title: "Room", type: "group")
        let original = message(id: "same", roomID: room.id, personID: "me", at: 1_100, text: "old")
        let edited = message(
            id: "same",
            roomID: room.id,
            personID: "me",
            at: 1_100,
            updatedAt: 1_500,
            text: "new"
        )

        let batches = WebexConversationBuilder.build(
            identity: identity,
            rooms: [room],
            messages: [original, edited],
            start: start,
            end: end
        )

        #expect(try #require(batches.first).messages.map(\.text) == ["new"])
    }

    @Test func repliesRenderDirectlyUnderTheirRootInCreatedOrder() throws {
        let room = WebexRoom(id: "group", title: "Project", type: "group")
        let root = message(id: "root", roomID: room.id, personID: "a", at: 1_100, text: "Root")
        let replyLate = message(
            id: "reply-late",
            roomID: room.id,
            personID: "b",
            at: 1_400,
            text: "Late",
            parentID: root.id
        )
        let replyEarly = message(
            id: "reply-early",
            roomID: room.id,
            personID: "c",
            at: 1_200,
            text: "Early",
            parentID: root.id
        )
        let secondRoot = message(
            id: "root-2",
            roomID: room.id,
            personID: "d",
            at: 1_300,
            text: "Second root"
        )
        let batch = WebexRoomMessageBatch(
            room: room,
            messages: [replyLate, secondRoot, replyEarly, root]
        )

        let output = WebexConversationFormatter.format(
            [batch],
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
        let rootRange = try #require(output.range(of: "a: Root"))
        let earlyRange = try #require(output.range(of: "c: Early"))
        let lateRange = try #require(output.range(of: "b: Late"))
        let secondRootRange = try #require(output.range(of: "d: Second root"))

        #expect(rootRange.lowerBound < earlyRange.lowerBound)
        #expect(earlyRange.lowerBound < lateRange.lowerBound)
        #expect(lateRange.lowerBound < secondRootRange.lowerBound)
        #expect(output.contains("\n  - ["))
    }

    @Test func formatterIdentifiesTheAuthenticatedUserInEveryConversation() {
        let room = WebexRoom(id: "group", title: "Project", type: "group")
        let message = message(
            id: "self-message",
            roomID: room.id,
            personID: "person-me",
            at: 1_100,
            text: "Status update"
        )
        let identity = WebexIdentity(
            id: "person-me",
            emails: ["me@example.com"],
            displayName: "Desklog User"
        )

        let output = WebexConversationFormatter.format(
            [WebexRoomMessageBatch(room: room, messages: [message])],
            identity: identity,
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        #expect(output.contains("> 記録ユーザー（自分）: Desklog User <me@example.com>"))
        #expect(output.contains("自分（Desklog User <me@example.com>）: Status update"))
    }

    @Test func formatterFallsBackToTheWebexPersonIDForIdentity() {
        let room = WebexRoom(id: "dm", title: "Teammate", type: "direct")
        let identity = WebexIdentity(id: "person-id-only", emails: [])

        let output = WebexConversationFormatter.format(
            [WebexRoomMessageBatch(room: room, messages: [])],
            identity: identity,
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        #expect(output.contains("> 記録ユーザー（自分）: person-id-only"))
    }

    @Test func orphanRepliesAndDownloadedAttachmentsAreNeverDropped() throws {
        let identity = WebexIdentity(id: "me", emails: [])
        let room = WebexRoom(id: "dm", title: "Teammate", type: "direct")
        let remote = "https://webexapis.com/v1/contents/file-1"
        let local = "/tmp/Webex Attachments/design draft.pdf"
        let orphan = message(
            id: "orphan",
            roomID: room.id,
            personID: "me",
            at: 1_200,
            text: nil,
            files: [URL(string: remote)!],
            parentID: "parent-from-yesterday"
        )
        let batch = WebexRoomMessageBatch(room: room, messages: [orphan])

        let output = WebexConversationFormatter.format(
            [batch],
            identity: identity,
            attachmentLocalPaths: [orphan.id: [remote: local]],
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        #expect(output.contains("## Webex DM: Teammate"))
        #expect(output.contains("### 対象期間外の親: parent-from-yesterday"))
        #expect(output.contains("自分（me）: （添付ファイル）"))
        #expect(output.contains("  - 添付: [design draft.pdf](</tmp/Webex Attachments/design draft.pdf>)"))
        let bodyRange = try #require(output.range(of: "自分（me）: （添付ファイル）"))
        let attachmentRange = try #require(output.range(of: "添付: [design draft.pdf]"))
        #expect(bodyRange.lowerBound < attachmentRange.lowerBound)
    }

    private func message(
        id: String,
        roomID: String,
        personID: String?,
        email: String? = nil,
        at timestamp: TimeInterval,
        updatedAt: TimeInterval? = nil,
        text: String? = "message",
        files: [URL] = [],
        parentID: String? = nil
    ) -> WebexMessage {
        WebexMessage(
            id: id,
            roomId: roomID,
            roomType: nil,
            text: text,
            markdown: nil,
            html: nil,
            personId: personID,
            personEmail: email,
            created: Date(timeIntervalSince1970: timestamp),
            updated: updatedAt.map(Date.init(timeIntervalSince1970:)),
            parentId: parentID,
            files: files
        )
    }
}
