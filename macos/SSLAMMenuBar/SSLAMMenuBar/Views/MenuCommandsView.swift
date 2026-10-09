import SwiftUI

struct MenuCommandsView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Start") {
            appState.start()
        }
        .disabled(appState.isRunning)

        Button("Stop") {
            appState.stop()
        }
        .disabled(!appState.isRunning)

        Divider()

        Button("Settings…") {
            openWindow(id: "settings")
        }

        Button("About…") {
            openWindow(id: "about")
        }

        Button("Log…") {
            openWindow(id: "log")
        }

        Divider()

        Button("Quit") {
            appState.quit()
        }
    }
}
