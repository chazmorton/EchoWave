import AVFoundation
import Speech

/// Owns the on-device speech model: picks the language, downloads the model if needed,
/// keeps it warm, and hands out `TranscriptionSession`s.
@MainActor
final class SpeechEngine: ObservableObject {
    enum Status: Equatable {
        case idle
        case checking
        case downloading(Double)
        case ready
        case unsupported
        case failed(String)

        var problemDescription: String {
            switch self {
            case .unsupported: "This language isn't supported"
            case .failed(let message): message
            default: "The speech model isn't ready yet"
            }
        }
    }

    enum EngineError: LocalizedError {
        case notReady
        case noAudioFormat

        var errorDescription: String? {
            switch self {
            case .notReady: "The speech model isn't ready yet"
            case .noAudioFormat: "The speech model can't accept microphone audio"
            }
        }
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var locale: Locale?
    @Published private(set) var availableLocales: [Locale] = []

    private var backend: SpeechBackend = .speechTranscriber
    private var audioFormat: AVAudioFormat?
    private var preparedIdentifier: String?
    private var prepareTask: Task<Void, Never>?

    var isReady: Bool { status == .ready }

    /// Starts preparing the model for a language ("" means the system language).
    func prepare(localeIdentifier: String) {
        prepareTask?.cancel()
        preparedIdentifier = localeIdentifier
        status = .checking
        prepareTask = Task { [weak self] in
            await self?.runPrepare(localeIdentifier)
        }
    }

    /// Makes sure the model for `localeIdentifier` is ready, waiting for any work in flight.
    func prepareIfNeeded(localeIdentifier: String) async {
        let matches = preparedIdentifier == localeIdentifier
        if matches, status == .ready { return }
        let inFlight: Bool
        switch status {
        case .checking, .downloading: inFlight = matches
        default: inFlight = false
        }
        if !inFlight { prepare(localeIdentifier: localeIdentifier) }

        // If the language changes while we wait, a new task replaces the old one; follow it.
        while let task = prepareTask {
            await task.value
            if task == prepareTask { break }
        }
    }

    func makeSession(contextualStrings: [String], reportsLiveResults: Bool) throws -> TranscriptionSession {
        guard status == .ready, let locale, let audioFormat else { throw EngineError.notReady }
        let module = TranscriberModule(backend: backend, locale: locale, reportsLiveResults: reportsLiveResults)
        return TranscriptionSession(module: module, audioFormat: audioFormat, contextualStrings: contextualStrings)
    }

    func loadAvailableLocales() async {
        let speechLocales = SpeechTranscriber.isAvailable ? await SpeechTranscriber.supportedLocales : []
        let dictationLocales = await DictationTranscriber.supportedLocales
        var seen = Set<String>()
        availableLocales = (speechLocales + dictationLocales)
            .filter { seen.insert($0.identifier).inserted }
            .sorted { Self.displayName(for: $0).localizedCompare(Self.displayName(for: $1)) == .orderedAscending }
    }

    static func displayName(for locale: Locale) -> String {
        Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }

    // MARK: - Preparation

    private func runPrepare(_ identifier: String) async {
        do {
            guard let (locale, backend) = await Self.resolve(identifier) else {
                guard !Task.isCancelled else { return }
                self.locale = nil
                status = .unsupported
                return
            }
            try Task.checkCancellation()

            let module = TranscriberModule(backend: backend, locale: locale, reportsLiveResults: false).module
            await Self.reserve(locale)
            if await AssetInventory.status(forModules: [module]) != .installed,
               let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                try Task.checkCancellation()
                status = .downloading(0)
                let progressTask = Task { [weak self] in
                    while !Task.isCancelled {
                        self?.status = .downloading(request.progress.fractionCompleted)
                        try? await Task.sleep(for: .milliseconds(250))
                    }
                }
                defer { progressTask.cancel() }
                try await request.downloadAndInstall()
            }
            try Task.checkCancellation()

            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
                throw EngineError.noAudioFormat
            }
            try Task.checkCancellation()

            self.locale = locale
            self.backend = backend
            self.audioFormat = format
            status = .ready

            // Load the model into memory now so the first dictation starts instantly.
            let warmup = SpeechAnalyzer(modules: [module], options: TranscriptionSession.analyzerOptions)
            try? await warmup.prepareToAnalyze(in: format)
        } catch is CancellationError {
            // Superseded by a newer prepare() call.
        } catch {
            guard !Task.isCancelled else { return }
            status = .failed(error.localizedDescription)
        }
    }

    private static func resolve(_ identifier: String) async -> (Locale, SpeechBackend)? {
        let requested = identifier.isEmpty ? Locale.current : Locale(identifier: identifier)
        if SpeechTranscriber.isAvailable,
           let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) {
            return (locale, .speechTranscriber)
        }
        if let locale = await DictationTranscriber.supportedLocale(equivalentTo: requested) {
            return (locale, .dictationTranscriber)
        }
        // The system language isn't supported at all: fall back to US English.
        if identifier.isEmpty, SpeechTranscriber.isAvailable,
           let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en_US")) {
            return (locale, .speechTranscriber)
        }
        return nil
    }

    /// Reserves the language's model for this app, releasing an old one if we're at the limit.
    private static func reserve(_ locale: Locale) async {
        let reserved = await AssetInventory.reservedLocales
        guard !reserved.contains(where: { $0.identifier == locale.identifier }) else { return }
        if reserved.count >= AssetInventory.maximumReservedLocales, let oldest = reserved.first {
            await AssetInventory.release(reservedLocale: oldest)
        }
        _ = try? await AssetInventory.reserve(locale: locale)
    }
}
