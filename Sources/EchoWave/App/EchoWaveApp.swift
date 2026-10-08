import AppKit
import Combine

@main
@MainActor
enum EchoWaveMain {
    private static let delegate = AppDelegate()

    static func main() {
        if CommandLineMode.runIfRequested() { return }
        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let prefs = Preferences.shared
    private let history = TranscriptHistory.shared
    private let permissions = PermissionsMonitor.shared
    private let speech = SpeechEngine()
    private var controller: DictationController!
    private var hotkeys: HotkeyCoordinator!
    private var floatingPanel: FloatingPanelController!
    private var statusBar: StatusBarController!
    private var settings: SettingsWindowController!
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if activateExistingInstance() {
            NSApp.terminate(nil)
            return
        }

        MainMenu.install()
        controller = DictationController(speech: speech, prefs: prefs, history: history, permissions: permissions)
        hotkeys = HotkeyCoordinator(controller: controller, prefs: prefs, permissions: permissions)
        settings = SettingsWindowController(prefs: prefs, speech: speech, controller: controller,
                                            hotkeys: hotkeys, permissions: permissions, history: history)
        AppRouter.shared.showSettingsHandler = { [weak self] tab in self?.settings.show(tab) }
        floatingPanel = FloatingPanelController(controller: controller, prefs: prefs)
        statusBar = StatusBarController(controller: controller, prefs: prefs, speech: speech, history: history)

        speech.prepare(localeIdentifier: prefs.localeIdentifier)
        Task { await speech.loadAvailableLocales() }
        prefs.$localeIdentifier
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] identifier in self?.speech.prepare(localeIdentifier: identifier) }
            .store(in: &cancellables)

        // First launch: walk through permissions.
        permissions.refresh()
        if !prefs.hasCompletedOnboarding {
            prefs.hasCompletedOnboarding = true
            settings.show(.permissions)
        }
    }

    /// Opening EchoWave again from Finder or Spotlight shows its settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settings?.show(nil)
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        permissions.refresh()
    }

    private func activateExistingInstance() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0 != NSRunningApplication.current }
        guard let existing = others.first else { return false }
        existing.activate()
        return true
    }
}
