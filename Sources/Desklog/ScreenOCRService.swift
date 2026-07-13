import AppKit
import CoreGraphics
import DesklogCore
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers
import Vision

struct ScreenOCRResult: Sendable {
    let displayTitle: String
    let windowID: UInt32
    let bundleIdentifier: String
    let text: String
    let imagePath: String?
}

final class ScreenOCRService: @unchecked Sendable {
    private let policyLock = NSLock()
    private var exclusionPolicy = CaptureExclusionPolicy(windows: [])
    private let captureAttemptLock = NSLock()
    private var activeCaptureAttempt: ScreenCaptureAttempt?

    func updateCaptureExclusionPolicy(desklogConfiguration: DesklogConfiguration) {
        policyLock.withLock {
            exclusionPolicy = desklogConfiguration.captureExclusionPolicy
        }
    }

    func cancelPendingCaptures() {
        captureAttemptLock.withLock { activeCaptureAttempt }?.cancel()
    }

    /// Returns the currently visible, ordinary application windows that can be
    /// selected for exclusion. Enumerating them requires Screen Recording.
    func availableWindows() async throws -> [ExcludedCaptureWindow] {
        guard CGPreflightScreenCaptureAccess() else {
            throw DesklogError.screenCapturePermissionRequired
        }
        let content = try await SCShareableContent.excludingDesktopWindows(
            true,
            onScreenWindowsOnly: true
        )
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return content.windows.compactMap { window in
            guard window.isOnScreen,
                  window.windowLayer == 0,
                  window.frame.width >= 80,
                  window.frame.height >= 50,
                  let application = window.owningApplication,
                  application.processID != ownPID,
                  !application.bundleIdentifier.isEmpty else {
                return nil
            }
            return ExcludedCaptureWindow(
                windowID: window.windowID,
                bundleIdentifier: application.bundleIdentifier,
                applicationName: application.applicationName,
                windowTitle: window.title ?? ""
            )
        }
        .sorted {
            let appOrder = $0.applicationName.localizedStandardCompare($1.applicationName)
            if appOrder != .orderedSame { return appOrder == .orderedAscending }
            return $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedAscending
        }
    }

    func capture(
        store: WorklogStore,
        configuration: DesklogConfiguration,
        at timestamp: Date = Date()
    ) async throws -> [ScreenOCRResult] {
        guard CGPreflightScreenCaptureAccess() else {
            throw DesklogError.screenCapturePermissionRequired
        }
        let attempt = ScreenCaptureAttempt()
        captureAttemptLock.withLock { activeCaptureAttempt = attempt }
        defer {
            captureAttemptLock.withLock {
                if activeCaptureAttempt === attempt { activeCaptureAttempt = nil }
            }
        }

        let expectedPolicy = configuration.captureExclusionPolicy
        try ensurePolicyIsCurrent(expectedPolicy, attempt: attempt)
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                true,
                onScreenWindowsOnly: true
            )
        } catch {
            try attempt.checkCancellation()
            throw DesklogError.screenContentUnavailable(error.localizedDescription)
        }
        try ensurePolicyIsCurrent(expectedPolicy, attempt: attempt)

        let ownPID = ProcessInfo.processInfo.processIdentifier
        guard let window = Self.firstCaptureWindow(
            in: content,
            policy: expectedPolicy,
            ownPID: ownPID
        ), let application = window.owningApplication else {
            return []
        }

        try ensurePolicyIsCurrent(expectedPolicy, attempt: attempt)
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = max(1, CGFloat(filter.pointPixelScale))
        let streamConfiguration = SCStreamConfiguration()
        streamConfiguration.width = max(1, Int(filter.contentRect.width * scale))
        streamConfiguration.height = max(1, Int(filter.contentRect.height * scale))
        streamConfiguration.showsCursor = false
        streamConfiguration.captureResolution = .best
        streamConfiguration.shouldBeOpaque = true

        let image: CGImage
        do {
            image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: streamConfiguration
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try ensurePolicyIsCurrent(expectedPolicy, attempt: attempt)
            throw DesklogError.screenContentUnavailable(error.localizedDescription)
        }
        try ensurePolicyIsCurrent(expectedPolicy, attempt: attempt)
        let url = configuration.saveScreenshots
            ? try await store.captureURL(at: timestamp)
            : nil
        let title = Self.captureTitle(for: window)

        let result = try await Task.detached(priority: .utility) {
            var shouldKeepScreenshot = false
            defer {
                if !shouldKeepScreenshot, let url {
                    try? FileManager.default.removeItem(at: url)
                }
            }
            try self.ensurePolicyIsCurrent(expectedPolicy, attempt: attempt)
            let recognized = try Self.recognizeText(
                in: image,
                languages: configuration.ocrLanguages
            )
            if let url {
                try attempt.performUnlessCancelled {
                    try Self.saveJPEG(image, to: url)
                }
            }
            try self.ensurePolicyIsCurrent(expectedPolicy, attempt: attempt)
            let body = recognized.isEmpty ? "_OCRで文字を検出できませんでした。_" : recognized
            let result = ScreenOCRResult(
                displayTitle: title,
                windowID: window.windowID,
                bundleIdentifier: application.bundleIdentifier,
                text: "## ウィンドウ: \(title)\n\n\(body)",
                imagePath: url?.path
            )
            shouldKeepScreenshot = true
            return result
        }.value
        return [result]
    }

    private func ensurePolicyIsCurrent(
        _ expected: CaptureExclusionPolicy,
        attempt: ScreenCaptureAttempt
    ) throws {
        try attempt.checkCancellation()
        guard policyLock.withLock({ exclusionPolicy == expected }) else {
            throw CancellationError()
        }
    }

    private static func firstCaptureWindow(
        in content: SCShareableContent,
        policy: CaptureExclusionPolicy,
        ownPID: pid_t
    ) -> SCWindow? {
        let eligible = content.windows.filter { window in
            guard window.isOnScreen,
                  window.windowLayer == 0,
                  window.frame.width >= 80,
                  window.frame.height >= 50,
                  let application = window.owningApplication else {
                return false
            }
            return application.processID != ownPID && !application.bundleIdentifier.isEmpty
        }
        let byID = Dictionary(uniqueKeysWithValues: eligible.map { ($0.windowID, $0) })
        var seen: Set<CGWindowID> = []
        let ordered: [ExcludedCaptureWindow] = (
            frontToBackWindowIDs() + eligible.map(\.windowID)
        ).compactMap { windowID -> ExcludedCaptureWindow? in
            guard seen.insert(windowID).inserted,
                  let window = byID[windowID],
                  let application = window.owningApplication else {
                return nil
            }
            return ExcludedCaptureWindow(
                windowID: window.windowID,
                bundleIdentifier: application.bundleIdentifier,
                applicationName: application.applicationName,
                windowTitle: window.title ?? ""
            )
        }
        guard let selection = policy.firstAllowed(fromFrontToBack: ordered) else { return nil }
        return byID[selection.windowID]
    }

    /// Core Graphics returns on-screen windows in front-to-back order; the IDs
    /// are then resolved to ScreenCaptureKit windows for the actual capture.
    private static func frontToBackWindowIDs() -> [CGWindowID] {
        guard let descriptions = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }
        return descriptions.compactMap {
            ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value
        }
    }

    private static func captureTitle(for window: SCWindow) -> String {
        let applicationName = window.owningApplication?.applicationName
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "アプリ"
        let windowTitle = window.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return windowTitle.isEmpty ? applicationName : "\(applicationName) — \(windowTitle)"
    }

    private static func recognizeText(in image: CGImage, languages: [String]) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = languages
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up)
        try handler.perform([request])

        return (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func saveJPEG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw DesklogError.screenCaptureFailed
        }
        let properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.72]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw DesklogError.screenCaptureFailed
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

private final class ScreenCaptureAttempt: @unchecked Sendable {
    private let lock = NSLock()
    private var isCancelled = false

    func cancel() {
        lock.withLock { isCancelled = true }
    }

    func checkCancellation() throws {
        if lock.withLock({ isCancelled }) { throw CancellationError() }
        try Task.checkCancellation()
    }

    func performUnlessCancelled<Result>(_ operation: () throws -> Result) throws -> Result {
        try lock.withLock {
            if isCancelled { throw CancellationError() }
            return try operation()
        }
    }
}
