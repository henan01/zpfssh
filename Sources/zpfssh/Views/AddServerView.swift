import SwiftUI

struct AddServerView: View {
    @ObservedObject var serverStore: ServerStore
    var editingServer: Server? = nil
    @Environment(\.dismiss) private var dismiss

    @State private var alias: String = ""
    @State private var host: String = ""
    @State private var port: String = "22"
    @State private var username: String = ""
    @State private var authType: AuthType = .password
    @State private var password: String = ""
    @State private var privateKeyPath: String = ""
    @State private var jumpHost: String = ""
    @State private var group: String = ""
    @State private var note: String = ""
    @State private var color: ServerColor = .blue
    @State private var showError: Bool = false
    @State private var errorMessage: String = ""
    @State private var showPassword: Bool = false

    var isEditing: Bool { editingServer != nil }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(isEditing ? "编辑服务器" : "添加服务器")
                    .font(.headline)
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
                Button(isEditing ? "保存" : "添加") { save() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(host.isEmpty || username.isEmpty)
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Basic info
                    GroupBox("基本信息") {
                        VStack(alignment: .leading, spacing: 12) {
                            FormRow("别名") {
                                TextField("可选，不填则显示 user@host", text: $alias)
                                    .textFieldStyle(.roundedBorder)
                            }
                            FormRow("主机") {
                                TextField("IP 或域名", text: $host)
                                    .textFieldStyle(.roundedBorder)
                            }
                            FormRow("端口") {
                                TextField("22", text: $port)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 80)
                            }
                            FormRow("用户名") {
                                TextField("root", text: $username)
                                    .textFieldStyle(.roundedBorder)
                            }
                        }
                        .padding(8)
                    }

                    // Auth
                    GroupBox("认证方式") {
                        VStack(alignment: .leading, spacing: 12) {
                            Picker("", selection: $authType) {
                                ForEach(AuthType.allCases, id: \.self) { t in
                                    Text(t.displayName).tag(t)
                                }
                            }
                            .pickerStyle(.segmented)

                            switch authType {
                            case .password:
                                FormRow("密码") {
                                    HStack(spacing: 4) {
                                        if showPassword {
                                            TextField("SSH 密码", text: $password)
                                                .textFieldStyle(.roundedBorder)
                                        } else {
                                            SecureField("SSH 密码", text: $password)
                                                .textFieldStyle(.roundedBorder)
                                        }
                                        Button(action: { showPassword.toggle() }) {
                                            Image(systemName: showPassword ? "eye.slash" : "eye")
                                                .foregroundColor(.secondary)
                                        }
                                        .buttonStyle(.plain)
                                        .help(showPassword ? "隐藏密码" : "显示密码")
                                    }
                                }
                            case .privateKey:
                                FormRow("私钥路径") {
                                    HStack {
                                        TextField("~/.ssh/id_rsa", text: $privateKeyPath)
                                            .textFieldStyle(.roundedBorder)
                                        Button("选择") { pickPrivateKey() }
                                    }
                                }
                            case .sshAgent:
                                Text("将使用系统 SSH Agent 认证")
                                    .foregroundColor(.secondary)
                                    .font(.caption)
                                    .padding(.top, 4)
                            }
                        }
                        .padding(8)
                    }

                    // Advanced
                    GroupBox("高级选项") {
                        VStack(alignment: .leading, spacing: 12) {
                            FormRow("跳板机") {
                                TextField("user@jumphost:22（可选）", text: $jumpHost)
                                    .textFieldStyle(.roundedBorder)
                            }
                            FormRow("分组") {
                                TextField("可选", text: $group)
                                    .textFieldStyle(.roundedBorder)
                            }
                            FormRow("备注") {
                                TextField("可选", text: $note)
                                    .textFieldStyle(.roundedBorder)
                            }
                        }
                        .padding(8)
                    }

                    // Color
                    GroupBox("标签颜色") {
                        HStack(spacing: 12) {
                            ForEach(ServerColor.allCases, id: \.self) { c in
                                Button(action: { color = c }) {
                                    Circle()
                                        .fill(c.color)
                                        .frame(width: 22, height: 22)
                                        .overlay(
                                            Circle()
                                                .strokeBorder(color == c ? Color.primary : Color.clear, lineWidth: 2)
                                                .padding(-3)
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(8)
                    }
                }
                .padding()
            }
        }
        .frame(width: 480, height: 560)
        .onAppear { loadEditingServer() }
        .alert("错误", isPresented: $showError) {
            Button("确定") {}
        } message: {
            Text(errorMessage)
        }
    }

    private func save() {
        guard !host.isEmpty && !username.isEmpty else { return }
        var server = editingServer ?? Server(alias: "", host: "", username: "")
        server.alias = alias
        server.host = host
        server.port = Int(port) ?? 22
        server.username = username
        server.authType = authType
        server.privateKeyPath = privateKeyPath
        server.jumpHost = jumpHost
        server.group = group
        server.note = note
        server.color = color

        if isEditing {
            serverStore.update(server, password: authType == .password ? password : nil)
        } else {
            serverStore.add(server, password: authType == .password ? password : nil)
        }
        dismiss()
    }

    private func loadEditingServer() {
        guard let s = editingServer else { return }
        alias = s.alias
        host = s.host
        port = "\(s.port)"
        username = s.username
        authType = s.authType
        privateKeyPath = s.privateKeyPath
        jumpHost = s.jumpHost
        group = s.group
        note = s.note
        color = s.color
        if s.authType == .password {
            password = serverStore.password(for: s) ?? ""
        }
    }

    private func pickPrivateKey() {
        let panel = NSOpenPanel()
        panel.message = "选择 SSH 私钥文件"
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory() + "/.ssh")
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK {
            privateKeyPath = panel.url?.path ?? ""
        }
    }
}

struct FormRow<Content: View>: View {
    let label: String
    let content: Content
    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }
    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(label)
                .font(.system(size: 12))
                .frame(width: 70, alignment: .trailing)
                .foregroundColor(.secondary)
            content
        }
    }
}
