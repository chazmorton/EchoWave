import AppKit
import Combine

/// The heart of EchoWave: runs one dictation at a time from "start" through
/// listening, transcribing and inserting the text.
@MainActor
final class DictationController: ObservableObject {
    enum Phase: Equatable {
        case idle
        /// Waiting on the microphone or speech model; shown like recording so it feels instant.
        case preparing
        case recording
        case transcribing
        case downloadingModel(Double)
        case done(InsertOutcome)
        case failed(String)

        var isActive: Bool {
            switch self {
            case .preparing, .recording, .transcribing, .downloadingModel: true
            case .idle, .done, .failed: false
            }
        }

        /// Groups phases that share a look, so the UI animates between groups only.
        var kind: String {
            switch self {
            case .idle: "idle"
            case .preparing, .recording: "recording"
            case .transcribing: "transcribing"
            case .downloadingModel: "downloading"
            case .done: "done"
            case .failed: "failed"
            }
        }
    }

    static let levelCount = 24
    private static let minimumDuration: TimeInterval = 0.3
    private static let maximumDuration: Duration = .seconds(10 * 60)
    /// Keep listening briefly after "stop" so the last syllable isn't clipped.
    private static let trailingCapture: Duration = .milliseconds(200)

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var levels = [CGFloat](repeating: 0, count: levelCount)
    @Published private(set) var liveText = ""
    @Published private(set) var recordingStartedAt: Date?
    @Published private(set) var lastTranscript: String?

    private let speech: SpeechEngine
    private let prefs: Preferences
    private let history: TranscriptHistory
    private let permissions: PermissionsMonitor
    private let recorder = AudioRecorder()

    /// Changes whenever a dictation starts or is cancelled, so stale async work can bail out.
    private var attemptID = UUID()
    private var session: TranscriptionSession?
    private var stopRequested = false
    private var levelTimer: Timer?
    private var autoStopTask: Task<Void, Never>?
    private var resetTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    init(speech: SpeechEngine, prefs: Preferences, history: TranscriptHistory, permissions: PermissionsMonitor) {
        self.speech = speech
        self.prefs = prefs
        self.history = history
        self.permissions = permissions

        speech.$status
            .sink { [weak self] status in self?.speechStatusChanged(status) }
            .store(in: &cancellables)
    }

    // MARK: - Controls

    func toggle() {
        switch phase {
        case .preparing, .recording: stop()
        case .transcribing, .downloadingModel: break
        case .idle, .done, .failed: start()
        }
    }

    func start() {
        guard !phase.isActive else { return }
        resetTask?.cancel()
        let attempt = UUID()
        attemptID = attempt
        stopRequested = false
        liveText = ""
        phase = .preparing
        Task { await beginRecording(attempt) }
    }

    /// Stops listening and inserts the transcript.
    func stop() {
        switch phase {
        case .preparing: stopRequested = true
        case .recording: finishRecording()
        default: break
        }
    }

    /// Stops without inserting anything.
    func cancel(silently: Bool = false) {
        guard phase.isActive else { return }
        attemptID = UUID()
        stopCapture()
        if let session {
            self.session = nil
            Task { await session.cancel() }
        }
        liveText = ""
        recordingStartedAt = nil
        phase = .idle
        if !silently { Sounds.play(.cancel) }
    }

    func pasteLastTranscript() {
        guard let lastTranscript else { return }
        _ = TextInserter.insert(output(for: lastTranscript), mode: .paste, restoreClipboard: prefs.restoreClipboard)
    }

    func copyLastTranscript() {
        guard let lastTranscript else { return }
        TextInserter.copy(lastTranscript)
    }

    // MARK: - Recording

    private func beginRecording(_ attempt: UUID) async {
        guard await permissions.ensureMicrophoneAccess() else {
            guard attemptID == attempt else { return }
            fail("Microphone access is off", showPermissions: true)
            return
        }
        guard attemptID == attempt else { return }

        if !speech.isReady {
            await speech.prepareIfNeeded(localeIdentifier: prefs.localeIdentifier)
            guard attemptID == attempt else { return }
            guard speech.isReady else {
                fail(speech.status.problemDescription)
                return
            }
            // After a model download, don't surprise the user by starting to listen much later.
            if case .downloadingModel = phase {
                phase = .idle
                return
            }
        }
        if stopRequested {
            phase = .idle
            return
        }

        let session: TranscriptionSession
        do {
            session = try speech.makeSession(contextualStrings: VocabularyRules(prefs.vocabulary).contextualStrings,
                                             reportsLiveResults: prefs.showLiveTranscript)
        } catch {
            fail(error.localizedDescription)
            return
        }
        session.onLiveText = { [weak self] text in
            guard let self, self.attemptID == attempt else { return }
            self.liveText = text
        }
        session.onError = { [weak self] _ in
            guard let self, self.attemptID == attempt, self.phase == .recording else { return }
            self.attemptID = UUID()
            self.stopCapture()
            self.session = nil
            self.fail("Speech recognition stopped unexpectedly")
        }

        do {
            try recorder.start(deviceUID: prefs.microphoneUID) { buffer in
                session.append(buffer)
            }
        } catch {
            await session.cancel()
            guard attemptID == attempt else { return }
            fail(error.localizedDescription)
            return
        }

        session.start()
        self.session = session
        levels = Array(repeating: 0, count: Self.levelCount)
        recordingStartedAt = Date()
        phase = .recording
        Sounds.play(.start)
        startLevelTimer()
        scheduleAutoStop(attempt)
        if stopRequested { finishRecording() }
    }

    private func finishRecording() {
        guard phase == .recording, let session else { return }
        let attempt = attemptID
        let duration = recordingStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        self.session = nil
        stopMeters()

        if duration < Self.minimumDuration {
            // Almost certainly an accidental double-click or tap.
            recorder.stop()
            Task { await session.cancel() }
            phase = .idle
            return
        }

        phase = .transcribing
        Sounds.play(.stop)
        Task {
            try? await Task.sleep(for: Self.trailingCapture)
            guard attemptID == attempt else {
                await session.cancel()
                return
            }
            recorder.stop()
            do {
                let raw = try await session.finish(timeout: .seconds(30))
                guard attemptID == attempt else { return }
                deliver(raw, duration: duration)
            } catch {
                await session.cancel()
                guard attemptID == attempt else { return }
                fail("Transcription failed — please try again")
            }
        }
    }

    private func deliver(_ raw: String, duration: TimeInterval) {
        let text = TranscriptFormatter.format(raw, rules: VocabularyRules(prefs.vocabulary))
        guard !text.isEmpty else {
            fail("Didn't catch that — try again")
            return
        }
        lastTranscript = text
        if prefs.saveHistory { history.add(text, duration: duration) }
        let outcome = TextInserter.insert(output(for: text), mode: prefs.insertionMode,
                                          restoreClipboard: prefs.restoreClipboard)
        phase = .done(outcome)
        scheduleReset(after: outcome == .pasted ? .seconds(1.2) : .seconds(2.5))
    }

    private func output(for text: String) -> String {
        prefs.addTrailingSpace ? text + " " : text
    }

    private func fail(_ message: String, showPermissions: Bool = false) {
        stopCapture()
        phase = .failed(message)
        Sounds.play(.error)
        scheduleReset(after: .seconds(3))
        if showPermissions { AppRouter.shared.showSettings(.permissions) }
    }

    private func scheduleReset(after delay: Duration) {
        resetTask?.cancel()
        resetTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            switch self.phase {
            case .done, .failed:
                self.phase = .idle
                self.liveText = ""
            default:
                break
            }
        }
    }

    private func speechStatusChanged(_ status: SpeechEngine.Status) {
        guard case .downloading(let progress) = status else { return }
        switch phase {
        case .preparing, .downloadingModel: phase = .downloadingModel(progress)
        default: break
        }
    }

    // MARK: - Metering

    private func startLevelTimer() {
        levelTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pushLevel() }
        }
        RunLoop.main.add(timer, forMode: .common)
        levelTimer = timer
    }

    private func pushLevel() {
        var next = levels
        next.removeFirst()
        next.append(CGFloat(recorder.nextLevel()))
        levels = next
    }

    private func scheduleAutoStop(_ attempt: UUID) {
        autoStopTask?.cancel()
        autoStopTask = Task { [weak self] in
            try? await Task.sleep(for: Self.maximumDuration)
            guard !Task.isCancelled, let self, self.attemptID == attempt else { return }
            self.stop()
        }
    }

    private func stopMeters() {
        levelTimer?.invalidate()
        levelTimer = nil
        autoStopTask?.cancel()
        autoStopTask = nil
    }

    private func stopCapture() {
        recorder.stop()
        stopMeters()
    }
}
