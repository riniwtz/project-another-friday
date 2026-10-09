import Foundation
import SwiftUI

struct SoundDetection: Hashable {
    let label: String
    let confidence: Double
}

struct SoundRecord: Codable, Identifiable {
    var id = UUID()
    var startedAt: Date
    var endedAt: Date?
    var labels: [String]
    var caption: String

    var duration: TimeInterval {
        max(0, (endedAt ?? Date()).timeIntervalSince(startedAt))
    }
}

struct HarkPreferences: Codable {
    // New settings have default values and are decoded individually for backward compatibility.
    var floatWindows = true
    var systemNotificationsEnabled = false
    var notificationSoundEnabled = false
    var alertCooldownSeconds = 60.0
    var inputDeviceID = "system"
    var outputDeviceID = "system"
    var inputGain = 0.8               // Software gain for the future audio pipeline.
    var listeningThreshold = 0.45     // Applied to sound confidence in this demo.
    var alertLabels: Set<String> = ["Doorbell", "Alarm", "Glass breaking"]
    var muteRepeatedAlerts = true
    var saveHistory = true

    enum CodingKeys: String, CodingKey {
        case inputDeviceID, outputDeviceID, inputGain, listeningThreshold, alertLabels,
             muteRepeatedAlerts, saveHistory, floatWindows, systemNotificationsEnabled,
             notificationSoundEnabled, alertCooldownSeconds
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        inputDeviceID = try c.decodeIfPresent(String.self, forKey: .inputDeviceID) ?? "system"
        outputDeviceID = try c.decodeIfPresent(String.self, forKey: .outputDeviceID) ?? "system"
        inputGain = try c.decodeIfPresent(Double.self, forKey: .inputGain) ?? 0.8
        listeningThreshold = try c.decodeIfPresent(Double.self, forKey: .listeningThreshold) ?? 0.45
        alertLabels = try c.decodeIfPresent(Set<String>.self, forKey: .alertLabels) ?? ["Doorbell", "Alarm", "Glass breaking"]
        muteRepeatedAlerts = try c.decodeIfPresent(Bool.self, forKey: .muteRepeatedAlerts) ?? true
        saveHistory = try c.decodeIfPresent(Bool.self, forKey: .saveHistory) ?? true
        floatWindows = try c.decodeIfPresent(Bool.self, forKey: .floatWindows) ?? true
        systemNotificationsEnabled = try c.decodeIfPresent(Bool.self, forKey: .systemNotificationsEnabled) ?? false
        notificationSoundEnabled = try c.decodeIfPresent(Bool.self, forKey: .notificationSoundEnabled) ?? false
        alertCooldownSeconds = try c.decodeIfPresent(Double.self, forKey: .alertCooldownSeconds) ?? 60
    }
}

@MainActor
final class HarkStore: ObservableObject {
    let notifications = NotificationManager()
    let startup = StartupManager()
    let models = ModelManager()
    var onFloatWindowsChanged: ((Bool) -> Void)?

    @Published private(set) var isListening = false
    @Published private(set) var caption = "Ready to listen"
    @Published private(set) var activeDetections: [SoundDetection] = []
    @Published private(set) var history: [SoundRecord] = []
    @Published private(set) var notice: String?
    @Published var preferences: HarkPreferences {
        didSet {
            savePreferences()
            if oldValue.floatWindows != preferences.floatWindows {
                onFloatWindowsChanged?(preferences.floatWindows)
            }
        }
    }

    private var timer: Timer?
    private var frameIndex = 0
    private var pendingSignature = ""
    private var pendingCount = 0
    private var committedSignature = ""
    private var lastAlertAt: [String: Date] = [:]

    static let alertOptions = ["Doorbell", "Knocking", "Alarm", "Dog barking", "Crying", "Glass breaking"]

    // Multiple concurrent labels are intentional: never collapse to a single argmax.
    private let demoFrames: [[SoundDetection]] = [
        [.init(label: "Speech", confidence: 0.91)],
        [.init(label: "Speech", confidence: 0.94)],
        [.init(label: "Speech", confidence: 0.88)],
        [.init(label: "Speech", confidence: 0.89), .init(label: "Clapping", confidence: 0.85)],
        [.init(label: "Speech", confidence: 0.87), .init(label: "Clapping", confidence: 0.82)],
        [.init(label: "Speech", confidence: 0.86)],
        [.init(label: "Speech", confidence: 0.91)],
        [.init(label: "Dog barking", confidence: 0.95), .init(label: "Rain", confidence: 0.69)],
        [.init(label: "Dog barking", confidence: 0.93), .init(label: "Rain", confidence: 0.72)],
        [.init(label: "Rain", confidence: 0.78)],
        [.init(label: "Rain", confidence: 0.81)],
        [.init(label: "Doorbell", confidence: 0.96), .init(label: "Speech", confidence: 0.63)],
        [.init(label: "Doorbell", confidence: 0.94), .init(label: "Speech", confidence: 0.68)],
        [.init(label: "Cat meowing", confidence: 0.91), .init(label: "Speech", confidence: 0.79)],
        [.init(label: "Cat meowing", confidence: 0.92), .init(label: "Speech", confidence: 0.82)],
        [.init(label: "Keyboard typing", confidence: 0.90)],
        [.init(label: "Keyboard typing", confidence: 0.89)],
        [.init(label: "Knocking", confidence: 0.96)],
        [.init(label: "Knocking", confidence: 0.93)],
        [.init(label: "Alarm", confidence: 0.97)],
        [.init(label: "Alarm", confidence: 0.94)],
        [.init(label: "Glass breaking", confidence: 0.97)],
        [.init(label: "Glass breaking", confidence: 0.92)],
        [.init(label: "Crying", confidence: 0.89)],
        [.init(label: "Crying", confidence: 0.90)]
    ]

    init() {
        let decoder = JSONDecoder()
        if let data = UserDefaults.standard.data(forKey: "hark.preferences") ?? UserDefaults(suiteName: "dev.rin.ambientlens")?.data(forKey: "ambient.preferences"),
           let decoded = try? decoder.decode(HarkPreferences.self, from: data) {
            preferences = decoded
        } else {
            preferences = HarkPreferences()
        }
        let initialHistoryURL = FileManager.default.fileExists(atPath: Self.historyURL.path)
            ? Self.historyURL : Self.legacyHistoryURL
        if let data = try? Data(contentsOf: initialHistoryURL),
           let records = try? decoder.decode([SoundRecord].self, from: data) {
            history = records
        }
    }

    var menuCaption: String { caption }

    func start() {
        guard !isListening else { return }
        isListening = true
        notice = nil
        frameIndex = 0
        pendingSignature = ""
        pendingCount = 0
        committedSignature = ""
        caption = "Listening…"
        consume(demoFrames[frameIndex])
        timer = Timer.scheduledTimer(withTimeInterval: 0.85, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.advanceDemo() }
        }
    }

    func stop() {
        guard isListening else { return }
        timer?.invalidate()
        timer = nil
        closeLatestRecord()
        isListening = false
        activeDetections = []
        committedSignature = ""
        pendingSignature = ""
        pendingCount = 0
        caption = "Hark"
        notice = nil
    }

    func clearHistory() {
        history.removeAll()
        saveHistory()
    }

    func showUpdateNotice() {
        notice = "Update checks aren't connected in the prototype."
    }

    // The production SSLAM adapter should pass detections into this function.
    func consume(_ detections: [SoundDetection]) {
        guard isListening else { return }
        let accepted = detections
            .filter { $0.confidence >= preferences.listeningThreshold }
            .sorted { $0.label < $1.label }
        let signature = accepted.map(\.label).joined(separator: "|")
        if signature == pendingSignature {
            pendingCount += 1
        } else {
            pendingSignature = signature
            pendingCount = 1
        }
        guard pendingCount >= 2, signature != committedSignature else { return }

        closeLatestRecord()
        committedSignature = signature
        activeDetections = accepted
        caption = Self.describe(accepted)

        if preferences.saveHistory, !accepted.isEmpty {
            history.insert(SoundRecord(startedAt: Date(), labels: accepted.map(\.label), caption: caption), at: 0)
            history = Array(history.prefix(500))
            saveHistory()
        }
        checkAlerts(accepted)
    }

    // Deterministic fallback for demos. Replace with the LFM scene narrator later.
    static func describe(_ detections: [SoundDetection]) -> String {
        let labels = Set(detections.map(\.label))
        if labels.isEmpty { return "No notable sounds" }
        if labels.contains("Speech") && labels.contains("Clapping") { return "Talking and clapping" }
        if labels.contains("Cat meowing") && labels.contains("Speech") { return "Cat meowing near conversation" }
        if labels.contains("Dog barking") && labels.contains("Rain") { return "Dog barking as rain falls" }
        if labels.contains("Doorbell") && labels.contains("Speech") { return "Doorbell during conversation" }
        let descriptions: [String: String] = [
            "Speech": "Someone is talking", "Clapping": "Clapping is audible",
            "Dog barking": "A dog is barking", "Rain": "Rain is falling",
            "Doorbell": "A doorbell is ringing", "Cat meowing": "A cat is meowing",
            "Keyboard typing": "Someone is typing", "Alarm": "An alarm is sounding",
            "Glass breaking": "Glass is breaking", "Knocking": "Someone is knocking",
            "Crying": "Crying is audible"
        ]
        if detections.count == 1 { return descriptions[detections[0].label] ?? detections[0].label }
        return detections.map(\.label).joined(separator: " + ")
    }

    func summarize(minutes: Int, question: String) -> String {
        let cutoff = Date().addingTimeInterval(Double(-minutes * 60))
        let records = history.filter { ($0.endedAt ?? Date()) >= cutoff }
        guard !records.isEmpty else { return "Synthetic history summary: No sound events have been recorded in this period." }
        let labels = Set(records.flatMap(\.labels)).sorted()
        let sequence = records.reversed().prefix(5).map(\.caption).joined(separator: "; ")
        return "Synthetic summary (rule-based, not LFM): Detected \(labels.joined(separator: ", ")). Recent changes: \(sequence). This is based only on saved event metadata, not microphone recordings."
    }

    private func advanceDemo() {
        frameIndex = (frameIndex + 1) % demoFrames.count
        consume(demoFrames[frameIndex])
    }

    private func checkAlerts(_ detections: [SoundDetection]) {
        for event in detections.map(\.label) where preferences.alertLabels.contains(event) {
            let now = Date()
            if preferences.muteRepeatedAlerts,
               let last = lastAlertAt[event], now.timeIntervalSince(last) < preferences.alertCooldownSeconds { continue }
            lastAlertAt[event] = now
            notice = "\(NotificationManager.symbol(for: event)) \(event) detected"
            if preferences.systemNotificationsEnabled {
                notifications.notify(label: event, summary: "Hark detected \(event.lowercased()). (Synthetic event)",
                                     urgent: event == "Alarm" || event == "Glass breaking",
                                     playSound: preferences.notificationSoundEnabled)
            }
            break
        }
    }

    private func closeLatestRecord() {
        guard !history.isEmpty, history[0].endedAt == nil else { return }
        history[0].endedAt = Date()
        saveHistory()
    }

    private func savePreferences() {
        if let data = try? JSONEncoder().encode(preferences) {
            UserDefaults.standard.set(data, forKey: "hark.preferences")
        }
    }

    private static var historyURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Hark", isDirectory: true).appendingPathComponent("history.json")
    }

    private static var legacyHistoryURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("AmbientLens", isDirectory: true).appendingPathComponent("history.json")
    }

    private func saveHistory() {
        guard let data = try? JSONEncoder().encode(history) else { return }
        try? FileManager.default.createDirectory(at: Self.historyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: Self.historyURL, options: .atomic)
    }
}
