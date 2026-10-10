import SwiftUI
import AppKit
import UserNotifications

// MARK: - Menu bar

struct StatusLabelView: View {
    @EnvironmentObject private var store: HarkStore

    var body: some View {
        HStack(spacing: 6) {
            Image("logo")
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .foregroundStyle(store.isListening ? Color.accentColor : Color.secondary)
                .frame(width: 17, height: 17)
            Divider().frame(height: 14)
            ZStack(alignment: .leading) {
                Text(store.menuCaption)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .id(store.menuCaption)
                    .transition(.asymmetric(
                        insertion: .offset(y: 19).combined(with: .opacity),
                        removal: .offset(y: -19).combined(with: .opacity)
                    ))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 20)
            .clipped()
            .animation(.easeInOut(duration: 0.3), value: store.menuCaption)
        }
        .foregroundStyle(.primary)
        .frame(maxWidth: .infinity, minHeight: 23)
        .accessibilityLabel("Hark: \(store.menuCaption)")
    }
}

private struct HoverMenuRow: View {
    let title: String
    let symbol: String
    var disabled = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text(title).font(.system(size: 13))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 11)
            .frame(height: 32)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .background(hovering && !disabled ? Color.accentColor : .clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
        .onHover { hovering = $0 }
    }
}

struct PopoverView: View {
    @EnvironmentObject private var store: HarkStore
    let open: (AppScreen) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                Image("logo")
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .foregroundStyle(.tint)
                    .padding(7)
                    .frame(width: 36, height: 36)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                Text("Hark")
                    .font(.system(size: 17, weight: .semibold))
                Spacer()
                Circle()
                    .fill(store.isListening ? Color.green : Color.secondary)
                    .frame(width: 8, height: 8)
                    .accessibilityLabel(store.isListening ? "Listening" : "Not listening")
            }
            .padding(.horizontal, 15)
            .padding(.top, 15)
            .padding(.bottom, 12)

            if store.isListening {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("CURRENT SCENE")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .tracking(0.7)
                        Spacer()
                        Image(systemName: "waveform")
                            .font(.caption)
                            .foregroundStyle(.green)
                            .accessibilityLabel("Listening")
                    }
                    Text(store.caption)
                        .font(.system(size: 15, weight: .medium))
                        .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
                        .contentTransition(.opacity)
                    if !store.activeDetections.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(store.activeDetections, id: \.label) { event in
                                    Text("\(event.label) · \(Int(event.confidence * 100))%")
                                        .font(.caption2)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 5)
                                        .background(.quaternary, in: Capsule())
                                }
                            }
                        }
                    }
                    if let notice = store.notice {
                        Label(notice, systemImage: "bell.badge")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(13)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.ultraThinMaterial.opacity(0.40), in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
                .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity),
                                        removal: .move(edge: .top).combined(with: .opacity)))
            }

            if !store.isListening, let notice = store.notice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 15)
                    .padding(.bottom, 8)
            }
            Divider()
            VStack(spacing: 2) {
                HoverMenuRow(title: "Start Listening", symbol: "play.fill", disabled: store.isListening) {
                    withAnimation(.easeInOut(duration: 0.25)) { store.start() }
                }
                HoverMenuRow(title: "Stop Listening", symbol: "stop.fill", disabled: !store.isListening) {
                    withAnimation(.easeInOut(duration: 0.25)) { store.stop() }
                }
                Divider().padding(.vertical, 4)
                HoverMenuRow(title: "Show Label History…", symbol: "clock.arrow.circlepath") { open(.history) }
                HoverMenuRow(title: "Ask About My Surroundings…", symbol: "text.bubble") { open(.ask) }
                HoverMenuRow(title: "Settings…", symbol: "gearshape") { open(.settings) }
                Divider().padding(.vertical, 4)
                HoverMenuRow(title: "About Hark", symbol: "info.circle") { open(.about) }
                HoverMenuRow(title: "Check for Updates…", symbol: "arrow.triangle.2.circlepath") { store.showUpdateNotice() }
                HoverMenuRow(title: "Quit Hark", symbol: "power") { NSApp.terminate(nil) }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
        .frame(width: 340)
        // NSPopover automatically supplies Apple's OS-native adaptive glass background.
        .animation(.easeInOut(duration: 0.25), value: store.isListening)
    }
}

// MARK: - Settings

private enum PreferencesTab: Hashable {
    case audio, ai, alerts, general, privacy

    var contentSize: NSSize {
        switch self {
        case .audio: NSSize(width: 800, height: 500)
        case .ai: NSSize(width: 800, height: 750)
        case .alerts: NSSize(width: 800, height: 700)
        case .general: NSSize(width: 800, height: 380)
        case .privacy: NSSize(width: 800, height: 410)
        }
    }
}

private struct WindowContentResizer: NSViewRepresentable {
    let size: NSSize

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            let topLeft = NSPoint(x: window.frame.minX, y: window.frame.maxY)
            let frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
            let targetFrame = NSRect(x: topLeft.x, y: topLeft.y - frame.height,
                                     width: frame.width, height: frame.height)
            window.setFrame(targetFrame, display: true, animate: true)
        }
    }
}

struct PreferencesView: View {
    @EnvironmentObject private var store: HarkStore
    @State private var selectedTab = PreferencesTab.audio
    @State private var inputDevices = [AudioDeviceChoice(id: "system", name: "System Default")]
    @State private var outputDevices = [AudioDeviceChoice(id: "system", name: "System Default")]
    @State private var confirmClear = false

    var body: some View {
        TabView(selection: $selectedTab) {
            Form {
                Picker("Input device", selection: $store.preferences.inputDeviceID) {
                    ForEach(inputDevices) { Text($0.name).tag($0.id) }
                }
                Picker("Output playback device", selection: $store.preferences.outputDeviceID) {
                    ForEach(outputDevices) { Text($0.name).tag($0.id) }
                }
                HStack {
                    Text("Input gain")
                    Slider(value: $store.preferences.inputGain, in: 0...2, step: 0.05)
                    Text("\(Int(store.preferences.inputGain * 100))%")
                        .monospacedDigit().frame(width: 48, alignment: .trailing)
                }
                HStack {
                    Text("Listening threshold")
                    Slider(value: $store.preferences.listeningThreshold, in: 0.10...0.90, step: 0.05)
                    Text("\(Int(store.preferences.listeningThreshold * 100))%")
                        .monospacedDigit().frame(width: 42, alignment: .trailing)
                }
                HStack {
                    Spacer()
                    Button("Restore Audio Defaults") {
                        store.preferences.inputGain = 1.0
                        store.preferences.listeningThreshold = 0.25
                    }
                }
                Text("Live mode captures microphone audio in memory and applies input gain and classification thresholds. Output device selection is retained for future audio playback (Hark does not play back recordings).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(16)
            .tabItem { Label("Audio", systemImage: "waveform") }
            .tag(PreferencesTab.audio)

            Form {
                Toggle("Generate captions with native LFM", isOn: $store.preferences.useNativeLFM)
                    .disabled(store.preferences.lfmDirectoryPath.isEmpty)
                HStack(spacing: 10) {
                    Text("LFM 1.2B MLX model folder")
                    Spacer(minLength: 10)
                    Text(store.preferences.lfmDirectoryPath.isEmpty ? "Not selected" : (store.preferences.lfmDirectoryPath as NSString).lastPathComponent)
                        .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                    Button("Choose…") { store.chooseLFMDirectory() }
                }
                Button("Test Native LFM") { store.testNativeLFM() }
                    .disabled(store.preferences.lfmDirectoryPath.isEmpty)
                Text(store.liveStatus)
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Divider()
                Text("SSLAM AudioSet-2M checkpoint")
                    .font(.headline)
                Text(store.preferences.sslamDirectoryPath)
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                HStack {
                    Text("Converted SSLAM Core ML")
                    Spacer()
                    Text(store.preferences.sslamCoreMLPath.isEmpty ? "Not selected" : (store.preferences.sslamCoreMLPath as NSString).lastPathComponent)
                        .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                    Button("Choose…") { store.chooseSSLAMModel() }
                        .disabled(store.isBenchmarkRunning || store.isListening)
                }
                Button("Test Native SSLAM") { store.testNativeSSLAM() }
                    .disabled(store.preferences.sslamCoreMLPath.isEmpty || store.isBenchmarkRunning)
                Picker("SSLAM compute units", selection: $store.preferences.sslamComputeMode) {
                    ForEach(SSLAMComputeMode.allCases) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
                .disabled(store.isListening || store.isBenchmarkRunning)
                HStack {
                    Button("Benchmark SSLAM (5 runs)") { store.benchmarkNativeSSLAM() }
                        .disabled(store.preferences.sslamCoreMLPath.isEmpty || store.isListening || store.isBenchmarkRunning)
                    if store.isBenchmarkRunning { ProgressView().controlSize(.small) }
                    if store.benchmarkFilePath != nil {
                        Button("Show Report in Finder") { store.showBenchmarkInFinder() }
                    }
                }
                if let timing = store.lastSSLAMTimings {
                    Text(String(format: "Live timing — Resample %.0f · Fbank %.0f · Input %.0f · Core ML %.0f · Labels %.0f · Total %.0f ms · Skipped %d",
                                timing.resampleMS, timing.filterbankMS, timing.inputCopyMS, timing.predictionMS,
                                timing.postprocessMS, timing.totalMS, store.skippedAudioWindows))
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
                if let report = store.sslamBenchmark {
                    Text(String(format: "Benchmark (%d runs) — Prediction median %.0f ms, p95 %.0f ms · Fbank median %.0f ms · Total median %.0f ms",
                                report.iterations, report.medianPredictionMS, report.p95PredictionMS,
                                report.medianFilterbankMS, report.medianTotalMS))
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
                Picker("Sound detection source", selection: $store.preferences.liveMode) {
                    Text("Synthetic events").tag(false)
                    Text("Live microphone · SSLAM Core ML").tag(true)
                }
                .disabled(store.isListening)
                if let ms = store.lastAudioInferenceMS {
                    Text("Last SSLAM inference: \(Int(ms)) ms").font(.caption).foregroundStyle(.secondary)
                }
                Label("Native SSLAM requires a validated Core ML conversion. Run the one-time conversion and compare predictions on actual sound clips before relying on live alerts.", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
                Text("All inference stays inside Hark. Neither Python nor LM Studio is required at runtime. Model folders must remain locally accessible.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(16)
            .tabItem { Label("AI", systemImage: "cpu") }
            .tag(PreferencesTab.ai)

            AlertSettingsView(store: store, manager: store.notifications)
                .tabItem { Label("Alerts", systemImage: "bell") }
                .tag(PreferencesTab.alerts)

            Form {
                Toggle("Float all Hark windows above other apps", isOn: $store.preferences.floatWindows)
                LaunchAtLoginSettings(manager: store.startup)
                Text("Only Hark's windows float. Native macOS notification banners never force the app to the foreground.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(16)
            .tabItem { Label("General", systemImage: "gearshape") }
            .tag(PreferencesTab.general)

            Form {
                Toggle("Save sound-event metadata locally", isOn: $store.preferences.saveHistory)
                Text("Synthetic and live modes are available. Live audio stays in memory, while optional event metadata, timestamps, labels, and captions are saved locally. LFM runs inside Hark.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Clear Saved History", role: .destructive) { confirmClear = true }
                        .disabled(store.history.isEmpty)
                }
            }
            .padding(16)
            .tabItem { Label("Privacy", systemImage: "hand.raised") }
            .tag(PreferencesTab.privacy)
        }
        .frame(width: selectedTab.contentSize.width, height: selectedTab.contentSize.height)
        .background(WindowContentResizer(size: selectedTab.contentSize))
        .background(.regularMaterial)
        .confirmationDialog("Clear all sound history?", isPresented: $confirmClear) {
            Button("Clear History", role: .destructive) { store.clearHistory() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes Hark's saved sound-event metadata from this Mac.")
        }
        .onAppear { loadDevices() }
    }

    private func loadDevices() {
        inputDevices = AudioDevices.choices(input: true)
        outputDevices = AudioDevices.choices(input: false)
        if !inputDevices.contains(where: { $0.id == store.preferences.inputDeviceID }) {
            inputDevices.append(.init(id: store.preferences.inputDeviceID, name: "Disconnected input device"))
        }
        if !outputDevices.contains(where: { $0.id == store.preferences.outputDeviceID }) {
            outputDevices.append(.init(id: store.preferences.outputDeviceID, name: "Disconnected output device"))
        }
    }
}

private struct LaunchAtLoginSettings: View {
    @ObservedObject var manager: StartupManager

    var body: some View {
        Toggle("Launch Hark at Login", isOn: Binding(
            get: { manager.isEnabled }, set: { manager.setEnabled($0) }
        ))
        if manager.requiresApproval {
            Label("Allow Hark in System Settings → Login Items", systemImage: "exclamationmark.circle")
                .font(.caption).foregroundStyle(.secondary)
            Button("Open Login Items Settings") { manager.openSystemSettings() }
        }
        if let error = manager.lastError {
            Text(error).font(.caption).foregroundStyle(.red)
            Button("Open Login Items Settings") { manager.openSystemSettings() }
        }
    }
}

private struct AlertSettingsView: View {
    @ObservedObject var store: HarkStore
    @ObservedObject var manager: NotificationManager

    private var bannerBinding: Binding<Bool> {
        Binding(get: { store.preferences.systemNotificationsEnabled }, set: { enabled in
            store.preferences.systemNotificationsEnabled = enabled
            if enabled && !manager.isAuthorized { manager.requestAuthorization() }
        })
    }

    var body: some View {
        Form {
            Toggle("Enable macOS notification banners", isOn: bannerBinding)
            HStack {
                Text("Permission")
                Spacer()
                Text(authDescription)
                    .foregroundStyle(manager.alertStyle == .none ? .orange : .secondary)
                Button("System Settings") { manager.openSystemNotificationSettings() }
                    .controlSize(.small)
            }
            if manager.isAuthorized && manager.alertStyle == .none {
                Label("Choose Banners or Alerts for Hark in System Settings to show notifications on screen.",
                      systemImage: "rectangle.badge.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Toggle("Play a notification sound", isOn: $store.preferences.notificationSoundEnabled)
            Divider()
            Text("Notify only for selected sounds").font(.headline)
            ForEach(HarkStore.alertOptions, id: \.self) { label in
                Toggle(isOn: Binding(
                    get: { store.preferences.alertLabels.contains(label) },
                    set: { value in
                        if value { store.preferences.alertLabels.insert(label) }
                        else { store.preferences.alertLabels.remove(label) }
                    }
                )) {
                    Label(label, systemImage: NotificationManager.systemImage(for: label))
                }
            }
            Toggle("Mute repeated alerts", isOn: $store.preferences.muteRepeatedAlerts)
            if store.preferences.muteRepeatedAlerts {
                HStack {
                    Text("Repeat cooldown")
                    Slider(value: $store.preferences.alertCooldownSeconds, in: 15...180, step: 15)
                    Text("\(Int(store.preferences.alertCooldownSeconds)) s")
                        .monospacedDigit().frame(width: 42, alignment: .trailing)
                }
            }
            if manager.isMuted {
                HStack {
                    Text("Alerts muted for one hour").foregroundStyle(.secondary)
                    Spacer()
                    Button("Unmute") { manager.clearMute() }
                }
            }
            HStack {
                Spacer()
                Button("Send Test Notification") {
                    manager.sendTestNotification(playSound: store.preferences.notificationSoundEnabled)
                }
            }
            if let error = manager.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            Text("Detections must persist across two inference results. Notifications are not certified safety alarms and may be delayed by classification or macOS Focus. Permission is requested only when enabled.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .onAppear { manager.refreshAuthorization() }
    }

    private var authDescription: String {
        switch manager.authorization {
        case .authorized:
            guard manager.alertsAllowed else { return "Banners disabled" }
            return manager.alertStyle == .none ? "Notification Center only" : "Allowed"
        case .provisional: return "Provisional"
        case .denied: return "Denied"
        case .notDetermined: return "Not requested"
        case .ephemeral: return "Temporary"
        @unknown default: return "Unknown"
        }
    }
}

// MARK: - History

struct HistoryView: View {
    @EnvironmentObject private var store: HarkStore
    @State private var query = ""
    @State private var confirmClear = false

    private var filtered: [SoundRecord] {
        guard !query.isEmpty else { return store.history }
        return store.history.filter { record in
            record.caption.localizedCaseInsensitiveContains(query) ||
            record.labels.joined(separator: " ").localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text("Sound Timeline").font(.title2.bold())
                Spacer()
                Button("Clear History", role: .destructive) { confirmClear = true }
                    .disabled(store.history.isEmpty)
            }
            TextField("Search events and captions", text: $query)
                .textFieldStyle(.roundedBorder)
            Divider()
            if filtered.isEmpty {
                ContentUnavailableView("No matching sound events", systemImage: "waveform",
                                       description: Text("Start listening to record sound events."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    GroupBox {
                        VStack(spacing: 10) {
                            ForEach(filtered) { record in
                                timelineRow(record)

                                if record.id != filtered.last?.id {
                                    Divider()
                                }
                            }
                        }
                        .padding(7)
                    }
                }
            }
        }
        .padding(20)
        .background(.regularMaterial)
        .confirmationDialog("Clear all sound history?", isPresented: $confirmClear) {
            Button("Clear History", role: .destructive) { store.clearHistory() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes the saved event history from this Mac. This can't be undone.")
        }
    }

    private func timelineRow(_ record: SoundRecord) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "waveform")
                .foregroundStyle(.tint)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(record.caption)
                    .font(.system(size: 13, weight: .medium))
                Text(record.labels.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(record.startedAt, style: .time)
                    .font(.caption)
                Text("\(Int(record.duration)) s")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Local models

struct ModelsView: View {
    @ObservedObject var manager: ModelManager

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Local AI Models").font(.title2.bold())
                Spacer()
                Button("Add Model Folder…") { manager.addFolder() }
                Button { manager.refresh() } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(manager.isScanning)
            }
            GroupBox("Hark model targets") {
                VStack(spacing: 10) {
                    targetRow("SSLAM", detail: "Polyphonic audio classification", installed: manager.installed("SSLAM"))
                    Divider()
                    targetRow("LFM2.5-1.2B Instruct 4-bit MLX", detail: "In-process narration and history Q&A", installed: manager.installed("LFM2.5"))
                }
                .padding(7)
            }
            HStack {
                Text("Detected model files").font(.headline)
                Spacer()
                if manager.isScanning { ProgressView().controlSize(.small) }
                Text("\(manager.models.count) found").foregroundStyle(.secondary).font(.caption)
            }
            if manager.models.isEmpty && !manager.isScanning {
                ContentUnavailableView("No local checkpoints found", systemImage: "externaldrive",
                    description: Text("Hark scans its model folder, common Hugging Face/LM Studio/Ollama caches, and any folders you add."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(manager.models) { model in
                    HStack(spacing: 10) {
                        Image(systemName: "cpu").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.name).fontWeight(.medium).lineLimit(1)
                            Text("\(model.source) · \(model.format) · \(ByteCountFormatter.string(fromByteCount: model.sizeBytes, countStyle: .file))")
                                .font(.caption).foregroundStyle(.secondary)
                            Text(model.location).font(.caption2).foregroundStyle(.tertiary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Button("Reveal") { manager.reveal(model) }
                            .controlSize(.small)
                    }
                    .padding(.vertical, 3)
                }
                .listStyle(.inset)
            }
            Text("Model discovery does not imply compatibility. Select the LFM MLX folder and a validated Core ML SSLAM export in Settings → AI; only these selected models are loaded.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .background(.regularMaterial)
        .onAppear { manager.refresh() }
    }

    private func targetRow(_ title: String, detail: String, installed: Bool) -> some View {
        HStack(spacing: 9) {
            Image(systemName: installed ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(installed ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(installed ? "Files detected" : "Not detected")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Ask and About

struct AskView: View {
    @EnvironmentObject private var store: HarkStore
    @State private var question = "What sounds have been happening?"
    @State private var selectedMinutes = 5
    @State private var answer = ""
    @State private var isAsking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Label("Ask About My Surroundings", systemImage: "text.bubble.fill")
                .font(.title2.bold())
            Text("Ask about locally recorded sound events in your recent history.")
                .font(.subheadline).foregroundStyle(.secondary)
            Picker("Look back", selection: $selectedMinutes) {
                Text("5 minutes").tag(5)
                Text("15 minutes").tag(15)
                Text("1 hour").tag(60)
            }
            .pickerStyle(.segmented)
            TextField("Ask a question…", text: $question)
                .textFieldStyle(.roundedBorder)
                .onSubmit { ask() }
            HStack {
                Spacer()
                if isAsking { ProgressView().controlSize(.small) }
                Button("Ask") { ask() }
                    .buttonStyle(.borderedProminent)
                    .disabled(isAsking || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            ScrollView {
                Text(answer.isEmpty ? "With native LFM enabled, answers are generated on this Mac using saved event metadata; otherwise a deterministic synthetic summary is shown." : answer)
                    .font(.system(size: 13))
                    .foregroundStyle(answer.isEmpty ? Color.secondary : Color.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(15)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
        }
        .padding(22)
        .background(.regularMaterial)
    }

    private func ask() {
        let prompt = question
        let minutes = selectedMinutes
        isAsking = true
        Task {
            answer = await store.askAboutSurroundings(minutes: minutes, question: prompt)
            isAsking = false
        }
    }
}

struct AboutView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform.path")
                .font(.system(size: 44)).foregroundStyle(.tint)
            Text("Hark").font(.title.bold())
            Text("Sound, made visible.").foregroundStyle(.secondary)
            Text("Native macOS menu-bar sound awareness\nLFM2.5-1.2B MLX · SSLAM Core ML (after conversion)")
                .multilineTextAlignment(.center).font(.subheadline)
            Text("Prototype 0.5 · Synthetic events + optional native MLX narration")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(25)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
    }
}
