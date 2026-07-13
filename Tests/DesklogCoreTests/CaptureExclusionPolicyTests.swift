import DesklogCore
import Testing

@Suite struct CaptureExclusionPolicyTests {
    @Test func policyNormalizesDeduplicatesAndMatchesWindowIdentity() {
        let safari = ExcludedCaptureWindow(
            windowID: 42,
            bundleIdentifier: " com.apple.Safari ",
            applicationName: " Safari ",
            windowTitle: " Private notes "
        )
        let duplicate = ExcludedCaptureWindow(
            windowID: 42,
            bundleIdentifier: "COM.APPLE.SAFARI",
            applicationName: "Safari",
            windowTitle: "Changed title"
        )
        let policy = CaptureExclusionPolicy(windows: [
            safari,
            duplicate,
            .init(windowID: 0, bundleIdentifier: "com.example.Bad", applicationName: "Bad", windowTitle: "Bad"),
            .init(windowID: 43, bundleIdentifier: "", applicationName: "Missing", windowTitle: "Missing"),
        ])

        #expect(policy.windows.count == 1)
        #expect(policy.windows[0].bundleIdentifier == "com.apple.Safari")
        #expect(policy.windows[0].applicationName == "Safari")
        #expect(policy.windows[0].windowTitle == "Private notes")
        #expect(policy.excludes(windowID: 42, bundleIdentifier: "COM.APPLE.SAFARI"))
        #expect(!policy.excludes(windowID: 41, bundleIdentifier: "com.apple.Safari"))
        #expect(!policy.excludes(windowID: 42, bundleIdentifier: "com.apple.Mail"))
        #expect(!policy.excludes(windowID: 42, bundleIdentifier: nil))
    }

    @Test func differentWindowsFromTheSameApplicationRemainIndependent() {
        let policy = CaptureExclusionPolicy(windows: [
            .init(windowID: 10, bundleIdentifier: "com.apple.Safari", applicationName: "Safari", windowTitle: "Secret"),
        ])

        #expect(policy.excludes(windowID: 10, bundleIdentifier: "com.apple.Safari"))
        #expect(!policy.excludes(windowID: 11, bundleIdentifier: "com.apple.Safari"))
    }

    @Test func titlelessWindowHasReadableDisplayTitle() {
        let window = ExcludedCaptureWindow(
            windowID: 9,
            bundleIdentifier: "com.example.App",
            applicationName: "Example",
            windowTitle: "  "
        )
        #expect(window.displayTitle == "タイトルなし")
    }
}
