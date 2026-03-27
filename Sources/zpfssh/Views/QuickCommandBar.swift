import SwiftUI

// MARK: - Quick Command Bar (bottom strip)

struct QuickCommandBar: View {
    @ObservedObject var store: QuickCommandStore
    @ObservedObject var sessionManager: SessionManager
    @State private var showEditor = false

    var body: some View {
        HStack(spacing: 0) {
            // Scrollable command buttons
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    if store.commands.isEmpty {
                        Text("点击 + 添加快捷命令")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 8)
                    } else {
                        ForEach(store.commands) { cmd in
                            QuickCommandButton(cmd: cmd) {
                                run(cmd)
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
            }

            Divider().frame(height: 20)

            // Edit button
            Button(action: { showEditor = true }) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 12))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .help("管理快捷命令")
        }
        .frame(height: 34)
        .background(Color(NSColor.windowBackgroundColor).opacity(0.95))
        .overlay(Divider(), alignment: .top)
        .sheet(isPresented: $showEditor) {
            QuickCommandEditorView(store: store)
        }
    }

    private func run(_ cmd: QuickCommand) {
        guard let tab = sessionManager.activeTab else { return }
        NotificationCenter.default.post(
            name: .sendSnippet,
            object: nil,
            userInfo: ["tabID": tab.id, "command": cmd.command]
        )
    }
}

struct QuickCommandButton: View {
    let cmd: QuickCommand
    let onTap: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            Text(cmd.title)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .foregroundColor(isHovered ? .white : cmd.color.color)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(isHovered ? cmd.color.color : cmd.color.color.opacity(0.12))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(cmd.color.color.opacity(0.4), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(cmd.command)
    }
}

// MARK: - Editor Sheet

struct QuickCommandEditorView: View {
    @ObservedObject var store: QuickCommandStore
    @Environment(\.dismiss) private var dismiss
    @State private var editingCmd: QuickCommand? = nil
    @State private var showAddForm = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("管理快捷命令")
                    .font(.headline)
                Spacer()
                Button(action: { showAddForm = true }) {
                    Label("添加", systemImage: "plus")
                }
                Button("完成") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
            .padding()

            Divider()

            if store.commands.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "bolt.slash")
                        .font(.system(size: 36))
                        .foregroundColor(.secondary)
                    Text("还没有快捷命令")
                        .foregroundColor(.secondary)
                    Button(action: { showAddForm = true }) {
                        Label("添加第一条命令", systemImage: "plus.circle")
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(store.commands) { cmd in
                        HStack(spacing: 10) {
                            Circle()
                                .fill(cmd.color.color)
                                .frame(width: 10, height: 10)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(cmd.title)
                                    .font(.system(size: 13, weight: .medium))
                                Text(cmd.command)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Button(action: { editingCmd = cmd }) {
                                Image(systemName: "pencil")
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                            Button(action: { store.delete(cmd) }) {
                                Image(systemName: "trash")
                                    .foregroundColor(.red)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 3)
                    }
                    .onMove { store.move(from: $0, to: $1) }
                }
                .listStyle(.plain)
            }
        }
        .frame(width: 440, height: 360)
        .sheet(isPresented: $showAddForm) {
            QuickCommandFormView(store: store)
        }
        .sheet(item: $editingCmd) { cmd in
            QuickCommandFormView(store: store, editing: cmd)
        }
    }
}

// MARK: - Add / Edit Form

struct QuickCommandFormView: View {
    @ObservedObject var store: QuickCommandStore
    var editing: QuickCommand? = nil
    @Environment(\.dismiss) private var dismiss

    @State private var title: String = ""
    @State private var command: String = ""
    @State private var color: QuickCommand.QuickCommandColor = .blue

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(editing == nil ? "添加快捷命令" : "编辑快捷命令")
                    .font(.headline)
                Spacer()
                Button("取消") { dismiss() }
                Button("保存") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(title.isEmpty || command.isEmpty)
            }
            .padding()

            Divider()

            Form {
                TextField("按钮名称（简短）", text: $title)
                TextField("命令内容", text: $command)
                Picker("颜色", selection: $color) {
                    ForEach(QuickCommand.QuickCommandColor.allCases, id: \.self) { c in
                        HStack {
                            Circle().fill(c.color).frame(width: 12, height: 12)
                            Text(c.rawValue)
                        }.tag(c)
                    }
                }
            }
            .padding()

            // Preview
            HStack {
                Text("预览：")
                    .font(.caption)
                    .foregroundColor(.secondary)
                QuickCommandButton(cmd: QuickCommand(title: title.isEmpty ? "示例" : title,
                                                     command: command,
                                                     color: color)) {}
            }
            .padding(.horizontal)
            .padding(.bottom, 16)
        }
        .frame(width: 380, height: 280)
        .onAppear {
            if let e = editing {
                title = e.title; command = e.command; color = e.color
            }
        }
    }

    private func save() {
        var cmd = editing ?? QuickCommand(title: "", command: "")
        cmd.title = title; cmd.command = command; cmd.color = color
        if editing == nil { store.add(cmd) } else { store.update(cmd) }
        dismiss()
    }
}
