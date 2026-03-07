import Foundation
import Combine

/// Loads and exposes the bundled Windows app catalog.
@MainActor
final class AppCatalogManager: ObservableObject {
    static let shared = AppCatalogManager()

    @Published private(set) var allApps: [WindowsApp] = []

    private init() {
        load()
    }

    // MARK: - Filtered results

    /// Returns apps filtered by a search query, preserving catalog order.
    func filteredApps(query: String) -> [WindowsApp] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return allApps }
        let q = query.lowercased()
        return allApps.filter {
            $0.name.lowercased().contains(q) ||
            $0.category.rawValue.lowercased().contains(q) ||
            $0.compatibility.rawValue.lowercased().contains(q)
        }
    }

    /// Returns apps for a specific category.
    func apps(in category: AppCategory) -> [WindowsApp] {
        allApps.filter { $0.category == category }
    }

    // MARK: - Load

    private func load() {
        guard let url = Bundle.module.url(forResource: "apps", withExtension: "json") else {
            loadFromSourceTree()
            return
        }
        decode(from: url)
    }

    /// Development fallback — resolves relative to the source file at compile time.
    private func loadFromSourceTree() {
        let devURL = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()          // Services/
            .deletingLastPathComponent()          // crossovr/
            .appendingPathComponent("Resources/apps.json")
        guard FileManager.default.fileExists(atPath: devURL.path) else { return }
        decode(from: devURL)
    }

    private func decode(from url: URL) {
        guard let data = try? Data(contentsOf: url) else { return }
        if let apps = try? JSONDecoder().decode([WindowsApp].self, from: data) {
            allApps = apps
        }
    }
}
