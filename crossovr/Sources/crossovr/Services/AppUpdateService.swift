import Foundation
import AppKit

@MainActor
final class AppUpdateService: ObservableObject {
    @Published private(set) var isChecking = false
    @Published private(set) var currentVersion: String = AppUpdateService.detectCurrentVersion()
    @Published private(set) var latestVersion: String?
    @Published private(set) var updateURL: URL?
    @Published private(set) var statusMessage: String = ""

    private let latestReleaseAPI = URL(string: "https://api.github.com/repos/Sikarugir-App/Sikarugir-foss-sources/releases/latest")!

    func checkForUpdates() async {
        if isChecking { return }
        isChecking = true
        defer { isChecking = false }

        do {
            var request = URLRequest(url: latestReleaseAPI)
            request.setValue("crossovr-app", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                statusMessage = "Could not check updates right now."
                return
            }

            let latest = try JSONDecoder().decode(GitHubRelease.self, from: data)
            latestVersion = latest.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            updateURL = URL(string: latest.htmlURL)

            guard let latestVersion else {
                statusMessage = "No release information found."
                return
            }

            if isVersion(latestVersion, newerThan: currentVersion) {
                statusMessage = "Update available: \(latestVersion)"
            } else {
                statusMessage = "You are up to date (\(currentVersion))."
            }
        } catch {
            statusMessage = "Update check failed: \(error.localizedDescription)"
        }
    }

    func openUpdatePage() {
        guard let updateURL else { return }
        NSWorkspace.shared.open(updateURL)
    }

    // MARK: - Helpers

    private static func detectCurrentVersion() -> String {
        let info = Bundle.main.infoDictionary
        if let short = info?["CFBundleShortVersionString"] as? String, !short.isEmpty {
            return short
        }
        return "dev"
    }

    /// Basic semver-ish compare (numeric segments). Non-numeric suffixes are ignored.
    private func isVersion(_ lhs: String, newerThan rhs: String) -> Bool {
        let a = lhs.split(separator: ".").map { Int($0.filter(\.isNumber)) ?? 0 }
        let b = rhs.split(separator: ".").map { Int($0.filter(\.isNumber)) ?? 0 }
        let maxLen = max(a.count, b.count)
        for i in 0..<maxLen {
            let av = i < a.count ? a[i] : 0
            let bv = i < b.count ? b[i] : 0
            if av != bv { return av > bv }
        }
        return false
    }
}

private struct GitHubRelease: Decodable {
    let tagName: String
    let htmlURL: String

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
    }
}

