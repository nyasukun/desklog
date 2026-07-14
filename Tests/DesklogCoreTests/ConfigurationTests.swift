import DesklogCore
import Foundation
import Testing

@Suite struct ConfigurationTests {
    @Test func removedLegacyCaptureSettingsAreIgnoredDuringMigration() throws {
        let data = Data(#"""
        {
          "screenCaptureMode":"automaticFrontmostWindows",
          "screenCaptureResolution":"maximum",
          "excludedCaptureBundleIdentifiers":["com.example.Legacy"],
          "captureIntervalSeconds":60
        }
        """#.utf8)

        let configuration = try JSONDecoder().decode(DesklogConfiguration.self, from: data)
        #expect(configuration.screenCaptureEnabled)
        #expect(configuration.microphoneCaptureEnabled)
        #expect(!configuration.externalControlEnabled)
        #expect(configuration.excludedCaptureWindows.isEmpty)

        let encoded = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(configuration)
        ) as? [String: Any])
        #expect(encoded["screenCaptureMode"] == nil)
        #expect(encoded["screenCaptureResolution"] == nil)
        #expect(encoded["excludedCaptureBundleIdentifiers"] == nil)
    }

    @Test func captureSourceSelectionsAndExcludedWindowsRoundTrip() throws {
        var configuration = DesklogConfiguration()
        configuration.screenCaptureEnabled = false
        configuration.externalControlEnabled = true
        configuration.excludedCaptureWindows = [
            .init(windowID: 123, bundleIdentifier: "com.apple.Safari", applicationName: "Safari", windowTitle: "Private"),
            .init(windowID: 456, bundleIdentifier: "com.apple.Notes", applicationName: "Notes", windowTitle: "Passwords"),
        ]

        let decoded = try JSONDecoder().decode(
            DesklogConfiguration.self,
            from: JSONEncoder().encode(configuration)
        )
        #expect(decoded == configuration)
        #expect(decoded.externalControlEnabled)
        #expect(decoded.excludesCaptureWindow(windowID: 123, bundleIdentifier: "COM.APPLE.SAFARI"))
        #expect(!decoded.excludesCaptureWindow(windowID: 124, bundleIdentifier: "com.apple.Safari"))
    }

    @Test func excludedWindowsAreNormalizedOnMutation() {
        var configuration = DesklogConfiguration()
        configuration.excludedCaptureWindows = [
            .init(windowID: 1, bundleIdentifier: " com.example.App ", applicationName: " App ", windowTitle: " Secret "),
            .init(windowID: 1, bundleIdentifier: "COM.EXAMPLE.APP", applicationName: "Duplicate", windowTitle: "Duplicate"),
            .init(windowID: 0, bundleIdentifier: "com.example.Invalid", applicationName: "Invalid", windowTitle: "Invalid"),
        ]
        #expect(configuration.excludedCaptureWindows.count == 1)
        #expect(configuration.excludedCaptureWindows[0].applicationName == "App")
    }

    @Test func customSummaryPromptRoundTrips() throws {
        var configuration = DesklogConfiguration()
        configuration.summaryPrompt = "プロジェクト別に、成果と次の一手を整理してください。"
        let decoded = try JSONDecoder().decode(
            DesklogConfiguration.self,
            from: JSONEncoder().encode(configuration)
        )
        #expect(decoded.summaryPrompt == configuration.summaryPrompt)
        #expect(decoded == configuration)
    }

    @Test func summaryPromptLengthIsBounded() {
        var configuration = DesklogConfiguration()
        configuration.summaryPrompt = String(
            repeating: "a",
            count: DesklogConfiguration.maximumSummaryPromptCharacters + 100
        )
        #expect(configuration.summaryPrompt.count == DesklogConfiguration.maximumSummaryPromptCharacters)
    }

    @Test func speechChunkingUsesTwelveSecondCoresWithTwoSecondsOfContext() {
        #expect(SpeechChunkingPolicy.cadenceSeconds == 12)
        #expect(SpeechChunkingPolicy.boundaryContextSeconds == 2)
        #expect(SpeechChunkingPolicy.firstFlushDelaySeconds == 14)
        #expect(SpeechChunkingPolicy.retainedOverlapSeconds == 4)
    }
}
