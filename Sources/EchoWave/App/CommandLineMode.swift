import AVFoundation
import Foundation

/// `EchoWave --transcribe <audio file> [--locale en_US]` runs a file through the same
/// streaming pipeline the microphone uses and prints the transcript. Handy for testing.
@MainActor
enum CommandLineMode {
    static func runIfRequested() -> Bool {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--transcribe"), flag + 1 < arguments.count else { return false }
        let path = arguments[flag + 1]
        let locale = arguments.firstIndex(of: "--locale").flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil } ?? ""

        Task { @MainActor in
            do {
                let started = Date()
                let text = try await transcribe(fileAt: path, localeIdentifier: locale)
                print(text)
                FileHandle.standardError.write(Data(String(format: "(%.2fs)\n", Date().timeIntervalSince(started)).utf8))
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
        dispatchMain()
    }

    private static func transcribe(fileAt path: String, localeIdentifier: String) async throws -> String {
        let engine = SpeechEngine()
        await engine.prepareIfNeeded(localeIdentifier: localeIdentifier)
        guard engine.isReady else { throw SpeechEngine.EngineError.notReady }

        let session = try engine.makeSession(contextualStrings: [], reportsLiveResults: true)
        session.onLiveText = { text in
            FileHandle.standardError.write(Data("  … \(text)\n".utf8))
        }
        session.start()

        // Feed the file in 100 ms chunks, the way the microphone tap delivers audio.
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let chunk = AVAudioFrameCount(file.processingFormat.sampleRate / 10)
        while file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk) else { break }
            try file.read(into: buffer, frameCount: chunk)
            if buffer.frameLength == 0 { break }
            session.append(buffer)
        }

        let raw = try await session.finish(timeout: .seconds(60))
        return TranscriptFormatter.format(raw, rules: VocabularyRules(Preferences.shared.vocabulary))
    }
}
