import Foundation
import SwiftUI

@MainActor
class SessionManager: ObservableObject {
    @Published var tabs: [SessionTab] = []
    @Published var activeTabID: UUID? = nil
    @Published var broadcastTargetIDs: Set<UUID> = []
    @Published var isBroadcastMode: Bool = false

    /// The tab shown in the secondary (right/bottom) split pane. nil = no cross-tab split.
    @Published var splitTabID: UUID? = nil
    /// Ratio of primary pane width to total width (0.2 … 0.8).
    @Published var splitRatio: CGFloat = 0.5
    /// Cross-tab split direction.
    @Published var splitDirection: SplitDirection = .horizontal

    var activeTab: SessionTab? {
        tabs.first { $0.id == activeTabID }
    }

    var splitTab: SessionTab? {
        guard let id = splitTabID else { return nil }
        return tabs.first { $0.id == id }
    }

    var connectedTabs: [SessionTab] {
        tabs.filter { $0.isConnected }
    }

    func openTab(for server: Server) {
        let tab = SessionTab(server: server)
        tabs.append(tab)
        activeTabID = tab.id
        Log.session("打开 tab \(tab.id.uuidString.prefix(8)) → \(server.host):\(server.port) 总数=\(tabs.count)")
    }

    func closeTab(_ tab: SessionTab) {
        Log.session("关闭 tab \(tab.id.uuidString.prefix(8)) 剩余=\(tabs.count - 1)")
        tabs.removeAll { $0.id == tab.id }
        broadcastTargetIDs.remove(tab.id)
        if splitTabID == tab.id { splitTabID = nil }
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
        Log.session("复制 tab \(tab.id.uuidString.prefix(8)) → 新 tab \(newTab.id.uuidString.prefix(8))")
    }

    /// Close the focused pane inside the active tab; if only one pane, close the whole tab
    func closeFocusedPane() {
        guard let tab = activeTab else { return }
        if tab.layout.allLeafIDs.count <= 1 {
            Log.session("关闭唯一 pane，关闭整个 tab \(tab.id.uuidString.prefix(8))")
            closeTab(tab)
        } else {
            Log.session("关闭 pane \(tab.focusedPaneID.uuidString.prefix(8)) in tab \(tab.id.uuidString.prefix(8))")
            tab.closePane(tab.focusedPaneID)
        }
    }

    func activateTab(_ tab: SessionTab) {
        if tab.id == splitTabID {
            splitTabID = activeTabID
        }
        activeTabID = tab.id
        Log.session("激活 tab \(tab.id.uuidString.prefix(8))")
    }

    /// Show `tab` in the secondary split pane alongside the current active tab.
    func setSplitTab(_ tab: SessionTab, direction: SplitDirection = .horizontal) {
        guard tab.id != activeTabID else { return }
        splitDirection = direction
        splitTabID = tab.id
    }

    /// Close the cross-tab split view (does NOT close the tab itself).
    func closeSplit() {
        splitTabID = nil
    }

    /// Split active tab with a neighboring existing tab (preserves both live sessions).
    /// Returns true if a split target was found.
    @discardableResult
    func splitWithNeighborTab(direction: SplitDirection = .horizontal) -> Bool {
        guard let activeID = activeTabID,
              let activeIndex = tabs.firstIndex(where: { $0.id == activeID }),
              tabs.count > 1 else {
            return false
        }

        let neighborIndex = activeIndex + 1 < tabs.count ? (activeIndex + 1) : (activeIndex - 1)
        guard tabs.indices.contains(neighborIndex) else { return false }
        splitDirection = direction
        splitTabID = tabs[neighborIndex].id
        return true
    }

    func moveTab(from source: IndexSet, to destination: Int) {
        tabs.move(fromOffsets: source, toOffset: destination)
    }

    /// Merge a tab into a specific pane of another tab by splitting that pane.
    /// Transfers the existing PaneSession to preserve the live SSH connection.
    @discardableResult
    func mergeTabIntoPane(
        sourceTabID: UUID,
        targetTabID: UUID,
        targetPaneID: UUID,
        position: PaneDropPosition = .center
    ) -> Bool {
        guard sourceTabID != targetTabID,
              let sourceTab = tabs.first(where: { $0.id == sourceTabID }),
              let targetTab = tabs.first(where: { $0.id == targetTabID }),
              let sourceSession = sourceTab.paneSessions[sourceTab.focusedPaneID] else {
            return false
        }

        guard targetTab.splitPaneWithSession(
            targetPaneID,
            direction: position.splitDirection,
            session: sourceSession,
            placeNewFirst: position.placeNewFirst
        ) else {
            return false
        }

        // Don't remove sourceSession from sourceTab.paneSessions —
        // dismantleNSView needs the cached reference to skip SSH termination.
        if splitTabID == sourceTabID {
            splitTabID = nil
        }
        broadcastTargetIDs.remove(sourceTabID)
        tabs.removeAll { $0.id == sourceTabID }
        activeTabID = targetTabID
        return true
    }

    /// Replace a pane's session with a source tab's session (center drop).
    /// Transfers existing PaneSessions to preserve live SSH connections.
    /// The displaced pane content becomes a new standalone tab in the tab bar.
    @discardableResult
    func replaceTabInPane(
        sourceTabID: UUID,
        targetTabID: UUID,
        targetPaneID: UUID
    ) -> Bool {
        guard sourceTabID != targetTabID,
              let sourceTab = tabs.first(where: { $0.id == sourceTabID }),
              let targetTab = tabs.first(where: { $0.id == targetTabID }),
              let targetSession = targetTab.paneSessions[targetPaneID],
              let sourceSession = sourceTab.paneSessions[sourceTab.focusedPaneID] else {
            return false
        }

        // Create a new standalone tab reusing the displaced pane's live session
        let displacedTab = SessionTab(existingSession: targetSession)
        if let idx = tabs.firstIndex(where: { $0.id == sourceTabID }) {
            tabs.insert(displacedTab, at: idx)
        } else {
            tabs.append(displacedTab)
        }

        // Replace the target pane with source session (swap leaf ID in layout)
        targetTab.layout = targetTab.layout.replaceLeaf(targetPaneID, with: sourceSession.id)
        targetTab.paneSessions[sourceSession.id] = sourceSession
        // Keep targetPaneID in paneSessions so dismantleNSView can find cached view
        targetTab.focusedPaneID = sourceSession.id

        // Don't remove sourceSession from sourceTab.paneSessions —
        // dismantleNSView needs the cached reference to skip SSH termination.
        if splitTabID == sourceTabID { splitTabID = nil }
        broadcastTargetIDs.remove(sourceTabID)
        tabs.removeAll { $0.id == sourceTabID }
        activeTabID = targetTabID
        return true
    }

    // MARK: – Broadcast

    func toggleBroadcastMode() {
        isBroadcastMode.toggle()
        if !isBroadcastMode {
            broadcastTargetIDs.removeAll()
            Log.session("广播模式 关闭")
        } else {
            broadcastTargetIDs = Set(connectedTabs.map { $0.id })
            Log.session("广播模式 开启, 目标 \(broadcastTargetIDs.count) 个 tab")
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
        Log.session("广播命令 → \(targets.count) 个 tab: \(command.prefix(50))")
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
