import SwiftUI

struct CommandPaletteView: View {
    @ObservedObject var snippetStore: SnippetStore
    @ObservedObject var sessionManager: SessionManager
    @Binding var isVisible: Bool

    @State private var searchText: String = ""
    @State private var selectedSnippet: Snippet? = nil
    @State private var paramValues: [String: String] = [:]
    @FocusState private var searchFocused: Bool

    var results: [Snippet] { snippetStore.search(searchText) }

    var body: some View {
        VStack(spacing: 0) {
            // Search input
            HStack {
                Image(systemName: "command")
                    .foregroundColor(.secondary)
                TextField("搜索命令... (⌘P)", text: $searchText)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit {
                        if let first = results.first { execute(first) }
                    }
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                    }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider()

            if let snippet = selectedSnippet, snippet.hasParameters {
                // Parameter filling
                ParameterFillView(snippet: snippet, params: $paramValues) {
                    let cmd = snippet.resolvedCommand(with: paramValues)
                    sendToActiveTab(cmd)
                    dismiss()
                } onCancel: {
                    selectedSnippet = nil
                    paramValues = [:]
                }
            } else {
                // Results list
                List(results) { snippet in
                    SnippetResultRow(snippet: snippet) {
                        execute(snippet)
                    } onFavorite: {
                        snippetStore.toggleFavorite(snippet)
                    }
                }
                .listStyle(.plain)
                .frame(maxHeight: 320)

                if results.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 32))
                            .foregroundColor(.secondary)
                        Text("未找到命令")
                            .foregroundColor(.secondary)
                    }
                    .frame(height: 100)
                }
            }
        }
        .frame(width: 560)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 20)
        .onAppear { searchFocused = true }
        .onExitCommand { dismiss() }
    }

    private func execute(_ snippet: Snippet) {
        if snippet.hasParameters {
            paramValues = Dictionary(uniqueKeysWithValues: snippet.parameterNames.map { ($0, "") })
            selectedSnippet = snippet
        } else {
            sendToActiveTab(snippet.command)
            dismiss()
        }
    }

    private func sendToActiveTab(_ command: String) {
        guard let tab = sessionManager.activeTab else { return }
        NotificationCenter.default.post(
            name: .sendSnippet,
            object: nil,
            userInfo: ["tabID": tab.id, "command": command]
        )
    }

    private func dismiss() {
        searchText = ""
        selectedSnippet = nil
        paramValues = [:]
        isVisible = false
    }
}

struct SnippetResultRow: View {
    let snippet: Snippet
    var onExecute: () -> Void
    var onFavorite: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if snippet.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.yellow)
                    }
                    Text(snippet.name)
                        .font(.system(size: 13, weight: .medium))
                    Text(snippet.category.rawValue)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.12))
                        .clipShape(Capsule())
                }
                Text(snippet.command)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if isHovered {
                Button(action: onFavorite) {
                    Image(systemName: snippet.isFavorite ? "star.fill" : "star")
                        .foregroundColor(snippet.isFavorite ? .yellow : .secondary)
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)

                Button("执行") { onExecute() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture(count: 2) { onExecute() }
    }
}

struct ParameterFillView: View {
    let snippet: Snippet
    @Binding var params: [String: String]
    var onExecute: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("填写参数")
                .font(.headline)
                .padding(.horizontal, 14)
                .padding(.top, 12)

            Text(snippet.command)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.secondary)
                .padding(.horizontal, 14)

            Divider()

            ForEach(snippet.parameterNames, id: \.self) { name in
                HStack {
                    Text(name)
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 120, alignment: .trailing)
                    TextField("输入 \(name)", text: Binding(
                        get: { params[name] ?? "" },
                        set: { params[name] = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                }
                .padding(.horizontal, 14)
            }

            HStack {
                Spacer()
                Button("取消", action: onCancel)
                Button("执行") { onExecute() }
                    .buttonStyle(.borderedProminent)
                    .disabled(params.values.contains { $0.isEmpty })
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
        }
    }
}
