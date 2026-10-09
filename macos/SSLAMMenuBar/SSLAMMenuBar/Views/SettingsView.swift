import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Form {
            Section("Display") {
                Slider(value: $appState.minScore, in: 0 ... 1, step: 0.05) {
                    Text("Minimum score")
                }
                Text("Events below this score are hidden in the menu bar ticker (Log always shows the full formatted line).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Mock feed") {
                Slider(value: $appState.mockInterval, in: 0.5 ... 10, step: 0.5) {
                    Text("Update interval (seconds)")
                }
                Text("Applies on the next Start. Future Python backend will use SSLAM hop/window settings instead.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Backend (future)") {
                Text("Python: .venv/bin/python app.py live --offline --jsonl …")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .padding()
    }
}
