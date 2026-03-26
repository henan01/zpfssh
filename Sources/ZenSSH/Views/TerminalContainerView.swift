import SwiftUI
import AppKit
import UniformTypeIdentifiers

private let minPaneSize: CGFloat = 160   // minimum pane dimension

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

    // Recursive layout rendering — AnyView avoids opaque-return recursion
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
                    sessionManager: sessionManager,
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
                .id(id)  // stable identity — prevents SSH process reuse across panes
            )

        case .split(let splitID, .horizontal, let ratio, let first, let second):
            return AnyView(
                GeometryReader { geo in
                    let totalW = geo.size.width
                    let divW: CGFloat = 4
                    let available = totalW - divW
                    // Clamp ratio so neither pane goes below minPaneSize
                    let clampedRatio = available > 0
                        ? max(minPaneSize / available, min(1 - minPaneSize / available, ratio))
                        : ratio
                    let leftW = available * clampedRatio

                    HStack(spacing: 0) {
                        paneView(for: first)
                            .frame(width: leftW)
                        // Draggable divider
                        Rectangle()
                            .fill(Color(NSColor.separatorColor))
                            .frame(width: divW)
                            .overlay(
                                Rectangle()
                                    .fill(Color.clear)
                                    .frame(width: 12)
                            )
                            .gesture(DragGesture()
                                .onChanged { value in
                                    let newRatio = max(0.15, min(0.85,
                                        (leftW + value.translation.width) / available))
                                    tab.layout = tab.layout.updateRatio(splitID, ratio: newRatio)
                                }
                            )
                            .cursor(.resizeLeftRight)
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
                            .overlay(
                                Rectangle()
                                    .fill(Color.clear)
                                    .frame(height: 12)
                            )
                            .gesture(DragGesture()
                                .onChanged { value in
                                    let newRatio = max(0.15, min(0.85,
                                        (topH + value.translation.height) / available))
                                    tab.layout = tab.layout.updateRatio(splitID, ratio: newRatio)
                                }
                            )
                            .cursor(.resizeUpDown)
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

// MARK: - Pane Container (with header bar when split)

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
    @ObservedObject var sessionManager: SessionManager
    var onFileDrop: (([URL]) -> Void)? = nil

    @State private var isDropTargeted = false

    var isSplit: Bool { tab.layout.allLeafIDs.count > 1 }

    var body: some View {
        VStack(spacing: 0) {
            // Per-pane header — only when in split mode
            if isSplit {
                PaneHeaderBar(
                    server: server,
                    paneID: paneID,
                    tab: tab,
                    isFocused: isFocused,
                    onClose: onClose
                )
            }

            TerminalPaneView(
                server: server,
                paneID: paneID,
                tab: tab,
                settings: settings,
                searchText: searchText,
                searchActive: searchActive
            )
            .overlay(dropOverlay)
            .overlay(
                RoundedRectangle(cornerRadius: 0)
                    .strokeBorder(isFocused ? Color.accentColor.opacity(0.6) : Color.clear,
                                  lineWidth: 1.5)
            )
            .contentShape(Rectangle())
            .onTapGesture { onFocus() }
            .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted) { providers in
                Task {
                    var urls: [URL] = []
                    for provider in providers {
                        if let url: URL = await withCheckedContinuation({ cont in
                            provider.loadItem(
                                forTypeIdentifier: UTType.fileURL.identifier,
                                options: nil
                            ) { item, _ in
                                if let data = item as? Data,
                                   let u = URL(dataRepresentation: data, relativeTo: nil) {
                                    cont.resume(returning: u)
                                } else {
                                    cont.resume(returning: nil)
                                }
                            }
                        }) {
                            urls.append(url)
                        }
                    }
                    await MainActor.run { onFileDrop?(urls) }
                }
                return true
            }
        }
    }

    @ViewBuilder
    private var dropOverlay: some View {
        if isDropTargeted {
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

    var body: some View {
        HStack(spacing: 6) {
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
