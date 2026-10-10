import AppKit
import SwiftUI

enum AppScreen: Hashable {
    case history, settings, ask, about

    var title: String {
        switch self {
        case .history: return "Label History"
        case .settings: return "Hark Settings"
        case .ask: return "Ask About My Surroundings"
        case .about: return "About Hark"
        }
    }
}

@MainActor
final class AppController: NSObject, NSApplicationDelegate {
    let store = HarkStore()
    private var statusController: StatusController?
    private var windows: [AppScreen: NSWindow] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        store.onFloatWindowsChanged = { [weak self] shouldFloat in
            self?.updateWindowLevels(shouldFloat)
        }
        statusController = StatusController(store: store) { [weak self] screen in
            self?.showWindow(screen)
        }
    }

    private func updateWindowLevels(_ enabled: Bool) {
        for window in windows.values {
            window.level = enabled ? .floating : .normal
            window.collectionBehavior = enabled ? [.canJoinAllSpaces, .fullScreenAuxiliary] : []
        }
    }

    private func showWindow(_ screen: AppScreen) {
        let window: NSWindow
        if let existing = windows[screen] {
            window = existing
        } else {
            let root: AnyView
            let size: NSSize
            switch screen {
            case .history:
                root = AnyView(HistoryView().environmentObject(store))
                size = NSSize(width: 700, height: 480)
            case .settings:
                root = AnyView(PreferencesView().environmentObject(store))
                size = NSSize(width: 760, height: 640)
            case .ask:
                root = AnyView(AskView().environmentObject(store))
                size = NSSize(width: 580, height: 425)
            case .about:
                root = AnyView(AboutView())
                size = NSSize(width: 460, height: 320)
            }

            // Standard NSWindow: system controls the window chrome, glass, corners,
            // material adaptivity, accessibility contrast, light/dark appearances.
            let hosting = NSHostingController(rootView: root)
            window = NSWindow(contentViewController: hosting)
            window.title = screen.title
            window.setContentSize(size)
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.isOpaque = false
            window.backgroundColor = .clear
            window.level = store.preferences.floatWindows ? .floating : .normal
            window.collectionBehavior = store.preferences.floatWindows
                ? [.canJoinAllSpaces, .fullScreenAuxiliary] : []
            window.minSize = screen == .settings
                ? NSSize(width: 700, height: 300)
                : NSSize(width: size.width - 50, height: size.height - 40)
            window.center()
            window.isReleasedWhenClosed = false
            windows[screen] = window
        }
        // Only intentional clicks on a window-opening command may activate the app.
        // Passive listening and native notifications never activate or steal focus.
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

final class ClickThroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
final class StatusController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: 202)
    private let popover = NSPopover()
    private let store: HarkStore
    private let open: (AppScreen) -> Void

    init(store: HarkStore, open: @escaping (AppScreen) -> Void) {
        self.store = store
        self.open = open
        super.init()

        if let button = item.button {
            button.title = ""
            button.toolTip = "Hark — local sound awareness"
            button.target = self
            button.action = #selector(togglePopover)
            let label = ClickThroughHostingView(rootView: StatusLabelView().environmentObject(store))
            label.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 5),
                label.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -5),
                label.topAnchor.constraint(equalTo: button.topAnchor),
                label.bottomAnchor.constraint(equalTo: button.bottomAnchor)
            ])
        }

        // NSPopover itself applies the system-native glass/material, including on future OSes.
        popover.behavior = .transient
        popover.animates = true
        let host = NSHostingController(rootView:
            PopoverView(open: { [weak self] screen in
                self?.popover.performClose(nil)
                self?.open(screen)
            }).environmentObject(store)
        )
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
    }

    @objc private func togglePopover() {
        guard let button = item.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}

@main
struct HarkApp: App {
    @NSApplicationDelegateAdaptor(AppController.self) var controller
    var body: some Scene { Settings { EmptyView() } }
}
