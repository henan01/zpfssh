import Foundation
import SwiftUI

@MainActor
class SnippetStore: ObservableObject {
    @Published var snippets: [Snippet] = []
    private let storageKey = "zen.ssh.snippets"

    init() {
        load()
        if snippets.isEmpty {
            snippets = Snippet.defaults
            save()
        }
    }

    func add(_ snippet: Snippet) {
        snippets.append(snippet)
        save()
    }

    func update(_ snippet: Snippet) {
        if let idx = snippets.firstIndex(where: { $0.id == snippet.id }) {
            snippets[idx] = snippet
            save()
        }
    }

    func delete(_ snippet: Snippet) {
        snippets.removeAll { $0.id == snippet.id }
        save()
    }

    func toggleFavorite(_ snippet: Snippet) {
        if let idx = snippets.firstIndex(where: { $0.id == snippet.id }) {
            snippets[idx].isFavorite.toggle()
            save()
        }
    }

    func search(_ query: String) -> [Snippet] {
        guard !query.isEmpty else { return sorted() }
        let q = query.lowercased()
        return sorted().filter {
            $0.name.lowercased().contains(q) ||
            $0.command.lowercased().contains(q) ||
            $0.description.lowercased().contains(q)
        }
    }

    func snippets(for category: SnippetCategory) -> [Snippet] {
        sorted().filter { $0.category == category }
    }

    var favorites: [Snippet] { sorted().filter { $0.isFavorite } }

    private func sorted() -> [Snippet] {
        snippets.sorted { a, b in
            if a.isFavorite != b.isFavorite { return a.isFavorite }
            return a.name < b.name
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(snippets) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([Snippet].self, from: data)
        else { return }
        snippets = decoded
    }
}
