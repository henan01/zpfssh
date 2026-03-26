import SwiftUI
import AppKit
import SwiftTerm

// MARK: - Coordinator

final class TerminalCoordinator: NSObject, LocalProcessTerminalViewDelegate, @unchecked Sendable {
    var paneID: UUID
    var tab: SessionTab?
    var lastSearchText: String = ""

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
        applyAppearance(to: tv)
        registerNotifications(for: tv)
        return tv
    }

    func updateNSView(_ tv: TerminalView, context: Context) {
        applyAppearance(to: tv)

        if searchActive && !searchText.isEmpty {
            if context.coordinator.lastSearchText != searchText {
                context.coordinator.lastSearchText = searchText
                tv.findNext(searchText)
            }
        } else if context.coordinator.lastSearchText != "" {
            context.coordinator.lastSearchText = ""
            tv.clearSearch()
        }
    }

    // MARK: - View factory

    /// Launches /usr/bin/ssh directly for all auth types.
    /// For password auth, SSH_ASKPASS injects the saved password without any
    /// expect/spawn pattern-matching — works on any port and with any server config.
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

    private func applyAppearance(to tv: TerminalView) {
        let theme = settings.currentTheme
        tv.nativeForegroundColor = theme.foreground.nsColor
        tv.nativeBackgroundColor = theme.background.nsColor
        let font = NSFont(name: settings.appearance.fontName, size: settings.appearance.fontSize)
            ?? NSFont.monospacedSystemFont(ofSize: settings.appearance.fontSize, weight: .regular)
        tv.font = font
    }

    // MARK: - Notification observers

    private func registerNotifications(for tv: TerminalView) {
        let capturedPaneID = paneID

        NotificationCenter.default.addObserver(
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

        NotificationCenter.default.addObserver(
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

        NotificationCenter.default.addObserver(
            forName: .terminalFindNext, object: nil, queue: .main
        ) { [weak tv] notification in
            guard
                let pid = notification.userInfo?["paneID"] as? UUID, pid == capturedPaneID,
                let text = notification.userInfo?["text"] as? String,
                let tv
            else { return }
            tv.findNext(text)
        }

        NotificationCenter.default.addObserver(
            forName: .terminalFindPrevious, object: nil, queue: .main
        ) { [weak tv] notification in
            guard
                let pid = notification.userInfo?["paneID"] as? UUID, pid == capturedPaneID,
                let text = notification.userInfo?["text"] as? String,
                let tv
            else { return }
            tv.findPrevious(text)
        }
    }
}

// PaneContainer is defined in TerminalContainerView.swift
