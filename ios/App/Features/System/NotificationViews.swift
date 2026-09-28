import FluxKit
import Observation
import SwiftUI
import UIKit
import UserNotifications

/// Whether iOS lets Flux show notifications.
@MainActor
@Observable
final class NotificationAccess {
    static let shared = NotificationAccess()

    private(set) var status = UNAuthorizationStatus.notDetermined

    private init() {}

    /// Reads the setting again, for example after the user returns from Settings.
    func refresh() {
        Task {
            status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        }
    }

    /// Asks iOS the first time, and opens the notification settings of Flux after that.
    func turnOn(model: AppModel) {
        guard status == .notDetermined else {
            if let url = URL(string: UIApplication.openNotificationSettingsURLString) { UIApplication.shared.open(url) }
            return
        }
        Task {
            do {
                _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            } catch {
                model.show("Notifications are not available: \(error.localizedDescription)")
            }
            refresh()
        }
    }

    /// The state in a word or two.
    static func text(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .authorized, .provisional, .ephemeral: return "On"
        case .denied: return "Off"
        case .notDetermined: return "Not set up"
        @unknown default: return "Unknown"
        }
    }

    static func isOn(_ status: UNAuthorizationStatus) -> Bool {
        [.authorized, .provisional, .ephemeral].contains(status)
    }
}

/// The notifications that a computer sends with flux-cli notify.
struct NotificationsTile: View {
    @Environment(AppModel.self) private var model
    let device: DeviceSnapshot

    var body: some View {
        if model.core.plugin(NotificationsPlugin.self) != nil, device.outgoing.contains(PacketType.notification) {
            let access = NotificationAccess.shared
            FeatureTile(
                "Notifications",
                systemImage: NotificationAccess.isOn(access.status) ? "bell.fill" : "bell.slash",
                tint: .red,
                subtitle: NotificationAccess.isOn(access.status) ? "From flux-cli notify" : "\(NotificationAccess.text(access.status)). Tap to turn on"
            ) {
                access.turnOn(model: model)
            }
            .accessibilityHint("Opens the notification settings of Flux")
        }
    }
}

/// The notification state in the settings.
struct NotificationSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let access = NotificationAccess.shared
        Section {
            Button {
                access.turnOn(model: model)
            } label: {
                LabeledContent("Notifications", value: NotificationAccess.text(access.status))
            }
            .tint(.primary)
        } header: {
            Text("Notifications")
        } footer: {
            Text("Pairing requests and the notifications that computers send with flux-cli notify show while Flux runs.")
        }
    }
}
