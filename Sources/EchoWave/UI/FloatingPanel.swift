import AppKit
import Combine
import SwiftUI

/// State shared between the floating button's AppKit shell and its SwiftUI content.
@MainActor
final class FloatingUIModel: ObservableObject {
    @Published var isHovering = false
    /// Show the transcript bubble below the button (when the button sits near the top of the screen).
    @Published var bubbleBelow = false

    /// The pill's frame in the panel, reported by SwiftUI and used for hit-testing.
    var pillFrame: CGRect = .zero {
        didSet { if pillFrame != oldValue { onPillFrameChange?() } }
    }
    var onPillFrameChange: (() -> Void)?
}

/// A borderless panel that floats above everything, on every Space, without ever
/// becoming key — so clicking it leaves focus in the app you're dictating into.
final class FloatingPanel: NSPanel {
    init(size: NSSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        becomesKeyOnlyIfNeeded = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Handles clicks, drags, hover and the context menu for the pill. The SwiftUI view
/// underneath only draws; clicks on the transparent rest of the panel pass through.
final class FloatingContainerView: NSView {
    var onClick: (() -> Void)?
    var onDragEnded: (() -> Void)?
    var menuProvider: (() -> NSMenu)?

    private let ui: FloatingUIModel
    private var trackingArea: NSTrackingArea?
    private var dragStartMouse: NSPoint?
    private var dragStartOrigin: NSPoint?
    private var isDragging = false

    init(frame: NSRect, ui: FloatingUIModel) {
        self.ui = ui
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true } // match SwiftUI's top-left coordinates
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return ui.pillFrame.insetBy(dx: -2, dy: -2).contains(local) ? self : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        guard ui.pillFrame != .zero else { return }
        let area = NSTrackingArea(rect: ui.pillFrame, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(area)
        trackingArea = area

        // The pill may have resized under a stationary cursor; re-sync hover state.
        if let window {
            let mouse = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            let inside = ui.pillFrame.contains(mouse)
            if inside != ui.isHovering {
                DispatchQueue.main.async { [ui] in ui.isHovering = inside }
            }
        }
    }

    override func mouseEntered(with event: NSEvent) { ui.isHovering = true }
    override func mouseExited(with event: NSEvent) { ui.isHovering = false }

    override func mouseDown(with event: NSEvent) {
        dragStartMouse = NSEvent.mouseLocation
        dragStartOrigin = window?.frame.origin
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStartMouse, let origin = dragStartOrigin, let window else { return }
        let mouse = NSEvent.mouseLocation
        let dx = mouse.x - start.x
        let dy = mouse.y - start.y
        if !isDragging, hypot(dx, dy) < 4 { return }
        isDragging = true
        window.setFrameOrigin(NSPoint(x: origin.x + dx, y: origin.y + dy))
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            dragStartMouse = nil
            dragStartOrigin = nil
            isDragging = false
        }
        if isDragging {
            onDragEnded?()
        } else {
            onClick?()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = menuProvider?() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}

/// Creates, positions and shows the floating dictation button.
@MainActor
final class FloatingPanelController {
    /// Large enough for the widest pill plus a transcript bubble above and below.
    static let windowSize = NSSize(width: 360, height: 176)

    private let panel = FloatingPanel(size: windowSize)
    private let ui = FloatingUIModel()
    private let controller: DictationController
    private let prefs: Preferences
    private var cancellables = Set<AnyCancellable>()

    init(controller: DictationController, prefs: Preferences) {
        self.controller = controller
        self.prefs = prefs

        let container = FloatingContainerView(frame: NSRect(origin: .zero, size: Self.windowSize), ui: ui)
        let hosting = NSHostingView(rootView: FloatingButtonView(controller: controller, ui: ui, prefs: prefs))
        hosting.sizingOptions = []
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)

        container.onClick = { [weak controller] in controller?.toggle() }
        container.onDragEnded = { [weak self] in self?.dragEnded() }
        container.menuProvider = { [weak self] in self?.makeContextMenu() ?? NSMenu() }
        ui.onPillFrameChange = { [weak container] in container?.updateTrackingAreas() }
        panel.contentView = container

        restorePosition()

        prefs.$showFloatingButton
            .removeDuplicates()
            .sink { [weak self] visible in self?.setVisible(visible) }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.restorePosition() }
            .store(in: &cancellables)
    }

    private func setVisible(_ visible: Bool) {
        if visible {
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
        }
    }

    // MARK: - Positioning

    private var pillCenter: NSPoint {
        NSPoint(x: panel.frame.midX, y: panel.frame.midY)
    }

    private func restorePosition() {
        if let saved = prefs.panelCenter,
           NSScreen.screens.contains(where: { $0.visibleFrame.contains(saved) }) {
            place(at: saved)
        } else {
            place(at: defaultCenter())
        }
    }

    /// Bottom center of the main screen, just above the Dock.
    private func defaultCenter() -> NSPoint {
        let frame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(x: frame.midX, y: frame.minY + 44)
    }

    private func place(at center: NSPoint) {
        panel.setFrameOrigin(NSPoint(x: center.x - Self.windowSize.width / 2,
                                     y: center.y - Self.windowSize.height / 2))
        updateBubbleSide()
    }

    private func dragEnded() {
        let center = clampedToScreen(pillCenter)
        place(at: center)
        prefs.panelCenter = center
    }

    /// Keeps the button far enough from the edges that the expanded pill stays visible.
    private func clampedToScreen(_ point: NSPoint) -> NSPoint {
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return point }
        let marginX: CGFloat = 116
        let marginY: CGFloat = 28
        return NSPoint(x: min(max(point.x, frame.minX + marginX), frame.maxX - marginX),
                       y: min(max(point.y, frame.minY + marginY), frame.maxY - marginY))
    }

    private func updateBubbleSide() {
        let center = pillCenter
        let screen = NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        ui.bubbleBelow = center.y > frame.maxY - 110
    }

    // MARK: - Context menu

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        switch controller.phase {
        case .preparing, .recording:
            menu.addItem(ActionMenuItem("Stop Dictation") { [weak self] in self?.controller.stop() })
            menu.addItem(ActionMenuItem("Cancel Dictation") { [weak self] in self?.controller.cancel() })
        default:
            let start = ActionMenuItem("Start Dictation") { [weak self] in self?.controller.start() }
            start.isEnabled = !controller.phase.isActive
            menu.addItem(start)
        }
        let paste = ActionMenuItem("Paste Last Transcript") { [weak self] in self?.controller.pasteLastTranscript() }
        paste.isEnabled = controller.lastTranscript != nil
        menu.addItem(paste)
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem("Reset Position") { [weak self] in
            guard let self else { return }
            self.place(at: self.defaultCenter())
            self.prefs.panelCenter = nil
        })
        menu.addItem(ActionMenuItem("Hide Floating Button") { [weak self] in self?.prefs.showFloatingButton = false })
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem("Settings…") { AppRouter.shared.showSettings() })
        menu.addItem(NSMenuItem(title: "Quit EchoWave", action: #selector(NSApplication.terminate(_:)), keyEquivalent: ""))
        return menu
    }
}
