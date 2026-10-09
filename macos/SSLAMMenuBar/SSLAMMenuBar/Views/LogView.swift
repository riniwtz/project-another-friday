import SwiftUI

struct LogView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Detection log")
                    .font(.headline)
                Spacer()
                Toggle("Auto-scroll", isOn: $appState.autoScrollLog)
                    .toggleStyle(.checkbox)
            }
            .padding()

            Divider()

            ScrollViewReader { proxy in
                List {
                    if appState.logEntries.isEmpty {
                        Text("No events yet. Choose Start from the menu bar menu.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(appState.logEntries) { entry in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.text)
                                    .font(.system(.body, design: .monospaced))
                                Text(entry.recordedAt.formatted(date: .omitted, time: .standard))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .id(entry.id)
                        }
                    }
                }
                .onChange(of: appState.logEntries.count) { _ in
                    guard appState.autoScrollLog, let last = appState.logEntries.last else { return }
                    withAnimation {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
        .frame(minWidth: 480, minHeight: 320)
    }
}
