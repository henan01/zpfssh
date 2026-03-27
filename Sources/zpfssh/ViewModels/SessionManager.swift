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
    }

    func closeTab(_ tab: SessionTab) {
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
        if tab.id == splitTabID {
            // Clicking the split tab swaps primary and secondary panes
            splitTabID = activeTabID
        }
        activeTabID = tab.id
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
    /// This enables free workspace composition from multiple tab sessions.
    @discardableResult
    func mergeTabIntoPane(
        sourceTabID: UUID,
        targetTabID: UUID,
        targetPaneID: UUID,
        position: PaneDropPosition = .center
    ) -> Bool {
        guard sourceTabID != targetTabID,
              let sourceIndex = tabs.firstIndex(where: { $0.id == sourceTabID }),
              let targetIndex = tabs.firstIndex(where: { $0.id == targetTabID }) else {
            return false
        }

        let sourceTab = tabs[sourceIndex]
        let targetTab = tabs[targetIndex]

        guard targetTab.splitPane(
            targetPaneID,
            direction: position.splitDirection,
            with: sourceTab.server,
            placeNewFirst: position.placeNewFirst
        ) != nil else {
            return false
        }

        if splitTabID == sourceTabID {
            splitTabID = nil
        }
        broadcastTargetIDs.remove(sourceTabID)
        tabs.removeAll { $0.id == sourceTabID }
        activeTabID = targetTabID
        return true
    }

    /// Replace a pane's session with a source tab's server (center drop).
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
              let targetPane = targetTab.paneSessions[targetPaneID] else {
            return false
        }

        // Create a new standalone tab for the displaced pane content
        let displacedTab = SessionTab(server: targetPane.server)
        if let idx = tabs.firstIndex(where: { $0.id == sourceTabID }) {
            tabs.insert(displacedTab, at: idx)
        } else {
            tabs.append(displacedTab)
        }

        // Replace the target pane's session with source tab's server
        targetTab.paneSessions[targetPaneID] = PaneSession(id: targetPaneID, server: sourceTab.server)
        targetTab.focusedPaneID = targetPaneID

        // Remove source tab
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
