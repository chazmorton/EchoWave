import AppKit
import Combine

/// EchoWave's menu bar icon and menu.
@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let controller: DictationController
    private let prefs: Preferences
    private let speech: SpeechEngine
    private let history: TranscriptHistory
    private var cancellables = Set<AnyCancellable>()

    init(controller: DictationController, prefs: Preferences, speech: SpeechEngine, history: TranscriptHistory) {
        self.controller = controller
        self.prefs = prefs
        self.speech = speech
        self.history = history
        super.init()

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
        statusItem.button?.toolTip = "EchoWave"

        controller.$phase
            .map(\.kind)
            .removeDuplicates()
            .sink { [weak self] kind in self?.updateIcon(kind) }
            .store(in: &cancellables)
    }

    private func updateIcon(_ phaseKind: String) {
        let symbol = switch phaseKind {
        case "recording": "waveform.circle.fill"
        case "transcribing": "ellipsis.circle"
        default: "waveform"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "EchoWave")
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let status = NSMenuItem(title: statusLine, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        switch controller.phase {
        case .preparing, .recording:
            menu.addItem(ActionMenuItem("Stop Dictation") { [weak self] in self?.controller.stop() })
            menu.addItem(ActionMenuItem("Cancel Dictation") { [weak self] in self?.controller.cancel() })
        default:
            let start = ActionMenuItem("Start Dictation") { [weak self] in self?.controller.start() }
            if let key = prefs.shortcut.menuKeyEquivalent {
                start.keyEquivalent = key
                start.keyEquivalentModifierMask = prefs.shortcut.modifierFlags
            } else {
                start.title += "  (\(prefs.shortcut.displayString))"
            }
            start.isEnabled = !controller.phase.isActive
            menu.addItem(start)
        }
        menu.addItem(.separator())

        let paste = ActionMenuItem("Paste Last Transcript") { [weak self] in
            // Let the menu close and focus return to the previous app first.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(150))
                self?.controller.pasteLastTranscript()
            }
        }
        paste.isEnabled = controller.lastTranscript != nil
        menu.addItem(paste)
        menu.addItem(recentTranscriptsItem())
        menu.addItem(.separator())

        let floating = ActionMenuItem("Show Floating Button") { [weak self] in self?.prefs.showFloatingButton.toggle() }
        floating.state = prefs.showFloatingButton ? .on : .off
        menu.addItem(floating)
        menu.addItem(ActionMenuItem("Settings…", keyEquivalent: ",") { AppRouter.shared.showSettings() })
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit EchoWave", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private var statusLine: String {
        switch controller.phase {
        case .preparing, .recording: return "Listening…"
        case .transcribing: return "Transcribing…"
        default: break
        }
        switch speech.status {
        case .ready:
            let language = speech.locale.map(SpeechEngine.displayName(for:)) ?? "Ready"
            return "Ready · \(language)"
        case .downloading(let progress): return "Downloading speech model… \(Int(progress * 100))%"
        case .idle, .checking: return "Preparing speech model…"
        case .unsupported: return "Language not supported — check Settings"
        case .failed: return "Speech model unavailable — check Settings"
        }
    }

    private func recentTranscriptsItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Recent Transcripts", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let recent = history.items.prefix(8)
        if recent.isEmpty {
            let empty = NSMenuItem(title: "No transcripts yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        } else {
            for record in recent {
                let title = record.text.count > 60 ? record.text.prefix(57) + "…" : record.text
                let entry = ActionMenuItem(title) { TextInserter.copy(record.text) }
                entry.toolTip = "Click to copy"
                submenu.addItem(entry)
            }
        }
        submenu.addItem(.separator())
        submenu.addItem(ActionMenuItem("Show All…") { AppRouter.shared.showSettings(.history) })
        item.submenu = submenu
        return item
    }
}
