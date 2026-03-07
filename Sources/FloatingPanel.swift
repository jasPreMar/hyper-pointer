import AppKit
import SwiftUI

class FloatingPanel: NSPanel {
    private static let maxPanelDimension: CGFloat = 392
    let searchViewModel = SearchViewModel()
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var globalClickMonitor: Any?
    private var commandKeyMouseMonitor: Any?
    private var hostingView: NSHostingView<PanelContentView>!
    private var isTerminalMode = false
    private var isCommandKeyVisible = false
    private var lastReportedContentSize: CGSize = .zero
    var isCommandKeyHeld = false

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 36),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false

        hostingView = NSHostingView(rootView: PanelContentView(viewModel: searchViewModel))
        contentView = hostingView

        // Wire up the submit callback
        searchViewModel.onSubmit = { [weak self] context, screenshotURL, screenshotStatus in
            self?.transitionToTerminal(
                message: context,
                screenshotURL: screenshotURL,
                screenshotStatus: screenshotStatus
            )
        }
        searchViewModel.onClose = { [weak self] in
            self?.close()
        }
        searchViewModel.onContentSizeChange = { [weak self] size in
            self?.resizeToContentSize(size, preserveTopEdge: true)
        }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    func show(at point: NSPoint) {
        searchViewModel.query = ""
        searchViewModel.updateHoveredApp()

        let fittingSize = hostingView.fittingSize
        setContentSize(fittingSize)

        // Position at click point with slight offset, clamped to screen
        let x = point.x + 4
        let y = point.y - fittingSize.height - 4

        if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main {
            let sf = screen.visibleFrame
            let clampedX = max(sf.minX, min(x, sf.maxX - fittingSize.width))
            let clampedY = max(sf.minY, y)
            setFrameOrigin(NSPoint(x: clampedX, y: clampedY))
        } else {
            setFrameOrigin(NSPoint(x: x, y: y))
        }

        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Dismiss on click outside (no mouse-move monitors — panel stays anchored)
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            guard let self = self, !self.isTerminalMode else { return }
            self.close()
        }
    }

    func show() {
        searchViewModel.query = ""

        positionAtCursor()
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Follow cursor
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            self?.positionAtCursor()
            self?.searchViewModel.updateHoveredApp()
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            self?.positionAtCursor()
            self?.searchViewModel.updateHoveredApp()
            return event
        }

        // Dismiss on any click outside
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            guard let self = self, !self.isTerminalMode else { return }
            self.close()
        }
    }

    func transitionToTerminal(
        message: String,
        screenshotURL: URL? = nil,
        screenshotStatus: String? = nil
    ) {
        isTerminalMode = true
        removeAllMonitors()

        // Switch to chat mode — the PanelContentView handles the rest
        searchViewModel.chatHistory.append((role: "user", text: searchViewModel.query))
        searchViewModel.query = ""

        let manager = ClaudeProcessManager()
        manager.onComplete = { [weak self] response in
            // Clear streaming text before appending to history to avoid duplicate display
            manager.outputText = ""
            self?.searchViewModel.chatHistory.append((role: "assistant", text: response))
            // Capture session ID for follow-up messages
            if let sid = manager.sessionId {
                self?.searchViewModel.currentSessionId = sid
            }
        }
        searchViewModel.claudeManager = manager
        searchViewModel.isChatMode = true

        manager.start(
            message: message,
            screenshotURL: screenshotURL,
            screenshotDebug: screenshotStatus
        )
    }

    private func positionAtCursor() {
        guard !isTerminalMode else { return }
        let fittingSize = hostingView.fittingSize
        setContentSize(fittingSize)

        let mouse = NSEvent.mouseLocation
        let x = mouse.x + 4
        let y = mouse.y - fittingSize.height - 4

        if let screen = NSScreen.main {
            let sf = screen.visibleFrame
            let clampedX = max(sf.minX, min(x, sf.maxX - fittingSize.width))
            let clampedY = max(sf.minY, y)
            setFrameOrigin(NSPoint(x: clampedX, y: clampedY))
        } else {
            setFrameOrigin(NSPoint(x: x, y: y))
        }
    }

    private func resizeToContentSize(_ size: CGSize, preserveTopEdge: Bool) {
        let normalizedSize = CGSize(
            width: min(ceil(size.width), Self.maxPanelDimension),
            height: min(ceil(size.height), Self.maxPanelDimension)
        )
        guard normalizedSize.width > 0, normalizedSize.height > 0 else { return }
        guard abs(normalizedSize.width - lastReportedContentSize.width) > 0.5 ||
              abs(normalizedSize.height - lastReportedContentSize.height) > 0.5 else { return }
        lastReportedContentSize = normalizedSize

        guard isVisible else { return }

        let previousTop = frame.maxY
        let previousOriginX = frame.minX

        setContentSize(normalizedSize)

        guard preserveTopEdge else { return }

        var nextOrigin = NSPoint(x: previousOriginX, y: previousTop - frame.height)
        if let screen = screen ?? NSScreen.screens.first(where: { $0.visibleFrame.intersects(frame) }) ?? NSScreen.main {
            let visibleFrame = screen.visibleFrame
            nextOrigin.x = max(visibleFrame.minX, min(nextOrigin.x, visibleFrame.maxX - frame.width))
            nextOrigin.y = max(visibleFrame.minY, min(nextOrigin.y, visibleFrame.maxY - frame.height))
        }

        setFrameOrigin(nextOrigin)
    }

    // MARK: - Command key mode

    /// Called when ⌘ is pressed. Shows a minimal icon indicator immediately,
    /// then expands to the full panel on the first cursor move.
    func startCommandKeyMode() {
        searchViewModel.isCommandKeyMode = true
        searchViewModel.isMinimalMode = true
        searchViewModel.query = ""
        isCommandKeyVisible = false

        // Show the indicator right away at the current cursor position
        searchViewModel.updateHoveredApp()
        positionAtCursor()
        orderFront(nil)

        commandKeyMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            guard let self else { return }
            if !self.isCommandKeyVisible {
                self.isCommandKeyVisible = true
                self.searchViewModel.isMinimalMode = false
            }
            self.positionAtCursor()
            self.searchViewModel.updateHoveredApp()
        }
    }

    /// Called when ⌘ is released. Anchors the panel and shows the input row.
    /// If the panel was never shown (cursor didn't move), discard silently.
    func endCommandKeyMode() {
        if let m = commandKeyMouseMonitor { NSEvent.removeMonitor(m); commandKeyMouseMonitor = nil }
        if let m = globalMouseMonitor { NSEvent.removeMonitor(m); globalMouseMonitor = nil }
        if let m = localMouseMonitor { NSEvent.removeMonitor(m); localMouseMonitor = nil }

        guard isCommandKeyVisible else {
            close()
            return
        }

        // Show input row if it was hidden
        if searchViewModel.isCommandKeyMode {
            searchViewModel.isCommandKeyMode = false
            makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }

        // Dismiss when cursor moves (unless ⌘ is held again or a message was sent)
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            guard let self, !self.isCommandKeyHeld, !self.searchViewModel.isChatMode else { return }
            self.close()
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            guard let self, !self.isCommandKeyHeld, !self.searchViewModel.isChatMode else { return event }
            self.close()
            return event
        }
    }

    /// Re-enter cursor-following on an already-visible panel.
    /// Hides the input row only if no text has been typed yet.
    func restartCommandKeyMode() {
        if let m = globalMouseMonitor { NSEvent.removeMonitor(m); globalMouseMonitor = nil }
        if let m = localMouseMonitor { NSEvent.removeMonitor(m); localMouseMonitor = nil }
        if let m = commandKeyMouseMonitor { NSEvent.removeMonitor(m); commandKeyMouseMonitor = nil }

        isCommandKeyVisible = true
        if searchViewModel.query.isEmpty {
            searchViewModel.isCommandKeyMode = true
        }

        // Global monitor fires when another app is frontmost; local monitor fires when we are.
        commandKeyMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            guard let self else { return }
            self.positionAtCursor()
            self.searchViewModel.updateHoveredApp()
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            guard let self else { return event }
            self.positionAtCursor()
            self.searchViewModel.updateHoveredApp()
            return event
        }
    }

    private func removeAllMonitors() {
        for monitor in [globalMouseMonitor, localMouseMonitor, globalClickMonitor, commandKeyMouseMonitor].compactMap({ $0 }) {
            NSEvent.removeMonitor(monitor)
        }
        globalMouseMonitor = nil
        localMouseMonitor = nil
        globalClickMonitor = nil
        commandKeyMouseMonitor = nil
    }

    override func close() {
        removeAllMonitors()
        super.close()
        searchViewModel.query = ""
        searchViewModel.isChatMode = false
        searchViewModel.isCommandKeyMode = false
        searchViewModel.isMinimalMode = false
        searchViewModel.chatHistory = []
        searchViewModel.claudeManager = nil
        searchViewModel.currentSessionId = nil
        lastReportedContentSize = .zero
        isTerminalMode = false
        isCommandKeyVisible = false
        isCommandKeyHeld = false
    }

    // Handle Escape: stop streaming if active, otherwise close
    override func cancelOperation(_ sender: Any?) {
        if let manager = searchViewModel.claudeManager,
           manager.status == .waiting || manager.status == .streaming {
            manager.stop()
        } else {
            close()
        }
    }
}
