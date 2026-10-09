import SwiftUI
import AppKit

// MARK: - App Entry Point
@main
struct AudioMosaicApp: App {
    @StateObject private var model = AudioDetectorViewModel()

    var body: some Scene {
        MenuBarExtra {
            // MARK: 1. Start Control
            Button(action: { model.startDetection() }) {
                HStack {
                    Text("Start")
                    if model.isListening {
                        Image(systemName: "checkmark")
                    }
                }
            }
            .disabled(model.isListening)

            // MARK: 2. Stop Control
            Button(action: { model.stopDetection() }) {
                Text("Stop")
            }
            .disabled(!model.isListening)

            Divider()

            // MARK: 3. Log Submenu
            Menu("Log (\(model.logs.count))") {
                if model.logs.isEmpty {
                    Text("No logs available")
                        .font(.caption)
                } else {
                    ForEach(model.logs.prefix(10), id: \.self) { entry in
                        Text(entry)
                    }
                    Divider()
                    Button("Clear Logs") {
                        model.clearLogs()
                    }
                }
            }

            // MARK: 4. Settings
            Button("Settings...") {
                model.openSettingsWindow()
            }

            // MARK: 5. About
            Button("About Audio Mosaic") {
                model.showAboutDialog()
            }

            Divider()

            // MARK: 6. Quit
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")

        } label: {
            // MARK: Clean Menu Bar Label (AppKit Compatible)
            HStack(spacing: 4) {
                Image(systemName: model.isListening ? "waveform.path.ecg.radial" : "waveform.circle")
                Text(" " + model.currentOutput)
            }
        }
        .menuBarExtraStyle(.menu)
    }
}

// MARK: - View Model & Mock Generator
@MainActor
final class AudioDetectorViewModel: ObservableObject {
    @Published private(set) var isListening: Bool = false
    @Published private(set) var currentOutput: String = "Idle"
    @Published private(set) var logs: [String] = []

    private var detectionTask: Task<Void, Never>?

    private let sampleOutputs = [
        "Dog Barking (92%)",
        "Speech: \"Hello world\"",
        "Keyboard Typing",
        "Piano Music (88%)",
        "Doorbell Chime",
        "Laughter Detected",
        "Speech: \"Testing mic\"",
        "Siren Sound (95%)"
    ]

    func startDetection() {
        guard !isListening else { return }
        isListening = true
        currentOutput = "Listening..."
        addLog("Started audio detection service")

        detectionTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                if Task.isCancelled { break }

                let nextOutput = self.sampleOutputs.randomElement() ?? "Sound Detected"
                let timestamp = Date().formatted(date: .omitted, time: .standard)

                self.currentOutput = nextOutput
                self.addLog("[\(timestamp)] \(nextOutput)")
            }
        }
    }

    func stopDetection() {
        guard isListening else { return }
        detectionTask?.cancel()
        detectionTask = nil
        isListening = false
        currentOutput = "Stopped"
        addLog("Stopped audio detection service")
    }

    func clearLogs() {
        logs.removeAll()
    }

    private func addLog(_ message: String) {
        logs.insert(message, at: 0)
        if logs.count > 30 {
            logs.removeLast()
        }
    }

    func showAboutDialog() {
        let alert = NSAlert()
        alert.messageText = "About Audio Mosaic"
        alert.informativeText = "Audio Mosaic Detector v1.0\n\nReal-time audio classification output stream."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    func openSettingsWindow() {
        let alert = NSAlert()
        alert.messageText = "Settings"
        alert.informativeText = "Audio Device: Default Microphone\nSensitivity: Normal\nDetection Interval: 2.5s"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Close")
        alert.runModal()
    }
}
