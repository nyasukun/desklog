import Foundation
import Testing

@Suite struct CaptureExclusionIntegrationTests {
    @Test func capturesOnlyTheFirstAllowedWindowInFrontToBackOrder() throws {
        let screenSource = try source("Sources/Desklog/ScreenOCRService.swift")
        #expect(screenSource.contains("SCShareableContent.excludingDesktopWindows("))
        #expect(screenSource.contains("CGWindowListCopyWindowInfo("))
        #expect(screenSource.contains("frontToBackWindowIDs()"))
        #expect(screenSource.contains("policy.firstAllowed(fromFrontToBack: ordered)"))
        #expect(screenSource.contains("SCContentFilter(desktopIndependentWindow: window)"))
        #expect(screenSource.contains("application.processID != ownPID"))
        #expect(screenSource.contains("ensurePolicyIsCurrent(expectedPolicy"))
        // `performUnlessCancelled` already holds the attempt lock. Calling
        // `ensurePolicyIsCurrent` inside that closure re-enters the same lock
        // and permanently stalls the first OCR capture.
        #expect(!screenSource.contains(
            "performUnlessCancelled {\n                        try self.ensurePolicyIsCurrent"
        ))
        #expect(!screenSource.contains("SCContentSharingPicker"))
    }

    @Test func exclusionsCanBeAddedAndRemovedWhileRecording() throws {
        let controllerSource = try source("Sources/Desklog/DesklogController.swift")
        #expect(controllerSource.contains("configuration.excludedCaptureWindows != oldValue.excludedCaptureWindows"))
        #expect(controllerSource.contains("screenOCR.cancelPendingCaptures()"))
        #expect(controllerSource.contains("screenOCR.updateCaptureExclusionPolicy("))

        let settingsSource = try source("Sources/Desklog/DashboardView.swift")
        #expect(settingsSource.contains("取得しないウィンドウ"))
        #expect(settingsSource.contains("ウィンドウを選ぶ…"))
        #expect(settingsSource.contains("removeExcludedCaptureWindow(window)"))
        #expect(!settingsSource.contains("captureExclusionEditingDisabled"))
        #expect(!settingsSource.contains("取得対象を選ぶ"))
        #expect(!settingsSource.contains("キャプチャ対象外アプリ"))
    }

    @Test func displayWideCaptureWorkflowWasRemoved() throws {
        let combined = try [
            "Sources/Desklog/ScreenOCRService.swift",
            "Sources/Desklog/DesklogController.swift",
            "Sources/Desklog/DashboardView.swift",
            "README.md",
        ].map(source).joined(separator: "\n")

        for removedText in [
            "SCContentFilter(display: display",
            "すべてのディスプレイを取得",
            "すべてのディスプレイをOCR",
        ] {
            #expect(!combined.contains(removedText))
        }
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: repositoryRoot.appendingPathComponent(path), encoding: .utf8)
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
