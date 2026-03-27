import SwiftUI

struct SnippetPanelView: View {
    @ObservedObject var snippetStore: SnippetStore
    @ObservedObject var sessionManager: SessionManager
    @State private var searchText: String = ""
    @State private var selectedCategory: SnippetCategory? = nil
    @State private var showAddSnippet: Bool = false
    @State private var editingSnippet: Snippet? = nil

    var filtered: [Snippet] {
        var list = snippetStore.search(searchText)
        if let cat = selectedCategory { list = list.filter { $0.category == cat } }
        return list
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("命令片段")
                    .font(.headline)
                Spacer()
                Button(action: { showAddSnippet = true }) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)
                .help("添加命令")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            // Search
            HStack {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("搜索命令...", text: $searchText)
                    .textFieldStyle(.plain)
            }
            .padding(8)
            .background(Color.secondary.opacity(0.08))

            // Category filter
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    CategoryChip(label: "全部", isSelected: selectedCategory == nil) {
                        selectedCategory = nil
                    }
                    ForEach(SnippetCategory.allCases) { cat in
                        CategoryChip(label: cat.rawValue, isSelected: selectedCategory == cat) {
                            selectedCategory = selectedCategory == cat ? nil : cat
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }

            Divider()

            // Snippet list
            List {
                ForEach(filtered) { snippet in
                    SnippetPanelRow(snippet: snippet) {
                        sendSnippet(snippet)
                    } onEdit: {
                        editingSnippet = snippet
                    } onDelete: {
                        snippetStore.delete(snippet)
                    } onFavorite: {
                        snippetStore.toggleFavorite(snippet)
                    }
                }
            }
            .listStyle(.plain)
        }
        .sheet(isPresented: $showAddSnippet) {
            EditSnippetView(snippetStore: snippetStore)
        }
        .sheet(item: $editingSnippet) { snippet in
            EditSnippetView(snippetStore: snippetStore, editingSnippet: snippet)
        }
    }

    private func sendSnippet(_ snippet: Snippet) {
        guard let tab = sessionManager.activeTab else { return }
        if snippet.hasParameters {
            // Show palette for parameter filling
            // For simplicity, just send with placeholders visible
        }
        NotificationCenter.default.post(
            name: .sendSnippet,
            object: nil,
            userInfo: ["tabID": tab.id, "command": snippet.command]
        )
    }
}

struct SnippetPanelRow: View {
    let snippet: Snippet
    var onSend: () -> Void
    var onEdit: () -> Void
    var onDelete: () -> Void
    var onFavorite: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    if snippet.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.system(size: 9))
                            .foregroundColor(.yellow)
                    }
                    Text(snippet.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                }
                Text(snippet.command)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            if isHovered {
                Button(action: onSend) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .help("发送到当前终端")
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture(count: 2) { onSend() }
        .contextMenu {
            Button("发送到终端") { onSend() }
            Button("编辑") { onEdit() }
            Button(snippet.isFavorite ? "取消收藏" : "收藏") { onFavorite() }
            Divider()
            Button("删除", role: .destructive) { onDelete() }
        }
    }
}

struct CategoryChip: View {
    let label: String
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Text(label)
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(isSelected ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.1))
                .clipShape(Capsule())
                .overlay(
                    Capsule().strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}

struct EditSnippetView: View {
    @ObservedObject var snippetStore: SnippetStore
    var editingSnippet: Snippet? = nil
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var command: String = ""
    @State private var description: String = ""
    @State private var category: SnippetCategory = .custom

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(editingSnippet == nil ? "添加命令" : "编辑命令")
                    .font(.headline)
                Spacer()
                Button("取消") { dismiss() }
                Button("保存") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(name.isEmpty || command.isEmpty)
            }
            .padding()

            Divider()

            Form {
                TextField("命令名称", text: $name)
                Picker("分类", selection: $category) {
                    ForEach(SnippetCategory.allCases) { cat in
                        Text(cat.rawValue).tag(cat)
                    }
                }
                TextField("描述（可选）", text: $description)
                VStack(alignment: .leading) {
                    Text("命令内容")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextEditor(text: $command)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(minHeight: 80)
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.secondary.opacity(0.3)))
                    Text("使用 {{参数名}} 定义占位符参数")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .padding()
        }
        .frame(width: 420, height: 340)
        .onAppear {
            if let s = editingSnippet {
                name = s.name; command = s.command
                description = s.description; category = s.category
            }
        }
    }

    private func save() {
        var snippet = editingSnippet ?? Snippet(name: "", command: "")
        snippet.name = name; snippet.command = command
        snippet.description = description; snippet.category = category
        if editingSnippet == nil { snippetStore.add(snippet) }
        else { snippetStore.update(snippet) }
        dismiss()
    }
}
