import AppKit

/// Subtle audio cues for starting and stopping dictation.
@MainActor
enum Sounds {
    enum Effect {
        case start, stop, cancel, error
    }

    private static var playing: [NSSound] = []

    static func play(_ effect: Effect) {
        guard Preferences.shared.playSounds else { return }
        let (name, volume): (String, Float) = switch effect {
        case .start: ("Tink", 0.4)
        case .stop: ("Pop", 0.4)
        case .cancel: ("Bottle", 0.25)
        case .error: ("Funk", 0.25)
        }
        guard let sound = NSSound(contentsOfFile: "/System/Library/Sounds/\(name).aiff", byReference: true) else { return }
        sound.volume = volume
        playing.removeAll { !$0.isPlaying }
        playing.append(sound) // keep a reference until it finishes
        sound.play()
    }
}
