import AppKit
import SwiftUI

@MainActor
final class MainWindowManager: NSObject, ObservableObject, NSWindowDelegate {
    private let controller: DesklogController
    private var window: NSWindow?

    init(controller: DesklogController) {
        self.controller = controller
    }

    func show() {
        controller.refreshPermissions()
        let window = window ?? makeWindow()
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Desklog"
        window.minSize = NSSize(width: 780, height: 560)
        window.contentViewController = NSHostingController(rootView: MainWindowView(controller: controller))
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("DesklogMainWindow")
        self.window = window
        return window
    }
}
