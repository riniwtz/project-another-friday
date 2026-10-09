import SwiftUI

@main
struct SSLAMMenuBarApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuCommandsView()
                .environmentObject(appState)
        } label: {
            MenuBarLabelView()
                .environmentObject(appState)
        }
        .menuBarExtraStyle(.menu)

        Window("Detection Log", id: "log") {
            LogView()
                .environmentObject(appState)
        }
        .defaultSize(width: 520, height: 400)

        Window("Settings", id: "settings") {
            SettingsView()
                .environmentObject(appState)
        }
        .defaultSize(width: 440, height: 320)

        Window("About SSLAM Menu Bar", id: "about") {
            AboutView()
        }
        .defaultSize(width: 380, height: 280)
    }
}
