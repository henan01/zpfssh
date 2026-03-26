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

    func splitLeaf(_ leafID: UUID, direction: SplitDirection, newLeafID: UUID) -> PaneLayout {
        switch self {
        case .leaf(let id):
            if id == leafID {
                return .split(id: UUID(), direction: direction, ratio: 0.5,
                              first: .leaf(id: id), second: .leaf(id: newLeafID))
            }
            return self
        case .split(let sid, let dir, let ratio, let first, let second):
            return .split(id: sid, direction: dir, ratio: ratio,
                          first: first.splitLeaf(leafID, direction: direction, newLeafID: newLeafID),
                          second: second.splitLeaf(leafID, direction: direction, newLeafID: newLeafID))
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
}

@MainActor
class PaneSession: ObservableObject, Identifiable {
    let id: UUID
    let server: Server
    @Published var hostname: String = ""
    @Published var isConnected: Bool = false
    @Published var isConnecting: Bool = false

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
        let newID = UUID()
        layout = layout.splitLeaf(focusedPaneID, direction: direction, newLeafID: newID)
        let pane = PaneSession(id: newID, server: server)
        paneSessions[newID] = pane
        focusedPaneID = newID
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
