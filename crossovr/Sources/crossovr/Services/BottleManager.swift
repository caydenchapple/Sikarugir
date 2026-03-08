import Foundation
import Combine

/// Observable store for all Wine bottles. Persists to / loads from
/// `~/Library/Application Support/MacWineRunner/Bottles/`.
@MainActor
final class BottleManager: ObservableObject {
    static let shared = BottleManager()

    @Published private(set) var bottles: [Bottle] = []

    private let bottlesRoot: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support
            .appendingPathComponent("crossovr")
            .appendingPathComponent("Bottles")
    }()

    /// Legacy location used by earlier app versions before rename to `crossovr`.
    private let legacyBottlesRoot: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support
            .appendingPathComponent("MacWineRunner")
            .appendingPathComponent("Bottles")
    }()

    private init() {
        loadAllBottles()
    }

    // MARK: - CRUD

    /// Creates a new bottle on disk and adds it to the in-memory list.
    func createBottle(
        name: String,
        engineID: String,
        backend: GraphicsBackend = .dxvk,
        arch: BottleArch = .win64,
        useRosetta: Bool = false
    ) throws -> Bottle {
        let bottle = Bottle(name: name, engineID: engineID, backend: backend,
                            arch: arch, useRosetta: useRosetta)

        try FileManager.default.createDirectory(at: bottle.prefixURL,
                                                withIntermediateDirectories: true)
        try bottle.save()
        bottles.append(bottle)
        return bottle
    }

    /// Persists any in-memory changes back to the bottle's config.json.
    func updateBottle(_ bottle: Bottle) throws {
        try bottle.save()
        if let idx = bottles.firstIndex(where: { $0.id == bottle.id }) {
            bottles[idx] = bottle
        }
    }

    /// Permanently deletes a bottle's directory and removes it from the list.
    func deleteBottle(_ bottle: Bottle) throws {
        if FileManager.default.fileExists(atPath: bottle.rootURL.path) {
            try FileManager.default.removeItem(at: bottle.rootURL)
        }
        bottles.removeAll { $0.id == bottle.id }
    }

    /// Returns a bottle by its UUID, or nil if not found.
    func bottle(withID id: UUID) -> Bottle? {
        bottles.first { $0.id == id }
    }

    /// Adds a shortcut to an installed app inside the given bottle and persists it.
    func addApp(_ app: InstalledApp, to bottle: Bottle) throws {
        guard let idx = bottles.firstIndex(where: { $0.id == bottle.id }) else { return }
        // Avoid duplicate launch entries for the same executable.
        let alreadyExists = bottles[idx].installedApps.contains {
            $0.exePath.caseInsensitiveCompare(app.exePath) == .orderedSame
        }
        guard !alreadyExists else { return }
        bottles[idx].installedApps.append(app)
        try bottles[idx].save()
    }

    /// Re-scan a bottle for launchable programs and merge into installedApps.
    func refreshInstalledApps(for bottle: Bottle) {
        guard let idx = bottles.firstIndex(where: { $0.id == bottle.id }) else { return }
        var copy = bottles[idx]
        sanitizeInstalledApps(for: &copy)
        autoImportSteamEntries(into: &copy)
        if copy.installedApps.isEmpty, let primary = detectPrimaryExecutable(in: copy) {
            copy.installedApps.append(
                InstalledApp(
                    name: primary.deletingPathExtension().lastPathComponent,
                    exePath: primary.path,
                    sfSymbol: "app.fill",
                    iconColor: "#5A6EAA",
                    isGame: false
                )
            )
        }
        bottles[idx] = copy
        try? bottles[idx].save()
    }

    /// Removes an installed-app shortcut from the given bottle and persists the change.
    func removeApp(_ app: InstalledApp, from bottle: Bottle) throws {
        guard let idx = bottles.firstIndex(where: { $0.id == bottle.id }) else { return }
        bottles[idx].installedApps.removeAll { $0.id == app.id }
        try bottles[idx].save()
    }

    /// Updates the custom storage root for a bottle and, if requested, moves its data.
    func setCustomRoot(_ path: String?, for bottle: Bottle) throws {
        guard var updated = bottles.first(where: { $0.id == bottle.id }) else { return }
        let oldRoot = updated.rootURL
        updated.customRootPath = path
        // Move existing data to the new location if the directory already exists
        if FileManager.default.fileExists(atPath: oldRoot.path) {
            let newRoot = updated.rootURL
            if oldRoot != newRoot {
                try FileManager.default.createDirectory(at: newRoot.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: oldRoot, to: newRoot)
            }
        }
        try updated.save()
        try updateBottle(updated)
    }

    // MARK: - Disk I/O

    /// Scans the Bottles directory and loads every valid config.json.
    func loadAllBottles() {
        var loadedByID: [UUID: Bottle] = [:]

        // Prefer crossovr root first, then legacy root for any missing bottles.
        let roots = [bottlesRoot, legacyBottlesRoot]
        for root in roots {
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil,
                options: .skipsHiddenFiles
            ) else { continue }

            for url in contents {
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
                      isDir.boolValue else { continue }
                guard var bottle = try? Bottle.load(from: url) else { continue }

                // Bind this bottle to the exact on-disk directory it was loaded from.
                // This prevents entries disappearing when legacy and renamed paths coexist.
                if bottle.customRootPath == nil {
                    bottle.customRootPath = url.path
                }

                sanitizeInstalledApps(for: &bottle)
                autoImportSteamEntries(into: &bottle)
                if bottle.installedApps.isEmpty, let primary = detectPrimaryExecutable(in: bottle) {
                    bottle.installedApps.append(
                        InstalledApp(
                            name: primary.deletingPathExtension().lastPathComponent,
                            exePath: primary.path,
                            sfSymbol: "app.fill",
                            iconColor: "#5A6EAA",
                            isGame: false
                        )
                    )
                }
                try? bottle.save()

                // Keep first-loaded bottle for this UUID (crossovr has priority by root order).
                if loadedByID[bottle.id] == nil {
                    loadedByID[bottle.id] = bottle
                }
            }
        }

        bottles = loadedByID.values.sorted { $0.createdAt < $1.createdAt }
    }

    // MARK: - Disk space

    /// Returns the total size in bytes of a bottle's prefix directory.
    func diskUsage(for bottle: Bottle) throws -> Int {
        guard FileManager.default.fileExists(atPath: bottle.prefixURL.path) else { return 0 }
        let resourceValues = try bottle.prefixURL
            .resourceValues(forKeys: [.totalFileSizeKey])
        return resourceValues.totalFileSize ?? 0
    }

    // MARK: - Duplicate

    /// Creates a deep copy of a bottle (copies prefix directory).
    func duplicateBottle(_ source: Bottle, newName: String) throws -> Bottle {
        var copy = source
        copy.id        = UUID()
        copy.name      = newName
        copy.createdAt = Date()
        copy.lastUsedAt = nil

        try FileManager.default.createDirectory(at: copy.rootURL, withIntermediateDirectories: true)
        // Deep-copy the Wine prefix
        if FileManager.default.fileExists(atPath: source.prefixURL.path) {
            try FileManager.default.copyItem(at: source.prefixURL, to: copy.prefixURL)
        }
        try copy.save()
        bottles.append(copy)
        return copy
    }

    // MARK: - Steam auto-import (Whisky-style pinned entries)

    /// Import Steam desktop shortcuts and installed game manifests as launchable library entries.
    private func autoImportSteamEntries(into bottle: inout Bottle) {
        var changed = false

        // 1) Import steam://rungameid links from Wine desktop .url files
        let desktopDirs = steamDesktopDirectories(in: bottle)
        for dir in desktopDirs where FileManager.default.fileExists(atPath: dir.path) {
            guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for file in files where file.pathExtension.lowercased() == "url" {
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                guard let line = text.components(separatedBy: .newlines).first(where: { $0.lowercased().hasPrefix("url=steam://rungameid/") }) else { continue }
                let steamURI = line.replacingOccurrences(of: "URL=", with: "", options: .caseInsensitive)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !steamURI.isEmpty else { continue }

                let name = file.deletingPathExtension().lastPathComponent
                let entry = InstalledApp(
                    name: name,
                    exePath: steamURI,
                    sfSymbol: "gamecontroller.fill",
                    iconColor: "#1B2838",
                    isGame: true
                )
                if !bottle.installedApps.contains(where: { $0.exePath.caseInsensitiveCompare(entry.exePath) == .orderedSame }) {
                    bottle.installedApps.append(entry)
                    changed = true
                }
            }
        }

        // 2) Import Steam installed games from appmanifest_*.acf
        if let steamRoot = resolveSteamRoot(in: bottle) {
            let steamApps = steamRoot.appendingPathComponent("steamapps")
            if let files = try? FileManager.default.contentsOfDirectory(at: steamApps, includingPropertiesForKeys: nil) {
                let manifests = files.filter {
                    $0.lastPathComponent.lowercased().hasPrefix("appmanifest_") &&
                    $0.pathExtension.lowercased() == "acf"
                }
                for manifest in manifests {
                    guard let text = try? String(contentsOf: manifest, encoding: .utf8) else { continue }
                    guard let appID = firstRegexMatch(#""appid"\s*"(\d+)""#, in: text),
                          let gameName = firstRegexMatch(#""name"\s*"([^"]+)""#, in: text) else { continue }
                    let steamURI = "steam://rungameid/\(appID)"
                    if !bottle.installedApps.contains(where: { $0.exePath.caseInsensitiveCompare(steamURI) == .orderedSame }) {
                        bottle.installedApps.append(
                            InstalledApp(
                                name: gameName,
                                exePath: steamURI,
                                sfSymbol: "gamecontroller.fill",
                                iconColor: "#1B2838",
                                isGame: true
                            )
                        )
                        changed = true
                    }
                }
            }
        }

        if changed {
            bottle.lastUsedAt = Date()
        }
    }

    private func steamDesktopDirectories(in bottle: Bottle) -> [URL] {
        let usersRoot = bottle.driveCURL.appendingPathComponent("users")
        guard let users = try? FileManager.default.contentsOfDirectory(at: usersRoot, includingPropertiesForKeys: nil) else {
            return [
                bottle.driveCURL.appendingPathComponent("users/crossover/Desktop"),
                bottle.driveCURL.appendingPathComponent("users/Public/Desktop")
            ]
        }
        var dirs = users.map { $0.appendingPathComponent("Desktop") }
        dirs.append(bottle.driveCURL.appendingPathComponent("users/Public/Desktop"))
        return dirs
    }

    private func resolveSteamRoot(in bottle: Bottle) -> URL? {
        let candidates = [
            bottle.driveCURL.appendingPathComponent("Program Files (x86)/Steam"),
            bottle.driveCURL.appendingPathComponent("Program Files/Steam")
        ]
        return candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) })
    }

    private func firstRegexMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range), match.numberOfRanges > 1 else { return nil }
        guard let r = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    private func sanitizeInstalledApps(for bottle: inout Bottle) {
        var seenPaths: Set<String> = []
        bottle.installedApps = bottle.installedApps.filter { app in
            let key = app.exePath.lowercased()
            guard !seenPaths.contains(key) else { return false }
            seenPaths.insert(key)
            // Remove known bad auto-detected system entries from prior versions.
            if key.contains("/windows media player/wmplayer.exe") ||
                key.hasSuffix("/iexplore.exe") ||
                key.hasSuffix("/explorer.exe") {
                return false
            }
            if app.exePath.lowercased().hasPrefix("steam://rungameid/") { return true }
            return FileManager.default.fileExists(atPath: app.exePath)
        }
    }

    private func detectPrimaryExecutable(in bottle: Bottle) -> URL? {
        let driveC = bottle.driveCURL
        let roots = [
            driveC.appendingPathComponent("Program Files"),
            driveC.appendingPathComponent("Program Files (x86)")
        ]
        let bottleTokens: [String] = bottle.name
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 }

        var best: (url: URL, score: Int)?
        let skipContains = [
            "install", "setup", "uninstall", "uninst", "update", "updater",
            "redist", "vcredist", "dxsetup", "helper", "crash", "repair"
        ]
        let hardBlock = Set(["wmplayer", "iexplore", "explorer", "regedit", "rundll32"])

        for root in roots where FileManager.default.fileExists(atPath: root.path) {
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in enumerator {
                guard url.pathExtension.lowercased() == "exe" else { continue }
                let name = url.deletingPathExtension().lastPathComponent.lowercased()
                if hardBlock.contains(name) { continue }
                if url.path.lowercased().contains("/windows media player/") { continue }
                if skipContains.contains(where: { name.contains($0) }) { continue }

                var score = 0
                for token in bottleTokens {
                    if name.contains(token) { score += 120 }
                    if url.path.lowercased().contains("/\(token)/") { score += 50 }
                }
                if name == "steam" || name.contains("epic") || name.contains("launcher") { score += 40 }
                if best == nil || score > best!.score {
                    best = (url, score)
                }
            }
        }
        return best?.url
    }
}
