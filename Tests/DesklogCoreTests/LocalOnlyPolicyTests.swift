@testable import DesklogCore
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing

@Suite(.serialized) struct LocalOnlyPolicyTests {
    @Test func ollamaEndpointPolicyAcceptsOnlyPlainHTTPLoopbackRoots() {
        let allowed = [
            "http://127.0.0.1:11434",
            "http://localhost:11434",
            "http://LOCALHOST:11434/",
            "http://[::1]:11434"
        ]
        let rejected = [
            "https://127.0.0.1:11434",
            "http://example.com:11434",
            "http://localhost.example.com:11434",
            "http://127.0.0.2:11434",
            "http://[::2]:11434",
            "http://user@localhost:11434",
            "http://localhost:11434/proxy",
            "http://localhost:11434?next=https://example.com",
            "file:///tmp/ollama.sock"
        ]

        for endpoint in allowed {
            #expect(OllamaClient.isAllowedLocalEndpoint(endpoint), "\(endpoint)")
        }
        for endpoint in rejected {
            #expect(!OllamaClient.isAllowedLocalEndpoint(endpoint), "\(endpoint)")
        }
    }

    @Test func rejectedRemoteEndpointNeverTouchesNetworkTransport() async throws {
        NetworkSpyURLProtocol.reset()
        let client = OllamaClient(
            baseURL: "https://example.com",
            model: "test",
            sessionConfiguration: makeSpySessionConfiguration()
        )
        do {
            _ = try await client.testConnection()
            Issue.record("A remote endpoint was accepted")
        } catch DesklogError.invalidOllamaURL {
            // Expected.
        } catch {
            Issue.record("Endpoint failed after reaching another code path: \(error)")
        }
        #expect(NetworkSpyURLProtocol.requestCount == 0)
    }

    @Test func allowedOllamaRequestsRemainOnLoopback() async throws {
        NetworkSpyURLProtocol.reset()
        let client = OllamaClient(
            baseURL: "http://127.0.0.1:11434",
            model: "local-model:latest",
            sessionConfiguration: makeSpySessionConfiguration()
        )
        let result = try await client.testConnection()

        #expect(result.configuredModelAvailable)
        #expect(NetworkSpyURLProtocol.requestCount == 2)
        #expect(Set(NetworkSpyURLProtocol.requestHosts) == ["127.0.0.1"])
    }

    @Test func localServiceCannotRedirectWorklogTrafficToARemoteHost() throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let localURL = try #require(URL(string: "http://127.0.0.1:11434/api/chat"))
        let remoteURL = try #require(URL(string: "https://example.com/collect"))
        let task = session.dataTask(with: localURL)
        let response = try #require(HTTPURLResponse(
            url: localURL,
            statusCode: 307,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": "https://example.com/collect"]
        ))
        let redirected = URLRequest(url: remoteURL)
        var requestToFollow: URLRequest? = redirected

        LocalOnlyRedirectDelegate.shared.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: redirected
        ) { requestToFollow = $0 }

        #expect(requestToFollow == nil)
    }

    @Test func runtimeSourcesHaveNoRemoteTransportOrImplicitModelDownload() throws {
        let root = repositoryRoot
        let runtimeRoots = [
            root.appendingPathComponent("Sources/Desklog", isDirectory: true),
            root.appendingPathComponent("Sources/DesklogCore", isDirectory: true),
            root.appendingPathComponent("Sources/DesklogSpeakerHelper", isDirectory: true)
        ]
        let files = try runtimeRoots.flatMap(swiftFiles(in:))

        let reviewedNetworkClients = ["OllamaClient.swift", "WebexClient.swift"]
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            if source.contains("https://") {
                #expect(
                    file.lastPathComponent == "WebexClient.swift",
                    "Runtime source contains an unreviewed remote URL: \(file.path)"
                )
            }
            if !reviewedNetworkClients.contains(file.lastPathComponent) {
                #expect(
                    !source.contains("URLSession("),
                    "Network transport exists outside a reviewed client: \(file.path)"
                )
            }
            if source.contains("Process()") {
                #expect(
                    ["LocalWhisperProcess.swift", "LocalSpeakerHelperClient.swift"]
                        .contains(file.lastPathComponent),
                    "A subprocess exists outside a reviewed network-denied boundary: \(file.path)"
                )
            }
        }

        let speechSource = try String(
            contentsOf: root.appendingPathComponent("Sources/Desklog/SpeechTranscriber.swift"),
            encoding: .utf8
        )
        #expect(!speechSource.contains("import SpeakerKit"))

        let speakerHelperSource = try String(
            contentsOf: root.appendingPathComponent("Sources/DesklogSpeakerHelper/main.swift"),
            encoding: .utf8
        )
        #expect(speakerHelperSource.contains("import SpeakerKit"))
        #expect(speakerHelperSource.contains("download: false"))
        #expect(!speakerHelperSource.contains("download: true"))
        #expect(speakerHelperSource.contains("guard speakerKit == nil else { return }"))

        let speakerClientSource = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/DesklogCore/LocalSpeakerHelperClient.swift"
            ),
            encoding: .utf8
        )
        #expect(speakerClientSource.contains("/usr/bin/sandbox-exec"))
        #expect(speakerClientSource.contains("(deny network*)"))
        #expect(speakerClientSource.contains("F_SETNOSIGPIPE"))

        let whisperProcessSource = try String(
            contentsOf: root.appendingPathComponent("Sources/DesklogCore/LocalWhisperProcess.swift"),
            encoding: .utf8
        )
        #expect(whisperProcessSource.contains("/usr/bin/sandbox-exec"))
        #expect(whisperProcessSource.contains("(deny network*)"))

        let packageSource = try String(
            contentsOf: root.appendingPathComponent("Package.swift"),
            encoding: .utf8
        )
        let desklogTarget = try #require(
            packageSource.range(
                of: #"\.executableTarget\(\s*name: "Desklog","#,
                options: .regularExpression
            )
        )
        let helperTarget = try #require(
            packageSource.range(
                of: #"\.executableTarget\(\s*name: "DesklogSpeakerHelper","#,
                options: .regularExpression
            )
        )
        let appTargetSource = String(packageSource[desklogTarget.lowerBound..<helperTarget.lowerBound])
        #expect(!appTargetSource.contains("SpeakerKit"))

        let ollamaSource = try String(
            contentsOf: root.appendingPathComponent("Sources/DesklogCore/OllamaClient.swift"),
            encoding: .utf8
        )
        #expect(ollamaSource.contains("delegate: LocalOnlyRedirectDelegate.shared"))
        #expect(ollamaSource.contains("completionHandler(nil)"))
        #expect(ollamaSource.contains("connectionProxyDictionary = [:]"))

        let webexSource = try String(
            contentsOf: root.appendingPathComponent("Sources/DesklogCore/WebexClient.swift"),
            encoding: .utf8
        )
        #expect(webexSource.contains(#"https://webexapis.com/v1"#))
        #expect(webexSource.contains(
            #"https://developer.webex.com/docs/getting-your-personal-access-token"#
        ))
        #expect(webexSource.contains(#"host == "webexapis.com" || host.hasSuffix(".webexapis.com")"#))
        #expect(webexSource.contains(#"host == "api.ciscospark.com""#))
        #expect(!webexSource.contains(#"hasSuffix(".ciscospark.com")"#))
        #expect(webexSource.contains("completionHandler(nil)"))
        #expect(webexSource.contains(#"request.setValue("Bearer \(accessToken)""#))
        #expect(!webexSource.contains("print(accessToken)"))

        let installerSource = try String(
            contentsOf: root.appendingPathComponent("Sources/DesklogModelSetup/main.swift"),
            encoding: .utf8
        )
        #expect(
            installerSource.contains("download: true"),
            "Only the explicit setup executable may download speaker models"
        )

        let controllerSource = try String(
            contentsOf: root.appendingPathComponent("Sources/Desklog/DesklogController.swift"),
            encoding: .utf8
        )
        for forbiddenMetadataKey in ["speaker_embedding", "audio_path", "wav_path"] {
            #expect(
                !controllerSource.contains("\"\(forbiddenMetadataKey)\""),
                "Sensitive audio data would be written to the worklog: \(forbiddenMetadataKey)"
            )
        }
    }

    @Test func webexTokenEntryRemainsAVisibleDedicatedScreen() throws {
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/Desklog/DashboardView.swift"
            ),
            encoding: .utf8
        )

        #expect(source.contains(#"case webex = "Webex""#))
        #expect(source.contains("Webex Personal Access Token"))
        #expect(source.contains("取得したトークンをここに貼り付け"))
        #expect(source.contains(".textFieldStyle(.roundedBorder)"))
        #expect(source.contains(#".accessibilityLabel("Webexアクセストークン")"#))
        #expect(source.contains("診断ログをFinderで表示"))
        #expect(source.contains("controller.webexDiagnosticLogPath"))
    }

    private func makeSpySessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NetworkSpyURLProtocol.self]
        return configuration
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func swiftFiles(in directory: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return [] }
        return enumerator.compactMap { item in
            guard let url = item as? URL, url.pathExtension == "swift" else { return nil }
            return url
        }
    }
}

private final class NetworkSpyURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var requests: [URLRequest] = []

    static var requestCount: Int {
        lock.synchronized { requests.count }
    }

    static var requestHosts: [String] {
        lock.synchronized { requests.compactMap { $0.url?.host } }
    }

    static func reset() {
        lock.synchronized { requests.removeAll() }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.synchronized { Self.requests.append(request) }
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let body: Data
        if url.path == "/api/version" {
            body = Data(#"{"version":"test"}"#.utf8)
        } else if url.path == "/api/tags" {
            body = Data(#"{"models":[{"name":"local-model:latest"}]}"#.utf8)
        } else {
            body = Data()
        }
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
}

private extension NSLock {
    func synchronized<Result>(_ body: () -> Result) -> Result {
        lock()
        defer { unlock() }
        return body()
    }
}
