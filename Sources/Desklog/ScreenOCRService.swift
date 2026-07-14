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
    let didRecognizeText: Bool
    let imagePath: String?
    let pixelWidth: Int
    let pixelHeight: Int
    let recognitionPass: OCRRecognitionPass
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
        at timestamp: Date = Date(),
        targetWindowID: UInt32? = nil,
        targetBundleIdentifier: String? = nil,
        recognitionPass: OCRRecognitionPass = .fullFrame
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
        let selectedWindow: SCWindow?
        if let targetWindowID {
            selectedWindow = Self.captureWindow(
                withID: targetWindowID,
                bundleIdentifier: targetBundleIdentifier,
                in: content,
                policy: expectedPolicy,
                ownPID: ownPID
            )
        } else {
            selectedWindow = Self.firstCaptureWindow(
                in: content,
                policy: expectedPolicy,
                ownPID: ownPID
            )
        }
        guard let window = selectedWindow,
              let application = window.owningApplication else {
            if targetWindowID != nil {
                throw DesklogError.screenContentUnavailable(
                    "確認したウィンドウが閉じられたか、取得対象から外れました。"
                )
            }
            return []
        }

        try ensurePolicyIsCurrent(expectedPolicy, attempt: attempt)
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = max(1, CGFloat(filter.pointPixelScale))
        let streamConfiguration = SCStreamConfiguration()
        streamConfiguration.width = max(1, Int((filter.contentRect.width * scale).rounded()))
        streamConfiguration.height = max(1, Int((filter.contentRect.height * scale).rounded()))
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
                languages: configuration.ocrLanguages,
                pass: recognitionPass
            )
            if let url {
                try attempt.performUnlessCancelled {
                    try Self.saveJPEG(image, to: url)
                }
            }
            try self.ensurePolicyIsCurrent(expectedPolicy, attempt: attempt)
            // A lone glyph such as "書©" is commonly a UI/icon false positive,
            // not useful OCR output. Treat it as a miss so retry passes continue.
            let didRecognizeText = Self.hasSubstantiveText(recognized)
            let body = didRecognizeText ? recognized : "_OCRで文字を検出できませんでした。_"
            let result = ScreenOCRResult(
                displayTitle: title,
                windowID: window.windowID,
                bundleIdentifier: application.bundleIdentifier,
                text: "## ウィンドウ: \(title)\n\n\(body)",
                didRecognizeText: didRecognizeText,
                imagePath: url?.path,
                pixelWidth: image.width,
                pixelHeight: image.height,
                recognitionPass: recognitionPass
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
            isEligibleCaptureWindow(window, ownPID: ownPID)
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

    private static func captureWindow(
        withID windowID: UInt32,
        bundleIdentifier: String?,
        in content: SCShareableContent,
        policy: CaptureExclusionPolicy,
        ownPID: pid_t
    ) -> SCWindow? {
        guard let window = content.windows.first(where: { $0.windowID == windowID }),
              isEligibleCaptureWindow(window, ownPID: ownPID),
              let application = window.owningApplication,
              bundleIdentifier == nil || application.bundleIdentifier.caseInsensitiveCompare(
                  bundleIdentifier ?? ""
              ) == .orderedSame,
              !policy.excludes(
                  windowID: window.windowID,
                  bundleIdentifier: application.bundleIdentifier
              ) else {
            return nil
        }
        return window
    }

    private static func isEligibleCaptureWindow(_ window: SCWindow, ownPID: pid_t) -> Bool {
        guard window.isOnScreen,
              window.windowLayer == 0,
              window.frame.width >= 80,
              window.frame.height >= 50,
              let application = window.owningApplication else {
            return false
        }
        return application.processID != ownPID && !application.bundleIdentifier.isEmpty
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

    private static func recognizeText(
        in image: CGImage,
        languages: [String],
        pass: OCRRecognitionPass
    ) throws -> String {
        if pass == .fullFrame {
            return try recognizedLines(in: image, languages: languages).joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var seen: Set<String> = []
        var recognized: [String] = []
        let regions = OCRTileLayout.regions(
            pixelWidth: image.width,
            pixelHeight: image.height,
            pass: pass
        )
        for region in regions {
            try Task.checkCancellation()
            let rect = CGRect(
                x: region.x,
                y: region.y,
                width: region.width,
                height: region.height
            )
            guard let crop = image.cropping(to: rect),
                  let prepared = scaledImage(crop, by: pass.preprocessingScale) else {
                continue
            }
            for line in try recognizedLines(
                in: prepared,
                languages: languages,
                minimumTextHeight: 0.005
            ) {
                let key = line.folding(
                    options: [.caseInsensitive, .widthInsensitive],
                    locale: .current
                ).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty, seen.insert(key).inserted else { continue }
                recognized.append(line)
            }
        }
        return recognized.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func recognizedLines(
        in image: CGImage,
        languages: [String],
        minimumTextHeight: Float? = nil
    ) throws -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = languages
        if let minimumTextHeight {
            request.minimumTextHeight = minimumTextHeight
        }
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up)
        try handler.perform([request])

        return (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func hasSubstantiveText(_ text: String) -> Bool {
        text.unicodeScalars.reduce(into: 0) { count, scalar in
            if CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar) {
                count += 1
            }
        } >= 2
    }

    private static func scaledImage(_ image: CGImage, by factor: Int) -> CGImage? {
        guard factor > 1 else { return image }
        guard let context = CGContext(
            data: nil,
            width: image.width * factor,
            height: image.height * factor,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.interpolationQuality = .high
        context.draw(
            image,
            in: CGRect(
                x: 0,
                y: 0,
                width: image.width * factor,
                height: image.height * factor
            )
        )
        return context.makeImage()
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
        let properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.92]
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
