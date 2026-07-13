import AVFoundation
import CoreGraphics
import DesklogCore
import Foundation

@MainActor
final class PermissionCoordinator: ObservableObject {
    @Published private(set) var screenCaptureStatus: DesklogPermissionStatus
    @Published private(set) var microphoneStatus: DesklogPermissionStatus
    @Published private(set) var isRequesting = false
    private let defaults: UserDefaults
    private let screenCaptureRequestKey = "desklog.screenCapturePermission.requested.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        screenCaptureStatus = ScreenCapturePermissionHistory.status(
            preflightGranted: CGPreflightScreenCaptureAccess(),
            hasRequestedBefore: defaults.bool(forKey: screenCaptureRequestKey)
        )
        microphoneStatus = Self.microphoneStatus()
    }

    func refresh() {
        screenCaptureStatus = ScreenCapturePermissionHistory.status(
            preflightGranted: CGPreflightScreenCaptureAccess(),
            hasRequestedBefore: defaults.bool(forKey: screenCaptureRequestKey)
        )
        microphoneStatus = Self.microphoneStatus()
    }

    /// Useful after rebuilding or moving an unsigned development app, where
    /// macOS may need to register the current executable before it appears in
    /// Privacy & Security. This never opens System Settings automatically.
    func retryScreenCaptureRegistration() async {
        guard !isRequesting else { return }
        isRequesting = true
        await performScreenCaptureRequest()
        isRequesting = false
    }

    /// Requests every permission used by the selected capture sources from one
    /// user action. Microphone is deliberately requested before screen capture:
    /// macOS can require a relaunch after enabling screen recording, so placing
    /// that prompt last avoids relaunching between the two permission prompts.
    func requestEnabledPermissions(
        screenCaptureEnabled: Bool,
        microphoneEnabled: Bool
    ) async {
        guard !isRequesting else { return }
        refresh()
        isRequesting = true

        if microphoneEnabled, microphoneStatus == .notDetermined {
            await performMicrophoneRequest()
        }
        if screenCaptureEnabled, screenCaptureStatus == .notDetermined {
            await performScreenCaptureRequest()
        }

        refresh()
        isRequesting = false
    }

    private func performMicrophoneRequest() async {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        microphoneStatus = granted ? .authorized : .denied
    }

    private func performScreenCaptureRequest() async {
        defaults.set(true, forKey: screenCaptureRequestKey)
        let granted = await Task.detached(priority: .userInitiated) {
            CGRequestScreenCaptureAccess()
        }.value
        screenCaptureStatus = granted ? .authorized : .denied
    }

    private static func microphoneStatus() -> DesklogPermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .authorized
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .restricted
        }
    }
}
