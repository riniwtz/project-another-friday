import Foundation
import Combine
import UserNotifications
import AppKit

/// System-native notifications. macOS owns their presentation and Focus rules; Hark never draws
/// a fake iOS notification or attempts to bypass notification permissions.
@MainActor
final class NotificationManager: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published private(set) var authorization: UNAuthorizationStatus = .notDetermined
    @Published private(set) var temporarilyMutedUntil: Date?
    @Published var lastError: String?

    private let center = UNUserNotificationCenter.current()
    private let muteAction = "HARK_MUTE_ONE_HOUR"

    override init() {
        super.init()
        center.delegate = self
        let mute = UNNotificationAction(identifier: muteAction, title: "Mute for 1 Hour", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "HARK_SOUND_EVENT", actions: [mute], intentIdentifiers: [], options: [])
        ])
        refreshAuthorization()
    }

    func refreshAuthorization() {
        center.getNotificationSettings { [weak self] settings in
            Task { @MainActor [weak self] in self?.authorization = settings.authorizationStatus }
        }
    }

    func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .badge, .sound]) { [weak self] _, error in
            Task { @MainActor [weak self] in
                self?.lastError = error?.localizedDescription
                self?.refreshAuthorization()
            }
        }
    }

    var isAuthorized: Bool { authorization == .authorized || authorization == .provisional }

    var isMuted: Bool {
        guard let date = temporarilyMutedUntil else { return false }
        return Date() < date
    }

    func clearMute() { temporarilyMutedUntil = nil }

    func openSystemNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
            NSWorkspace.shared.open(url)
        }
    }

    func notify(label: String, summary: String, urgent: Bool, playSound: Bool) {
        guard isAuthorized, !isMuted else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(urgent ? "⚠️" : Self.symbol(for: label))  \(label)"
        content.subtitle = "Hark detected a sound"
        content.body = summary
        content.categoryIdentifier = "HARK_SOUND_EVENT"
        content.threadIdentifier = "hark.\(label.lowercased().replacingOccurrences(of: " ", with: "-"))"
        // Only request normal system delivery. Even urgent sounds are not certified safety alarms.
        content.interruptionLevel = .active // Selected sounds use a normal visible banner.
        if playSound { content.sound = .default }
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { [weak self] error in
            if let error {
                Task { @MainActor [weak self] in self?.lastError = error.localizedDescription }
            }
        }
    }

    func sendTestNotification(playSound: Bool) {
        notify(label: "Doorbell", summary: "Someone may be at the door. (Synthetic test)", urgent: false, playSound: playSound)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // macOS decides final banner style; banners are non-modal and don't steal keyboard focus.
        var presentation: UNNotificationPresentationOptions = [.banner, .list]
        if notification.request.content.sound != nil { presentation.insert(.sound) }
        completionHandler(presentation)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.actionIdentifier == "HARK_MUTE_ONE_HOUR" {
            Task { @MainActor [weak self] in self?.temporarilyMutedUntil = Date().addingTimeInterval(3600) }
        }
        completionHandler()
    }

    static func symbol(for label: String) -> String {
        switch label {
        case "Doorbell": return "🔔"
        case "Knocking": return "🚪"
        case "Alarm": return "🚨"
        case "Dog barking": return "🐕"
        case "Crying": return "💧"
        case "Glass breaking": return "⚠️"
        default: return "🔊"
        }
    }
}
