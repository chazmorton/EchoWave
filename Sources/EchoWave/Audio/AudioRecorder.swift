import Accelerate
import AVFoundation
import os

enum AudioRecorderError: LocalizedError {
    case noInputDevice
    case engineFailed(Error)

    var errorDescription: String? {
        switch self {
        case .noInputDevice: "No microphone found"
        case .engineFailed: "Couldn't start the microphone"
        }
    }
}

/// Captures microphone audio with AVAudioEngine and meters it for the waveform.
final class AudioRecorder: @unchecked Sendable {
    private struct Meter {
        var pending: [Float] = []
        var last: Float = 0
    }

    private var engine: AVAudioEngine?
    private let meter = OSAllocatedUnfairLock(initialState: Meter())

    /// Starts capturing. `onBuffer` is called on the realtime audio thread.
    func start(deviceUID: String, onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        stop()
        // A fresh engine per recording picks up device changes (AirPods connecting, etc.).
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if !deviceUID.isEmpty, let deviceID = AudioDevices.deviceID(forUID: deviceUID) {
            AudioDevices.setInputDevice(deviceID, for: input)
        }

        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw AudioRecorderError.noInputDevice }

        meter.withLock { $0 = Meter() }
        let framesPerLevel = max(256, Int(format.sampleRate / 30))
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [meter] buffer, _ in
            onBuffer(buffer)
            let levels = Self.levels(in: buffer, framesPerLevel: framesPerLevel)
            meter.withLock { state in
                state.pending.append(contentsOf: levels)
                if state.pending.count > 6 {
                    state.pending.removeFirst(state.pending.count - 6)
                }
            }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw AudioRecorderError.engineFailed(error)
        }
        self.engine = engine
    }

    func stop() {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
    }

    /// The next waveform level in 0…1; call at a steady rate (~30 Hz) while recording.
    func nextLevel() -> Float {
        meter.withLock { state in
            if state.pending.isEmpty {
                state.last *= 0.85
            } else {
                state.last = state.pending.removeFirst()
            }
            return state.last
        }
    }

    private static func levels(in buffer: AVAudioPCMBuffer, framesPerLevel: Int) -> [Float] {
        guard let samples = buffer.floatChannelData?[0] else { return [] }
        let frameCount = Int(buffer.frameLength)
        var levels: [Float] = []
        var offset = 0
        while offset < frameCount {
            let count = min(framesPerLevel, frameCount - offset)
            var rms: Float = 0
            vDSP_rmsqv(samples + offset, 1, &rms, vDSP_Length(count))
            levels.append(normalized(rms))
            offset += count
        }
        return levels
    }

    /// Maps RMS amplitude onto 0…1 using a decibel scale, which matches how loud speech feels.
    private static func normalized(_ rms: Float) -> Float {
        let decibels = 20 * log10(max(rms, 1e-6))
        return min(1, max(0, (decibels + 55) / 42)) // −55 dB → 0, −13 dB → 1
    }
}
