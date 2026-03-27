import SwiftUI
import AppKit

// MARK: - Model

@MainActor
final class ZModemProgressModel: ObservableObject {
    @Published var fileName: String = ""
    @Published var bytesHandled: Int = 0
    @Published var totalBytes: Int = 0
    @Published var statusMessage: String = ""
    @Published var isUploading: Bool = false

    private var startTime: Date = Date()
    private var lastBytes: Int = 0
    private var lastTime: Date = Date()
    @Published var speedText: String = ""

    var progress: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1.0, Double(bytesHandled) / Double(totalBytes))
    }

    var progressText: String {
        guard totalBytes > 0 else { return formatBytes(bytesHandled) }
        return "\(formatBytes(bytesHandled)) / \(formatBytes(totalBytes))"
    }

    func begin(uploading: Bool, name: String, total: Int) {
        isUploading = uploading
        fileName    = name
        totalBytes  = total
        bytesHandled = 0
        statusMessage = ""
        startTime = Date()
        lastBytes = 0
        lastTime  = startTime
        speedText = ""
    }

    func update(bytes: Int) {
        bytesHandled = bytes
        let now  = Date()
        let dt   = now.timeIntervalSince(lastTime)
        if dt > 0.5 {
            let db = bytes - lastBytes
            let speed = Double(db) / dt
            speedText = "\(formatBytes(Int(speed)))/s"
            lastBytes = bytes
            lastTime  = now
        }
    }

    private func formatBytes(_ n: Int) -> String {
        if n < 1024         { return "\(n) B" }
        if n < 1024 * 1024  { return String(format: "%.1f KB", Double(n) / 1024) }
        return String(format: "%.2f MB", Double(n) / (1024 * 1024))
    }
}

// MARK: - SwiftUI view

struct ZModemProgressView: View {
    @ObservedObject var model: ZModemProgressModel
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack(spacing: 10) {
                Image(systemName: model.isUploading
                      ? "arrow.up.to.line.circle.fill"
                      : "arrow.down.to.line.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(model.isUploading ? Color.blue : Color.green)

                VStack(alignment: .leading, spacing: 2) {
                    Text(model.isUploading ? "ZMODEM 上传" : "ZMODEM 下载")
                        .font(.headline)
                    Text(model.fileName.isEmpty ? "—" : model.fileName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                Button("取消", action: onCancel)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }

            // Progress bar
            if model.totalBytes > 0 {
                ProgressView(value: model.progress)
                    .progressViewStyle(.linear)
                    .tint(model.isUploading ? .blue : .green)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
            }

            // Stats row
            HStack {
                if !model.statusMessage.isEmpty {
                    Text(model.statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text(model.progressText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    if !model.speedText.isEmpty {
                        Text(model.speedText)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 380)
    }
}

// MARK: - Window controller (singleton, main-thread only)

@MainActor
final class ZModemProgressWindowController {

    static let shared = ZModemProgressWindowController()
    let model = ZModemProgressModel()
    var onCancel: (() -> Void)?

    private(set) var panel: NSPanel?
    private var hideWorkItem: DispatchWorkItem?

    private init() {}

    var isVisible: Bool { panel?.isVisible ?? false }

    /// Start a brand-new transfer — resets the model and shows the panel.
    func beginTransfer(uploading: Bool, fileName: String = "", totalBytes: Int = 0) {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        model.begin(uploading: uploading, name: fileName, total: totalBytes)
        if panel == nil { buildPanel() }
        panel?.title = uploading ? "ZMODEM 上传" : "ZMODEM 下载"
        panel?.makeKeyAndOrderFront(nil)
    }

    /// Update progress numbers only — never resets the model.
    func updateProgress(fileName: String, bytes: Int, total: Int) {
        if !fileName.isEmpty && model.fileName != fileName {
            model.fileName = fileName
        }
        if total > 0 { model.totalBytes = total }
        model.update(bytes: bytes)
    }

    func hide() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        panel?.orderOut(nil)
    }

    // MARK: Private

    private func buildPanel() {
        let root = ZModemProgressView(model: model) { [weak self] in
            self?.onCancel?()
            self?.hide()
        }
        let hosting = NSHostingView(rootView: root)
        hosting.setFrameSize(hosting.fittingSize)

        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 120),
            styleMask: [.titled, .closable, .hudWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.title = "ZMODEM"
        p.contentView = hosting
        p.isFloatingPanel = true
        p.level = .floating
        p.isReleasedWhenClosed = false
        p.center()
        panel = p
    }
}
