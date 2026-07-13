import Foundation

public enum DesklogCaptureRequirement: String, Sendable, Equatable {
    case screenCapturePermission
    case microphonePermission
}

public enum ScreenCapturePermissionHistory {
    public static func status(
        preflightGranted: Bool,
        hasRequestedBefore: Bool
    ) -> DesklogPermissionStatus {
        if preflightGranted { return .authorized }
        return hasRequestedBefore ? .denied : .notDetermined
    }
}

/// A platform-independent view of the permissions required by enabled capture
/// sources. The app can request every still-undetermined permission from one
/// setup action; this type only describes readiness and does not impose a
/// sequential onboarding flow.
public struct CaptureReadinessGate: Sendable, Equatable {
    public var screenCaptureEnabled: Bool
    public var microphoneCaptureEnabled: Bool
    public var screenCaptureStatus: DesklogPermissionStatus
    public var microphoneStatus: DesklogPermissionStatus

    public init(
        screenCaptureEnabled: Bool,
        microphoneCaptureEnabled: Bool,
        screenCaptureStatus: DesklogPermissionStatus,
        microphoneStatus: DesklogPermissionStatus
    ) {
        self.screenCaptureEnabled = screenCaptureEnabled
        self.microphoneCaptureEnabled = microphoneCaptureEnabled
        self.screenCaptureStatus = screenCaptureStatus
        self.microphoneStatus = microphoneStatus
    }

    public var hasEnabledCaptureSource: Bool {
        screenCaptureEnabled || microphoneCaptureEnabled
    }

    public var missingRequirements: [DesklogCaptureRequirement] {
        var result: [DesklogCaptureRequirement] = []
        if screenCaptureEnabled, screenCaptureStatus != .authorized {
            result.append(.screenCapturePermission)
        }
        if microphoneCaptureEnabled, microphoneStatus != .authorized {
            result.append(.microphonePermission)
        }
        return result
    }

    public var canStart: Bool {
        hasEnabledCaptureSource && missingRequirements.isEmpty
    }

}
