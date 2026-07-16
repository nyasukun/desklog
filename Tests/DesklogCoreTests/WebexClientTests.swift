import DesklogCore
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing

@Suite(.serialized) struct WebexClientTests {
    @Test func identityUsesAuthoritativePersonIDBeforeEmailFallback() {
        let identity = WebexIdentity(id: "me", emails: ["Me@Example.com"])
        let mismatch = message(
            id: "mismatch",
            personID: "someone-else",
            email: "me@example.com"
        )
        let missingID = message(id: "fallback", personID: nil, email: "me@example.COM")

        #expect(!identity.authored(mismatch))
        #expect(identity.authored(missingID))
    }

    @Test func roomsUseOnlyMostRecentPageAndIgnoreLinkHeader() async throws {
        StubWebexURLProtocol.install { request in
            let url = try #require(request.url)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token")
            #expect(url.host == "webexapis.com")
            #expect(url.path == "/v1/rooms")
            #expect(url.query == "sortBy=lastactivity&max=100")
            return .json(
                #"{"items":[{"id":"room-1","title":"Old title","type":"group","lastActivity":"2026-07-15T01:00:00.000Z"},{"id":"room-1","title":"Current title","type":"group","lastActivity":"2026-07-15T02:00:00Z"},{"id":"room-2","title":"Direct","type":"direct","lastActivity":"2026-07-15T03:00:00Z"}]}"#,
                headers: ["Link": "<https://attacker.example/collect>; rel=\"next\""]
            )
        }
        let client = makeClient()

        let rooms = try await client.listRooms()

        #expect(rooms.map(\.id) == ["room-1", "room-2"])
        #expect(rooms.first?.title == "Current title")
        #expect(StubWebexURLProtocol.requests.count == 1)
    }

    @Test func messagesPageBackwardByOldestCreatedAndLatestEditWins() async throws {
        StubWebexURLProtocol.install { request in
            let url = try #require(request.url)
            #expect(queryValue("roomId", in: url) == "room-1")
            #expect(queryValue("max", in: url) == "100")
            switch try timestamp(queryValue("before", in: url)) {
            case Date(timeIntervalSince1970: 2_000):
                return .json(
                    #"{"items":[{"id":"m2","roomId":"room-1","text":"old","personId":"me","created":"1970-01-01T00:25:00.000Z"},{"id":"m2","roomId":"room-1","text":"edited","personId":"me","created":"1970-01-01T00:25:00Z","updated":"1970-01-01T00:30:00.000Z"},{"id":"m1","roomId":"room-1","text":"first","personId":"other","created":"1970-01-01T00:20:00Z"}]}"#,
                    headers: ["Link": "<https://attacker.example/collect>; rel=\"next\""]
                )
            case Date(timeIntervalSince1970: 1_200):
                return .json(
                    #"{"items":[{"id":"m0","roomId":"room-1","text":"earlier","personId":"other","created":"1970-01-01T00:18:20Z"},{"id":"foreign","roomId":"room-2","text":"ignore","created":"1970-01-01T00:18:00Z"},{"id":"too-old","roomId":"room-1","text":"ignore","created":"1970-01-01T00:15:00Z"}]}"#
                )
            default:
                Issue.record("Unexpected messages URL: \(url)")
                return .json(#"{"items":[]}"#)
            }
        }
        let client = makeClient()

        let messages = try await client.listMessages(
            roomID: "room-1",
            from: Date(timeIntervalSince1970: 1_000),
            before: Date(timeIntervalSince1970: 2_000)
        )

        #expect(messages.map(\.id) == ["m0", "m1", "m2"])
        #expect(messages.last?.text == "edited")
        #expect(messages.last?.files == [])
        #expect(StubWebexURLProtocol.requests.count == 2)
    }

    @Test func getMessageDecodesTextOnlyPayloadWithoutFiles() async throws {
        StubWebexURLProtocol.install { request in
            #expect(request.url?.path == "/v1/messages/message-id")
            return .json(
                #"{"id":"message-id","roomId":"room-id","text":"hello","created":"2026-07-15T01:02:03.456Z"}"#
            )
        }

        let result = try await makeClient().getMessage(id: "message-id")

        #expect(result.text == "hello")
        #expect(result.files.isEmpty)
    }

    @Test func untrustedAPIRedirectIsRejectedBeforeTokenCanLeaveWebex() async throws {
        StubWebexURLProtocol.install { _ in
            .init(
                statusCode: 302,
                body: Data(),
                headers: ["Location": "https://attacker.example/collect"]
            )
        }

        do {
            _ = try await makeClient().currentUser()
            Issue.record("An untrusted API redirect was accepted")
        } catch WebexAPIError.unsafePaginationURL(let url) {
            #expect(url.host == "attacker.example")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(StubWebexURLProtocol.requests.count == 1)
    }

    @Test func stalledMessageBoundaryStopsAsTypedPaginationLoop() async throws {
        StubWebexURLProtocol.install { request in
            let url = try #require(request.url)
            let boundary = try timestamp(queryValue("before", in: url))
            #expect(
                boundary == Date(timeIntervalSince1970: 2_000) ||
                    boundary == Date(timeIntervalSince1970: 1_500)
            )
            return .json(
                #"{"items":[{"id":"same","roomId":"room-1","text":"same","created":"1970-01-01T00:25:00Z"}]}"#
            )
        }

        do {
            _ = try await makeClient().listMessages(
                roomID: "room-1",
                before: Date(timeIntervalSince1970: 2_000)
            )
            Issue.record("A stalled message page boundary was accepted")
        } catch WebexAPIError.paginationLoop(let url) {
            #expect(queryValue("before", in: url) != nil)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(StubWebexURLProtocol.requests.count == 2)
    }

    @Test func messagePagingStopsAfterTwentyPages() async throws {
        StubWebexURLProtocol.install { request in
            let page = StubWebexURLProtocol.requests.count
            let url = try #require(request.url)
            if page == 1 {
                #expect(queryValue("before", in: url) == nil)
            } else {
                let expectedBoundary = Date(timeIntervalSince1970: TimeInterval(10_100 - page * 100))
                #expect(try timestamp(queryValue("before", in: url)) == expectedBoundary)
            }
            let created = webexTimestamp(
                Date(timeIntervalSince1970: TimeInterval(10_000 - page * 100))
            )
            return .json(
                "{\"items\":[{\"id\":\"m\(page)\",\"roomId\":\"room-1\",\"text\":\"page\",\"created\":\"\(created)\"}]}"
            )
        }

        let messages = try await makeClient().listMessages(roomID: "room-1")

        #expect(messages.count == 20)
        #expect(StubWebexURLProtocol.requests.count == 20)
    }

    @Test func trustedWebexAPIHostsCanRedirectBetweenEachOther() async throws {
        StubWebexURLProtocol.install { request in
            let url = try #require(request.url)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token")
            switch url.host {
            case "webexapis.com":
                return .init(
                    statusCode: 302,
                    body: Data(),
                    headers: [
                        "Location": "https://integration.webexapis.com/v1/people/me"
                    ]
                )
            case "integration.webexapis.com":
                return .init(
                    statusCode: 307,
                    body: Data(),
                    headers: ["Location": "https://api.ciscospark.com/v1/people/me"]
                )
            case "api.ciscospark.com":
                return .json(#"{"id":"me","emails":["me@example.com"]}"#)
            default:
                Issue.record("Unexpected redirect host: \(url.host ?? "nil")")
                return .json(#"{}"#, statusCode: 500)
            }
        }

        let identity = try await makeClient().currentUser()

        #expect(identity.id == "me")
        #expect(StubWebexURLProtocol.requests.map { $0.url?.host } == [
            "webexapis.com",
            "integration.webexapis.com",
            "api.ciscospark.com"
        ])
    }

    @Test func trustedAttachmentHostsCanRedirectBetweenEachOther() async throws {
        StubWebexURLProtocol.install { request in
            let url = try #require(request.url)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token")
            switch url.host {
            case "files.webexapis.com":
                return .init(
                    statusCode: 302,
                    body: Data(),
                    headers: ["Location": "https://api.ciscospark.com/v1/contents/file"]
                )
            case "api.ciscospark.com":
                return .init(statusCode: 200, body: Data("attachment".utf8), headers: [:])
            default:
                Issue.record("Unexpected attachment host: \(url.host ?? "nil")")
                return .init(statusCode: 500, body: Data(), headers: [:])
            }
        }

        let data = try await makeClient().downloadAttachment(
            from: URL(string: "https://files.webexapis.com/v1/contents/file")!
        )

        #expect(data == Data("attachment".utf8))
        #expect(StubWebexURLProtocol.requests.count == 2)
    }

    @Test func untrustedAttachmentRedirectIsRejectedBeforeTokenCanLeaveWebex() async throws {
        StubWebexURLProtocol.install { _ in
            .init(
                statusCode: 302,
                body: Data(),
                headers: ["Location": "https://attacker.example/attachment"]
            )
        }

        do {
            _ = try await makeClient().downloadAttachment(
                from: URL(string: "https://files.webexapis.com/v1/contents/file")!
            )
            Issue.record("An untrusted attachment redirect was accepted")
        } catch WebexAPIError.unsafeAttachmentURL(let url) {
            #expect(url.host == "attacker.example")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(StubWebexURLProtocol.requests.count == 1)
    }

    @Test func trustedHostRedirectOutsideV1IsRejectedForAPI() async throws {
        StubWebexURLProtocol.install { _ in
            .init(
                statusCode: 302,
                body: Data(),
                headers: ["Location": "https://api.ciscospark.com/not-v1/people/me"]
            )
        }

        do {
            _ = try await makeClient().currentUser()
            Issue.record("A Webex API redirect outside /v1 was accepted")
        } catch WebexAPIError.unsafePaginationURL(let url) {
            #expect(url.host == "api.ciscospark.com")
            #expect(url.path == "/not-v1/people/me")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(StubWebexURLProtocol.requests.count == 1)
    }

    @Test func baseAndAttachmentHostValidationRejectLookalikeAndPlainHTTPHosts() async throws {
        let rejected = [
            URL(string: "https://webexapis.com.attacker.example/v1/contents/file")!,
            URL(string: "https://fakewebexapis.com/v1/contents/file")!,
            URL(string: "https://api.ciscospark.com.attacker.example/v1/contents/file")!,
            URL(string: "https://sub.api.ciscospark.com/v1/contents/file")!,
            URL(string: "http://webexapis.com/v1/contents/file")!,
            URL(string: "https://user@webexapis.com/v1/contents/file")!
        ]
        for url in rejected {
            #expect(!WebexAPIClient.isAllowedAttachmentURL(url), "\(url)")
        }
        #expect(WebexAPIClient.isAllowedAttachmentURL(
            URL(string: "https://integration.webexapis.com/v1/contents/file")!
        ))
        #expect(WebexAPIClient.isAllowedAttachmentURL(
            URL(string: "https://api.ciscospark.com/v1/contents/file")!
        ))

        StubWebexURLProtocol.install { _ in
            Issue.record("An invalid base URL reached the network transport")
            return .json(#"{}"#)
        }
        do {
            _ = try await makeClient().downloadAttachment(
                from: URL(string: "https://attacker.example/secret")!
            )
            Issue.record("An untrusted attachment URL was accepted")
        } catch WebexAPIError.unsafeAttachmentURL(let url) {
            #expect(url.host == "attacker.example")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        for baseURL in [
            URL(string: "https://example.com/v1")!,
            URL(string: "https://webexapis.com/not-v1")!
        ] {
            let client = WebexAPIClient(
                accessToken: "token",
                baseURL: baseURL,
                sessionConfiguration: makeConfiguration()
            )
            do {
                _ = try await client.currentUser()
                Issue.record("An invalid API base URL was accepted: \(baseURL)")
            } catch WebexAPIError.invalidBaseURL {
                // Expected.
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
        }
        #expect(StubWebexURLProtocol.requests.isEmpty)
    }

    @Test func attachmentRetriesLockedResponseAndSavesPrivateSafeFile() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DesklogWebexClientTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        StubWebexURLProtocol.install { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token")
            if StubWebexURLProtocol.requests.count == 1 {
                return .init(statusCode: 423, body: Data(), headers: ["Retry-After": "0"])
            }
            return .init(
                statusCode: 200,
                body: Data("attachment-body".utf8),
                headers: ["Content-Disposition": "attachment; filename=\"../../secret.txt\""]
            )
        }
        let client = makeClient(retryPolicy: .init(
            maximumRetryCount: 2,
            baseDelay: 0,
            maximumDelay: 0
        ))

        let saved = try await client.downloadAttachment(
            from: URL(string: "https://webexapis.com/v1/contents/file")!,
            into: root
        )

        #expect(saved.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL)
        #expect(saved.lastPathComponent == ".._.._secret.txt")
        #expect(try Data(contentsOf: saved) == Data("attachment-body".utf8))
        let attributes = try FileManager.default.attributesOfItem(atPath: saved.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(StubWebexURLProtocol.requests.count == 2)
    }

    @Test func unscannableAttachmentIsForceDownloadedWhenExplicitlyAllowed() async throws {
        let remoteURL = URL(string: "https://webexapis.com/v1/contents/encrypted")!
        StubWebexURLProtocol.install { request in
            if queryValue("allow", in: try #require(request.url)) == "unscannable" {
                return .init(
                    statusCode: 200,
                    body: Data("encrypted-body".utf8),
                    headers: [:]
                )
            }
            return .json(
                #"{"message":"File cannot be scanned"}"#,
                statusCode: 428
            )
        }

        let data = try await makeClient().downloadAttachment(
            from: remoteURL,
            allowUnscannable: true
        )

        #expect(data == Data("encrypted-body".utf8))
        #expect(StubWebexURLProtocol.requests.count == 2)
        #expect(queryValue("allow", in: try #require(StubWebexURLProtocol.requests[0].url)) == nil)
        #expect(
            queryValue("allow", in: try #require(StubWebexURLProtocol.requests[1].url)) ==
                "unscannable"
        )
    }

    @Test func serverErrorsNeverExposeTheBearerToken() async throws {
        let token = "super-secret-token"
        StubWebexURLProtocol.install { _ in
            .json(
                #"{"message":"invalid super-secret-token; issue another super-secret-token"}"#,
                statusCode: 401
            )
        }
        let client = WebexAPIClient(
            accessToken: token,
            sessionConfiguration: makeConfiguration(),
            retryPolicy: .init(maximumRetryCount: 0)
        )

        do {
            _ = try await client.currentUser()
            Issue.record("An unauthorized response succeeded")
        } catch let error as WebexAPIError {
            #expect(!String(describing: error).contains(token))
            #expect(!(error.errorDescription ?? "").contains(token))
            #expect((error.errorDescription ?? "").contains("<redacted>"))
        }
    }

    private func makeClient(retryPolicy: WebexRetryPolicy = .init(maximumRetryCount: 0)) -> WebexAPIClient {
        WebexAPIClient(
            accessToken: "token",
            sessionConfiguration: makeConfiguration(),
            retryPolicy: retryPolicy
        )
    }

    private func makeConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubWebexURLProtocol.self]
        return configuration
    }

    private func message(
        id: String,
        personID: String?,
        email: String?
    ) -> WebexMessage {
        WebexMessage(
            id: id,
            roomId: "room",
            personId: personID,
            personEmail: email,
            created: Date(timeIntervalSince1970: 1_000)
        )
    }
}

private func queryValue(_ name: String, in url: URL) -> String? {
    URLComponents(url: url, resolvingAgainstBaseURL: false)?
        .queryItems?
        .first { $0.name == name }?
        .value
}

private func timestamp(_ value: String?) throws -> Date {
    let value = try #require(value)
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: value) { return date }
    let wholeSeconds = ISO8601DateFormatter()
    wholeSeconds.formatOptions = [.withInternetDateTime]
    return try #require(wholeSeconds.date(from: value))
}

private func webexTimestamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}

private final class StubWebexURLProtocol: URLProtocol {
    struct Stub {
        let statusCode: Int
        let body: Data
        let headers: [String: String]

        static func json(
            _ body: String,
            statusCode: Int = 200,
            headers: [String: String] = [:]
        ) -> Stub {
            var responseHeaders = headers
            responseHeaders["Content-Type"] = "application/json"
            return Stub(statusCode: statusCode, body: Data(body.utf8), headers: responseHeaders)
        }
    }

    private static let lock = NSLock()
    private static var handler: ((URLRequest) throws -> Stub)?
    private static var recordedRequests: [URLRequest] = []

    static var requests: [URLRequest] {
        lock.withLock { recordedRequests }
    }

    static func install(_ handler: @escaping (URLRequest) throws -> Stub) {
        lock.withLock {
            recordedRequests.removeAll()
            Self.handler = handler
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let handler = Self.lock.withLock { () -> ((URLRequest) throws -> Stub)? in
            Self.recordedRequests.append(request)
            return Self.handler
        }
        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        do {
            let stub = try handler(request)
            guard let url = request.url,
                  let response = HTTPURLResponse(
                    url: url,
                    statusCode: stub.statusCode,
                    httpVersion: "HTTP/1.1",
                    headerFields: stub.headers
                  ) else {
                throw URLError(.badServerResponse)
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: stub.body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
