import DesklogCore
import Testing

@Suite struct CaptureReadinessGateTests {
    @Test func reportsAllMissingPermissionsUntilBothAreGranted() {
        var gate = CaptureReadinessGate(
            screenCaptureEnabled: true,
            microphoneCaptureEnabled: true,
            screenCaptureStatus: .notDetermined,
            microphoneStatus: .notDetermined
        )

        #expect(!gate.canStart)
        #expect(gate.missingRequirements == [.screenCapturePermission, .microphonePermission])
        gate.screenCaptureStatus = .authorized
        #expect(gate.missingRequirements == [.microphonePermission])
        gate.microphoneStatus = .authorized
        #expect(gate.canStart)
    }

    @Test func disabledScreenSourceDoesNotRequireScreenPermission() {
        let gate = CaptureReadinessGate(
            screenCaptureEnabled: false,
            microphoneCaptureEnabled: true,
            screenCaptureStatus: .denied,
            microphoneStatus: .authorized
        )
        #expect(gate.canStart)
        #expect(gate.missingRequirements.isEmpty)
    }

    @Test func authorizedScreenSourceCanStartWithoutMicrophone() {
        let gate = CaptureReadinessGate(
            screenCaptureEnabled: true,
            microphoneCaptureEnabled: false,
            screenCaptureStatus: .authorized,
            microphoneStatus: .denied
        )
        #expect(gate.canStart)
    }

    @Test func atLeastOneCaptureSourceMustRemainEnabled() {
        let gate = CaptureReadinessGate(
            screenCaptureEnabled: false,
            microphoneCaptureEnabled: false,
            screenCaptureStatus: .authorized,
            microphoneStatus: .authorized
        )
        #expect(!gate.hasEnabledCaptureSource)
        #expect(!gate.canStart)
    }

    @Test func deniedPermissionsRemainRecoveryRequirements() {
        let gate = CaptureReadinessGate(
            screenCaptureEnabled: true,
            microphoneCaptureEnabled: true,
            screenCaptureStatus: .denied,
            microphoneStatus: .restricted
        )
        #expect(gate.missingRequirements == [.screenCapturePermission, .microphonePermission])
    }

    @Test func screenPermissionHistoryDistinguishesFirstRequestFromDenial() {
        #expect(ScreenCapturePermissionHistory.status(preflightGranted: true, hasRequestedBefore: false) == .authorized)
        #expect(ScreenCapturePermissionHistory.status(preflightGranted: false, hasRequestedBefore: false) == .notDetermined)
        #expect(ScreenCapturePermissionHistory.status(preflightGranted: false, hasRequestedBefore: true) == .denied)
    }
}
