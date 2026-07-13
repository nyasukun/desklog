import Foundation

/// A window the user chose not to include in screen OCR or saved screenshots.
///
/// ScreenCaptureKit window IDs identify a particular window instance. The app
/// identity is stored as well so a recycled numeric ID cannot exclude a window
/// owned by a different application.
public struct ExcludedCaptureWindow: Codable, Identifiable, Sendable, Equatable, Hashable {
    public let windowID: UInt32
    public let bundleIdentifier: String
    public let applicationName: String
    public let windowTitle: String

    public init(
        windowID: UInt32,
        bundleIdentifier: String,
        applicationName: String,
        windowTitle: String
    ) {
        self.windowID = windowID
        self.bundleIdentifier = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        self.applicationName = applicationName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.windowTitle = windowTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var id: String {
        "\(windowID):\(bundleIdentifier.lowercased())"
    }

    public var displayTitle: String {
        windowTitle.isEmpty ? "タイトルなし" : windowTitle
    }
}

public struct CaptureExclusionPolicy: Sendable, Equatable {
    public let windows: [ExcludedCaptureWindow]

    public init(windows: [ExcludedCaptureWindow]) {
        var seen: Set<String> = []
        self.windows = windows.compactMap { window in
            let normalized = ExcludedCaptureWindow(
                windowID: window.windowID,
                bundleIdentifier: window.bundleIdentifier,
                applicationName: window.applicationName,
                windowTitle: window.windowTitle
            )
            guard normalized.windowID != 0,
                  !normalized.bundleIdentifier.isEmpty,
                  seen.insert(normalized.id).inserted else {
                return nil
            }
            return normalized
        }
    }

    public func excludes(windowID: UInt32, bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return windows.contains {
            $0.windowID == windowID &&
                $0.bundleIdentifier.caseInsensitiveCompare(bundleIdentifier) == .orderedSame
        }
    }

    /// Candidates must be supplied in front-to-back order. If the active
    /// window is excluded, selection naturally falls through to the next one.
    public func firstAllowed(
        fromFrontToBack candidates: [ExcludedCaptureWindow]
    ) -> ExcludedCaptureWindow? {
        candidates.first {
            !excludes(windowID: $0.windowID, bundleIdentifier: $0.bundleIdentifier)
        }
    }
}
