import Foundation
import SwiftUI

/// The Windows architecture presented inside the bottle's WINEPREFIX.
enum BottleArch: String, CaseIterable, Codable {
    case win64 = "win64"
    case win32 = "win32"
}

// MARK: - InstalledApp

/// A shortcut to an app that has been installed inside a bottle.
/// Saved in the bottle's config.json so it persists across launches.
struct InstalledApp: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var exePath: String     // absolute Unix path to the .exe inside drive_c
    var sfSymbol: String    // SF Symbol name for the icon
    var iconColor: String   // hex color, e.g. "#1B2838"
    var isGame: Bool        // shows up in the Games section when true

    init(name: String, exePath: String, sfSymbol: String = "app.fill",
         iconColor: String = "#5A6EAA", isGame: Bool = false) {
        self.id        = UUID()
        self.name      = name
        self.exePath   = exePath
        self.sfSymbol  = sfSymbol
        self.iconColor = iconColor
        self.isGame    = isGame
    }

    enum CodingKeys: String, CodingKey {
        case id, name, exePath, sfSymbol, iconColor, isGame
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id        = try c.decode(UUID.self,   forKey: .id)
        name      = try c.decode(String.self, forKey: .name)
        exePath   = try c.decode(String.self, forKey: .exePath)
        sfSymbol  = try c.decodeIfPresent(String.self, forKey: .sfSymbol) ?? "app.fill"
        iconColor = try c.decodeIfPresent(String.self, forKey: .iconColor) ?? "#5A6EAA"
        isGame    = try c.decodeIfPresent(Bool.self,   forKey: .isGame)   ?? false
    }

    var parsedIconColor: Color {
        Color(hex: iconColor) ?? .accentColor
    }
}

// MARK: - Bottle

/// A Windows environment container — equivalent to a CrossOver "bottle" or Wineskin "wrapper".
struct Bottle: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var engineID: String          // WineEngine.id of the selected engine
    var backend: GraphicsBackend
    var arch: BottleArch
    var useRosetta: Bool          // Run Wine via `arch -x86_64` on Apple Silicon
    var notes: String
    var createdAt: Date
    var lastUsedAt: Date?
    var installedApps: [InstalledApp]

    /// Optional custom storage root. When nil, the default App Support path is used.
    var customRootPath: String?

    /// Root directory for this bottle.
    var rootURL: URL {
        if let custom = customRootPath {
            return URL(fileURLWithPath: custom)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support
            .appendingPathComponent("crossovr")
            .appendingPathComponent("Bottles")
            .appendingPathComponent(id.uuidString)
    }

    /// The WINEPREFIX directory — where Wine stores the virtual Windows filesystem.
    var prefixURL: URL {
        rootURL.appendingPathComponent("prefix")
    }

    /// Path to the persisted Bottle configuration JSON.
    var configURL: URL {
        rootURL.appendingPathComponent("config.json")
    }

    /// Convenience path strings used when building environment dictionaries.
    var prefixPath: String { prefixURL.path }

    /// The drive_c directory inside the WINEPREFIX.
    var driveCURL: URL {
        prefixURL.appendingPathComponent("drive_c")
    }

    init(name: String,
         engineID: String,
         backend: GraphicsBackend = .dxvk,
         arch: BottleArch = .win64,
         useRosetta: Bool = false,
         notes: String = "") {
        self.id            = UUID()
        self.name          = name
        self.engineID      = engineID
        self.backend       = backend
        self.arch          = arch
        self.useRosetta    = useRosetta
        self.notes         = notes
        self.createdAt     = Date()
        self.installedApps = []
        self.customRootPath = nil
    }

    // Provide default values for new fields when decoding older config.json files.
    enum CodingKeys: String, CodingKey {
        case id, name, engineID, backend, arch, useRosetta, notes, createdAt, lastUsedAt, installedApps, customRootPath
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id             = try c.decode(UUID.self,           forKey: .id)
        name           = try c.decode(String.self,         forKey: .name)
        engineID       = try c.decode(String.self,         forKey: .engineID)
        backend        = try c.decode(GraphicsBackend.self, forKey: .backend)
        arch           = try c.decode(BottleArch.self,     forKey: .arch)
        useRosetta     = try c.decode(Bool.self,           forKey: .useRosetta)
        notes          = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        createdAt      = try c.decode(Date.self,           forKey: .createdAt)
        lastUsedAt     = try c.decodeIfPresent(Date.self,  forKey: .lastUsedAt)
        installedApps  = try c.decodeIfPresent([InstalledApp].self, forKey: .installedApps) ?? []
        customRootPath = try c.decodeIfPresent(String.self, forKey: .customRootPath)
    }
}

// MARK: - Persistence

extension Bottle {
    /// Persists this bottle's configuration to disk.
    func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(self)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try data.write(to: configURL, options: .atomicWrite)
    }

    /// Loads a Bottle from its config.json at the given root URL.
    static func load(from rootURL: URL) throws -> Bottle {
        let configURL = rootURL.appendingPathComponent("config.json")
        let data = try Data(contentsOf: configURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Bottle.self, from: data)
    }
}

// MARK: - Color hex helper (shared)

extension Color {
    init?(hex: String) {
        var hex = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let rgb = UInt64(hex, radix: 16) else { return nil }
        self.init(
            red:   Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8)  & 0xFF) / 255,
            blue:  Double( rgb        & 0xFF) / 255
        )
    }
}
