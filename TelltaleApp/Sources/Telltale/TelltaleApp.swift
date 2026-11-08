import SwiftUI
import TelltaleCore

@main
struct TelltaleApp: App {
    @State private var model: AppModel

    init() {
        let model = AppModel()
        model.start()
        _model = State(initialValue: model)

        // Launch flags so these paths can be exercised without clicking: `open -n Telltale.app --args --open-history`.
        let args = CommandLine.arguments
        if args.contains("--open-history") {
            DispatchQueue.main.async { HistoryWindowController.shared.show(model: model) }
        }
        if args.contains("--test-notification") {
            Task { _ = await model.notifier.send(title: "Telltale test", body: "Notifications are working.", sound: true) }
        }
        // `Telltale --login-item on|off` registers or removes the login item and prints the outcome (for verification).
        if let i = args.firstIndex(of: "--login-item"), i + 1 < args.count {
            model.setLaunchAtLogin(args[i + 1] == "on")
            let line = "login item: status=\(model.launchAtLoginStatus) error=\(model.launchAtLoginError ?? "none")\n"
            FileHandle.standardError.write(Data(line.utf8))
        }
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView(model: model)
        } label: {
            MenuBarLabel(state: model.menuState)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Glyph, plus a short cause next to it only when something is wrong.
struct MenuBarLabel: View {
    let state: MenuBarState

    var body: some View {
        HStack(spacing: 4) {
            Image(nsImage: StatusGlyph.image(for: state.level))
            if let label = state.label { Text(label) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(StatusGlyph.accessibilityName(state.level) + (state.label.map { ", \($0)" } ?? ""))
    }
}
