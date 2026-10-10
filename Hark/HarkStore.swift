import Foundation
import SwiftUI
import AppKit
import MLXLLM
import MLXLMCommon
import MLXHuggingFace
import HuggingFace
import Tokenizers

struct SoundDetection: Hashable, Sendable {
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
    var systemNotificationsEnabled = true
    var notificationSoundEnabled = false
    var alertCooldownSeconds = 60.0
    var inputDeviceID = "system"
    var outputDeviceID = "system"
    var inputGain = 1.0               // Software gain applied before feature extraction.
    var listeningThreshold = 0.25     // Sensitive enough for quieter and shorter household sounds.
    var alertLabels: Set<String> = ["Doorbell", "Alarm", "Glass breaking"]
    var muteRepeatedAlerts = true
    var saveHistory = true
    // Live mode requires an exported and parity-validated Core ML SSLAM.
    var liveMode = false
    var useNativeLFM = false
    var lfmDirectoryPath = ""
    var sslamDirectoryPath = "/Users/rin/Documents/Coding/project-another-friday/models/SSLAM_AS2M_Finetuned"
    var sslamCoreMLPath = ""
    var sslamComputeMode = "all"

    enum CodingKeys: String, CodingKey {
        case inputDeviceID, outputDeviceID, inputGain, listeningThreshold, alertLabels,
             muteRepeatedAlerts, saveHistory, floatWindows, systemNotificationsEnabled,
             notificationSoundEnabled, alertCooldownSeconds, liveMode, useNativeLFM,
             lfmDirectoryPath, sslamDirectoryPath, sslamCoreMLPath, sslamComputeMode
    }

    init() {}

    init(from decoder: any Swift.Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        inputDeviceID = try c.decodeIfPresent(String.self, forKey: .inputDeviceID) ?? "system"
        outputDeviceID = try c.decodeIfPresent(String.self, forKey: .outputDeviceID) ?? "system"
        let savedGain = try c.decodeIfPresent(Double.self, forKey: .inputGain)
        inputGain = savedGain == 0.8 ? 1.0 : (savedGain ?? 1.0)
        let savedThreshold = try c.decodeIfPresent(Double.self, forKey: .listeningThreshold)
        // Migrate former defaults while preserving sensitivity values the user customized.
        listeningThreshold = savedThreshold.map { [0.45, 0.35].contains($0) } == true
            ? 0.25 : (savedThreshold ?? 0.25)
        alertLabels = try c.decodeIfPresent(Set<String>.self, forKey: .alertLabels) ?? ["Doorbell", "Alarm", "Glass breaking"]
        muteRepeatedAlerts = try c.decodeIfPresent(Bool.self, forKey: .muteRepeatedAlerts) ?? true
        saveHistory = try c.decodeIfPresent(Bool.self, forKey: .saveHistory) ?? true
        floatWindows = try c.decodeIfPresent(Bool.self, forKey: .floatWindows) ?? true
        systemNotificationsEnabled = try c.decodeIfPresent(Bool.self, forKey: .systemNotificationsEnabled) ?? true
        notificationSoundEnabled = try c.decodeIfPresent(Bool.self, forKey: .notificationSoundEnabled) ?? false
        alertCooldownSeconds = try c.decodeIfPresent(Double.self, forKey: .alertCooldownSeconds) ?? 60
        // Old HTTP live settings should not activate native capture without a Core ML export.
        let requestedLive = try c.decodeIfPresent(Bool.self, forKey: .liveMode) ?? false
        useNativeLFM = try c.decodeIfPresent(Bool.self, forKey: .useNativeLFM) ?? false
        lfmDirectoryPath = try c.decodeIfPresent(String.self, forKey: .lfmDirectoryPath) ?? ""
        sslamDirectoryPath = try c.decodeIfPresent(String.self, forKey: .sslamDirectoryPath) ?? "/Users/rin/Documents/Coding/project-another-friday/models/SSLAM_AS2M_Finetuned"
        sslamCoreMLPath = try c.decodeIfPresent(String.self, forKey: .sslamCoreMLPath) ?? ""
        sslamComputeMode = try c.decodeIfPresent(String.self, forKey: .sslamComputeMode) ?? "all"
        liveMode = requestedLive && !sslamCoreMLPath.isEmpty
    }
}

@MainActor
final class HarkStore: ObservableObject {
    let notifications = NotificationManager()
    let startup = StartupManager()
    let models = ModelManager()
    private let lfm = NativeLFMEngine()
    private let sslam = SSLAMCoreMLEngine()
    private var microphone: MicrophoneCapture?
    private var audioInferenceBusy = false
    @Published private(set) var lastAudioInferenceMS: Double?
    @Published private(set) var lastSSLAMTimings: SSLAMTimings?
    @Published private(set) var sslamBenchmark: SSLAMBenchmark?
    @Published private(set) var benchmarkFilePath: String?
    @Published private(set) var isBenchmarkRunning = false
    @Published private(set) var skippedAudioWindows = 0
    @Published private(set) var liveStatus = "Choose a validated SSLAM Core ML export to enable live listening"
    var onFloatWindowsChanged: ((Bool) -> Void)?

    @Published private(set) var isListening = false
    @Published private(set) var caption = "Ready to listen"
    @Published private(set) var activeDetections: [SoundDetection] = []
    @Published private(set) var history: [SoundRecord] = []
    @Published private(set) var notice: String?
    @Published var preferences: HarkPreferences {
        didSet {
            savePreferences()
            if oldValue.lfmDirectoryPath != preferences.lfmDirectoryPath {
                Task { await lfm.unload() }
            }
            if oldValue.floatWindows != preferences.floatWindows {
                onFloatWindowsChanged?(preferences.floatWindows)
            }
        }
    }

    private var timer: Timer?
    private var narrationTask: Task<Void, Never>?
    private var connectionCheck: Task<Void, Never>?
    private var captureSession = UUID()
    private var frameIndex = 0
    private var pendingSignature = ""
    private var pendingCount = 0
    private var committedSignature = ""
    private var lastAlertAt: [String: Date] = [:]
    private var lastNarrationStarted = Date.distantPast

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
        if preferences.liveMode && isBenchmarkRunning {
            liveStatus = "Wait for the SSLAM benchmark to finish before starting live listening."
            return
        }
        skippedAudioWindows = 0
        isListening = true
        captureSession = UUID()
        notice = nil
        frameIndex = 0
        pendingSignature = ""
        pendingCount = 0
        committedSignature = ""
        lastNarrationStarted = .distantPast
        caption = "Listening…"
        if preferences.liveMode {
            guard !preferences.sslamCoreMLPath.isEmpty else {
                stop()
                liveStatus = "Select your converted SSLAM.mlpackage in Settings → AI first."
                notice = liveStatus
                return
            }
            liveStatus = "Preparing on-device SSLAM…"
            let session = captureSession
            Task { [weak self] in
                guard let self else { return }
                guard await MicrophoneCapture.requestPermission() else {
                    guard self.captureSession == session else { return }
                    self.stop()
                    self.liveStatus = AudioPipelineError.permissionDenied.localizedDescription
                    self.notice = self.liveStatus
                    return
                }
                do {
                    // Do not expose unverified Core ML outputs to notifications.
                    let path = self.preferences.sslamCoreMLPath
                    _ = try await Task.detached(priority: .userInitiated) {
                        try FeatureParityVerifier.verify(modelPath: path)
                    }.value
                    let mode = SSLAMComputeMode(rawValue: self.preferences.sslamComputeMode) ?? .all
                    try await self.sslam.load(at: URL(fileURLWithPath: path), computeMode: mode)
                    guard self.isListening, self.captureSession == session else { return }
                    let microphone = MicrophoneCapture { [weak self] window, rate, _ in
                        Task { @MainActor in self?.consumeLiveAudio(window, sampleRate: rate, session: session) }
                    }
                    try microphone.start(deviceID: self.preferences.inputDeviceID)
                    guard self.isListening, self.captureSession == session else {
                        microphone.stop()
                        return
                    }
                    self.microphone = microphone
                    self.liveStatus = "Native SSLAM listening — offline, no recordings"
                } catch {
                    guard self.captureSession == session else { return }
                    self.stop()
                    self.liveStatus = "SSLAM error: \(error.localizedDescription)"
                    self.notice = self.liveStatus
                }
            }
        } else {
            liveStatus = "Synthetic demo mode"
            consume(demoFrames[frameIndex])
            timer = Timer.scheduledTimer(withTimeInterval: 0.85, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.advanceDemo() }
            }
        }
    }

    // Backpressure: a slow Core ML inference must never queue indefinitely or
    // block the audio callback / SwiftUI thread. Stale sessions cannot publish.
    private func consumeLiveAudio(_ window: [Float], sampleRate: Double, session: UUID) {
        guard isListening, preferences.liveMode, captureSession == session else { return }
        guard !audioInferenceBusy else {
            skippedAudioWindows += 1
            return
        }
        audioInferenceBusy = true
        let threshold = preferences.listeningThreshold
        let gain = preferences.inputGain
        Task { [weak self] in
            guard let self else { return }
            let start = ProcessInfo.processInfo.systemUptime
            defer {
                if self.captureSession == session { self.audioInferenceBusy = false }
            }
            do {
                let result = try await self.sslam.classifyMeasured(pcm: window, sampleRate: sampleRate,
                                                                    threshold: threshold, gain: gain)
                guard self.isListening, self.captureSession == session else { return }
                self.lastSSLAMTimings = result.timings
                self.lastAudioInferenceMS = (ProcessInfo.processInfo.systemUptime - start) * 1000
                self.consume(result.detections)
            } catch {
                guard self.isListening, self.captureSession == session else { return }
                self.liveStatus = "Native SSLAM inference failed: \(error.localizedDescription)"
            }
        }
    }

    func chooseSSLAMModel() {
        let panel = NSOpenPanel()
        panel.message = "Select the converted SSLAM.mlpackage or SSLAM.mlmodelc folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.treatsFilePackagesAsDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            preferences.sslamCoreMLPath = url.path
            liveStatus = "Core ML model selected — use Test Native SSLAM before live listening"
        }
    }

    func testNativeSSLAM() {
        guard !preferences.sslamCoreMLPath.isEmpty else {
            liveStatus = "Select converted SSLAM model first"
            return
        }
        let path = preferences.sslamCoreMLPath
        liveStatus = "Loading native SSLAM model…"
        Task { [weak self] in
            guard let self else { return }
            do {
                let parity = try await Task.detached(priority: .userInitiated) {
                    try FeatureParityVerifier.verify(modelPath: path)
                }.value
                let mode = SSLAMComputeMode(rawValue: self.preferences.sslamComputeMode) ?? .all
                try await self.sslam.load(at: URL(fileURLWithPath: path), computeMode: mode)
                let began = ProcessInfo.processInfo.systemUptime
                let detections = try await self.sslam.classify(
                    pcm16k: [Float](repeating: 0, count: 16000), threshold: 0.5, gain: 1)
                let elapsed = Int((ProcessInfo.processInfo.systemUptime - began) * 1000)
                self.liveStatus = "Core ML inference OK (\(elapsed)ms, \(detections.count) detections on silence). Swift filterbank parity MAE: \(String(format: "%.4f", parity.meanAbsoluteError)). Real-world accuracy and onset latency still require testing."
            } catch {
                self.liveStatus = "Native SSLAM test failed: \(error.localizedDescription)"
            }
        }
    }

    // Measured off the UI actor. Saved reports include timings and settings,
    // never microphone audio or raw features.
    func benchmarkNativeSSLAM() {
        guard !isListening, !isBenchmarkRunning else {
            liveStatus = "Stop listening before benchmarking SSLAM."
            return
        }
        let path = preferences.sslamCoreMLPath
        guard !path.isEmpty else {
            liveStatus = "Choose the converted SSLAM model first."
            return
        }
        let mode = SSLAMComputeMode(rawValue: preferences.sslamComputeMode) ?? .all
        isBenchmarkRunning = true
        liveStatus = "SSLAM benchmark: loading + warmup, then 5 timed predictions…"
        Task { [weak self] in
            guard let self else { return }
            defer { self.isBenchmarkRunning = false }
            do {
                let report = try await self.sslam.benchmark(modelPath: path, mode: mode)
                self.sslamBenchmark = report
                let file = try Self.saveBenchmark(report)
                self.benchmarkFilePath = file.path
                self.liveStatus = String(format: "SSLAM benchmark completed. Median prediction %.0f ms; p95 prediction %.0f ms; median filterbank %.0f ms. Saved metadata report.",
                                         report.medianPredictionMS, report.p95PredictionMS, report.medianFilterbankMS)
            } catch {
                self.liveStatus = "SSLAM benchmark failed: \(error.localizedDescription)"
            }
        }
    }

    func showBenchmarkInFinder() {
        guard let benchmarkFilePath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: benchmarkFilePath)])
    }

    private static func saveBenchmark(_ report: SSLAMBenchmark) throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory,
                                                  in: .userDomainMask, appropriateFor: nil, create: true)
        let folder = support.appendingPathComponent("Hark/Benchmarks", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = "sslam-\(Int(report.recordedAt.timeIntervalSince1970))-\(report.computeUnits).json"
        let output = folder.appendingPathComponent(name)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(report).write(to: output, options: .atomic)
        return output
    }

    func stop() {
        guard isListening else { return }
        timer?.invalidate()
        timer = nil
        microphone?.stop()
        microphone = nil
        audioInferenceBusy = false
        captureSession = UUID()
        narrationTask?.cancel()
        narrationTask = nil
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
        // Selected alert sounds commit on the first confident window. Other ambient
        // labels retain two-window persistence to reduce transient false positives.
        let containsSelectedAlert = accepted.contains { preferences.alertLabels.contains($0.label) }
        let requiredWindows = containsSelectedAlert ? 1 : 2
        guard pendingCount >= requiredWindows, signature != committedSignature else { return }

        closeLatestRecord()
        committedSignature = signature
        activeDetections = accepted
        caption = Self.describe(accepted) // Fast, deterministic fallback: alerts never wait for LFM.

        if preferences.saveHistory, !accepted.isEmpty {
            history.insert(SoundRecord(startedAt: Date(), labels: accepted.map(\.label), caption: caption), at: 0)
            history = Array(history.prefix(500))
            saveHistory()
        }
        checkAlerts(accepted)
        narrationTask?.cancel()
        if preferences.useNativeLFM && !preferences.lfmDirectoryPath.isEmpty && !accepted.isEmpty,
           Date().timeIntervalSince(lastNarrationStarted) >= 3 {
            lastNarrationStarted = Date()
            let expectedSession = captureSession
            let expectedSignature = committedSignature
            let directory = URL(fileURLWithPath: preferences.lfmDirectoryPath, isDirectory: true)
            narrationTask = Task { [weak self] in
                guard let self else { return }
                do {
                    let result = try await self.lfm.narrate(detections: accepted, from: directory)
                    guard !Task.isCancelled, self.isListening, self.captureSession == expectedSession,
                          self.committedSignature == expectedSignature else { return }
                    guard NativeLFMEngine.captionIsGrounded(result, in: accepted) else {
                        self.liveStatus = "LFM generated an unverified caption; using detection labels"
                        return
                    }
                    self.caption = result
                    if self.preferences.saveHistory, !self.history.isEmpty,
                       self.history[0].endedAt == nil {
                        self.history[0].caption = result
                        self.saveHistory()
                    }
                } catch {
                    if !Task.isCancelled { self.liveStatus = "LFM: \(error.localizedDescription)" }
                }
            }
        }
    }

    /// Loads and tests LFM inside Hark. Neither LM Studio nor an HTTP service is used.
    func testNativeLFM() {
        connectionCheck?.cancel()
        let path = preferences.lfmDirectoryPath
        guard !path.isEmpty else {
            liveStatus = "Choose the complete LFM MLX model directory first."
            return
        }
        liveStatus = "Loading local LFM…"
        connectionCheck = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.lfm.test(from: URL(fileURLWithPath: path, isDirectory: true))
                guard !Task.isCancelled else { return }
                self.liveStatus = "LFM loaded and responded: \(result)"
            } catch {
                guard !Task.isCancelled else { return }
                self.liveStatus = "LFM error: \(error.localizedDescription)"
            }
        }
    }

    func chooseLFMDirectory() {
        let panel = NSOpenPanel()
        panel.message = "Select the folder containing LFM2.5-1.2B-Instruct-4bit config.json, tokenizer.json, and model.safetensors"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            preferences.lfmDirectoryPath = url.path
            liveStatus = "LFM folder selected. Press Test Native LFM."
        }
    }

    func askAboutSurroundings(minutes: Int, question: String) async -> String {
        guard preferences.useNativeLFM, !preferences.lfmDirectoryPath.isEmpty else {
            return summarize(minutes: minutes, question: question)
        }
        let cutoff = Date().addingTimeInterval(-Double(minutes * 60))
        let records = history.filter { ($0.endedAt ?? Date()) >= cutoff }
        guard !records.isEmpty else { return "No recorded sound events for this period." }
        do {
            return try await lfm.answer(
                question: question,
                history: records,
                from: URL(fileURLWithPath: preferences.lfmDirectoryPath, isDirectory: true)
            )
        } catch {
            return "Local LFM unavailable (\(error.localizedDescription)). \(summarize(minutes: minutes, question: question))"
        }
    }

    // Deterministic fallback for model timeouts, single-label events, and demo mode.
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
            notice = "\(event) detected"
            if preferences.systemNotificationsEnabled {
                notifications.notify(label: event, summary: "Hark detected \(event.lowercased())." + (preferences.liveMode ? "" : " (Synthetic event)"),
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

// MARK: - Native LFM inference
// Kept in the same compilation unit as HarkStore to prevent source-target
// membership mismatches that previously caused "Cannot find NativeLFMEngine in scope".

/// In-process MLX inference: no LM Studio and no HTTP server.
/// The actor serializes generation and retains the model between captions/Q&A.
actor NativeLFMEngine {
    private var model: ModelContainer?
    private var loadedDirectory: URL?

    enum NativeError: LocalizedError {
        case missingFile(String)
        case emptyOutput

        var errorDescription: String? {
            switch self {
            case .missingFile(let file): return "Missing required MLX model file: \(file)"
            case .emptyOutput: return "The model returned an empty response."
            }
        }
    }

    func unload() {
        model = nil
        loadedDirectory = nil
    }

    private func load(at directory: URL) async throws -> ModelContainer {
        let canonical = directory.standardizedFileURL
        if let model, loadedDirectory == canonical { return model }
        for file in ["config.json", "tokenizer.json"] {
            guard FileManager.default.fileExists(atPath: canonical.appendingPathComponent(file).path) else {
                throw NativeError.missingFile(file)
            }
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: canonical.path)
        guard files.contains(where: { $0.hasSuffix(".safetensors") }) else {
            throw NativeError.missingFile("model.safetensors")
        }
        // Loads local files using the user's existing MLX checkpoint.
        // No Hub downloads or remote API calls are made here.
        let container = try await loadModelContainer(
            from: canonical,
            using: #huggingFaceTokenizerLoader()
        )
        loadedDirectory = canonical
        model = container
        return container
    }

    private func generate(_ prompt: String, from directory: URL, maxTokens: Int) async throws -> String {
        let container = try await load(at: directory)
        let session = ChatSession(
            container,
            generateParameters: GenerateParameters(maxTokens: maxTokens, temperature: 0.1)
        )
        // Fresh session per request prevents stale conversation context contaminating captions.
        let value = try await session.respond(to: prompt)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw NativeError.emptyOutput }
        return value
    }

    func test(from directory: URL) async throws -> String {
        try await generate("Reply with exactly one word: ready", from: directory, maxTokens: 12)
    }

    func narrate(detections: [SoundDetection], from directory: URL) async throws -> String {
        let labels = detections.map { "\($0.label): \(Int($0.confidence * 100))%" }.joined(separator: ", ")
        let prompt = """
        You write short auditory scene captions for a deaf/hard-of-hearing person.
        Detected events: \(labels)
        Write one calm caption of at most 12 words. Describe ONLY the listed labels.
        Do not infer locations, speakers, causes, danger, or events not listed.
        No explanation, no quotes, no prefix.
        """
        return try await generate(prompt, from: directory, maxTokens: 24)
    }

    func answer(question: String, history: [SoundRecord], from directory: URL) async throws -> String {
        let recent = history.prefix(30).map { record in
            "\(record.startedAt.formatted(date: .omitted, time: .shortened)): \(record.labels.joined(separator: ", "))"
        }.joined(separator: "\n")
        let prompt = """
        You answer questions about recorded sound events. Use only the log below.
        If the log lacks evidence, say that you don't know. No invented events.
        EVENT LOG:
        \(recent)
        QUESTION: \(question)
        Provide a short answer, under 70 words.
        """
        return try await generate(prompt, from: directory, maxTokens: 128)
    }

    /// Allows only short captions whose vocabulary can be justified by detected events.
    /// This is a conservative heuristic, not a proof of semantic correctness.
    static func captionIsGrounded(_ text: String, in detections: [SoundDetection]) -> Bool {
        let glue: Set<String> = ["a", "an", "the", "and", "is", "are", "was", "were", "as",
                                 "while", "with", "nearby", "audible", "heard", "sound", "sounds",
                                 "someone", "something", "of", "in", "background", "there", "can", "be"]
        let synonyms: [String: Set<String>] = [
            "Speech": ["talking", "talk", "speaking", "speech", "conversation", "voices", "voice", "person"],
            "Clapping": ["clapping", "clap", "claps", "applause"],
            "Doorbell": ["doorbell", "ringing", "rings", "ring"],
            "Knocking": ["knocking", "knocks", "knock"],
            "Dog barking": ["dog", "barking", "barks", "bark"],
            "Cat meowing": ["cat", "meowing", "meows", "meow"],
            "Alarm": ["alarm", "ringing", "beeping", "sounds"],
            "Glass breaking": ["glass", "breaking", "breaks", "shattering", "shatters"],
            "Crying": ["crying", "cries", "cry", "sobbing"],
            "Rain": ["rain", "raining", "falling", "falls"],
            "Keyboard typing": ["keyboard", "typing", "keys", "typed", "tapping"]
        ]
        let words = text.lowercased()
            .split(whereSeparator: { !$0.isLetter })
            .map(String.init)
        guard !words.isEmpty, words.count <= 12 else { return false }
        var allowed = glue
        var evidence = Set<String>()
        for detection in detections {
            let vocabulary = Set(detection.label.lowercased()
                .split(whereSeparator: { !$0.isLetter }).map(String.init))
                .union(synonyms[detection.label] ?? [])
            allowed.formUnion(vocabulary)
            evidence.formUnion(vocabulary)
        }
        return words.allSatisfy(allowed.contains) && words.contains(where: evidence.contains)
    }
}
