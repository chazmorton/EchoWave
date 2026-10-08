import AppKit
import Carbon.HIToolbox
import SwiftUI

/// A button that records the next key combination as the new shortcut.
struct ShortcutRecorder: View {
    @Binding var shortcut: KeyShortcut
    /// Called with true while recording, so the current global shortcut can step aside.
    var onRecordingChange: (Bool) -> Void

    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            isRecording ? stopRecording() : startRecording()
        } label: {
            Text(isRecording ? "Type a shortcut…" : shortcut.displayString)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .frame(minWidth: 120)
        }
        .buttonStyle(.bordered)
        .tint(isRecording ? .accentColor : nil)
        .help("Click, then press the keys you want to use. Esc cancels.")
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        isRecording = true
        onRecordingChange(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape), event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
                stopRecording()
            } else if let recorded = KeyShortcut(event: event) {
                shortcut = recorded
                stopRecording()
            } else {
                NSSound.beep() // needs ⌘, ⌥ or ⌃ (or an F-key)
            }
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard isRecording else { return }
        isRecording = false
        onRecordingChange(false)
    }
}
