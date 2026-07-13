import DesklogCore
import Foundation
import Testing

@Suite struct RecordingControlTests {
    @Test func menuBarStatusUsesTheRequiredExactText() {
        #expect(RecordingMode.stopped.menuBarStatusText == nil)
        #expect(RecordingMode.screenOnly.menuBarStatusText == "記録中（画面のみ）")
        #expect(RecordingMode.screenAndAudio.menuBarStatusText == "記録中（音声込み）")
    }

    @Test func menuBarStatusPrioritizesAlertThenSummaryThenRecording() {
        #expect(
            MenuBarPresentation.statusText(
                recordingMode: .stopped,
                isSummarizing: false,
                audioAlert: nil
            ) == nil
        )
        #expect(
            MenuBarPresentation.statusText(
                recordingMode: .screenOnly,
                isSummarizing: true,
                audioAlert: nil
            ) == "要約中"
        )
        #expect(
            MenuBarPresentation.statusText(
                recordingMode: .screenAndAudio,
                isSummarizing: true,
                audioAlert: .musicDetected
            ) == "音楽を検出しました。記録を停止してください"
        )
    }

    @Test func recordingAndAudioFollowTheAllowedStateTransitions() {
        var mode = RecordingMode.stopped

        #expect(mode.allows(.startRecording))
        mode = mode.applying(.startRecording)
        #expect(mode == .screenOnly)

        #expect(mode.allows(.startAudio))
        mode = mode.applying(.startAudio)
        #expect(mode == .screenAndAudio)

        #expect(mode.allows(.stopAudio))
        mode = mode.applying(.stopAudio)
        #expect(mode == .screenOnly)

        #expect(mode.allows(.stopRecording))
        mode = mode.applying(.stopRecording)
        #expect(mode == .stopped)
    }

    @Test func stoppingRecordingAlsoStopsAudio() {
        let stopped = RecordingMode.screenAndAudio.applying(.stopRecording)
        #expect(stopped == .stopped)
    }

    @Test func unsupportedOrRepeatedActionsAreNoOps() {
        #expect(RecordingMode.stopped.applying(.stopRecording) == .stopped)
        #expect(RecordingMode.stopped.applying(.startAudio) == .stopped)
        #expect(RecordingMode.stopped.applying(.stopAudio) == .stopped)
        #expect(RecordingMode.screenOnly.applying(.startRecording) == .screenOnly)
        #expect(RecordingMode.screenOnly.applying(.stopAudio) == .screenOnly)
        #expect(RecordingMode.screenAndAudio.applying(.startRecording) == .screenAndAudio)
        #expect(RecordingMode.screenAndAudio.applying(.startAudio) == .screenAndAudio)

        #expect(!RecordingMode.stopped.allows(.startAudio))
        #expect(!RecordingMode.screenOnly.allows(.stopAudio))
        #expect(!RecordingMode.screenAndAudio.allows(.startAudio))
    }

    @Test func externalURLsMapToTheFiveSupportedActions() throws {
        let cases: [(String, DesklogExternalAction)] = [
            ("desklog://record/start", .startRecording),
            ("desklog://record/stop", .stopRecording),
            ("desklog://audio/start", .startAudio),
            ("desklog://audio/stop", .stopAudio),
            ("desklog://summary/start", .startSummary),
        ]

        for (string, expected) in cases {
            let url = try #require(URL(string: string))
            #expect(DesklogExternalAction(url: url) == expected)
        }
    }

    @Test func externalURLParserRejectsDecoratedAndUnknownURLs() throws {
        let rejected = [
            "https://record/start",
            "DESKLOG://record/start",
            "desklog:record/start",
            "desklog://user@record/start",
            "desklog://user:password@record/start",
            "desklog://record:123/start",
            "desklog://record/start?",
            "desklog://record/start?source=raycast",
            "desklog://record/start#",
            "desklog://record/start#fragment",
            "desklog://record/start/extra",
            "desklog://record/start/",
            "desklog://record/%73tart",
            "desklog://unknown/start",
            "desklog://summary/stop",
        ]

        for string in rejected {
            let url = try #require(URL(string: string))
            #expect(DesklogExternalAction(url: url) == nil, "Accepted \(string)")
        }
    }

    @Test func externalRecordingActionsExposeTheirReducerAction() throws {
        let startSummary = try #require(URL(string: "desklog://summary/start"))
        #expect(
            DesklogExternalAction.startRecording.recordingControlAction == .startRecording
        )
        #expect(DesklogExternalAction.stopRecording.recordingControlAction == .stopRecording)
        #expect(DesklogExternalAction.startAudio.recordingControlAction == .startAudio)
        #expect(DesklogExternalAction.stopAudio.recordingControlAction == .stopAudio)
        #expect(DesklogExternalAction(url: startSummary)?.recordingControlAction == nil)
    }

    @Test func applicationRegistersTheExternalControlScheme() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Resources/Info.plist"))
        let propertyList = try PropertyListSerialization.propertyList(from: data, format: nil)
        let dictionary = try #require(propertyList as? [String: Any])
        let urlTypes = try #require(dictionary["CFBundleURLTypes"] as? [[String: Any]])
        let schemes = urlTypes.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }

        #expect(schemes.contains("desklog"))
    }

    @Test func bundledRaycastCommandsUseEverySupportedURL() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let scripts = root.appendingPathComponent("scripts/raycast", isDirectory: true)
        let expected = [
            "desklog-record-start.sh": "desklog://record/start",
            "desklog-record-stop.sh": "desklog://record/stop",
            "desklog-audio-start.sh": "desklog://audio/start",
            "desklog-audio-stop.sh": "desklog://audio/stop",
            "desklog-summary-start.sh": "desklog://summary/start",
        ]

        for (filename, externalURL) in expected {
            let script = scripts.appendingPathComponent(filename)
            let contents = try String(contentsOf: script, encoding: .utf8)
            #expect(contents.contains("/usr/bin/open -g '\(externalURL)'"))
            #expect(FileManager.default.isExecutableFile(atPath: script.path))
        }
    }
}

@Suite struct AudioActivityMonitorTests {
    @Test func detectorThresholdsMatchTheRequirements() {
        #expect(AudioActivityMonitor.inputLevelThreshold == 0.04)
        #expect(AudioActivityMonitor.prolongedSilenceDuration == 600)
        #expect(AudioActivityMonitor.musicConfidenceThreshold == 0.75)
        #expect(AudioActivityMonitor.requiredConsecutiveMusicDetections == 2)
    }

    @Test func alertMessagesUseTheRequiredExactText() {
        #expect(
            AudioAlertKind.musicDetected.message ==
                "音楽を検出しました。記録を停止してください"
        )
        #expect(
            AudioAlertKind.prolongedSilence.message ==
                "10分無音を検出しました。記録を停止してください"
        )
    }

    @Test func silenceIsReportedAfterExactlyTenMinutes() {
        var monitor = AudioActivityMonitor()
        let start = Date(timeIntervalSinceReferenceDate: 1_000)

        #expect(monitor.observeInputLevel(0.039, at: start) == nil)
        #expect(monitor.observeInputLevel(0, at: start.addingTimeInterval(599.999)) == nil)
        #expect(
            monitor.observeInputLevel(0, at: start.addingTimeInterval(600)) ==
                .prolongedSilence
        )
        #expect(monitor.observeInputLevel(0, at: start.addingTimeInterval(601)) == nil)
    }

    @Test func thresholdLevelIsAudibleAndResetsTheSilenceTimer() {
        var monitor = AudioActivityMonitor()
        let start = Date(timeIntervalSinceReferenceDate: 2_000)

        #expect(monitor.observeInputLevel(0, at: start) == nil)
        #expect(monitor.observeInputLevel(0.04, at: start.addingTimeInterval(500)) == nil)
        #expect(monitor.observeInputLevel(0, at: start.addingTimeInterval(501)) == nil)
        #expect(monitor.observeInputLevel(0, at: start.addingTimeInterval(1_100)) == nil)
        #expect(
            monitor.observeInputLevel(0, at: start.addingTimeInterval(1_101)) ==
                .prolongedSilence
        )
    }

    @Test func musicRequiresTwoConsecutiveDetectionsAtTheThreshold() {
        var monitor = AudioActivityMonitor()

        #expect(monitor.observeMusicConfidence(0.75) == nil)
        #expect(monitor.observeMusicConfidence(0.75) == .musicDetected)
        #expect(monitor.observeMusicConfidence(1) == nil)
    }

    @Test func lowMusicConfidenceBreaksTheConsecutiveSequence() {
        var monitor = AudioActivityMonitor()

        #expect(monitor.observeMusicConfidence(0.9) == nil)
        #expect(monitor.observeMusicConfidence(0.749) == nil)
        #expect(monitor.observeMusicConfidence(0.9) == nil)
        #expect(monitor.observeMusicConfidence(0.9) == .musicDetected)
    }

    @Test func musicCanBeReportedAgainAfterTheConditionClears() {
        var monitor = AudioActivityMonitor()

        #expect(monitor.observeMusicConfidence(0.9) == nil)
        #expect(monitor.observeMusicConfidence(0.9) == .musicDetected)
        #expect(monitor.observeMusicConfidence(0.1) == nil)
        #expect(monitor.observeMusicConfidence(0.9) == nil)
        #expect(monitor.observeMusicConfidence(0.9) == .musicDetected)
    }

    @Test func resetClearsBothDetectionHistories() {
        var monitor = AudioActivityMonitor()
        let start = Date(timeIntervalSinceReferenceDate: 3_000)

        #expect(monitor.observeInputLevel(0, at: start) == nil)
        #expect(monitor.observeMusicConfidence(1) == nil)
        monitor.reset()

        #expect(monitor.observeInputLevel(0, at: start.addingTimeInterval(600)) == nil)
        #expect(monitor.observeMusicConfidence(1) == nil)
    }
}

@Suite struct AudioAlertSnoozeStateTests {
    @Test func snoozeSuppressesOnlyTheSelectedKindForTenMinutes() {
        var state = AudioAlertSnoozeState()
        let start = Date(timeIntervalSinceReferenceDate: 4_000)
        #expect(AudioAlertSnoozeState.duration == 600)
        state.snooze(.musicDetected, at: start)

        #expect(state.isSnoozed(.musicDetected, at: start))
        #expect(state.isSnoozed(.musicDetected, at: start.addingTimeInterval(599.999)))
        #expect(!state.isSnoozed(.musicDetected, at: start.addingTimeInterval(600)))
        #expect(!state.isSnoozed(.prolongedSilence, at: start))
        #expect(!state.shouldPresent(.musicDetected, at: start))
        #expect(state.shouldPresent(.prolongedSilence, at: start))
    }

    @Test func clearAndResetRemoveSnoozes() {
        var state = AudioAlertSnoozeState()
        let now = Date(timeIntervalSinceReferenceDate: 5_000)
        state.snooze(.musicDetected, at: now)
        state.snooze(.prolongedSilence, at: now)

        state.clear(.musicDetected)
        #expect(!state.isSnoozed(.musicDetected, at: now))
        #expect(state.isSnoozed(.prolongedSilence, at: now))

        state.reset()
        #expect(!state.isSnoozed(.prolongedSilence, at: now))
    }
}
