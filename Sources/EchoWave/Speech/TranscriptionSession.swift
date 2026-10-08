import AVFoundation
import os
import Speech

enum SpeechBackend {
    /// Apple's newer long-form model (macOS 26). Best accuracy; adds punctuation on its own.
    case speechTranscriber
    /// The classic dictation model. Supports more languages; used as a fallback.
    case dictationTranscriber
}

/// Wraps Apple's two transcriber modules behind one interface.
enum TranscriberModule {
    case speech(SpeechTranscriber)
    case dictation(DictationTranscriber)

    init(backend: SpeechBackend, locale: Locale, reportsLiveResults: Bool) {
        switch backend {
        case .speechTranscriber:
            self = .speech(SpeechTranscriber(locale: locale,
                                             transcriptionOptions: [],
                                             reportingOptions: reportsLiveResults ? [.volatileResults] : [],
                                             attributeOptions: []))
        case .dictationTranscriber:
            self = .dictation(DictationTranscriber(locale: locale,
                                                   contentHints: [],
                                                   transcriptionOptions: [.punctuation],
                                                   reportingOptions: reportsLiveResults ? [.volatileResults] : [],
                                                   attributeOptions: []))
        }
    }

    var module: any SpeechModule {
        switch self {
        case .speech(let transcriber): transcriber
        case .dictation(let transcriber): transcriber
        }
    }

    func forEachResult(_ body: (_ text: String, _ isFinal: Bool) -> Void) async throws {
        switch self {
        case .speech(let transcriber):
            for try await result in transcriber.results {
                body(String(result.text.characters), result.isFinal)
            }
        case .dictation(let transcriber):
            for try await result in transcriber.results {
                body(String(result.text.characters), result.isFinal)
            }
        }
    }
}

/// One dictation: streams microphone buffers into `SpeechAnalyzer` and collects the transcript.
///
/// Audio appended before the analyzer has finished starting is buffered, so nothing
/// said right after pressing the button is lost.
final class TranscriptionSession: @unchecked Sendable {
    /// Keep the model loaded between dictations so each one starts instantly.
    static let analyzerOptions = SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .processLifetime)

    /// Finalized plus in-progress text, delivered on the main actor. Set before `start()`.
    var onLiveText: (@MainActor (String) -> Void)?
    /// Recognition stopped with an error while recording. Set before `start()`.
    var onError: (@MainActor (Error) -> Void)?

    private let module: TranscriberModule
    private let analyzer: SpeechAnalyzer
    private let audioFormat: AVAudioFormat
    private let contextualStrings: [String]
    private let converter = BufferConverter() // only touched from the audio thread
    private let input: AsyncStream<AnalyzerInput>
    private let inputContinuation: AsyncStream<AnalyzerInput>.Continuation
    private var analysisTask: Task<Void, Error>?
    private var resultsTask: Task<String, Error>?

    init(module: TranscriberModule, audioFormat: AVAudioFormat, contextualStrings: [String]) {
        self.module = module
        self.audioFormat = audioFormat
        self.contextualStrings = contextualStrings
        analyzer = SpeechAnalyzer(modules: [module.module], options: Self.analyzerOptions)
        (input, inputContinuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
    }

    func start() {
        let module = module
        let onLiveText = onLiveText
        let onError = onError
        resultsTask = Task {
            var finalized = ""
            var volatile = ""
            do {
                try await module.forEachResult { text, isFinal in
                    if isFinal {
                        finalized += text
                        volatile = ""
                    } else {
                        volatile = text
                    }
                    if let onLiveText {
                        let snapshot = (finalized + volatile).trimmingCharacters(in: .whitespaces)
                        Task { @MainActor in onLiveText(snapshot) }
                    }
                }
            } catch {
                if !(error is CancellationError), let onError {
                    Task { @MainActor in onError(error) }
                }
                throw error
            }
            return finalized
        }

        let analyzer = analyzer
        let input = input
        let contextualStrings = contextualStrings
        analysisTask = Task {
            do {
                if !contextualStrings.isEmpty {
                    let context = AnalysisContext()
                    context.contextualStrings[.general] = contextualStrings
                    try? await analyzer.setContext(context)
                }
                try await analyzer.start(inputSequence: input)
            } catch {
                if let onError { Task { @MainActor in onError(error) } }
                throw error
            }
        }
    }

    /// Feeds microphone audio. Called on the realtime audio thread.
    func append(_ buffer: AVAudioPCMBuffer) {
        guard let converted = try? converter.convert(buffer, to: audioFormat) else { return }
        inputContinuation.yield(AnalyzerInput(buffer: converted))
    }

    /// Ends the audio stream and returns the final transcript.
    func finish(timeout: Duration) async throws -> String {
        inputContinuation.finish()
        return try await withTimeout(timeout) { [analysisTask, resultsTask, analyzer] in
            try await analysisTask?.value
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            return try await resultsTask?.value ?? ""
        }
    }

    func cancel() async {
        inputContinuation.finish()
        resultsTask?.cancel()
        await analyzer.cancelAndFinishNow()
    }
}

/// Converts microphone buffers (usually 48 kHz Float32) to the analyzer's format (16 kHz Int16 mono).
final class BufferConverter {
    enum ConversionError: Error {
        case unsupportedFormat
        case allocationFailed
        case failed(NSError?)
    }

    private var converter: AVAudioConverter?

    func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        if buffer.format == format { return buffer }
        if converter == nil || converter?.inputFormat != buffer.format || converter?.outputFormat != format {
            converter = AVAudioConverter(from: buffer.format, to: format)
            converter?.primeMethod = .none // no priming, so consecutive buffers line up without gaps
        }
        guard let converter else { throw ConversionError.unsupportedFormat }

        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up))
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(capacity, 1)) else {
            throw ConversionError.allocationFailed
        }

        var error: NSError?
        var consumed = false
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error else { throw ConversionError.failed(error) }
        return output
    }
}

struct TimeoutError: LocalizedError {
    var errorDescription: String? { "The operation timed out" }
}

/// Runs `operation`, giving up after `timeout` even if the operation ignores cancellation.
func withTimeout<T: Sendable>(_ timeout: Duration, operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        let resumed = OSAllocatedUnfairLock(initialState: false)
        let complete: @Sendable (Result<T, Error>) -> Void = { result in
            let isFirst = resumed.withLock { done -> Bool in
                defer { done = true }
                return !done
            }
            if isFirst { continuation.resume(with: result) }
        }
        let work = Task {
            do { complete(.success(try await operation())) } catch { complete(.failure(error)) }
        }
        Task {
            try? await Task.sleep(for: timeout)
            work.cancel()
            complete(.failure(TimeoutError()))
        }
    }
}
