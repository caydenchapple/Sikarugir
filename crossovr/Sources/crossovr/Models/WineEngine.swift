import Foundation

/// Represents the CPU architecture Wine should present to Windows applications.
enum WineArch: String, CaseIterable, Codable {
    case win64 = "win64"
    case win32 = "win32"
}

/// The source/variant of a Wine build.
enum WineEngineVariant: String, Codable, CaseIterable {
    case crossover  = "CrossOver"
    case proton     = "Proton"
    case vanilla    = "Vanilla"
    case staging    = "Staging"
    case gptk       = "GPTK"
}

/// A versioned Wine engine build that can be downloaded and used by bottles.
struct WineEngine: Codable, Identifiable, Hashable {
    var id: String { "\(variant.rawValue)-\(version)" }

    let version: String
    let variant: WineEngineVariant
    let downloadURL: URL
    let supportedArch: [WineArch]
    let minMacOSVersion: String
    var isInstalled: Bool = false

    var displayName: String {
        "\(variant.rawValue) \(version)"
    }

    /// Local install path under the app's support directory.
    var localPath: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support
            .appendingPathComponent("crossovr")
            .appendingPathComponent("Engines")
            .appendingPathComponent(id)
    }

    /// The `wine` binary within the installed engine bundle.
    /// Gcenx macOS builds are packaged as .app bundles:
    /// the binary lives at Contents/Resources/wine/bin/wine.
    var wineBinaryPath: URL {
        // Primary location inside the .app-style bundle
        let bundled = localPath.appendingPathComponent("Contents/Resources/wine/bin/wine")
        if FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        // Fallback: flat tarball layout (bin/wine or bin/wine64)
        let flatWine64 = localPath.appendingPathComponent("bin/wine64")
        if FileManager.default.fileExists(atPath: flatWine64.path) { return flatWine64 }
        let flatWine = localPath.appendingPathComponent("bin/wine")
        if FileManager.default.fileExists(atPath: flatWine.path) { return flatWine }
        // Return the bundle path as default (will produce a clear error if missing)
        return bundled
    }

    var wineServerBinaryPath: URL {
        let bundled = localPath.appendingPathComponent("Contents/Resources/wine/bin/wineserver")
        if FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        return localPath.appendingPathComponent("bin/wineserver")
    }

    // MARK: - Codable (exclude computed isInstalled from encoding)
    enum CodingKeys: String, CodingKey {
        case version, variant, downloadURL, supportedArch, minMacOSVersion
    }

    init(version: String, variant: WineEngineVariant, downloadURL: URL,
         supportedArch: [WineArch], minMacOSVersion: String) {
        self.version = version
        self.variant = variant
        self.downloadURL = downloadURL
        self.supportedArch = supportedArch
        self.minMacOSVersion = minMacOSVersion
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version           = try c.decode(String.self,              forKey: .version)
        variant           = try c.decode(WineEngineVariant.self,   forKey: .variant)
        downloadURL       = try c.decode(URL.self,                 forKey: .downloadURL)
        supportedArch     = try c.decode([WineArch].self,          forKey: .supportedArch)
        minMacOSVersion   = try c.decode(String.self,              forKey: .minMacOSVersion)
        isInstalled       = FileManager.default.fileExists(atPath: localPath.path)
    }
}
