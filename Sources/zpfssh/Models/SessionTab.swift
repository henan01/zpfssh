import Foundation
import SwiftUI

enum PaneID: Hashable, Identifiable, Sendable {
    case single(UUID)
    var id: UUID {
        switch self { case .single(let id): return id }
    }
}

enum SplitDirection: String, Codable, Sendable {
    case horizontal, vertical
}

enum PaneDropPosition: Sendable {
    case center, left, right, top, bottom, forbidden

    var splitDirection: SplitDirection {
        switch self {
        case .left, .right, .center, .forbidden: return .horizontal
        case .top, .bottom: return .vertical
        }
    }

    var placeNewFirst: Bool {
        switch self {
        case .left, .top: return true
        case .center, .right, .bottom, .forbidden: return false
        }
    }
}

indirect enum PaneLayout: Identifiable, Sendable {
    case leaf(id: UUID)
    case split(id: UUID, direction: SplitDirection, ratio: CGFloat, first: PaneLayout, second: PaneLayout)

    var id: UUID {
        switch self {
        case .leaf(let id): return id
        case .split(let id, _, _, _, _): return id
        }
    }

    var allLeafIDs: [UUID] {
        switch self {
        case .leaf(let id): return [id]
        case .split(_, _, _, let f, let s): return f.allLeafIDs + s.allLeafIDs
        }
    }

    func splitLeaf(
        _ leafID: UUID,
        direction: SplitDirection,
        newLeafID: UUID,
        placeNewFirst: Bool = false
    ) -> PaneLayout {
        switch self {
        case .leaf(let id):
            if id == leafID {
                return .split(
                    id: UUID(),
                    direction: direction,
                    ratio: 0.5,
                    first: placeNewFirst ? .leaf(id: newLeafID) : .leaf(id: id),
                    second: placeNewFirst ? .leaf(id: id) : .leaf(id: newLeafID)
                )
            }
            return self
        case .split(let sid, let dir, let ratio, let first, let second):
            return .split(id: sid, direction: dir, ratio: ratio,
                          first: first.splitLeaf(
                            leafID,
                            direction: direction,
                            newLeafID: newLeafID,
                            placeNewFirst: placeNewFirst
                          ),
                          second: second.splitLeaf(
                            leafID,
                            direction: direction,
                            newLeafID: newLeafID,
                            placeNewFirst: placeNewFirst
                          ))
        }
    }

    func insertLeaf(
        _ existingLeafID: UUID,
        nextTo targetLeafID: UUID,
        direction: SplitDirection,
        placeNewFirst: Bool = false
    ) -> PaneLayout {
        switch self {
        case .leaf(let id):
            if id == targetLeafID {
                return .split(
                    id: UUID(),
                    direction: direction,
                    ratio: 0.5,
                    first: placeNewFirst ? .leaf(id: existingLeafID) : .leaf(id: id),
                    second: placeNewFirst ? .leaf(id: id) : .leaf(id: existingLeafID)
                )
            }
            return self
        case .split(let sid, let dir, let ratio, let first, let second):
            return .split(
                id: sid,
                direction: dir,
                ratio: ratio,
                first: first.insertLeaf(
                    existingLeafID,
                    nextTo: targetLeafID,
                    direction: direction,
                    placeNewFirst: placeNewFirst
                ),
                second: second.insertLeaf(
                    existingLeafID,
                    nextTo: targetLeafID,
                    direction: direction,
                    placeNewFirst: placeNewFirst
                )
            )
        }
    }

    func removeLeaf(_ leafID: UUID) -> PaneLayout? {
        switch self {
        case .leaf(let id):
            return id == leafID ? nil : self
        case .split(let sid, let dir, let ratio, let first, let second):
            let newFirst = first.removeLeaf(leafID)
            let newSecond = second.removeLeaf(leafID)
            switch (newFirst, newSecond) {
            case (nil, let s?): return s
            case (let f?, nil): return f
            case (let f?, let s?):
                return .split(id: sid, direction: dir, ratio: ratio, first: f, second: s)
            default: return nil
            }
        }
    }

    func updateRatio(_ splitID: UUID, ratio: CGFloat) -> PaneLayout {
        switch self {
        case .leaf: return self
        case .split(let sid, let dir, let r, let first, let second):
            if sid == splitID {
                return .split(id: sid, direction: dir, ratio: ratio, first: first, second: second)
            }
            return .split(id: sid, direction: dir, ratio: r,
                          first: first.updateRatio(splitID, ratio: ratio),
                          second: second.updateRatio(splitID, ratio: ratio))
        }
    }

    /// Flip the split direction (horizontal↔vertical) for a specific split node.
    func toggleDirection(_ splitID: UUID) -> PaneLayout {
        switch self {
        case .leaf: return self
        case .split(let sid, let dir, let ratio, let first, let second):
            let newDir: SplitDirection = sid == splitID
                ? (dir == .horizontal ? .vertical : .horizontal)
                : dir
            return .split(id: sid, direction: newDir, ratio: ratio,
                          first: first.toggleDirection(splitID),
                          second: second.toggleDirection(splitID))
        }
    }

    /// Swap two leaf IDs in place — used for drag-to-rearrange panes.
    func swapLeaves(_ a: UUID, _ b: UUID) -> PaneLayout {
        switch self {
        case .leaf(let id):
            if id == a { return .leaf(id: b) }
            if id == b { return .leaf(id: a) }
            return self
        case .split(let sid, let dir, let ratio, let first, let second):
            return .split(id: sid, direction: dir, ratio: ratio,
                          first: first.swapLeaves(a, b),
                          second: second.swapLeaves(a, b))
        }
    }
}

@MainActor
class PaneSession: ObservableObject, Identifiable {
    let id: UUID
    let server: Server
    @Published var hostname: String = ""
    @Published var isConnected: Bool = false
    @Published var isConnecting: Bool = false
    /// Cached AppKit terminal view — preserved across SwiftUI layout rebuilds
    /// so that SSH connections survive split/resize operations.
    var cachedTerminalView: NSView?

    init(id: UUID = UUID(), server: Server) {
        self.id = id
        self.server = server
    }
}

@MainActor
class SessionTab: ObservableObject, Identifiable {
    let id: UUID
    let server: Server
    @Published var displayTitle: String
    @Published var autoTitle: Bool = true
    @Published var isConnected: Bool = false
    @Published var layout: PaneLayout
    @Published var paneSessions: [UUID: PaneSession] = [:]
    @Published var focusedPaneID: UUID
    @Published var isBroadcastTarget: Bool = false
    @Published var tabColor: Color?

    private let primaryPaneID: UUID

    init(server: Server) {
        self.server = server
        let paneID = UUID()
        self.id = UUID()
        self.displayTitle = server.displayTitle
        self.layout = .leaf(id: paneID)
        self.primaryPaneID = paneID
        self.focusedPaneID = paneID
        let pane = PaneSession(id: paneID, server: server)
        self.paneSessions = [paneID: pane]
    }

    func splitFocused(direction: SplitDirection) {
        _ = splitPane(
            focusedPaneID,
            direction: direction,
            with: server
        )
    }

    @discardableResult
    func splitPane(
        _ targetPaneID: UUID,
        direction: SplitDirection,
        with paneServer: Server,
        placeNewFirst: Bool = false
    ) -> UUID? {
        guard layout.allLeafIDs.contains(targetPaneID) else { return nil }
        let newID = UUID()
        layout = layout.splitLeaf(
            targetPaneID,
            direction: direction,
            newLeafID: newID,
            placeNewFirst: placeNewFirst
        )
        let pane = PaneSession(id: newID, server: paneServer)
        paneSessions[newID] = pane
        focusedPaneID = newID
        return newID
    }

    @discardableResult
    func movePane(
        _ movingPaneID: UUID,
        to targetPaneID: UUID,
        position: PaneDropPosition
    ) -> Bool {
        guard movingPaneID != targetPaneID,
              layout.allLeafIDs.contains(movingPaneID),
              layout.allLeafIDs.contains(targetPaneID),
              layout.allLeafIDs.count > 1,
              let reduced = layout.removeLeaf(movingPaneID) else {
            return false
        }

        layout = reduced.insertLeaf(
            movingPaneID,
            nextTo: targetPaneID,
            direction: position.splitDirection,
            placeNewFirst: position.placeNewFirst
        )
        focusedPaneID = movingPaneID
        return true
    }

    func closePane(_ id: UUID) {
        guard layout.allLeafIDs.count > 1 else { return }
        if let newLayout = layout.removeLeaf(id) {
            layout = newLayout
            paneSessions.removeValue(forKey: id)
            if focusedPaneID == id {
                focusedPaneID = layout.allLeafIDs.first ?? UUID()
            }
        }
    }

    func swapPanes(_ a: UUID, _ b: UUID) {
        layout = layout.swapLeaves(a, b)
    }

    func updateHostname(_ hostname: String, forPane paneID: UUID) {
        paneSessions[paneID]?.hostname = hostname
        if autoTitle && paneID == primaryPaneID {
            displayTitle = hostname.isEmpty ? server.displayTitle : hostname
        }
    }

    func setConnected(_ connected: Bool, forPane paneID: UUID) {
        paneSessions[paneID]?.isConnected = connected
        isConnected = paneSessions.values.contains { $0.isConnected }
    }
}
