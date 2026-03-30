import AppKit
import SwiftTerm

// MARK: - ZModemTerminalView

/// `LocalProcessTerminalView` subclass that:
///   • intercepts the PTY byte stream through `ZModemEngine`
///   • handles `sz` downloads (saves to ~/Downloads, shows progress)
///   • handles `rz` uploads  (file picker or drag-and-drop → sends via ZMODEM)
///   • shows a floating progress panel during any transfer
final class ZModemTerminalView: LocalProcessTerminalView {

    private let engine   = ZModemEngine()
    private let progress = ZModemProgressWindowController.shared

    // Pane/tab drag-and-drop callbacks (set by TerminalPaneView)
    var currentTabID: UUID?
    var targetPaneID: UUID?
    var onHighlightChange: ((PaneDropPosition?) -> Void)?
    var onFileHighlightChange: ((Bool) -> Void)?
    var onMergeTab: ((UUID, PaneDropPosition) -> Void)?
    var onMovePane: ((UUID, PaneDropPosition) -> Void)?
    var onPaneFileDrop: (([URL]) -> Void)?

    private static let panePBType = NSPasteboard.PasteboardType("com.zpfssh.pane-id")
    private static let tabPBType  = NSPasteboard.PasteboardType("com.zpfssh.tab-id")

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupEngine()
        registerForDraggedTypes([Self.panePBType, Self.tabPBType, .fileURL])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    // MARK: - Intercept PTY data

    override func dataReceived(slice: ArraySlice<UInt8>) {
        let passthrough = engine.feed(slice)
        if !passthrough.isEmpty {
            super.dataReceived(slice: passthrough)
        }
    }

    // MARK: - Engine wiring

    private func setupEngine() {

        // Write ZMODEM protocol bytes to SSH stdin
        engine.onSend = { [weak self] bytes in
            self?.process.send(data: ArraySlice(bytes))
            Log.zmodem("发送 \(bytes.count) 字节")
        }

        // File fully received → save to ~/Downloads (don't hide panel here; onTransferDone does it)
        engine.onFileReceived = { [weak self] name, data in
            Log.zmodem("接收完成 \(name) \(data.count)B")
            DispatchQueue.main.async {
                self?.saveDownload(name: name, data: data)
            }
        }

        // Progress update — only update numbers, never reset
        engine.onProgress = { name, bytes, total in
            DispatchQueue.main.async {
                ZModemProgressWindowController.shared.updateProgress(
                    fileName: name,
                    bytes: bytes,
                    total: total
                )
            }
        }

        // Status text — show in terminal AND update panel label.
        // `show()` / `beginTransfer()` is called ONCE per transfer start, not on every status line.
        engine.onStatusChange = { [weak self] msg in
            Log.zmodem("状态: \(msg)")
            DispatchQueue.main.async { [weak self] in
                self?.feed(text: "\r\n\u{1B}[32m[\(msg)]\u{1B}[0m\r\n")
                ZModemProgressWindowController.shared.model.statusMessage = msg

                let prog = ZModemProgressWindowController.shared
                // Begin panel only at transfer start; progress updates use updateProgress()
                if msg == "ZMODEM: 接收开始" {
                    prog.beginTransfer(uploading: false)
                } else if msg.hasPrefix("ZMODEM: 发送 ") && !prog.isVisible {
                    // rz triggered by typing — panel wasn't opened by drag-drop
                    prog.beginTransfer(uploading: true)
                }
            }
        }

        // Transfer done — show completion state briefly, then auto-hide
        engine.onTransferDone = {
            DispatchQueue.main.async {
                let prog = ZModemProgressWindowController.shared
                prog.model.statusMessage = "传输完成 ✓"
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    prog.hide()
                }
            }
        }

        // Remote ran `rz` but we have no files queued → show file picker
        engine.onNeedFilesForSend = { [weak self] in
            DispatchQueue.main.async { [weak self] in
                self?.presentFilePicker()
            }
        }

        // Cancel button in progress panel → send 8× CAN to abort ZMODEM
        progress.onCancel = { [weak self] in
            let cancel: [UInt8] = Array(repeating: 0x18, count: 8) + [0x0D, 0x0D, 0x0D]
            self?.process.send(data: ArraySlice(cancel))
        }
    }

    // MARK: - File picker (triggered when remote runs rz)

    private func presentFilePicker() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles          = true
        panel.canChooseDirectories    = false
        panel.message = "选择要上传到远程服务器的文件"
        panel.prompt  = "上传"

        guard panel.runModal() == .OK, !panel.urls.isEmpty else {
            // User cancelled — abort remote rz
            let cancel: [UInt8] = Array(repeating: 0x18, count: 8) + [0x0D, 0x0D, 0x0D]
            process.send(data: ArraySlice(cancel))
            return
        }

        let files = loadFiles(from: panel.urls)
        guard !files.isEmpty else { return }

        ZModemProgressWindowController.shared.beginTransfer(
            uploading: true,
            fileName: files.first?.name ?? "",
            totalBytes: files.reduce(0) { $0 + $1.data.count }
        )

        DispatchQueue.main.async { [weak self] in
            self?.engine.resumeSendWithFiles(files)
        }
    }

    // MARK: - File save (sz download)

    private func saveDownload(name: String, data: Data) {
        let downloads = FileManager.default.urls(
            for: .downloadsDirectory, in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory())

        var dest = downloads.appendingPathComponent(name)
        var counter = 1
        let base = dest.deletingPathExtension().lastPathComponent
        let ext  = dest.pathExtension
        while FileManager.default.fileExists(atPath: dest.path) {
            let n = ext.isEmpty ? "\(base)_\(counter)" : "\(base)_\(counter).\(ext)"
            dest  = downloads.appendingPathComponent(n)
            counter += 1
        }

        do {
            try data.write(to: dest)
            // Update panel to 100% and reveal file; panel will be hidden by onTransferDone
            let prog = ZModemProgressWindowController.shared
            prog.model.update(bytes: prog.model.totalBytes > 0
                              ? prog.model.totalBytes : data.count)
            NSWorkspace.shared.activateFileViewerSelecting([dest])
        } catch {
            ZModemProgressWindowController.shared.hide()
            let alert = NSAlert()
            alert.messageText     = "ZMODEM 接收失败"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    // MARK: - Drag and drop (pane/tab composition + ZModem file upload)

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let types = sender.draggingPasteboard.types ?? []
        if types.contains(Self.panePBType) || types.contains(Self.tabPBType) {
            updatePaneHighlight(sender)
            return .move
        }
        // Check for SFTP file drop callback first; fall back to ZModem
        if types.contains(.fileURL), onPaneFileDrop != nil {
            onHighlightChange?(nil)
            onFileHighlightChange?(true)
            return .copy
        }
        let pb = sender.draggingPasteboard
        let ok = pb.canReadObject(forClasses: [NSURL.self],
                                  options: [.urlReadingFileURLsOnly: true])
        return ok ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let types = sender.draggingPasteboard.types ?? []
        if types.contains(Self.panePBType) || types.contains(Self.tabPBType) {
            updatePaneHighlight(sender)
            return detectPanePosition(sender) == .forbidden ? NSDragOperation() : .move
        }
        if types.contains(.fileURL), onPaneFileDrop != nil {
            onHighlightChange?(nil)
            onFileHighlightChange?(true)
            return .copy
        }
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onHighlightChange?(nil)
        onFileHighlightChange?(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        let types = pb.types ?? []

        onHighlightChange?(nil)
        onFileHighlightChange?(false)

        // Pane rearrangement
        if let data = pb.data(forType: Self.panePBType),
           let payload = String(data: data, encoding: .utf8),
           payload.hasPrefix("PANE:"),
           let sourcePaneID = UUID(uuidString: String(payload.dropFirst(5))),
           sourcePaneID != targetPaneID {
            let pos = detectPanePosition(sender)
            guard pos != .forbidden else { return false }
            onMovePane?(sourcePaneID, pos)
            return true
        }

        // Tab merge / replace
        if let data = pb.data(forType: Self.tabPBType),
           let payload = String(data: data, encoding: .utf8),
           payload.hasPrefix("TAB:"),
           let sourceTabID = UUID(uuidString: String(payload.dropFirst(4))),
           sourceTabID != currentTabID {
            let pos = detectPanePosition(sender)
            guard pos != .forbidden else { return false }
            onMergeTab?(sourceTabID, pos)
            return true
        }

        // File drop — use SFTP callback if set, otherwise ZModem
        if types.contains(.fileURL) {
            guard let raw = pb.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]
            ) as? [URL], !raw.isEmpty else { return false }

            if let fileDrop = onPaneFileDrop {
                fileDrop(raw)
                return true
            }

            // ZModem upload path
            let files = loadFiles(from: raw)
            guard !files.isEmpty else { return false }

            engine.queueFilesForUpload(files)
            process.send(data: ArraySlice(Array("rz\n".utf8)))

            ZModemProgressWindowController.shared.beginTransfer(
                uploading: true,
                fileName: files.first?.name ?? "",
                totalBytes: files.reduce(0) { $0 + $1.data.count }
            )
            return true
        }

        return false
    }

    // MARK: - Pane drop position helpers

    private func updatePaneHighlight(_ sender: NSDraggingInfo) {
        onHighlightChange?(detectPanePosition(sender))
        onFileHighlightChange?(false)
    }

    private func detectPanePosition(_ sender: NSDraggingInfo) -> PaneDropPosition {
        let loc = convert(sender.draggingLocation, from: nil)
        let w = bounds.width
        let h = bounds.height
        guard w > 0, h > 0 else { return .center }
        let x = loc.x / w
        let y = 1.0 - loc.y / h  // flip Y: AppKit is bottom-left origin
        let edge: CGFloat = 0.22

        let isPaneDrag = sender.draggingPasteboard.types?.contains(Self.panePBType) == true

        if x < edge { return .left }
        if x > 1 - edge { return .right }
        if y < edge { return .top }
        if y > 1 - edge { return .bottom }
        return isPaneDrag ? .forbidden : .center
    }

    // MARK: - Helpers

    private func loadFiles(from urls: [URL]) -> [(name: String, data: Data)] {
        urls.compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return (name: url.lastPathComponent, data: data)
        }
    }
}
