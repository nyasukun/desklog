import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct WebexIdentity: Codable, Sendable, Equatable {
    public let id: String
    public let emails: [String]
    public let displayName: String?

    public init(id: String, emails: [String], displayName: String? = nil) {
        self.id = id
        self.emails = emails
        self.displayName = displayName
    }

    public func matches(personID: String?, email: String?) -> Bool {
        let identityID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let messageID = personID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !identityID.isEmpty, !messageID.isEmpty { return identityID == messageID }
        guard let email else { return false }
        let normalized = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !normalized.isEmpty && emails.contains {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalized
        }
    }

    public func authored(_ message: WebexMessage) -> Bool {
        matches(personID: message.personId, email: message.personEmail)
    }
}

public struct WebexRoom: Codable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let type: String
    public let lastActivity: Date?
    public let created: Date?

    public init(
        id: String,
        title: String,
        type: String,
        lastActivity: Date? = nil,
        created: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.type = type
        self.lastActivity = lastActivity
        self.created = created
    }
}

public struct WebexMessage: Codable, Sendable, Equatable {
    public let id: String
    public let roomId: String
    public let roomType: String?
    public let text: String?
    public let markdown: String?
    public let html: String?
    public let personId: String?
    public let personEmail: String?
    public let created: Date
    public let updated: Date?
    public let parentId: String?
    public let files: [URL]

    public init(
        id: String,
        roomId: String,
        roomType: String? = nil,
        text: String? = nil,
        markdown: String? = nil,
        html: String? = nil,
        personId: String? = nil,
        personEmail: String? = nil,
        created: Date,
        updated: Date? = nil,
        parentId: String? = nil,
        files: [URL] = []
    ) {
        self.id = id
        self.roomId = roomId
        self.roomType = roomType
        self.text = text
        self.markdown = markdown
        self.html = html
        self.personId = personId
        self.personEmail = personEmail
        self.created = created
        self.updated = updated
        self.parentId = parentId
        self.files = files
    }

    public var fileURLs: [URL] {
        files
    }

    private enum CodingKeys: String, CodingKey {
        case id, roomId, roomType, text, markdown, html, personId, personEmail
        case created, updated, parentId, files
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        roomId = try container.decode(String.self, forKey: .roomId)
        roomType = try container.decodeIfPresent(String.self, forKey: .roomType)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        markdown = try container.decodeIfPresent(String.self, forKey: .markdown)
        html = try container.decodeIfPresent(String.self, forKey: .html)
        personId = try container.decodeIfPresent(String.self, forKey: .personId)
        personEmail = try container.decodeIfPresent(String.self, forKey: .personEmail)
        created = try container.decode(Date.self, forKey: .created)
        updated = try container.decodeIfPresent(Date.self, forKey: .updated)
        parentId = try container.decodeIfPresent(String.self, forKey: .parentId)
        files = try container.decodeIfPresent([URL].self, forKey: .files) ?? []
    }
}

public struct WebexRetryPolicy: Sendable, Equatable {
    /// Number of additional attempts after the initial request.
    public let maximumRetryCount: Int
    public let baseDelay: TimeInterval
    public let maximumDelay: TimeInterval

    public init(
        maximumRetryCount: Int = 4,
        baseDelay: TimeInterval = 0.5,
        maximumDelay: TimeInterval = 30
    ) {
        self.maximumRetryCount = max(0, maximumRetryCount)
        self.baseDelay = max(0, baseDelay)
        self.maximumDelay = max(0, maximumDelay)
    }
}

public enum WebexAPIError: LocalizedError, Sendable, Equatable {
    case invalidAccessToken
    case invalidBaseURL(String)
    case invalidDateRange
    case invalidResponse
    case malformedResponse(String)
    case unauthorized(String?)
    case forbidden(String?)
    case rateLimited(retryAfter: TimeInterval?)
    case attachmentLocked(retryAfter: TimeInterval?)
    case attachmentUnavailable(statusCode: Int, message: String?)
    case attachmentRequiresUserConsent(String?)
    case httpStatus(statusCode: Int, message: String?)
    case transport(code: Int?, message: String)
    case unsafePaginationURL(URL)
    case unsafeAttachmentURL(URL)
    case paginationLoop(URL)
    case tooManyRedirects
    case invalidFileDestination(URL)
    case fileWriteFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidAccessToken:
            return "Webex access token is empty."
        case .invalidBaseURL(let value):
            return "The Webex API base URL is invalid: \(value)"
        case .invalidDateRange:
            return "The Webex message date range is invalid."
        case .invalidResponse:
            return "Webex returned a non-HTTP response."
        case .malformedResponse(let detail):
            return "The Webex response could not be decoded: \(detail)"
        case .unauthorized(let message):
            return message ?? "Webex authentication failed."
        case .forbidden(let message):
            return message ?? "Webex denied access to this resource."
        case .rateLimited(let retryAfter):
            return Self.retryDescription("Webex rate limited the request.", retryAfter: retryAfter)
        case .attachmentLocked(let retryAfter):
            return Self.retryDescription("The Webex attachment is still being scanned.", retryAfter: retryAfter)
        case .attachmentUnavailable(let statusCode, let message):
            return message ?? "The Webex attachment is unavailable (HTTP \(statusCode))."
        case .attachmentRequiresUserConsent(let message):
            return message ?? "The Webex attachment cannot be scanned and requires explicit user consent."
        case .httpStatus(let statusCode, let message):
            return message ?? "Webex returned HTTP \(statusCode)."
        case .transport(_, let message):
            return "The Webex request failed: \(message)"
        case .unsafePaginationURL(let url):
            return "Webex supplied an untrusted pagination URL host: \(Self.safeHost(url))"
        case .unsafeAttachmentURL(let url):
            return "The attachment URL is not hosted by Webex: \(Self.safeHost(url))"
        case .paginationLoop(let url):
            return "Webex pagination repeated a page on: \(Self.safeHost(url))"
        case .tooManyRedirects:
            return "The Webex request exceeded the redirect limit."
        case .invalidFileDestination(let url):
            return "The attachment destination is invalid: \(url.path)"
        case .fileWriteFailed(let detail):
            return "The Webex attachment could not be saved: \(detail)"
        }
    }

    private static func retryDescription(_ message: String, retryAfter: TimeInterval?) -> String {
        guard let retryAfter else { return message }
        return "\(message) Retry after \(retryAfter) seconds."
    }

    private static func safeHost(_ url: URL) -> String {
        url.host ?? "unknown host"
    }
}

/// Read-only Webex REST client used by the daily conversation collector.
///
/// Room discovery is intentionally limited to Webex's 100 most recently active
/// rooms. Message history is paged backwards with the oldest `created` value,
/// matching the access pattern used by the companion webex-agent project.
public actor WebexAPIClient {
    public static let defaultBaseURL = URL(string: "https://webexapis.com/v1")!
    public static let personalAccessTokenURL = URL(
        string: "https://developer.webex.com/docs/getting-your-personal-access-token"
    )!

    public nonisolated let baseURL: URL

    private let accessToken: String
    private let retryPolicy: WebexRetryPolicy
    private let session: URLSession
    private static let maximumMessagePageCount = 20

    public init(
        accessToken: String,
        baseURL: URL = WebexAPIClient.defaultBaseURL,
        sessionConfiguration: URLSessionConfiguration? = nil,
        retryPolicy: WebexRetryPolicy = .init()
    ) {
        self.accessToken = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        self.baseURL = baseURL
        self.retryPolicy = retryPolicy

        let configuration = sessionConfiguration ?? .ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(
            configuration: configuration,
            delegate: WebexNoRedirectDelegate.shared,
            delegateQueue: nil
        )
    }

    public init(
        accessToken: String,
        baseURL: String,
        sessionConfiguration: URLSessionConfiguration? = nil,
        retryPolicy: WebexRetryPolicy = .init()
    ) {
        self.init(
            accessToken: accessToken,
            baseURL: URL(string: baseURL) ?? URL(fileURLWithPath: baseURL),
            sessionConfiguration: sessionConfiguration,
            retryPolicy: retryPolicy
        )
    }

    public func currentUser() async throws -> WebexIdentity {
        let url = try endpoint(path: "people/me")
        let (data, response) = try await request(url, kind: .api)
        try validate(response: response, data: data, kind: .api)
        return try decode(WebexIdentity.self, from: data)
    }

    public func identity() async throws -> WebexIdentity {
        try await currentUser()
    }

    public func listRooms(
        type: String? = nil,
        activeSince: Date? = nil
    ) async throws -> [WebexRoom] {
        var query = [
            URLQueryItem(name: "sortBy", value: "lastactivity"),
            URLQueryItem(name: "max", value: "100")
        ]
        if let type, !type.isEmpty {
            query.append(URLQueryItem(name: "type", value: type))
        }
        let initialURL = try endpoint(path: "rooms", query: query)
        let (data, response) = try await request(initialURL, kind: .api)
        try validate(response: response, data: data, kind: .api)
        let rooms = try decode(WebexListResponse<WebexRoom>.self, from: data)
            .items
            .compactMap(\.value)

        var order: [String] = []
        var roomsByID: [String: WebexRoom] = [:]
        for room in rooms where !room.id.isEmpty {
            if let type, room.type.caseInsensitiveCompare(type) != .orderedSame { continue }
            if let activeSince {
                guard let lastActivity = room.lastActivity, lastActivity >= activeSince else { continue }
            }
            if let existing = roomsByID[room.id] {
                if Self.roomVersion(room) > Self.roomVersion(existing) {
                    roomsByID[room.id] = room
                }
            } else {
                order.append(room.id)
                roomsByID[room.id] = room
            }
        }
        return order.compactMap { roomsByID[$0] }
    }

    public func rooms(
        type: String? = nil,
        activeSince: Date? = nil
    ) async throws -> [WebexRoom] {
        try await listRooms(type: type, activeSince: activeSince)
    }

    public func getMessage(id: String) async throws -> WebexMessage {
        let url = try endpoint(path: "messages/\(id)")
        let (data, response) = try await request(url, kind: .api)
        try validate(response: response, data: data, kind: .api)
        return try decode(WebexMessage.self, from: data)
    }

    /// Returns messages created in the half-open interval `[from, before)`.
    /// A nil boundary leaves that side of the range unbounded.
    public func listMessages(
        roomID: String,
        from: Date? = nil,
        before: Date? = nil
    ) async throws -> [WebexMessage] {
        if let from, let before, from >= before {
            throw WebexAPIError.invalidDateRange
        }

        var pageBefore = before
        var pages: [WebexMessage] = []
        var visitedPageURLs: Set<String> = []
        for _ in 0..<Self.maximumMessagePageCount {
            var query = [
                URLQueryItem(name: "roomId", value: roomID),
                URLQueryItem(name: "max", value: "100")
            ]
            if let pageBefore {
                query.append(URLQueryItem(
                    name: "before",
                    value: Self.webexTimestamp(pageBefore)
                ))
            }
            let pageURL = try endpoint(path: "messages", query: query)
            guard visitedPageURLs.insert(pageURL.absoluteString).inserted else {
                throw WebexAPIError.paginationLoop(pageURL)
            }

            let (data, response) = try await request(pageURL, kind: .api)
            try validate(response: response, data: data, kind: .api)
            let items = try decode(WebexListResponse<WebexMessage>.self, from: data)
                .items
                .compactMap(\.value)
            guard !items.isEmpty else { break }
            pages.append(contentsOf: items)

            guard let oldest = items.map(\.created).min() else { break }
            if let currentBoundary = pageBefore, oldest >= currentBoundary {
                throw WebexAPIError.paginationLoop(pageURL)
            }
            if let from, oldest < from { break }
            pageBefore = oldest
        }

        var messagesByID: [String: WebexMessage] = [:]
        for message in pages where !message.id.isEmpty && message.roomId == roomID {
            if let from, message.created < from { continue }
            if let before, message.created >= before { continue }
            if let existing = messagesByID[message.id] {
                if Self.messageVersion(message) > Self.messageVersion(existing) {
                    messagesByID[message.id] = message
                }
            } else {
                messagesByID[message.id] = message
            }
        }
        return messagesByID.values.sorted {
            if $0.created != $1.created { return $0.created < $1.created }
            return $0.id < $1.id
        }
    }

    public func messages(
        in roomID: String,
        from: Date? = nil,
        before: Date? = nil
    ) async throws -> [WebexMessage] {
        try await listMessages(roomID: roomID, from: from, before: before)
    }

    public func downloadAttachment(
        from remoteURL: URL,
        allowUnscannable: Bool = false
    ) async throws -> Data {
        try await attachmentPayload(
            from: remoteURL,
            allowUnscannable: allowUnscannable
        ).data
    }

    @discardableResult
    public func downloadAttachment(
        from remoteURL: URL,
        to destinationURL: URL,
        allowUnscannable: Bool = false
    ) async throws -> URL {
        guard destinationURL.isFileURL, !destinationURL.hasDirectoryPath else {
            throw WebexAPIError.invalidFileDestination(destinationURL)
        }
        let payload = try await attachmentPayload(
            from: remoteURL,
            allowUnscannable: allowUnscannable
        )
        try Self.write(payload.data, to: destinationURL)
        return destinationURL
    }

    /// Downloads an attachment and chooses a safe, collision-free filename.
    @discardableResult
    public func downloadAttachment(
        from remoteURL: URL,
        into directoryURL: URL,
        suggestedFilename: String? = nil,
        allowUnscannable: Bool = false
    ) async throws -> URL {
        guard directoryURL.isFileURL else {
            throw WebexAPIError.invalidFileDestination(directoryURL)
        }
        let payload = try await attachmentPayload(
            from: remoteURL,
            allowUnscannable: allowUnscannable
        )
        let serverName = Self.filename(from: payload.response)
        let fallbackName = remoteURL.lastPathComponent.isEmpty ? "attachment" : remoteURL.lastPathComponent
        let filename = Self.safeFilename(suggestedFilename ?? serverName ?? fallbackName)

        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw WebexAPIError.fileWriteFailed(error.localizedDescription)
        }
        let destination = Self.availableDestination(in: directoryURL, filename: filename)
        try Self.write(payload.data, to: destination)
        return destination
    }

    public static func isAllowedAttachmentURL(
        _ url: URL,
        relativeTo baseURL: URL = WebexAPIClient.defaultBaseURL
    ) -> Bool {
        guard url.user == nil, url.password == nil, url.fragment == nil,
              let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased() else {
            return false
        }

        guard scheme == "https", url.port == nil || url.port == 443 else { return false }
        return isTrustedWebexHost(host)
    }

    private func attachmentPayload(
        from remoteURL: URL,
        allowUnscannable: Bool
    ) async throws -> AttachmentPayload {
        guard Self.isAllowedAttachmentURL(remoteURL, relativeTo: baseURL) else {
            throw WebexAPIError.unsafeAttachmentURL(remoteURL)
        }
        var (data, response) = try await request(remoteURL, kind: .attachment)
        if response.statusCode == 428, allowUnscannable {
            let forcedURL = try Self.forceDownloadURL(for: remoteURL)
            (data, response) = try await request(forcedURL, kind: .attachment)
        }
        try validate(response: response, data: data, kind: .attachment)
        return AttachmentPayload(data: data, response: response)
    }

    private static func forceDownloadURL(for remoteURL: URL) throws -> URL {
        guard var components = URLComponents(
            url: remoteURL,
            resolvingAgainstBaseURL: false
        ) else {
            throw WebexAPIError.unsafeAttachmentURL(remoteURL)
        }
        var queryItems = components.queryItems ?? []
        queryItems.removeAll { $0.name.caseInsensitiveCompare("allow") == .orderedSame }
        queryItems.append(URLQueryItem(name: "allow", value: "unscannable"))
        components.queryItems = queryItems
        guard let forcedURL = components.url,
              isAllowedAttachmentURL(forcedURL) else {
            throw WebexAPIError.unsafeAttachmentURL(remoteURL)
        }
        return forcedURL
    }

    private func request(
        _ url: URL,
        kind: RequestKind
    ) async throws -> (Data, HTTPURLResponse) {
        try validateConfiguration()
        var currentURL = url
        var redirectCount = 0

        while true {
            try validate(url: currentURL, kind: kind)
            let request = authenticatedRequest(url: currentURL)
            let (data, response) = try await requestWithRetries(request, kind: kind)
            guard (300..<400).contains(response.statusCode) else {
                return (data, response)
            }
            guard redirectCount < 5 else { throw WebexAPIError.tooManyRedirects }
            guard let location = response.value(forHTTPHeaderField: "Location"),
                  let next = URL(string: location, relativeTo: currentURL)?.absoluteURL else {
                throw WebexAPIError.httpStatus(statusCode: response.statusCode, message: nil)
            }
            try validate(url: next, kind: kind)
            currentURL = next
            redirectCount += 1
        }
    }

    private func requestWithRetries(
        _ request: URLRequest,
        kind: RequestKind
    ) async throws -> (Data, HTTPURLResponse) {
        var retryCount = 0
        while true {
            try Task.checkCancellation()
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw WebexAPIError.invalidResponse
                }
                if Self.isRetryable(statusCode: http.statusCode, kind: kind),
                   retryCount < retryPolicy.maximumRetryCount {
                    try await waitBeforeRetry(response: http, retryCount: retryCount)
                    retryCount += 1
                    continue
                }
                return (data, http)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as WebexAPIError {
                throw error
            } catch {
                if Task.isCancelled { throw CancellationError() }
                let urlError = error as? URLError
                if let urlError, Self.isRetryable(urlError), retryCount < retryPolicy.maximumRetryCount {
                    try await waitBeforeRetry(response: nil, retryCount: retryCount)
                    retryCount += 1
                    continue
                }
                throw WebexAPIError.transport(
                    code: urlError?.errorCode,
                    message: redacted(error.localizedDescription) ?? "Unknown transport error"
                )
            }
        }
    }

    private func waitBeforeRetry(
        response: HTTPURLResponse?,
        retryCount: Int
    ) async throws {
        let serverDelay = response.flatMap(Self.retryAfter)
        let exponential = retryPolicy.baseDelay * pow(2, Double(retryCount))
        let delay = min(serverDelay ?? exponential, retryPolicy.maximumDelay)
        guard delay > 0 else { return }
        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
    }

    private func validate(response: HTTPURLResponse, data: Data, kind: RequestKind) throws {
        guard (200..<300).contains(response.statusCode) else {
            let message = redacted(Self.errorMessage(from: data))
            let retryAfter = Self.retryAfter(response)
            switch response.statusCode {
            case 401:
                throw WebexAPIError.unauthorized(message)
            case 403:
                throw WebexAPIError.forbidden(message)
            case 429:
                throw WebexAPIError.rateLimited(retryAfter: retryAfter)
            case 423 where kind == .attachment:
                throw WebexAPIError.attachmentLocked(retryAfter: retryAfter)
            case 410 where kind == .attachment:
                throw WebexAPIError.attachmentUnavailable(statusCode: 410, message: message)
            case 428 where kind == .attachment:
                throw WebexAPIError.attachmentRequiresUserConsent(message)
            default:
                throw WebexAPIError.httpStatus(statusCode: response.statusCode, message: message)
            }
        }
    }

    private func validateConfiguration() throws {
        guard !accessToken.isEmpty else { throw WebexAPIError.invalidAccessToken }
        guard Self.isValidBaseURL(baseURL) else {
            throw WebexAPIError.invalidBaseURL(baseURL.absoluteString)
        }
    }

    private func redacted(_ value: String?) -> String? {
        guard let value else { return nil }
        guard !accessToken.isEmpty else { return value }
        return value.replacingOccurrences(of: accessToken, with: "<redacted>")
    }

    private func validate(url: URL, kind: RequestKind) throws {
        switch kind {
        case .api:
            guard Self.isAllowedAPIURL(url, relativeTo: baseURL) else {
                throw WebexAPIError.unsafePaginationURL(url)
            }
        case .attachment:
            guard Self.isAllowedAttachmentURL(url, relativeTo: baseURL) else {
                throw WebexAPIError.unsafeAttachmentURL(url)
            }
        }
    }

    private func endpoint(path: String, query: [URLQueryItem] = []) throws -> URL {
        try validateConfiguration()
        let url = baseURL.appendingPathComponent(path)
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw WebexAPIError.invalidBaseURL(baseURL.absoluteString)
        }
        components.queryItems = query.isEmpty ? nil : query
        guard let result = components.url else {
            throw WebexAPIError.invalidBaseURL(baseURL.absoluteString)
        }
        return result
    }

    private func authenticatedRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            guard let date = Self.parseWebexTimestamp(value) else {
                throw DecodingError.dataCorruptedError(
                    in: try decoder.singleValueContainer(),
                    debugDescription: "Invalid Webex timestamp: \(value)"
                )
            }
            return date
        }
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw WebexAPIError.malformedResponse(error.localizedDescription)
        }
    }

    private static func isValidBaseURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              isTrustedWebexHost(host),
              url.port == nil || url.port == 443,
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil else {
            return false
        }
        return url.path == "/v1" || url.path == "/v1/"
    }

    private static func isAllowedAPIURL(_ url: URL, relativeTo baseURL: URL) -> Bool {
        guard isValidBaseURL(baseURL),
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(), isTrustedWebexHost(host),
              url.port == nil || url.port == 443,
              url.user == nil, url.password == nil, url.fragment == nil else {
            return false
        }
        let root = baseURL.path.hasSuffix("/")
            ? String(baseURL.path.dropLast())
            : baseURL.path
        return root.isEmpty || url.path == root || url.path.hasPrefix(root + "/")
    }

    private static func isTrustedWebexHost(_ host: String) -> Bool {
        host == "webexapis.com" || host.hasSuffix(".webexapis.com")
            || host == "api.ciscospark.com"
    }

    private static func retryAfter(_ response: HTTPURLResponse) -> TimeInterval? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        if let seconds = TimeInterval(raw) { return max(0, seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        guard let date = formatter.date(from: raw) else { return nil }
        return max(0, date.timeIntervalSinceNow)
    }

    private static func isRetryable(statusCode: Int, kind: RequestKind) -> Bool {
        statusCode == 429
            || (500...504).contains(statusCode)
            || (kind == .attachment && statusCode == 423)
    }

    private static func isRetryable(_ error: URLError) -> Bool {
        switch error.code {
        case .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
             .dnsLookupFailed, .notConnectedToInternet, .internationalRoamingOff,
             .callIsActive, .dataNotAllowed, .secureConnectionFailed:
            return true
        default:
            return false
        }
    }

    private static func errorMessage(from data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        if let payload = try? JSONDecoder().decode(WebexErrorResponse.self, from: data) {
            return payload.message ?? payload.errors?.compactMap(\.description).first
        }
        let raw = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw, !raw.isEmpty else { return nil }
        return String(raw.prefix(1_000))
    }

    private static func roomVersion(_ room: WebexRoom) -> Date {
        room.lastActivity ?? room.created ?? .distantPast
    }

    private static func messageVersion(_ message: WebexMessage) -> Date {
        message.updated ?? message.created
    }

    private static func webexTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func parseWebexTimestamp(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let wholeSeconds = ISO8601DateFormatter()
        wholeSeconds.formatOptions = [.withInternetDateTime]
        return wholeSeconds.date(from: value)
    }

    private static func filename(from response: HTTPURLResponse) -> String? {
        guard let disposition = response.value(forHTTPHeaderField: "Content-Disposition") else {
            return nil
        }
        for component in disposition.split(separator: ";").dropFirst() {
            let pair = component.split(separator: "=", maxSplits: 1)
            guard pair.count == 2 else { continue }
            let key = pair[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            var value = pair[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if key == "filename*" {
                if let marker = value.range(of: "''") { value = String(value[marker.upperBound...]) }
                return value.removingPercentEncoding ?? value
            }
            if key == "filename" {
                return value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
        }
        return nil
    }

    private static func safeFilename(_ value: String) -> String {
        let disallowed = CharacterSet(charactersIn: "/\\:\0")
            .union(.newlines)
            .union(.controlCharacters)
        let pieces = value.components(separatedBy: disallowed)
        let sanitized = pieces.joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if sanitized.isEmpty || sanitized == "." || sanitized == ".." { return "attachment" }
        return String(sanitized.prefix(240))
    }

    private static func availableDestination(in directory: URL, filename: String) -> URL {
        var candidate = directory.appendingPathComponent(filename, isDirectory: false)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }

        let source = URL(fileURLWithPath: filename)
        let ext = source.pathExtension
        let stem = source.deletingPathExtension().lastPathComponent
        var index = 2
        repeat {
            let nextName = ext.isEmpty ? "\(stem)-\(index)" : "\(stem)-\(index).\(ext)"
            candidate = directory.appendingPathComponent(nextName, isDirectory: false)
            index += 1
        } while FileManager.default.fileExists(atPath: candidate.path)
        return candidate
    }

    private static func write(_ data: Data, to destination: URL) throws {
        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try data.write(to: destination, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: destination.path
            )
        } catch {
            throw WebexAPIError.fileWriteFailed(error.localizedDescription)
        }
    }
}

private enum RequestKind: Sendable, Equatable {
    case api
    case attachment
}

private struct WebexListResponse<Item: Decodable>: Decodable {
    let items: [LossyDecodable<Item>]
}

private struct LossyDecodable<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

private struct WebexErrorResponse: Decodable {
    let message: String?
    let errors: [Detail]?

    struct Detail: Decodable {
        let description: String?
    }
}

private struct AttachmentPayload {
    let data: Data
    let response: HTTPURLResponse
}

/// Redirects are validated and followed explicitly by `WebexAPIClient` so an
/// Authorization header cannot be forwarded by URLSession to an untrusted host.
final class WebexNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = WebexNoRedirectDelegate()

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
