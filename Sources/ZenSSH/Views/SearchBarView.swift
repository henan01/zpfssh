import SwiftUI
import AppKit
import SwiftTerm

struct SearchBarView: View {
    @Binding var searchText: String
    @Binding var isVisible: Bool
    var onNext: () -> Void
    var onPrev: () -> Void
    var matchInfo: String

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
                .font(.system(size: 13))

            TextField("搜索终端输出...", text: $searchText)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .onSubmit { onNext() }
                .onChange(of: searchText) { _ in onNext() }
                .frame(minWidth: 200)

            if !matchInfo.isEmpty {
                Text(matchInfo)
                    .foregroundColor(.secondary)
                    .font(.caption)
                    .monospacedDigit()
            }

            Divider().frame(height: 16)

            Button(action: onPrev) {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.plain)
            .help("上一个匹配 (⌘⇧G)")

            Button(action: onNext) {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.plain)
            .help("下一个匹配 (⌘G)")

            Button(action: close) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(radius: 4)
        .onAppear { isFocused = true }
    }

    private func close() {
        searchText = ""
        isVisible = false
    }
}
