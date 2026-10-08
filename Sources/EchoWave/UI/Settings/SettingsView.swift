import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var router: SettingsRouter

    var body: some View {
        TabView(selection: $router.tab) {
            Tab("General", systemImage: "gearshape", value: SettingsTab.general) {
                GeneralSettingsView()
            }
            Tab("Shortcuts", systemImage: "keyboard", value: SettingsTab.shortcuts) {
                ShortcutSettingsView()
            }
            Tab("Speech", systemImage: "waveform", value: SettingsTab.speech) {
                SpeechSettingsView()
            }
            Tab("Permissions", systemImage: "lock.shield", value: SettingsTab.permissions) {
                PermissionsSettingsView()
            }
            Tab("History", systemImage: "clock.arrow.circlepath", value: SettingsTab.history) {
                HistorySettingsView()
            }
        }
        .frame(width: 620, height: 560)
    }
}

// MARK: - General

private struct GeneralSettingsView: View {
    @EnvironmentObject private var prefs: Preferences
    @State private var microphones: [AudioInputDevice] = []
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginItemMessage: String?

    var body: some View {
        Form {
            Section("Floating button") {
                Toggle("Show the floating button", isOn: $prefs.showFloatingButton)
                Toggle("Show live transcript while you speak", isOn: $prefs.showLiveTranscript)
            }

            Section("Output") {
                Picker("After transcribing", selection: $prefs.insertionMode) {
                    ForEach(InsertionMode.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Restore your previous clipboard after pasting", isOn: $prefs.restoreClipboard)
                    .disabled(prefs.insertionMode != .paste)
                Toggle("Add a space after inserted text", isOn: $prefs.addTrailingSpace)
            }

            Section("Audio") {
                Picker("Microphone", selection: $prefs.microphoneUID) {
                    Text("System default").tag("")
                    ForEach(microphones) { Text($0.name).tag($0.uid) }
                    if !prefs.microphoneUID.isEmpty, !microphones.contains(where: { $0.uid == prefs.microphoneUID }) {
                        Text("Disconnected device").tag(prefs.microphoneUID)
                    }
                }
                Toggle("Play sounds", isOn: $prefs.playSounds)
            }

            Section {
                Toggle("Open EchoWave at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                if let loginItemMessage {
                    Text(loginItemMessage).font(.callout).foregroundStyle(.secondary)
                }
            } header: {
                Text("System")
            } footer: {
                Text(versionLine).font(.caption).foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
        .onAppear { microphones = AudioDevices.inputDevices() }
    }

    private var versionLine: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        return "EchoWave \(version) · On-device speech recognition"
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled, service.status != .enabled {
                try service.register()
            } else if !enabled, service.status == .enabled {
                try service.unregister()
            }
            loginItemMessage = service.status == .requiresApproval
                ? "Approve EchoWave in System Settings → General → Login Items."
                : nil
        } catch {
            loginItemMessage = error.localizedDescription
            let actual = service.status == .enabled
            if actual != launchAtLogin { launchAtLogin = actual }
        }
    }
}

// MARK: - Shortcuts

private struct ShortcutSettingsView: View {
    @EnvironmentObject private var prefs: Preferences
    @EnvironmentObject private var hotkeys: HotkeyCoordinator
    @EnvironmentObject private var permissions: PermissionsMonitor

    var body: some View {
        Form {
            Section {
                LabeledContent("Dictation shortcut") {
                    HStack(spacing: 8) {
                        ShortcutRecorder(shortcut: $prefs.shortcut) { hotkeys.setSuspended($0) }
                        if prefs.shortcut != .defaultShortcut {
                            Button("Reset") { prefs.shortcut = .defaultShortcut }
                        }
                    }
                }
                if hotkeys.shortcutUnavailable {
                    Label("Another app is already using this shortcut. Pick a different one.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                Picker("Behavior", selection: $prefs.hotkeyMode) {
                    ForEach(HotkeyMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Text(prefs.hotkeyMode.explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Keyboard shortcut")
            }

            Section {
                Picker("Also start with", selection: $prefs.modifierTrigger) {
                    ForEach(ModifierTrigger.allCases) { Text($0.title).tag($0) }
                }
                if prefs.modifierTrigger != .off {
                    Text("Tap or hold this key on its own, just like the shortcut above.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if prefs.modifierTrigger == .fn {
                        Text("Tip: in System Settings → Keyboard, set “Press 🌐 key to” → “Do Nothing” so macOS doesn't react to fn as well.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    if !permissions.accessibility {
                        HStack {
                            Label("Needs Accessibility access to see this key.", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Spacer()
                            Button("Grant…") { permissions.requestAccessibility() }
                        }
                    }
                }
            } header: {
                Text("Single-key trigger")
            }

            Section("While dictating") {
                LabeledContent("Finish", value: "Shortcut again, release, or click the button")
                LabeledContent("Cancel", value: "Esc")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Speech

private struct SpeechSettingsView: View {
    @EnvironmentObject private var prefs: Preferences
    @EnvironmentObject private var speech: SpeechEngine

    var body: some View {
        Form {
            Section {
                Picker("Language", selection: $prefs.localeIdentifier) {
                    Text("Match system (\(SpeechEngine.displayName(for: .current)))").tag("")
                    ForEach(speech.availableLocales, id: \.identifier) { locale in
                        Text(SpeechEngine.displayName(for: locale)).tag(locale.identifier)
                    }
                    if !prefs.localeIdentifier.isEmpty,
                       !speech.availableLocales.contains(where: { $0.identifier == prefs.localeIdentifier }) {
                        Text(SpeechEngine.displayName(for: Locale(identifier: prefs.localeIdentifier))).tag(prefs.localeIdentifier)
                    }
                }
                LabeledContent("Speech model") { modelStatus }
            } header: {
                Text("Recognition")
            } footer: {
                Text("EchoWave transcribes with Apple's on-device speech model. Your voice never leaves this Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                TextEditor(text: $prefs.vocabulary)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 130)
            } header: {
                Text("Vocabulary")
            } footer: {
                Text("One term per line (names, jargon, product words) to keep their spelling and capitalization. Use “spoken -> written” for replacements, e.g. “echo wave -> EchoWave”.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task {
            if speech.availableLocales.isEmpty { await speech.loadAvailableLocales() }
        }
    }

    @ViewBuilder private var modelStatus: some View {
        switch speech.status {
        case .idle, .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking…").foregroundStyle(.secondary)
            }
        case .downloading(let progress):
            HStack(spacing: 8) {
                ProgressView(value: progress).frame(width: 140)
                Text("\(Int(progress * 100))%").monospacedDigit().foregroundStyle(.secondary)
            }
        case .ready:
            Label("Ready · \(speech.locale.map(SpeechEngine.displayName(for:)) ?? "")", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .unsupported:
            Label("Not available for this language", systemImage: "xmark.circle.fill")
                .foregroundStyle(.secondary)
        case .failed(let message):
            HStack(spacing: 8) {
                Text(message).foregroundStyle(.red).lineLimit(2)
                Button("Retry") { speech.prepare(localeIdentifier: prefs.localeIdentifier) }
            }
        }
    }
}

// MARK: - Permissions

private struct PermissionsSettingsView: View {
    @EnvironmentObject private var prefs: Preferences
    @EnvironmentObject private var permissions: PermissionsMonitor

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 60, height: 60)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(permissions.allGranted ? "You're all set" : "Welcome to EchoWave")
                            .font(.title2.weight(.semibold))
                        Text(permissions.allGranted
                             ? "Dictate into any app: click the floating button or press \(prefs.shortcut.displayString)."
                             : "Two quick permissions and you can dictate into any app.")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 6)
            }

            Section("Permissions") {
                PermissionRow(symbol: "mic.fill",
                              title: "Microphone",
                              detail: "To hear you while you dictate.",
                              isGranted: permissions.microphoneGranted,
                              actionTitle: permissions.microphone == .notDetermined ? "Allow" : "Open Settings") {
                    permissions.requestMicrophone()
                }
                PermissionRow(symbol: "accessibility",
                              title: "Accessibility",
                              detail: "To paste text into other apps and notice single-key triggers.",
                              isGranted: permissions.accessibility,
                              actionTitle: "Grant…") {
                    permissions.requestAccessibility()
                }
            }

            Section("How to dictate") {
                HowToRow(number: 1, text: "Click the floating button, or press \(prefs.shortcut.displayString). Hold the shortcut to talk, or tap it to go hands-free.")
                HowToRow(number: 2, text: "Speak naturally. Punctuation is added for you.")
                HowToRow(number: 3, text: "Click again, press the shortcut again, or let go. Your words appear wherever your cursor is. Esc cancels.")
            }

            if !permissions.accessibility {
                Section {
                    Text("Switched EchoWave on but it still shows as off here? That entry belongs to an earlier build of EchoWave. Click Grant… again: EchoWave clears the old entry, and you can switch it on once more.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("Open Accessibility Settings") { permissions.openAccessibilitySettings() }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct PermissionRow: View {
    let symbol: String
    let title: String
    let detail: String
    let isGranted: Bool
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(isGranted ? Color.green : Color.orange))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if isGranted {
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct HowToRow: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Brand.gradient))
            Text(text)
        }
    }
}

// MARK: - History

private struct HistorySettingsView: View {
    @EnvironmentObject private var prefs: Preferences
    @EnvironmentObject private var history: TranscriptHistory

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Toggle("Save transcription history", isOn: $prefs.saveHistory)
                Spacer()
                Button("Clear All", role: .destructive) { history.clear() }
                    .disabled(history.items.isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            Divider()
            if history.items.isEmpty {
                ContentUnavailableView("No transcriptions yet",
                                       systemImage: "waveform",
                                       description: Text("Everything you dictate shows up here."))
                    .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(history.items) { record in
                        HistoryRow(record: record) { history.remove(record) }
                    }
                }
                .listStyle(.inset)
            }
        }
    }
}

private struct HistoryRow: View {
    let record: TranscriptRecord
    let onDelete: () -> Void
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(record.text)
                    .lineLimit(4)
                    .textSelection(.enabled)
                Text("\(record.date.formatted(date: .abbreviated, time: .shortened)) · \(Self.duration(record.duration))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                TextInserter.copy(record.text)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.2))
                    copied = false
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy")
            Button(action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete")
        }
        .padding(.vertical, 4)
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
