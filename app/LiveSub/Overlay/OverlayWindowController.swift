import AppKit
import Foundation
import SwiftUI
import LiveSubSubtitles

@MainActor
public final class OverlayWindowController: NSObject {
    private let presentation = OverlayPresentation()
    private let placementKey = "local.jujube.livesub.overlayPlacement.v1"
    private var panel: SubtitlePanel?
    private var savedPlacement: OverlayPlacement?
    private var fadeTask: Task<Void, Never>?
    private var dragStartFrame: CGRect?
    private var resizeStartFrame: CGRect?
    private var wasVisibleBeforeAdjustment = false

    /// Called when the user presses the in-overlay "完成" control; the owner decides how to finish.
    public var onFinishAdjustmentRequest: (() -> Void)?
    public private(set) var isVisible = false
    public var isAdjusting: Bool { presentation.isAdjusting }
    public var fontSize: CGFloat { presentation.fontSize }
    public var showsBackdrop: Bool { presentation.showsBackdrop }
    var caption: OverlayCaption? { presentation.caption }

    public override init() {
        if let data = UserDefaults.standard.data(forKey: placementKey) {
            savedPlacement = try? JSONDecoder().decode(OverlayPlacement.self, from: data)
        }
        presentation.fontSize = OverlayTypography.load()
        presentation.showsBackdrop = UserDefaults.standard.bool(forKey: OverlayTypography.backdropPreferenceKey)
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    public func show() {
        guard let panel = ensurePanel() else { return }
        isVisible = true
        panel.orderFrontRegardless()
        restartFade()
    }

    public func hide() {
        if presentation.isAdjusting { saveCurrentPlacement() }
        presentation.isAdjusting = false
        panel?.ignoresMouseEvents = true
        dragStartFrame = nil
        resizeStartFrame = nil
        isVisible = false
        fadeTask?.cancel()
        fadeTask = nil
        panel?.orderOut(nil)
    }

    public func update(_ caption: OverlayCaption) {
        guard presentation.caption != caption else { return }
        presentation.caption = caption
        presentation.textOpacity = 1
        if isVisible { restartFade() }
    }

    public func setDisplayMode(_ mode: SubtitleDisplayMode) {
        guard presentation.displayMode != mode else { return }
        presentation.displayMode = mode
        dragStartFrame = nil
        resizeStartFrame = nil
        updatePanelHeight()
        if isVisible { restartFade() }
    }

    public func setFontSize(_ size: CGFloat) {
        let next = OverlayTypography.bounded(size)
        guard presentation.fontSize != next else { return }
        presentation.fontSize = next
        UserDefaults.standard.set(Double(next), forKey: OverlayTypography.preferenceKey)
        updatePanelHeight()
    }

    public func setBackdrop(_ visible: Bool) {
        guard presentation.showsBackdrop != visible else { return }
        presentation.showsBackdrop = visible
        UserDefaults.standard.set(visible, forKey: OverlayTypography.backdropPreferenceKey)
    }

    public func resetFontSize() {
        UserDefaults.standard.removeObject(forKey: OverlayTypography.preferenceKey)
        presentation.fontSize = OverlayTypography.defaultSize
        updatePanelHeight()
    }

    public func clearCaption() {
        fadeTask?.cancel()
        fadeTask = nil
        presentation.caption = nil
        presentation.textOpacity = 1
    }

    public func beginPositionAdjustment() {
        guard let panel = ensurePanel() else { return }
        wasVisibleBeforeAdjustment = isVisible
        fadeTask?.cancel()
        fadeTask = nil
        presentation.textOpacity = 1
        presentation.isAdjusting = true
        panel.ignoresMouseEvents = false
        isVisible = true
        panel.orderFrontRegardless()
    }

    public func finishPositionAdjustment() {
        guard presentation.isAdjusting else { return }
        presentation.isAdjusting = false
        panel?.ignoresMouseEvents = true
        dragStartFrame = nil
        resizeStartFrame = nil
        saveCurrentPlacement()
        if wasVisibleBeforeAdjustment {
            restartFade()
        } else {
            hide()
        }
        wasVisibleBeforeAdjustment = false
    }

    public func resetPosition() {
        savedPlacement = nil
        UserDefaults.standard.removeObject(forKey: placementKey)
        repositionForAvailableScreens()
    }

    private func ensurePanel() -> SubtitlePanel? {
        if let panel { return panel }
        guard let frame = resolvedFrame() else { return nil }
        let panel = SubtitlePanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        let hostingView = FirstMouseHostingView(rootView: OverlayView(
            presentation: presentation,
            onMove: { [weak self] in self?.move(by: $0) },
            onMoveEnd: { [weak self] in self?.endMove() },
            onResize: { [weak self] in self?.resize(by: $0) },
            onResizeEnd: { [weak self] in self?.endResize() },
            onDone: { [weak self] in self?.onFinishAdjustmentRequest?() }
        ))
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.layer?.isOpaque = false
        panel.contentView = hostingView
        self.panel = panel
        return panel
    }

    private func restartFade() {
        fadeTask?.cancel()
        guard !presentation.isAdjusting, presentation.caption != nil else { return }
        presentation.textOpacity = 1
        fadeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled, let self, self.isVisible, !self.presentation.isAdjusting else { return }
            withAnimation(.easeOut(duration: 0.35)) {
                self.presentation.textOpacity = 0
            }
        }
    }

    private func updatePanelHeight() {
        guard let panel else { return }
        // Preserve the lower edge while the text scale or number of rows changes.
        var frame = panel.frame
        frame.size.height = OverlayTypography.panelHeight(for: presentation.displayMode, fontSize: presentation.fontSize)
        panel.setFrame(clamped(frame), display: true)
        if savedPlacement != nil { saveCurrentPlacement() }
    }

    private func move(by translation: CGSize) {
        guard presentation.isAdjusting, let panel else { return }
        if dragStartFrame == nil { dragStartFrame = panel.frame }
        guard let start = dragStartFrame else { return }
        let candidate = start.offsetBy(dx: translation.width, dy: -translation.height)
        panel.setFrame(clamped(candidate), display: true)
    }

    private func endMove() {
        dragStartFrame = nil
        saveCurrentPlacement()
    }

    private func resize(by delta: CGFloat) {
        guard presentation.isAdjusting, let panel else { return }
        if resizeStartFrame == nil { resizeStartFrame = panel.frame }
        guard let start = resizeStartFrame else { return }
        let candidate = CGRect(x: start.minX, y: start.minY, width: max(240, start.width + delta), height: start.height)
        panel.setFrame(clamped(candidate), display: true)
    }

    private func endResize() {
        resizeStartFrame = nil
        saveCurrentPlacement()
    }

    private func clamped(_ frame: CGRect) -> CGRect {
        let displays = availableDisplays()
        guard let display = displays.first(where: { $0.visibleFrame.contains(CGPoint(x: frame.midX, y: frame.midY)) })
            ?? displays.first(where: { $0.visibleFrame.intersects(frame) })
            ?? displays.first else { return frame }
        let visible = display.visibleFrame
        let width = min(frame.width, min(1_200, visible.width))
        let height = min(frame.height, visible.height)
        return CGRect(
            x: min(max(frame.minX, visible.minX), visible.maxX - width),
            y: min(max(frame.minY, visible.minY), visible.maxY - height),
            width: width,
            height: height
        )
    }

    private func saveCurrentPlacement() {
        guard let panel else { return }
        let displays = availableDisplays()
        guard let display = displays.first(where: { $0.visibleFrame.contains(CGPoint(x: panel.frame.midX, y: panel.frame.midY)) })
            ?? displays.first else { return }
        let placement = OverlayPlacementGeometry.record(frame: panel.frame, on: display)
        savedPlacement = placement
        if let data = try? JSONEncoder().encode(placement) {
            UserDefaults.standard.set(data, forKey: placementKey)
        }
    }

    private func resolvedFrame() -> CGRect? {
        let mainID = NSScreen.main.flatMap(screenID)
        return OverlayPlacementGeometry.resolve(
            saved: savedPlacement,
            screens: availableDisplays(),
            preferredDisplayID: mainID,
            height: OverlayTypography.panelHeight(for: presentation.displayMode, fontSize: presentation.fontSize)
        )
    }

    private func repositionForAvailableScreens() {
        guard let panel, let frame = resolvedFrame() else { return }
        panel.setFrame(frame, display: true)
        if savedPlacement != nil { saveCurrentPlacement() }
    }

    @objc private func screenParametersChanged(_ notification: Notification) {
        repositionForAvailableScreens()
    }

    private func availableDisplays() -> [OverlayDisplay] {
        NSScreen.screens.enumerated().map { index, screen in
            OverlayDisplay(id: screenID(screen) ?? UInt32(index), visibleFrame: screen.visibleFrame)
        }
    }

    private func screenID(_ screen: NSScreen) -> UInt32? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

private final class SubtitlePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class FirstMouseHostingView: NSHostingView<OverlayView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
