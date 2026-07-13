import DesklogCore
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing

@Suite(.serialized) struct SummaryPromptTests {
    @Test func customInstructionsAreCombinedWithTheTimeline() {
        let input = SummaryInput(
            start: Date(timeIntervalSince1970: 0),
            end: Date(timeIntervalSince1970: 60),
            timeline: "09:00 設計レビューを開始"
        )

        let prompt = OllamaClient.prompt(
            for: input,
            summaryPrompt: "英語で、リスクを先頭にまとめてください。"
        )

        #expect(prompt.contains("英語で、リスクを先頭にまとめてください。"))
        #expect(prompt.contains("--- ログ開始 ---"))
        #expect(prompt.contains(input.timeline))
        #expect(!prompt.contains("## TODO・フォローアップ"))
    }

    @Test func blankInstructionsFallBackToTheDefault() {
        let effective = OllamaClient.effectiveSummaryPrompt("  \n\t ")

        #expect(effective == DesklogConfiguration.defaultSummaryPrompt)
        #expect(effective.contains("# ワークログ要約"))
    }

    @Test func excessiveInstructionsAreBounded() {
        let value = String(
            repeating: "a",
            count: DesklogConfiguration.maximumSummaryPromptCharacters + 500
        )

        #expect(
            OllamaClient.effectiveSummaryPrompt(value).count ==
                DesklogConfiguration.maximumSummaryPromptCharacters
        )
    }

    @Test func customInstructionsReachEveryStageOfALongLocalRequest() async throws {
        SummaryPromptURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SummaryPromptURLProtocol.self]
        let client = OllamaClient(
            baseURL: "http://127.0.0.1:11434",
            model: "local-model:latest",
            sessionConfiguration: configuration
        )
        let customPrompt = "プロジェクトごとに成果、懸念、次の一手を整理してください。"
        let input = SummaryInput(
            start: Date(timeIntervalSince1970: 0),
            end: Date(timeIntervalSince1970: 60),
            timeline: String(repeating: "09:00 作業記録と判断材料\n", count: 1_200)
        )

        let result = try await client.summarize(input, summaryPrompt: customPrompt)
        let messages = SummaryPromptURLProtocol.userMessages

        #expect(result == "ローカル要約")
        #expect(messages.count > 1) // chunk extraction plus final integration
        #expect(messages.allSatisfy { $0.contains(customPrompt) })
        #expect(Set(SummaryPromptURLProtocol.requestHosts) == ["127.0.0.1"])
    }

    @Test func chronologicalWindowsAreFoldedIntoThePreviousSummary() async throws {
        SummaryPromptURLProtocol.reset(responseContent: "累積要約")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SummaryPromptURLProtocol.self]
        let client = OllamaClient(
            baseURL: "http://127.0.0.1:11434",
            model: "gpt-oss:latest",
            sessionConfiguration: configuration
        )
        let start = Date(timeIntervalSince1970: 0)
        let inputs = [
            SummaryInput(
                start: start,
                end: start.addingTimeInterval(10 * 60),
                timeline: "[09:00:00][画面OCR] 設計画面\n[09:01:00][音声/Speaker-001] 方針を相談"
            ),
            SummaryInput(
                start: start.addingTimeInterval(10 * 60),
                end: start.addingTimeInterval(20 * 60),
                timeline: "[09:10:00][音声/Speaker-001] 実装開始\n[09:11:00][画面OCR] テスト画面"
            )
        ]

        let result = try await client.summarize(inputs)
        let messages = SummaryPromptURLProtocol.userMessages
        let bodies = SummaryPromptURLProtocol.requestBodies

        #expect(result == "累積要約")
        #expect(messages.count == 2)
        #expect(messages[0].contains("設計画面") && messages[0].contains("方針を相談"))
        #expect(messages[1].contains("累積要約"))
        #expect(messages[1].contains("実装開始") && messages[1].contains("テスト画面"))
        let firstBody = try #require(
            JSONSerialization.jsonObject(with: bodies[0]) as? [String: Any]
        )
        let options = try #require(firstBody["options"] as? [String: Any])
        #expect(firstBody["think"] as? String == "low")
        #expect(options["num_ctx"] as? Int == 16_384)
        #expect(options["num_predict"] as? Int == 2_048)
    }

    @Test func nonCondensingModelCannotCauseAnUnboundedRequestLoop() async throws {
        let oversizedResponse = String(repeating: "長", count: 31_000)
        SummaryPromptURLProtocol.reset(responseContent: oversizedResponse)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SummaryPromptURLProtocol.self]
        let client = OllamaClient(
            baseURL: "http://127.0.0.1:11434",
            model: "local-model:latest",
            sessionConfiguration: configuration
        )
        let input = SummaryInput(
            start: Date(timeIntervalSince1970: 0),
            end: Date(timeIntervalSince1970: 60),
            timeline: String(repeating: "長い作業記録\n", count: 4_000)
        )

        let result = try await client.summarize(
            input,
            summaryPrompt: "一字も省略せず出力してください。"
        )

        #expect(result == oversizedResponse)
        #expect(SummaryPromptURLProtocol.requestCount <= 10)
        #expect(Set(SummaryPromptURLProtocol.requestHosts) == ["127.0.0.1"])
    }
}

private final class SummaryPromptURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var messages: [String] = []
    private static var hosts: [String] = []
    private static var bodies: [Data] = []
    private static var responseContent = "ローカル要約"

    static var userMessages: [String] {
        lock.withLock { messages }
    }

    static var requestHosts: [String] {
        lock.withLock { hosts }
    }

    static var requestCount: Int {
        lock.withLock { hosts.count }
    }

    static var requestBodies: [Data] {
        lock.withLock { bodies }
    }

    static func reset(responseContent: String = "ローカル要約") {
        lock.withLock {
            messages.removeAll()
            hosts.removeAll()
            bodies.removeAll()
            Self.responseContent = responseContent
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let requestBody = request.httpBody ?? request.httpBodyStream.flatMap(Self.readAll)
        let message = requestBody.flatMap(Self.userMessage)
        Self.lock.withLock {
            if let host = url.host { Self.hosts.append(host) }
            if let message { Self.messages.append(message) }
            if let requestBody { Self.bodies.append(requestBody) }
        }
        let content = Self.lock.withLock { Self.responseContent }
        let body = try! JSONSerialization.data(withJSONObject: [
            "message": ["role": "assistant", "content": content]
        ])
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func userMessage(from body: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: body),
              let dictionary = object as? [String: Any],
              let messages = dictionary["messages"] as? [[String: Any]] else {
            return nil
        }
        return messages.first { $0["role"] as? String == "user" }?["content"] as? String
    }

    private static func readAll(from stream: InputStream) -> Data? {
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { return nil }
            if count == 0 { return result }
            result.append(buffer, count: count)
        }
    }
}
