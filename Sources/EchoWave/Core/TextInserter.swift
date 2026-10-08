import AppKit
import ApplicationServices

enum InsertOutcome: Equatable {
    case pasted
    case copied
    /// Couldn't paste because EchoWave isn't trusted for Accessibility; the text is on the clipboard.
    case copiedNeedsAccessibility

    var message: String {
        switch self {
        case .pasted: "Inserted"
        case .copied: "Copied to clipboard"
        case .copiedNeedsAccessibility: "Copied — allow Accessibility to auto-paste"
        }
    }
}

/// Types the transcript into whatever app has focus, by pasting it.
@MainActor
enum TextInserter {
    /// Tells clipboard managers to skip our temporary clipboard contents (nspasteboard.org convention).
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    static func insert(_ text: String, mode: InsertionMode, restoreClipboard: Bool) -> InsertOutcome {
        let pasteboard = NSPasteboard.general
        guard mode == .paste else {
            write(text, to: pasteboard, transient: false)
            return .copied
        }
        guard AXIsProcessTrusted() else {
            write(text, to: pasteboard, transient: false)
            return .copiedNeedsAccessibility
        }

        let saved = restoreClipboard ? snapshot(of: pasteboard) : nil
        write(text, to: pasteboard, transient: restoreClipboard)
        let changeCount = pasteboard.changeCount
        postCommandV()

        if let saved {
            Task { @MainActor in
                // Give the target app time to read the clipboard before putting the old contents back.
                try? await Task.sleep(for: .milliseconds(600))
                guard pasteboard.changeCount == changeCount else { return } // something else was copied meanwhile
                pasteboard.clearContents()
                if !saved.isEmpty { pasteboard.writeObjects(saved) }
            }
        }
        return .pasted
    }

    static func copy(_ text: String) {
        write(text, to: NSPasteboard.general, transient: false)
    }

    private static func write(_ text: String, to pasteboard: NSPasteboard, transient: Bool) {
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        if transient { item.setData(Data(), forType: transientType) }
        pasteboard.writeObjects([item])
    }

    private static func snapshot(of pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
    }

    private static func postCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let key = KeyboardLayout.pasteKeyCode()
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cgSessionEventTap)
        keyUp?.post(tap: .cgSessionEventTap)
    }
}
