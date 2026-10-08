import AppKit
import Combine

/// Turns keyboard input (the global shortcut, the optional single-key trigger and Esc)
/// into dictation start / stop / cancel.
@MainActor
final class HotkeyCoordinator: ObservableObject {
    /// True when another app already owns the chosen shortcut.
    @Published private(set) var shortcutUnavailable = false

    private enum HotkeyID {
        static let dictation: UInt32 = 1
        static let cancel: UInt32 = 2
    }

    /// In "tap or hold" mode, presses longer than this count as push-to-talk.
    private static let holdThreshold: TimeInterval = 0.35

    private let manager = HotkeyManager()
    private let modifierMonitor = ModifierKeyMonitor()
    private let controller: DictationController
    private let prefs: Preferences
    private var cancellables = Set<AnyCancellable>()
    private var isSuspended = false
    private var shortcutIsDown = false
    /// Set when the current key press started a dictation.
    private var pressStartedRecordingAt: Date?

    init(controller: DictationController, prefs: Preferences, permissions: PermissionsMonitor) {
        self.controller = controller
        self.prefs = prefs

        modifierMonitor.onPress = { [weak self] in self?.triggerPressed() }
        modifierMonitor.onRelease = { [weak self] in self?.triggerReleased() }
        modifierMonitor.onInterrupt = { [weak self] in self?.triggerInterrupted() }

        prefs.$shortcut
            .removeDuplicates()
            .sink { [weak self] shortcut in self?.register(shortcut) }
            .store(in: &cancellables)
        prefs.$modifierTrigger
            .removeDuplicates()
            .sink { [weak self] trigger in self?.modifierMonitor.setTrigger(trigger) }
            .store(in: &cancellables)
        // Key monitors created before Accessibility was granted receive nothing; recreate them.
        permissions.$accessibility
            .removeDuplicates()
            .dropFirst()
            .filter { $0 }
            .sink { [weak self] _ in self?.modifierMonitor.reinstall() }
            .store(in: &cancellables)
        controller.$phase
            .map(\.isActive)
            .removeDuplicates()
            .sink { [weak self] isActive in self?.setCancelHotkeyEnabled(isActive) }
            .store(in: &cancellables)
    }

    /// Temporarily releases the shortcut, e.g. while the user records a new one.
    func setSuspended(_ suspended: Bool) {
        isSuspended = suspended
        if suspended {
            manager.unregister(id: HotkeyID.dictation)
            shortcutIsDown = false
        } else {
            register(prefs.shortcut)
        }
    }

    private func register(_ shortcut: KeyShortcut) {
        manager.unregister(id: HotkeyID.dictation)
        shortcutIsDown = false
        guard !isSuspended else { return }
        shortcutUnavailable = !manager.register(shortcut, id: HotkeyID.dictation) { [weak self] isPressed in
            self?.shortcutChanged(isPressed: isPressed)
        }
    }

    private func shortcutChanged(isPressed: Bool) {
        if isPressed {
            guard !shortcutIsDown else { return } // ignore key repeat
            shortcutIsDown = true
            triggerPressed()
        } else {
            guard shortcutIsDown else { return }
            shortcutIsDown = false
            triggerReleased()
        }
    }

    private func triggerPressed() {
        switch controller.phase {
        case .preparing, .recording:
            pressStartedRecordingAt = nil
            controller.stop()
        case .idle, .done, .failed:
            pressStartedRecordingAt = Date()
            controller.start()
        case .transcribing, .downloadingModel:
            pressStartedRecordingAt = nil
        }
    }

    private func triggerReleased() {
        guard let startedAt = pressStartedRecordingAt else { return }
        pressStartedRecordingAt = nil
        switch prefs.hotkeyMode {
        case .toggle:
            break
        case .pushToTalk:
            controller.stop()
        case .hybrid:
            if Date().timeIntervalSince(startedAt) >= Self.holdThreshold { controller.stop() }
        }
    }

    private func triggerInterrupted() {
        guard pressStartedRecordingAt != nil else { return }
        pressStartedRecordingAt = nil
        controller.cancel(silently: true)
    }

    private func setCancelHotkeyEnabled(_ enabled: Bool) {
        if enabled {
            manager.register(.escape, id: HotkeyID.cancel) { [weak self] isPressed in
                if isPressed { self?.controller.cancel() }
            }
        } else {
            manager.unregister(id: HotkeyID.cancel)
        }
    }
}
