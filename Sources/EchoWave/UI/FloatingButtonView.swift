import SwiftUI

/// The floating dictation button: a mic when idle that grows into a live waveform pill
/// while you speak, with an optional transcript bubble.
struct FloatingButtonView: View {
    @ObservedObject var controller: DictationController
    @ObservedObject var ui: FloatingUIModel
    @ObservedObject var prefs: Preferences

    private static let pillHeight: CGFloat = 48
    private static let gap: CGFloat = 8
    private static let size = FloatingPanelController.windowSize

    var body: some View {
        VStack(spacing: Self.gap) {
            bubbleSlot(below: false)
            pill
            bubbleSlot(below: true)
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }

    // MARK: - Pill

    private var pill: some View {
        ZStack {
            content
                .id(controller.phase.kind)
                .transition(.opacity.combined(with: .scale(scale: 0.92)))
        }
        .padding(7)
        .frame(height: Self.pillHeight)
        .background { PillBackground() }
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .global)
        } action: { frame in
            ui.pillFrame = frame
        }
        .scaleEffect(ui.isHovering && controller.phase == .idle ? 1.07 : 1)
        .animation(.spring(response: 0.34, dampingFraction: 0.8), value: controller.phase.kind)
        .animation(.spring(response: 0.25, dampingFraction: 0.65), value: ui.isHovering)
    }

    @ViewBuilder private var content: some View {
        switch controller.phase {
        case .idle:
            MicBadge()
        case .preparing, .recording:
            RecordingContent(levels: controller.levels,
                             startedAt: controller.recordingStartedAt,
                             isLive: controller.phase == .recording)
        case .transcribing:
            StatusContent(text: "Transcribing…") { SpinnerBadge() }
        case .downloadingModel(let progress):
            StatusContent(text: "Downloading speech model… \(Int(progress * 100))%") { ProgressBadge(progress: progress) }
        case .done(let outcome):
            StatusContent(text: outcome.message) { SymbolBadge(symbol: "checkmark", tint: Brand.success) }
        case .failed(let message):
            StatusContent(text: message) { SymbolBadge(symbol: "exclamationmark", tint: Brand.warning) }
        }
    }

    // MARK: - Bubble

    private func bubbleSlot(below: Bool) -> some View {
        let height = (Self.size.height - Self.pillHeight) / 2 - Self.gap
        return ZStack(alignment: below ? .top : .bottom) {
            Color.clear
            if ui.bubbleBelow == below, let text = bubbleText {
                BubbleView(text: text)
                    .transition(.opacity.combined(with: .offset(y: below ? -4 : 4)))
            }
        }
        .frame(height: height)
        .animation(.easeOut(duration: 0.18), value: bubbleText)
    }

    private var bubbleText: String? {
        switch controller.phase {
        case .idle:
            return ui.isHovering ? "Click or press \(prefs.shortcut.displayString) to dictate" : nil
        case .preparing, .recording, .transcribing:
            if prefs.showLiveTranscript, !controller.liveText.isEmpty { return Self.tail(of: controller.liveText) }
            return controller.phase == .recording && ui.isHovering ? "Click to finish · Esc to cancel" : nil
        default:
            return nil
        }
    }

    /// The last couple of lines' worth of the transcript, starting on a word boundary.
    private static func tail(of text: String, limit: Int = 90) -> String {
        guard text.count > limit else { return text }
        let suffix = text.suffix(limit)
        guard let space = suffix.firstIndex(of: " ") else { return "…" + suffix }
        return "…" + suffix[suffix.index(after: space)...]
    }
}

// MARK: - Pieces

private struct PillBackground: View {
    var body: some View {
        Capsule(style: .continuous)
            .fill(Brand.surface.opacity(0.94))
            .overlay(Capsule(style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 9, y: 3)
    }
}

private struct BubbleView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(.white.opacity(0.94))
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Brand.surface.opacity(0.92))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.1), lineWidth: 1))
            }
            .frame(maxWidth: 330)
    }
}

private struct MicBadge: View {
    var body: some View {
        ZStack {
            Circle().fill(Brand.gradient)
            Image(systemName: "mic.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: 34, height: 34)
    }
}

private struct RecordingContent: View {
    let levels: [CGFloat]
    let startedAt: Date?
    let isLive: Bool

    var body: some View {
        HStack(spacing: 10) {
            StopBadge()
            WaveformView(levels: levels)
                .opacity(isLive ? 1 : 0.35)
            Group {
                if let startedAt {
                    Text(timerInterval: startedAt...Date.distantFuture, countsDown: false)
                } else {
                    Text("0:00")
                }
            }
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.8))
            .frame(width: 36, alignment: .leading)
        }
        .padding(.trailing, 4)
    }
}

/// The red stop button with a pulsing ring.
private struct StopBadge: View {
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(Brand.recording.opacity(0.6), lineWidth: 2)
                .scaleEffect(pulse ? 1.3 : 1)
                .opacity(pulse ? 0 : 1)
            Circle().fill(Brand.recording)
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(.white)
                .frame(width: 11, height: 11)
        }
        .frame(width: 34, height: 34)
        .onAppear {
            withAnimation(.easeOut(duration: 1.3).repeatForever(autoreverses: false)) { pulse = true }
        }
    }
}

/// Scrolling level meter; newest audio on the right.
private struct WaveformView: View {
    let levels: [CGFloat]

    private let barWidth: CGFloat = 3
    private let spacing: CGFloat = 2
    private let maxHeight: CGFloat = 26

    var body: some View {
        let width = CGFloat(levels.count) * barWidth + CGFloat(max(levels.count - 1, 0)) * spacing
        Brand.waveGradient
            .frame(width: width, height: maxHeight)
            .mask {
                HStack(alignment: .center, spacing: spacing) {
                    ForEach(levels.indices, id: \.self) { index in
                        Capsule().frame(width: barWidth, height: max(3, levels[index] * maxHeight))
                    }
                }
                .animation(.linear(duration: 1.0 / 30.0), value: levels)
            }
    }
}

private struct StatusContent<Icon: View>: View {
    let text: String
    @ViewBuilder let icon: Icon

    var body: some View {
        HStack(spacing: 10) {
            icon.frame(width: 34, height: 34)
            Text(text.count > 44 ? text.prefix(43) + "…" : text)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.trailing, 10)
    }
}

private struct SymbolBadge: View {
    let symbol: String
    let tint: Color

    var body: some View {
        ZStack {
            Circle().fill(tint)
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
        }
    }
}

private struct SpinnerBadge: View {
    @State private var spinning = false

    var body: some View {
        ZStack {
            Circle().fill(.white.opacity(0.08))
            Circle()
                .trim(from: 0.08, to: 0.72)
                .stroke(Brand.gradient, style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
                .frame(width: 18, height: 18)
                .rotationEffect(.degrees(spinning ? 360 : 0))
        }
        .onAppear {
            withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { spinning = true }
        }
    }
}

private struct ProgressBadge: View {
    let progress: Double

    var body: some View {
        ZStack {
            Circle().fill(.white.opacity(0.08))
            Circle()
                .stroke(.white.opacity(0.15), lineWidth: 2.6)
                .frame(width: 18, height: 18)
            Circle()
                .trim(from: 0, to: max(0.02, progress))
                .stroke(Brand.gradient, style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
                .frame(width: 18, height: 18)
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.25), value: progress)
        }
    }
}
