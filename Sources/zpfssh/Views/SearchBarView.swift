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
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
                .font(.system(size: 12))

            TextField("搜索...", text: $searchText)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .font(.system(size: 12))
                .onSubmit { onNext() }
                .onChange(of: searchText) { _ in onNext() }
                .frame(minWidth: 160)

            if !matchInfo.isEmpty {
                Text(matchInfo)
                    .foregroundColor(.secondary)
                    .font(.caption2)
                    .monospacedDigit()
            }

            Divider().frame(height: 14)

            Button(action: onPrev) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .help("上一个 (⌘⇧G)")

            Button(action: onNext) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .help("下一个 (⌘G)")

            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
        .onAppear { isFocused = true }
    }

    private func close() {
        searchText = ""
        isVisible = false
    }
}
