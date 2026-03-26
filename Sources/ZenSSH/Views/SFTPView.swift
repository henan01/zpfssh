import SwiftUI
import UniformTypeIdentifiers

struct SFTPView: View {
    @StateObject private var sftp = SFTPService()
    let server: Server
    let password: String?
    @State private var selectedFiles: Set<String> = []
    @State private var showFileImporter: Bool = false
    @State private var isDragging: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "folder.fill.badge.gearshape")
                    .foregroundColor(.accentColor)
                Text("SFTP: \(server.displayTitle)")
                    .font(.headline)
                Spacer()
                Button(action: { sftp.listDirectory(sftp.currentRemotePath) }) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("刷新")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            // Path bar
            HStack(spacing: 4) {
                Image(systemName: "folder").font(.system(size: 11)).foregroundColor(.secondary)
                Text(sftp.currentRemotePath)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Spacer()
                Button(action: goUp) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .disabled(sftp.currentRemotePath == "/")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.secondary.opacity(0.06))

            Divider()

            if sftp.isLoading {
                ProgressView("加载中...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let err = sftp.errorMessage {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundColor(.orange)
                    Text(err).foregroundColor(.secondary)
                    Button("重试") { sftp.listDirectory(sftp.currentRemotePath) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // File list
                List(sftp.remoteFiles, selection: $selectedFiles) { file in
                    FileRowView(file: file)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            if file.isDirectory { sftp.listDirectory(file.path) }
                        }
                        .contextMenu {
                            if !file.isDirectory {
                                Button("下载") { downloadFile(file) }
                            }
                            if file.isDirectory {
                                Button("进入目录") { sftp.listDirectory(file.path) }
                            }
                        }
                }
                .listStyle(.plain)
                .overlay(dropOverlay)
                .onDrop(of: [.fileURL], isTargeted: $isDragging) { providers in
                    handleDrop(providers: providers)
                    return true
                }
            }

            Divider()

            // Transfer queue
            if !sftp.transferQueue.isEmpty {
                TransferQueueView(tasks: sftp.transferQueue) { id in
                    sftp.deleteTransferTask(id: id)
                }
                .frame(maxHeight: 120)
            }

            // Bottom toolbar
            HStack {
                Button(action: { showFileImporter = true }) {
                    Label("上传文件", systemImage: "arrow.up.doc")
                        .font(.caption)
                }
                .buttonStyle(.plain)

                Spacer()

                if !selectedFiles.isEmpty {
                    Button(action: downloadSelected) {
                        Label("下载选中", systemImage: "arrow.down.doc")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .onAppear { sftp.connect(to: server, password: password) }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            if let urls = try? result.get() {
                for url in urls {
                    sftp.uploadFile(localURL: url, toRemotePath: sftp.currentRemotePath + "/" + url.lastPathComponent)
                }
            }
        }
    }

    @ViewBuilder
    var dropOverlay: some View {
        if isDragging {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.accentColor, lineWidth: 2)
                .background(Color.accentColor.opacity(0.08))
                .overlay(
                    VStack(spacing: 8) {
                        Image(systemName: "arrow.up.doc.on.clipboard")
                            .font(.system(size: 32))
                        Text("松开以上传")
                    }
                    .foregroundColor(.accentColor)
                )
        }
    }

    private func goUp() {
        let path = sftp.currentRemotePath
        if path == "/" { return }
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        sftp.listDirectory(parent.isEmpty ? "/" : parent)
    }

    private func downloadFile(_ file: RemoteFile) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = file.name
        if panel.runModal() == .OK, let url = panel.url {
            sftp.downloadFile(remotePath: file.path, toLocalURL: url)
        }
    }

    private func downloadSelected() {
        let panel = NSOpenPanel()
        panel.message = "选择下载目录"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        if panel.runModal() == .OK, let dir = panel.url {
            for path in selectedFiles {
                let name = URL(fileURLWithPath: path).lastPathComponent
                sftp.downloadFile(remotePath: path, toLocalURL: dir.appendingPathComponent(name))
            }
        }
    }

    private func handleDrop(providers: [NSItemProvider]) {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                DispatchQueue.main.async {
                    sftp.uploadFile(localURL: url, toRemotePath: sftp.currentRemotePath + "/" + url.lastPathComponent)
                }
            }
        }
    }
}

struct FileRowView: View {
    let file: RemoteFile
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: file.isDirectory ? "folder.fill" : "doc")
                .foregroundColor(file.isDirectory ? .yellow : .secondary)
                .font(.system(size: 14))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name)
                    .font(.system(size: 12))
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text(file.permissions)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                    if !file.isDirectory {
                        Text(formatSize(file.size))
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    Text(file.modifiedAt)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    func formatSize(_ bytes: Int64) -> String {
        let kb = Double(bytes) / 1024
        let mb = kb / 1024
        let gb = mb / 1024
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        if mb >= 1 { return String(format: "%.1f MB", mb) }
        if kb >= 1 { return String(format: "%.1f KB", kb) }
        return "\(bytes) B"
    }
}

struct TransferQueueView: View {
    let tasks: [TransferTask]
    var onDelete: (UUID) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            Text("传输队列")
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.top, 4)

            List(tasks) { task in
                HStack(spacing: 8) {
                    Image(systemName: task.isUpload ? "arrow.up.circle" : "arrow.down.circle")
                        .foregroundColor(task.error != nil ? .red
                                         : task.isCompleted  ? .green
                                         : .accentColor)
                        .font(.system(size: 16))

                    VStack(alignment: .leading, spacing: 3) {
                        Text(task.fileName)
                            .font(.caption)
                            .lineLimit(1)

                        if let err = task.error {
                            Text(err)
                                .font(.caption2)
                                .foregroundColor(.red)
                                .lineLimit(2)
                        } else if task.isCompleted {
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                    .font(.system(size: 10))
                                Text("完成 · \(formatBytes(task.totalBytes))")
                                    .font(.caption2)
                                    .foregroundColor(.green)
                            }
                        } else {
                            // Live progress bar + byte counter
                            VStack(alignment: .leading, spacing: 2) {
                                ProgressView(value: task.progress)
                                    .progressViewStyle(.linear)
                                    .frame(height: 4)
                                    .tint(.accentColor)

                                HStack {
                                    Text("\(formatBytes(task.transferredBytes)) / \(formatBytes(task.totalBytes))")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                    Spacer()
                                    Text(String(format: "%.0f%%", task.progress * 100))
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }

                    Spacer()

                    Button(action: { onDelete(task.id) }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .help("从列表移除")
                }
                .padding(.vertical, 3)
            }
            .listStyle(.plain)
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let kb = Double(bytes) / 1_024
        let mb = kb / 1_024
        let gb = mb / 1_024
        if bytes == 0 { return "—" }
        if gb >= 1    { return String(format: "%.1f GB", gb) }
        if mb >= 1    { return String(format: "%.1f MB", mb) }
        if kb >= 1    { return String(format: "%.0f KB", kb) }
        return "\(bytes) B"
    }
}
