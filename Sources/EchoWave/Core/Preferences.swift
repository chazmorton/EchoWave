import Combine
import Foundation

/// How the dictation shortcut behaves.
enum HotkeyMode: String, CaseIterable, Identifiable {
    case hybrid, toggle, pushToTalk

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hybrid: "Tap or hold"
        case .toggle: "Toggle"
        case .pushToTalk: "Hold to talk"
        }
    }

    var explanation: String {
        switch self {
        case .hybrid: "Tap to start and tap again to stop — or hold while you speak and let go to finish."
        case .toggle: "Press once to start dictating and press again to stop."
        case .pushToTalk: "Hold the shortcut while you speak. Let go to finish."
        }
    }
}

/// An optional single key that also triggers dictation, like Wispr Flow's fn key.
enum ModifierTrigger: String, CaseIterable, Identifiable {
    case off, fn, rightOption, rightCommand, rightControl

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: "Off"
        case .fn: "fn / 🌐 Globe"
        case .rightOption: "Right ⌥ Option"
        case .rightCommand: "Right ⌘ Command"
        case .rightControl: "Right ⌃ Control"
        }
    }
}

/// What happens with the transcript once it's ready.
enum InsertionMode: String, CaseIterable, Identifiable {
    case paste, clipboard

    var id: String { rawValue }

    var title: String {
        switch self {
        case .paste: "Paste into the active app"
        case .clipboard: "Copy to the clipboard only"
        }
    }
}

/// User settings, persisted in UserDefaults.
@MainActor
final class Preferences: ObservableObject {
    static let shared = Preferences()

    private enum Key: String {
        case shortcut, hotkeyMode, modifierTrigger, localeIdentifier, insertionMode
        case restoreClipboard, addTrailingSpace, playSounds, showFloatingButton
        case showLiveTranscript, saveHistory, vocabulary, microphoneUID
        case panelCenterX, panelCenterY, hasCompletedOnboarding
    }

    private let defaults: UserDefaults

    @Published var shortcut: KeyShortcut {
        didSet { defaults.set(try? JSONEncoder().encode(shortcut), forKey: Key.shortcut.rawValue) }
    }
    @Published var hotkeyMode: HotkeyMode {
        didSet { defaults.set(hotkeyMode.rawValue, forKey: Key.hotkeyMode.rawValue) }
    }
    @Published var modifierTrigger: ModifierTrigger {
        didSet { defaults.set(modifierTrigger.rawValue, forKey: Key.modifierTrigger.rawValue) }
    }
    /// Empty string means "match the system language".
    @Published var localeIdentifier: String {
        didSet { defaults.set(localeIdentifier, forKey: Key.localeIdentifier.rawValue) }
    }
    @Published var insertionMode: InsertionMode {
        didSet { defaults.set(insertionMode.rawValue, forKey: Key.insertionMode.rawValue) }
    }
    @Published var restoreClipboard: Bool {
        didSet { defaults.set(restoreClipboard, forKey: Key.restoreClipboard.rawValue) }
    }
    @Published var addTrailingSpace: Bool {
        didSet { defaults.set(addTrailingSpace, forKey: Key.addTrailingSpace.rawValue) }
    }
    @Published var playSounds: Bool {
        didSet { defaults.set(playSounds, forKey: Key.playSounds.rawValue) }
    }
    @Published var showFloatingButton: Bool {
        didSet { defaults.set(showFloatingButton, forKey: Key.showFloatingButton.rawValue) }
    }
    @Published var showLiveTranscript: Bool {
        didSet { defaults.set(showLiveTranscript, forKey: Key.showLiveTranscript.rawValue) }
    }
    @Published var saveHistory: Bool {
        didSet { defaults.set(saveHistory, forKey: Key.saveHistory.rawValue) }
    }
    /// Custom words and `spoken -> written` replacements, one per line.
    @Published var vocabulary: String {
        didSet { defaults.set(vocabulary, forKey: Key.vocabulary.rawValue) }
    }
    /// Core Audio device UID; empty string means the system default input.
    @Published var microphoneUID: String {
        didSet { defaults.set(microphoneUID, forKey: Key.microphoneUID.rawValue) }
    }

    /// Screen position of the floating button's center.
    var panelCenter: CGPoint? {
        get {
            guard defaults.object(forKey: Key.panelCenterX.rawValue) != nil else { return nil }
            return CGPoint(x: defaults.double(forKey: Key.panelCenterX.rawValue),
                           y: defaults.double(forKey: Key.panelCenterY.rawValue))
        }
        set {
            defaults.set(newValue?.x, forKey: Key.panelCenterX.rawValue)
            defaults.set(newValue?.y, forKey: Key.panelCenterY.rawValue)
        }
    }

    var hasCompletedOnboarding: Bool {
        get { defaults.bool(forKey: Key.hasCompletedOnboarding.rawValue) }
        set { defaults.set(newValue, forKey: Key.hasCompletedOnboarding.rawValue) }
    }

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func bool(_ key: Key, _ fallback: Bool) -> Bool {
            defaults.object(forKey: key.rawValue) as? Bool ?? fallback
        }
        func string(_ key: Key) -> String? {
            defaults.string(forKey: key.rawValue)
        }

        shortcut = defaults.data(forKey: Key.shortcut.rawValue)
            .flatMap { try? JSONDecoder().decode(KeyShortcut.self, from: $0) } ?? .defaultShortcut
        hotkeyMode = string(.hotkeyMode).flatMap(HotkeyMode.init(rawValue:)) ?? .hybrid
        modifierTrigger = string(.modifierTrigger).flatMap(ModifierTrigger.init(rawValue:)) ?? .off
        localeIdentifier = string(.localeIdentifier) ?? ""
        insertionMode = string(.insertionMode).flatMap(InsertionMode.init(rawValue:)) ?? .paste
        restoreClipboard = bool(.restoreClipboard, true)
        addTrailingSpace = bool(.addTrailingSpace, true)
        playSounds = bool(.playSounds, true)
        showFloatingButton = bool(.showFloatingButton, true)
        showLiveTranscript = bool(.showLiveTranscript, true)
        saveHistory = bool(.saveHistory, true)
        vocabulary = string(.vocabulary) ?? ""
        microphoneUID = string(.microphoneUID) ?? ""
    }
}
