import Foundation
import Combine
import ServiceManagement

@MainActor
final class StartupManager: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var requiresApproval = false
    @Published var lastError: String?

    init() { refresh() }

    func refresh() {
        let status = SMAppService.mainApp.status
        isEnabled = status == .enabled
        requiresApproval = status == .requiresApproval
    }

    func setEnabled(_ value: Bool) {
        do {
            if value { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        refresh() // Always show actual OS registration, not merely intended UI state.
    }

    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}
