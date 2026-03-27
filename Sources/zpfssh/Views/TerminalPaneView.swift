import SwiftUI
import AppKit
import SwiftTerm

// MARK: - Coordinator

final class TerminalCoordinator: NSObject, LocalProcessTerminalViewDelegate, @unchecked Sendable {
    var paneID: UUID
    var tab: SessionTab?
    var lastSearchText: String = ""
    // Appearance cache — avoids redundant AppKit calls on every tab switch
    var lastThemeID: String = ""
    var lastFontName: String = ""
    var lastFontSize: Double = 0
    // Notification observer tokens — stored so they can be removed in dismantleNSView
    var observers: [NSObjectProtocol] = []
    // Local key monitor tokens for NSEvent.removeMonitor(_:)
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

    func makeCoordinator() -> TerminalCoordinator {
        TerminalCoordinator(paneID: paneID)
    }

    func makeNSView(context: Context) -> TerminalView {
        context.coordinator.tab = tab

        let tv = makeZModemView(coordinator: context.coordinator)
        tv.autoresizingMask = [.width, .height]
        applyAppearanceIfNeeded(to: tv, context: context)
        registerNotifications(for: tv, coordinator: context.coordinator)
        registerKeyboardCompatibility(for: tv, coordinator: context.coordinator)
        return tv
    }

    func updateNSView(_ tv: TerminalView, context: Context) {
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

    /// Called by SwiftUI when the view is removed from the hierarchy (pane or tab closed).
    /// This is the correct place to terminate the SSH subprocess and remove observers.
    static func dismantleNSView(_ nsView: TerminalView, coordinator: TerminalCoordinator) {
        // Remove notification observers — prevents dead observer accumulation
        coordinator.observers.forEach { NotificationCenter.default.removeObserver($0) }
        coordinator.observers.removeAll()
        coordinator.keyMonitors.forEach { NSEvent.removeMonitor($0) }
        coordinator.keyMonitors.removeAll()

        // Terminate the SSH subprocess (sends SIGTERM + closes pty)
        // Without this, /usr/bin/ssh processes become orphans after pane/tab close.
        (nsView as? LocalProcessTerminalView)?.terminate()
    }

    // MARK: - View factory

    /// Launches /usr/bin/ssh directly for all auth types.
    /// Uses ZModemTerminalView so that `sz` transfers work automatically.
    private func makeZModemView(coordinator: TerminalCoordinator) -> ZModemTerminalView {
        let tv = ZModemTerminalView(frame: .zero)
        tv.processDelegate = coordinator

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

    /// Maps macOS Home/End-style keys to terminal-compatible sequences.
    /// This also covers compact keyboards where `fn+←/→` behaves like Home/End.
    private func registerKeyboardCompatibility(for tv: TerminalView, coordinator: TerminalCoordinator) {
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak tv] event in
            guard let tv, tv.window?.firstResponder === tv else { return event }

            let isFnArrow = event.modifierFlags.contains(.function)
                && (event.keyCode == 123 || event.keyCode == 124)
            let isHomeEnd = event.keyCode == 115 || event.keyCode == 119
            guard isFnArrow || isHomeEnd else { return event }

            switch event.keyCode {
            case 123, 115:
                tv.send(txt: "\u{1B}[H")
            case 124, 119:
                tv.send(txt: "\u{1B}[F")
            default:
                return event
            }
            return nil
        }
        coordinator.keyMonitors.append(monitor)
    }
}

// PaneContainer is defined in TerminalContainerView.swift
