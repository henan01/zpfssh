import Foundation
import SwiftUI

@MainActor
class SessionManager: ObservableObject {
    @Published var tabs: [SessionTab] = []
    @Published var activeTabID: UUID? = nil
    @Published var broadcastTargetIDs: Set<UUID> = []
    @Published var isBroadcastMode: Bool = false

    var activeTab: SessionTab? {
        tabs.first { $0.id == activeTabID }
    }

    var connectedTabs: [SessionTab] {
        tabs.filter { $0.isConnected }
    }

    func openTab(for server: Server) {
        let tab = SessionTab(server: server)
        tabs.append(tab)
        activeTabID = tab.id
    }

    func closeTab(_ tab: SessionTab) {
        tabs.removeAll { $0.id == tab.id }
        broadcastTargetIDs.remove(tab.id)
        if activeTabID == tab.id {
            activeTabID = tabs.last?.id
        }
    }

    func closeTab(id: UUID) {
        if let tab = tabs.first(where: { $0.id == id }) {
            closeTab(tab)
        }
    }

    /// Duplicate a tab: open a new independent SSH connection to the same server
    func duplicateTab(_ tab: SessionTab) {
        let newTab = SessionTab(server: tab.server)
        if let idx = tabs.firstIndex(where: { $0.id == tab.id }) {
            tabs.insert(newTab, at: idx + 1)
        } else {
            tabs.append(newTab)
        }
        activeTabID = newTab.id
    }

    /// Close the focused pane inside the active tab; if only one pane, close the whole tab
    func closeFocusedPane() {
        guard let tab = activeTab else { return }
        if tab.layout.allLeafIDs.count <= 1 {
            closeTab(tab)
        } else {
            tab.closePane(tab.focusedPaneID)
        }
    }

    func activateTab(_ tab: SessionTab) {
        activeTabID = tab.id
    }

    func moveTab(from source: IndexSet, to destination: Int) {
        tabs.move(fromOffsets: source, toOffset: destination)
    }

    // MARK: – Broadcast

    func toggleBroadcastMode() {
        isBroadcastMode.toggle()
        if !isBroadcastMode {
            broadcastTargetIDs.removeAll()
        } else {
            // Default: all connected tabs
            broadcastTargetIDs = Set(connectedTabs.map { $0.id })
        }
    }

    func toggleBroadcastTarget(_ tab: SessionTab) {
        if broadcastTargetIDs.contains(tab.id) {
            broadcastTargetIDs.remove(tab.id)
        } else {
            broadcastTargetIDs.insert(tab.id)
        }
    }

    /// Sends a notification so TerminalPaneViews can pick up the broadcast command
    func broadcast(_ command: String) {
        let targets = isBroadcastMode ? broadcastTargetIDs : Set(tabs.map { $0.id })
        NotificationCenter.default.post(
            name: .broadcastCommand,
            object: nil,
            userInfo: ["command": command, "targets": targets]
        )
    }

    // MARK: – Tab renaming

    func renameTab(_ tab: SessionTab, title: String) {
        tab.displayTitle = title
        tab.autoTitle = false
    }

    func resetTabTitle(_ tab: SessionTab) {
        tab.autoTitle = true
        tab.displayTitle = tab.server.displayTitle
    }
}

extension Notification.Name {
    static let broadcastCommand = Notification.Name("zen.ssh.broadcastCommand")
    static let sendSnippet = Notification.Name("zen.ssh.sendSnippet")
    static let terminalFindNext = Notification.Name("zen.ssh.terminalFindNext")
    static let terminalFindPrevious = Notification.Name("zen.ssh.terminalFindPrevious")
}
