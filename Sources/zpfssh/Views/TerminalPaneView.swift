import SwiftUI
import AppKit
import SwiftTerm

// MARK: - Coordinator

final class TerminalCoordinator: NSObject, LocalProcessTerminalViewDelegate, @unchecked Sendable {
    var paneID: UUID
    var tab: SessionTab?
    var onFocus: (() -> Void)?
    var lastSearchText: String = ""
    var lastThemeID: String = ""
    var lastFontName: String = ""
    var lastFontSize: Double = 0
    var observers: [NSObjectProtocol] = []
    var keyMonitors: [Any] = []

    init(paneID: UUID) {
        self.paneID = paneID
    }

    // Called by SshTerminalView callbacks and by LocalProcessTerminalViewDelegate
    func handleTitleChange(_ title: String) {
        let hostname: String
        if title.contains("@") {
            hostname = title
                .components(separatedBy: "@").last?
                .components(separatedBy: ":").first?
                .trimmingCharacters(in: .whitespaces) ?? title
        } else {
            hostname = title.components(separatedBy: ":").first?
                .trimmingCharacters(in: .whitespaces) ?? title
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, let tab = self.tab, !hostname.isEmpty else { return }
            tab.updateHostname(hostname, forPane: self.paneID)
        }
    }

    // MARK: LocalProcessTerminalViewDelegate (SSH-agent / fallback path)

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        handleTitleChange(title)
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.tab?.setConnected(false, forPane: self.paneID)
        }
    }
}

// MARK: - SwiftUI Representable

struct TerminalPaneView: NSViewRepresentable {
    let server: Server
    let paneID: UUID
    let tab: SessionTab
    @ObservedObject var settings: AppSettings
    var searchText: String
    var searchActive: Bool
    var onFocus: (() -> Void)? = nil
    var onHighlightChange: ((PaneDropPosition?) -> Void)? = nil
    var onFileHighlightChange: ((Bool) -> Void)? = nil
    var onMergeTab: ((UUID, PaneDropPosition) -> Void)? = nil
    var onMovePane: ((UUID, PaneDropPosition) -> Void)? = nil
    var onFileDrop: (([URL]) -> Void)? = nil

    func makeCoordinator() -> TerminalCoordinator {
        TerminalCoordinator(paneID: paneID)
    }

    func makeNSView(context: Context) -> TerminalView {
        context.coordinator.tab = tab
        context.coordinator.onFocus = onFocus

        // Reuse cached terminal view to preserve SSH connection across layout changes.
        // When a pane is split, SwiftUI rebuilds the view tree (AnyView structure changes),
        // which would normally dismantle the old TerminalView and create a new one.
        // By caching the NSView in PaneSession, we keep the SSH process alive.
        if let cached = tab.paneSessions[paneID]?.cachedTerminalView as? LocalProcessTerminalView {
            cached.removeFromSuperview()
            cached.processDelegate = context.coordinator
            cached.autoresizingMask = [.width, .height]
            applyDropCallbacks(to: cached)
            applyAppearanceIfNeeded(to: cached, context: context)
            registerNotifications(for: cached, coordinator: context.coordinator)
            registerFocusDetection(for: cached, coordinator: context.coordinator)
            return cached
        }

        let tv = makeZModemView(coordinator: context.coordinator)
        tv.autoresizingMask = [.width, .height]
        tab.paneSessions[paneID]?.cachedTerminalView = tv
        applyAppearanceIfNeeded(to: tv, context: context)
        registerNotifications(for: tv, coordinator: context.coordinator)
        registerFocusDetection(for: tv, coordinator: context.coordinator)
        return tv
    }

    func updateNSView(_ tv: TerminalView, context: Context) {
        applyDropCallbacks(to: tv)
        applyAppearanceIfNeeded(to: tv, context: context)

        if searchActive && !searchText.isEmpty {
            if context.coordinator.lastSearchText != searchText {
                context.coordinator.lastSearchText = searchText
                // findNext marks ALL occurrences and scrolls to the first/next match
                tv.findNext(searchText)
            }
        } else if !context.coordinator.lastSearchText.isEmpty {
            context.coordinator.lastSearchText = ""
            tv.clearSearch()
        }
    }

    /// Called by SwiftUI when the view is removed from the hierarchy.
    /// Only terminates the SSH subprocess if the pane was actually closed or replaced.
    /// Layout-only changes (splits, resizes) should NOT kill the connection — the
    /// cached terminal view will be reused in the next makeNSView call.
    static func dismantleNSView(_ nsView: TerminalView, coordinator: TerminalCoordinator) {
        // Remove notification observers — prevents dead observer accumulation
        coordinator.observers.forEach { NotificationCenter.default.removeObserver($0) }
        coordinator.observers.removeAll()
        coordinator.keyMonitors.forEach { NSEvent.removeMonitor($0) }
        coordinator.keyMonitors.removeAll()

        // Only terminate SSH if the pane was truly closed (removed from paneSessions)
        // or replaced (cachedTerminalView is a different instance).
        // When just repositioning (split/resize), the cached view === nsView → keep alive.
        let cached = coordinator.tab?.paneSessions[coordinator.paneID]?.cachedTerminalView
        if cached == nil || cached !== nsView {
            (nsView as? LocalProcessTerminalView)?.terminate()
        }
    }

    // MARK: - View factory

    /// Launches /usr/bin/ssh directly for all auth types.
    /// Uses ZModemTerminalView so that `sz` transfers work automatically
    /// and pane/tab drag-and-drop is handled at the AppKit level.
    private func makeZModemView(coordinator: TerminalCoordinator) -> ZModemTerminalView {
        let tv = ZModemTerminalView(frame: .zero)
        tv.processDelegate = coordinator
        applyDropCallbacks(to: tv)

        var sshEnv = ProcessInfo.processInfo.environment
        let executable: String
        let execArgs: [String]

        if let config = SSHAskPassService.shared.launchConfig(for: server) {
            executable = config.executable
            execArgs   = config.args
            for (k, v) in config.env { sshEnv[k] = v }
        } else {
            executable = "/usr/bin/ssh"
            execArgs   = server.sshArgs()
        }

        tv.startProcess(executable: executable, args: execArgs,
                        environment: sshEnv.map { "\($0.key)=\($0.value)" },
                        execName: "ssh")

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak tab] in
            tab?.setConnected(true, forPane: paneID)
        }
        return tv
    }

    // MARK: - Drop callbacks

    /// Applies drag-and-drop callbacks to the terminal view.
    /// Called on create, reuse, and update to keep closures current.
    private func applyDropCallbacks(to tv: TerminalView) {
        guard let ztv = tv as? ZModemTerminalView else { return }
        ztv.currentTabID = tab.id
        ztv.targetPaneID = paneID
        ztv.onHighlightChange = onHighlightChange
        ztv.onFileHighlightChange = onFileHighlightChange
        ztv.onMergeTab = onMergeTab
        ztv.onMovePane = onMovePane
        ztv.onPaneFileDrop = onFileDrop
    }

    // MARK: - Appearance

    /// Only applies appearance when something actually changed — avoids triggering
    /// AppKit redraws on every tab switch when nothing has changed.
    private func applyAppearanceIfNeeded(to tv: TerminalView, context: Context) {
        let themeID  = settings.appearance.themeId
        let fontName = settings.appearance.fontName
        let fontSize = settings.appearance.fontSize
        let coord    = context.coordinator
        guard coord.lastThemeID != themeID
                || coord.lastFontName != fontName
                || coord.lastFontSize != fontSize else { return }
        coord.lastThemeID  = themeID
        coord.lastFontName = fontName
        coord.lastFontSize = fontSize
        let theme = settings.currentTheme
        tv.nativeForegroundColor = theme.foreground.nsColor
        tv.nativeBackgroundColor = theme.background.nsColor
        let font = NSFont(name: fontName, size: fontSize)
            ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        tv.font = font
    }

    // MARK: - Notification observers

    private func registerNotifications(for tv: TerminalView, coordinator: TerminalCoordinator) {
        let capturedPaneID = paneID

        let o1 = NotificationCenter.default.addObserver(
            forName: .broadcastCommand, object: nil, queue: .main
        ) { [weak tv, weak tab] notification in
            guard
                let targets = notification.userInfo?["targets"] as? Set<UUID>,
                let tabID = tab?.id, targets.contains(tabID),
                let command = notification.userInfo?["command"] as? String,
                let tv
            else { return }
            tv.send(txt: command + "\n")
        }

        let o2 = NotificationCenter.default.addObserver(
            forName: .sendSnippet, object: nil, queue: .main
        ) { [weak tv, weak tab] notification in
            guard
                let targetID = notification.userInfo?["tabID"] as? UUID,
                let tabID = tab?.id, targetID == tabID,
                let command = notification.userInfo?["command"] as? String,
                let tv
            else { return }
            tv.send(txt: command + "\n")
        }

        let o3 = NotificationCenter.default.addObserver(
            forName: .terminalFindNext, object: nil, queue: .main
        ) { [weak tv] notification in
            guard
                let pid = notification.userInfo?["paneID"] as? UUID, pid == capturedPaneID,
                let text = notification.userInfo?["text"] as? String,
                let tv
            else { return }
            tv.findNext(text)
        }

        let o4 = NotificationCenter.default.addObserver(
            forName: .terminalFindPrevious, object: nil, queue: .main
        ) { [weak tv] notification in
            guard
                let pid = notification.userInfo?["paneID"] as? UUID, pid == capturedPaneID,
                let text = notification.userInfo?["text"] as? String,
                let tv
            else { return }
            tv.findPrevious(text)
        }

        coordinator.observers = [o1, o2, o3, o4]
    }

    /// Detects mouse-down on the terminal and triggers focus WITHOUT consuming the event.
    /// This replaces the old SwiftUI .onTapGesture approach which blocked all clicks
    /// from reaching the AppKit TerminalView, preventing keyboard input entirely.
    private func registerFocusDetection(for tv: TerminalView, coordinator: TerminalCoordinator) {
        let monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak tv] event in
            guard let tv, let window = tv.window, let contentView = window.contentView else {
                return event
            }
            let hitView = contentView.hitTest(event.locationInWindow)
            if hitView === tv || (hitView != nil && hitView!.isDescendant(of: tv)) {
                coordinator.onFocus?()
                if window.firstResponder !== tv {
                    window.makeFirstResponder(tv)
                }
            }
            return event
        }
        if let monitor { coordinator.keyMonitors.append(monitor) }
    }
}
