import AppKit
import SwiftUI

@MainActor
final class DesklogApplicationDelegate: NSObject, NSApplicationDelegate {
    private static let hardTerminationTimeoutNanoseconds: UInt64 = 25_000_000_000
    weak var controller: DesklogController? {
        didSet {
            deliverPendingExternalURLs()
        }
    }
    private var pendingExternalURLs: [URL] = []
    private var isDeferringTermination = false
    private var didReplyToTermination = false
    private var terminationTimeoutTask: Task<Void, Never>?

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let controller else {
            pendingExternalURLs.append(contentsOf: urls)
            return
        }
        for url in urls {
            controller.handleExternalURL(url)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let controller else { return .terminateNow }
        guard !isDeferringTermination else { return .terminateLater }
        isDeferringTermination = true
        didReplyToTermination = false
        terminationTimeoutTask = Task { [weak self, weak sender] in
            do {
                try await Task.sleep(nanoseconds: Self.hardTerminationTimeoutNanoseconds)
            } catch {
                return
            }
            guard let self, let sender else { return }
            self.finishDeferredTermination(sender)
        }
        Task {
            await controller.prepareForTermination()
            finishDeferredTermination(sender)
        }
        return .terminateLater
    }

    private func deliverPendingExternalURLs() {
        guard let controller, !pendingExternalURLs.isEmpty else { return }
        let urls = pendingExternalURLs
        pendingExternalURLs.removeAll()
        for url in urls {
            controller.handleExternalURL(url)
        }
    }

    /// A final safety net for OS APIs that can remain blocked despite task
    /// cancellation (notably an in-flight ScreenCaptureKit screenshot).
    private func finishDeferredTermination(_ sender: NSApplication) {
        guard !didReplyToTermination else { return }
        didReplyToTermination = true
        terminationTimeoutTask?.cancel()
        terminationTimeoutTask = nil
        sender.reply(toApplicationShouldTerminate: true)
    }
}

@main
struct DesklogApp: App {
    @NSApplicationDelegateAdaptor(DesklogApplicationDelegate.self) private var appDelegate
    @StateObject private var controller: DesklogController
    @StateObject private var windowManager: MainWindowManager

    init() {
        let controller = DesklogController()
        let windowManager = MainWindowManager(controller: controller)
        _controller = StateObject(wrappedValue: controller)
        _windowManager = StateObject(wrappedValue: windowManager)
        appDelegate.controller = controller

        let onboardingKey = "desklog.did-show-permission-onboarding.v2"
        if !UserDefaults.standard.bool(forKey: onboardingKey) {
            UserDefaults.standard.set(true, forKey: onboardingKey)
            DispatchQueue.main.async {
                windowManager.show()
            }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(controller: controller) {
                windowManager.show()
            }
        } label: {
            if let displayText = controller.menuBarDisplayText {
                Label(
                    displayText,
                    systemImage: controller.isRunning ? "record.circle.fill" : "record.circle"
                )
                .labelStyle(.titleAndIcon)
            } else {
                Image(systemName: controller.isRunning ? "record.circle.fill" : "record.circle")
                    .accessibilityLabel("Desklog")
            }
        }
        .menuBarExtraStyle(.menu)
    }
}
