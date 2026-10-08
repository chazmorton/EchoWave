import AppKit

/// Watches a single modifier key (fn, right ⌥, …) and reports it as press / release,
/// ignoring it when it's used as part of a regular shortcut such as fn+← or ⌥E.
/// Global key monitoring requires the Accessibility permission.
@MainActor
final class ModifierKeyMonitor {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    /// The key turned out to be part of a key combination after `onPress` already fired.
    var onInterrupt: (() -> Void)?

    /// How long the key must be held alone before it counts as a press.
    private let armingDelay: Duration = .milliseconds(180)

    private var trigger: ModifierTrigger = .off
    private var monitors: [Any] = []
    private var isHeld = false
    private var didPress = false
    private var interrupted = false
    private var armTask: Task<Void, Never>?

    func setTrigger(_ trigger: ModifierTrigger) {
        guard trigger != self.trigger else { return }
        self.trigger = trigger
        reinstall()
    }

    /// Re-creates the event monitors, e.g. after Accessibility access was granted.
    func reinstall() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        reset()
        guard trigger != .off else { return }

        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }) {
            monitors.append(local)
        }
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .keyDown:
            if isHeld { interrupt() }
        case .flagsChanged:
            if event.keyCode == trigger.keyCode {
                let isDown = trigger.isDown(in: event.modifierFlags)
                if isDown, !isHeld {
                    began()
                } else if !isDown, isHeld {
                    ended()
                }
            } else if isHeld {
                interrupt()
            }
        default:
            break
        }
    }

    private func began() {
        isHeld = true
        didPress = false
        interrupted = false
        armTask?.cancel()
        armTask = Task { [weak self, armingDelay] in
            try? await Task.sleep(for: armingDelay)
            guard let self, !Task.isCancelled, self.isHeld, !self.interrupted else { return }
            self.didPress = true
            self.onPress?()
        }
    }

    private func ended() {
        isHeld = false
        armTask?.cancel()
        armTask = nil
        guard !interrupted else { return }
        if didPress {
            onRelease?()
        } else {
            // A quick tap: report it as an instant press and release.
            onPress?()
            onRelease?()
        }
    }

    private func interrupt() {
        guard !interrupted else { return }
        interrupted = true
        armTask?.cancel()
        armTask = nil
        if didPress { onInterrupt?() }
    }

    private func reset() {
        armTask?.cancel()
        armTask = nil
        isHeld = false
        didPress = false
        interrupted = false
    }
}

private extension ModifierTrigger {
    var keyCode: UInt16 {
        switch self {
        case .off: UInt16.max
        case .fn: 63
        case .rightOption: 61
        case .rightCommand: 54
        case .rightControl: 62
        }
    }

    /// Uses the device-dependent flag bits so the left and right keys are told apart.
    func isDown(in flags: NSEvent.ModifierFlags) -> Bool {
        switch self {
        case .off: false
        case .fn: flags.contains(.function)
        case .rightOption: flags.rawValue & 0x40 != 0 // NX_DEVICERALTKEYMASK
        case .rightCommand: flags.rawValue & 0x10 != 0 // NX_DEVICERCMDKEYMASK
        case .rightControl: flags.rawValue & 0x2000 != 0 // NX_DEVICERCTLKEYMASK
        }
    }
}
