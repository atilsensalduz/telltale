import AppKit
import ServiceManagement
import SwiftUI
import TelltaleCore
import UserNotifications

/// Owns the Settings window, opened from the popover. AppKit-hosted for the same reason as the History window.
@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show(model: AppModel) {
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 440, height: 470),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Telltale Settings"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView(model: model))
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    let model: AppModel
    @State private var status: UNAuthorizationStatus?

    private func binding(_ keyPath: WritableKeyPath<NotificationSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { model.notificationSettings[keyPath: keyPath] },
            set: { value in
                var settings = model.notificationSettings
                settings[keyPath: keyPath] = value
                model.updateNotificationSettings(settings)
            })
    }

    private var statusText: String? {
        switch status {
        case .denied: return "Notifications are turned off for Telltale. Turn them on in System Settings, under Notifications."
        case .notDetermined: return "macOS will ask for permission the first time a notification is sent."
        default: return nil
        }
    }

    var body: some View {
        Form {
            Section("General") {
                Toggle("Open Telltale when you log in", isOn: Binding(
                    get: { model.launchAtLoginStatus == .enabled || model.launchAtLoginStatus == .requiresApproval },
                    set: { model.setLaunchAtLogin($0) }))
                if model.launchAtLoginStatus == .requiresApproval {
                    Text("macOS needs your approval: open System Settings, then General, then Login Items.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error = model.launchAtLoginError {
                    Text(error).font(.caption).foregroundStyle(.orange)
                }
            }
            Section("Notify me") {
                Toggle("When an outage starts", isOn: binding(\.outageStart))
                Toggle("Play a sound", isOn: binding(\.outageSound))
                    .padding(.leading, 18)
                    .disabled(!model.notificationSettings.outageStart)
                Toggle("When an outage ends", isOn: binding(\.outageEnd))
                Toggle("When quality drops for 2 minutes or more", isOn: binding(\.qualityDrop))
                Text("Only the start of an outage can play a sound. A connection that keeps dropping is reported once, then summarised when it settles.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Button("Send test notification") {
                    model.sendTestNotification()
                    Task { status = await model.notifier.currentStatus() }
                }
                if let note = model.notificationNote {
                    Text(note).font(.caption).foregroundStyle(.orange)
                }
                if let text = statusText {
                    Text(text).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .task {
            model.refreshLaunchAtLogin()
            status = await model.notifier.currentStatus()
        }
    }
}
