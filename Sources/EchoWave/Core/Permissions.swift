import AppKit
import ApplicationServices
import AVFoundation

/// Tracks the two permissions EchoWave needs: the microphone (to hear you) and
/// Accessibility (to paste into other apps and watch for single-key triggers).
@MainActor
final class PermissionsMonitor: ObservableObject {
    static let shared = PermissionsMonitor()

    @Published private(set) var microphone = AVCaptureDevice.authorizationStatus(for: .audio)
    @Published private(set) var accessibility = AXIsProcessTrusted()

    private var pollTimer: Timer?

    var microphoneGranted: Bool { microphone == .authorized }
    var allGranted: Bool { microphoneGranted && accessibility }

    func refresh() {
        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        if mic != microphone { microphone = mic }
        let trusted = AXIsProcessTrusted()
        if trusted != accessibility { accessibility = trusted }
    }

    /// macOS doesn't announce permission changes, so poll while the settings window is open.
    func startPolling() {
        refresh()
        guard pollTimer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// Returns whether the microphone may be used, asking the first time.
    func ensureMicrophoneAccess() async -> Bool {
        refresh()
        switch microphone {
        case .authorized:
            return true
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            refresh()
            return granted
        default:
            return false
        }
    }

    func requestMicrophone() {
        if microphone == .notDetermined {
            Task { _ = await ensureMicrophoneAccess() }
        } else {
            open("Privacy_Microphone")
        }
    }

    func requestAccessibility() {
        // An entry left by an earlier build looks switched on in System Settings but doesn't
        // apply to this build, and the prompt below won't replace it. Clear it first.
        resetAccessibilityEntry()
        // Shows the system prompt and adds this build of EchoWave to the Accessibility list.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) {
            startPolling()
        }
    }

    private func resetAccessibilityEntry() {
        guard !AXIsProcessTrusted(), let bundleID = Bundle.main.bundleIdentifier else { return }
        let tccutil = Process()
        tccutil.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        tccutil.arguments = ["reset", "Accessibility", bundleID]
        tccutil.standardOutput = FileHandle.nullDevice
        tccutil.standardError = FileHandle.nullDevice
        do {
            try tccutil.run()
            tccutil.waitUntilExit()
        } catch {
            NSLog("EchoWave: couldn't reset Accessibility entry: \(error.localizedDescription)")
        }
    }

    func openAccessibilitySettings() {
        open("Privacy_Accessibility")
    }

    private func open(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}
