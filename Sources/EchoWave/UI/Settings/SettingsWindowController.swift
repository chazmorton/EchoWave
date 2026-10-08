import AppKit
import SwiftUI

enum SettingsTab: Hashable {
    case general, shortcuts, speech, permissions, history
}

@MainActor
final class SettingsRouter: ObservableObject {
    @Published var tab: SettingsTab = .general
}

/// Hosts the SwiftUI settings in a regular window. While it's open, EchoWave shows in
/// the Dock and ⌘-Tab like a normal app; otherwise it lives only in the menu bar.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let router = SettingsRouter()
    private let permissions: PermissionsMonitor
    private let makeContent: (SettingsRouter) -> AnyView
    private var window: NSWindow?

    init(prefs: Preferences, speech: SpeechEngine, controller: DictationController,
         hotkeys: HotkeyCoordinator, permissions: PermissionsMonitor, history: TranscriptHistory) {
        self.permissions = permissions
        makeContent = { router in
            AnyView(SettingsView(router: router)
                .environmentObject(prefs)
                .environmentObject(speech)
                .environmentObject(controller)
                .environmentObject(hotkeys)
                .environmentObject(permissions)
                .environmentObject(history))
        }
        super.init()
    }

    func show(_ tab: SettingsTab?) {
        if let tab { router.tab = tab }
        if window == nil {
            let hosting = NSHostingController(rootView: makeContent(router))
            let window = NSWindow(contentViewController: hosting)
            window.title = "EchoWave"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        permissions.startPolling()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        permissions.stopPolling()
        NSApp.setActivationPolicy(.accessory)
    }
}
