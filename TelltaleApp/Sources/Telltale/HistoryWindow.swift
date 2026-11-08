import AppKit
import SwiftUI

/// Owns the single History window. Hosted with AppKit rather than a SwiftUI `Window` scene because, on macOS 14,
/// a `Window` scene opens at launch and cannot be suppressed, and a menu bar app needs the window to open on demand.
@MainActor
final class HistoryWindowController: NSObject, NSWindowDelegate {
    static let shared = HistoryWindowController()
    private var window: NSWindow?
    private var history: HistoryModel?

    func show(model: AppModel) {
        let history = model.history
        self.history = history
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 780, height: 800),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false)
            w.title = "Telltale History"
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.contentView = NSHostingView(rootView: HistoryWindowView(model: history))
            w.setFrameAutosaveName("TelltaleHistory")
            w.center()
            window = w
        }
        history.setActive(true)
        // Without a Dock icon the app is not active by default, so the window would open behind other apps.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Stop refreshing while the window is closed.
    func windowWillClose(_ notification: Notification) {
        history?.setActive(false)
    }
}
