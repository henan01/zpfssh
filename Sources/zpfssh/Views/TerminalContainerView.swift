import SwiftUI
import AppKit
import UniformTypeIdentifiers

private let minPaneSize: CGFloat = 160

private let paneUTType = UTType(exportedAs: "com.zpfssh.pane-id")

struct TerminalContainerView: View {
    @ObservedObject var tab: SessionTab
    @ObservedObject var sessionManager: SessionManager
    @ObservedObject var settings: AppSettings
    var searchText: String = ""
    var searchActive: Bool = false
    var password: String? = nil

    @StateObject private var dropSFTP = SFTPService()

    var body: some View {
        ZStack {
            backgroundView
            paneView(for: tab.layout)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    func paneView(for layout: PaneLayout) -> AnyView {
        switch layout {
        case .leaf(let id):
            guard let pane = tab.paneSessions[id] else { return AnyView(EmptyView()) }
            let paneServer = pane.server
            let panePassword = password
            return AnyView(
                PaneContainer(
                    server: paneServer,
                    paneID: id,
                    tab: tab,
                    settings: settings,
                    isFocused: tab.focusedPaneID == id,
                    searchText: searchText,
                    searchActive: searchActive,
                    onFocus: { tab.focusedPaneID = id },
                    onClose: { tab.closePane(id) },
                    onMergeTab: { sourceTabID, position in
                        if position == .center {
                            _ = sessionManager.replaceTabInPane(
                                sourceTabID: sourceTabID,
                                targetTabID: tab.id,
                                targetPaneID: id
                            )
                        } else {
                            _ = sessionManager.mergeTabIntoPane(
                                sourceTabID: sourceTabID,
                                targetTabID: tab.id,
                                targetPaneID: id,
                                position: position
                            )
                        }
                    },
                    onMovePane: { sourcePaneID, position in
                        _ = tab.movePane(sourcePaneID, to: id, position: position)
                    },
                    onFileDrop: { [dropSFTP] urls in
                        dropSFTP.connectForUpload(to: paneServer, password: panePassword)
                        for url in urls {
                            dropSFTP.uploadFile(
                                localURL: url,
                                toRemotePath: url.lastPathComponent
                            )
                        }
                    }
                )
                .id(id)
            )

        case .split(let splitID, .horizontal, let ratio, let first, let second):
            return AnyView(
                GeometryReader { geo in
                    let totalW = geo.size.width
                    let divW: CGFloat = 4
                    let available = totalW - divW
                    let clampedRatio = available > 0
                        ? max(minPaneSize / available, min(1 - minPaneSize / available, ratio))
                        : ratio
                    let leftW = available * clampedRatio

                    HStack(spacing: 0) {
                        paneView(for: first)
                            .frame(width: leftW)
                        Rectangle()
                            .fill(Color(NSColor.separatorColor))
                            .frame(width: divW)
                            .overlay(Rectangle().fill(Color.clear).frame(width: 12))
                            .gesture(DragGesture()
                                .onChanged { value in
                                    let newRatio = max(0.15, min(0.85,
                                        (leftW + value.translation.width) / available))
                                    tab.layout = tab.layout.updateRatio(splitID, ratio: newRatio)
                                }
                            )
                            .cursor(.resizeLeftRight)
                            .contextMenu {
                                Button {
                                    tab.layout = tab.layout.toggleDirection(splitID)
                                } label: {
                                    Label("改为上下分屏", systemImage: "rectangle.split.1x2")
                                }
                                Divider()
                                Button("关闭右侧面板", role: .destructive) {
                                    if let id = second.allLeafIDs.first {
                                        tab.closePane(id)
                                    }
                                }
                            }
                        paneView(for: second)
                    }
                }
            )

        case .split(let splitID, .vertical, let ratio, let first, let second):
            return AnyView(
                GeometryReader { geo in
                    let totalH = geo.size.height
                    let divH: CGFloat = 4
                    let available = totalH - divH
                    let clampedRatio = available > 0
                        ? max(minPaneSize / available, min(1 - minPaneSize / available, ratio))
                        : ratio
                    let topH = available * clampedRatio

                    VStack(spacing: 0) {
                        paneView(for: first)
                            .frame(height: topH)
                        Rectangle()
                            .fill(Color(NSColor.separatorColor))
                            .frame(height: divH)
                            .overlay(Rectangle().fill(Color.clear).frame(height: 12))
                            .gesture(DragGesture()
                                .onChanged { value in
                                    let newRatio = max(0.15, min(0.85,
                                        (topH + value.translation.height) / available))
                                    tab.layout = tab.layout.updateRatio(splitID, ratio: newRatio)
                                }
                            )
                            .cursor(.resizeUpDown)
                            .contextMenu {
                                Button {
                                    tab.layout = tab.layout.toggleDirection(splitID)
                                } label: {
                                    Label("改为左右分屏", systemImage: "rectangle.split.2x1")
                                }
                                Divider()
                                Button("关闭下方面板", role: .destructive) {
                                    if let id = second.allLeafIDs.first {
                                        tab.closePane(id)
                                    }
                                }
                            }
                        paneView(for: second)
                    }
                }
            )
        }
    }

    // MARK: - Background

    @ViewBuilder
    var backgroundView: some View {
        let ap = settings.appearance
        switch ap.backgroundType {
        case .solidColor:
            Color(settings.currentTheme.background.nsColor)
        case .image:
            if !ap.backgroundImagePath.isEmpty,
               let img = NSImage(contentsOfFile: ap.backgroundImagePath) {
                ZStack {
                    Color(settings.currentTheme.background.nsColor)
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: fillMode(ap.imageFillMode))
                        .opacity(ap.backgroundOpacity)
                        .blur(radius: ap.backgroundBlur)
                        .clipped()
                }
            } else {
                Color(settings.currentTheme.background.nsColor)
            }
        case .gradient:
            LinearGradient(
                colors: [Color(ap.gradientStart.nsColor), Color(ap.gradientEnd.nsColor)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private func fillMode(_ m: ImageFillMode) -> ContentMode {
        switch m {
        case .aspectFit: return .fit
        default: return .fill
        }
    }
}

// MARK: - Pane Container (with AppKit drop handling)

struct PaneContainer: View {
    let server: Server
    let paneID: UUID
    let tab: SessionTab
    @ObservedObject var settings: AppSettings
    let isFocused: Bool
    var searchText: String = ""
    var searchActive: Bool = false
    var onFocus: () -> Void = {}
    var onClose: () -> Void = {}
    var onMergeTab: ((UUID, PaneDropPosition) -> Void)? = nil
    var onMovePane: ((UUID, PaneDropPosition) -> Void)? = nil
    var onFileDrop: (([URL]) -> Void)? = nil

    @State private var dropHighlight: PaneDropPosition? = nil
    @State private var isFileDropTargeted: Bool = false

    var isSplit: Bool { tab.layout.allLeafIDs.count > 1 }

    var body: some View {
        VStack(spacing: 0) {
            if isSplit {
                PaneHeaderBar(
                    server: server,
                    paneID: paneID,
                    tab: tab,
                    isFocused: isFocused,
                    onClose: onClose
                )
            }

            GeometryReader { geo in
                ZStack {
                    TerminalPaneView(
                        server: server,
                        paneID: paneID,
                        tab: tab,
                        settings: settings,
                        searchText: searchText,
                        searchActive: searchActive,
                        onFocus: onFocus,
                        onHighlightChange: { dropHighlight = $0 },
                        onFileHighlightChange: { isFileDropTargeted = $0 },
                        onMergeTab: { id, pos in onMergeTab?(id, pos) },
                        onMovePane: { id, pos in onMovePane?(id, pos) },
                        onFileDrop: { urls in onFileDrop?(urls) }
                    )

                    if let pos = dropHighlight {
                        DropPositionHighlight(position: pos, size: geo.size)
                            .allowsHitTesting(false)
                    }

                    if isFileDropTargeted {
                        ZStack {
                            Color.accentColor.opacity(0.12)
                            VStack(spacing: 8) {
                                Image(systemName: "arrow.up.doc.on.clipboard")
                                    .font(.system(size: 28))
                                Text("松开以上传到 ~/")
                                    .font(.callout)
                            }
                            .foregroundColor(.accentColor)
                        }
                        .allowsHitTesting(false)
                    }

                    RoundedRectangle(cornerRadius: 0)
                        .strokeBorder(isFocused ? Color.accentColor.opacity(0.6) : Color.clear,
                                      lineWidth: 1.5)
                        .allowsHitTesting(false)
                }
            }
        }
    }
}

// MARK: - Drop Position Highlight

/// Visual feedback showing where a dragged item will be placed.
/// Half the pane highlights in the drag direction; center highlights the whole pane.
private struct DropPositionHighlight: View {
    let position: PaneDropPosition
    let size: CGSize

    var body: some View {
        ZStack(alignment: alignment) {
            Color.clear
            if position == .forbidden {
                forbiddenOverlay
            } else {
                highlightRect
                    .frame(
                        width: isHorizontalEdge ? size.width * 0.5 : nil,
                        height: isVerticalEdge ? size.height * 0.5 : nil
                    )
            }
        }
        .animation(.easeInOut(duration: 0.12), value: position)
    }

    private var alignment: Alignment {
        switch position {
        case .left: return .leading
        case .right: return .trailing
        case .top: return .top
        case .bottom: return .bottom
        case .center, .forbidden: return .center
        }
    }

    private var isHorizontalEdge: Bool {
        position == .left || position == .right
    }

    private var isVerticalEdge: Bool {
        position == .top || position == .bottom
    }

    private var highlightRect: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(accentFill)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(accentBorder, lineWidth: 2)
            )
    }

    private var forbiddenOverlay: some View {
        ZStack {
            Color.red.opacity(0.08)
            Image(systemName: "nosign")
                .font(.system(size: 36, weight: .light))
                .foregroundColor(.red.opacity(0.5))
        }
    }

    private var accentFill: Color {
        position == .center ? Color.orange.opacity(0.15) : Color.accentColor.opacity(0.13)
    }

    private var accentBorder: Color {
        position == .center ? .orange : .accentColor
    }
}

// MARK: - Pane Header Bar

struct PaneHeaderBar: View {
    let server: Server
    let paneID: UUID
    @ObservedObject var tab: SessionTab
    let isFocused: Bool
    let onClose: () -> Void

    var pane: PaneSession? { tab.paneSessions[paneID] }

    private var otherPaneIDs: [UUID] {
        tab.layout.allLeafIDs.filter { $0 != paneID }
    }

    private var paneDragPayload: NSItemProvider {
        let provider = NSItemProvider()
        let payload = "PANE:\(paneID.uuidString)"
        provider.registerDataRepresentation(
            forTypeIdentifier: paneUTType.identifier,
            visibility: .ownProcess
        ) { completion in
            completion(payload.data(using: .utf8), nil)
            return nil
        }
        return provider
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 10))
                .foregroundColor(.secondary.opacity(0.6))
                .padding(.leading, 2)
                .onDrag { paneDragPayload }
                .cursor(.openHand)
                .help("拖动到其他面板边缘以重新组合")

            Circle()
                .fill(pane?.isConnected == true ? Color.green : Color.gray)
                .frame(width: 6, height: 6)

            Text(pane?.hostname.isEmpty == false ? pane!.hostname : server.displayTitle)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .lineLimit(1)

            Spacer()

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("关闭此面板 (⌘W)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(isFocused
                    ? Color.accentColor.opacity(0.08)
                    : Color(NSColor.windowBackgroundColor).opacity(0.7))
        .overlay(Divider(), alignment: .bottom)
        .onDrag { paneDragPayload }
        .contextMenu {
            Button {
                tab.splitPane(paneID, direction: .horizontal, with: server, placeNewFirst: true)
            } label: {
                Label("向左拆分", systemImage: "rectangle.lefthalf.inset.filled")
            }
            Button {
                tab.splitPane(paneID, direction: .horizontal, with: server)
            } label: {
                Label("向右拆分", systemImage: "rectangle.righthalf.inset.filled")
            }
            Button {
                tab.splitPane(paneID, direction: .vertical, with: server, placeNewFirst: true)
            } label: {
                Label("向上拆分", systemImage: "rectangle.tophalf.inset.filled")
            }
            Button {
                tab.splitPane(paneID, direction: .vertical, with: server)
            } label: {
                Label("向下拆分", systemImage: "rectangle.bottomhalf.inset.filled")
            }

            if !otherPaneIDs.isEmpty {
                Divider()
                Menu("交换窗格位置") {
                    ForEach(otherPaneIDs, id: \.self) { otherID in
                        Button {
                            tab.swapPanes(paneID, otherID)
                        } label: {
                            let otherPane = tab.paneSessions[otherID]
                            let title = otherPane?.hostname.isEmpty == false
                                ? otherPane!.hostname
                                : otherPane?.server.displayTitle ?? "窗格"
                            Text(title)
                        }
                    }
                }
            }

            Divider()
            Button("关闭当前窗格", role: .destructive) { onClose() }
        }
    }
}

// MARK: - NSCursor helper

extension View {
    func cursor(_ cursor: NSCursor) -> some View {
        self.onHover { inside in
            if inside { cursor.push() } else { NSCursor.pop() }
        }
    }
}

extension NSColor {
    var asSwiftUIColor: Color { Color(self) }
}
