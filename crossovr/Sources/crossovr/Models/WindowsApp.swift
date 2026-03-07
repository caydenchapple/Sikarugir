import Foundation
import SwiftUI

/// How well a Windows application runs under Wine on macOS.
enum CompatibilityLabel: String, Codable, CaseIterable {
    case runsGreat = "Runs Great"
    case runsWell  = "Runs Well"
    case runsAtAll = "Runs at Times"
    case tbd       = "TBD"

    /// SF Symbol name to represent this rating.
    var icon: String {
        switch self {
        case .runsGreat: return "checkmark.seal.fill"
        case .runsWell:  return "checkmark.circle.fill"
        case .runsAtAll: return "exclamationmark.circle.fill"
        case .tbd:       return "questionmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .runsGreat: return .green
        case .runsWell:  return Color(red: 0.2, green: 0.6, blue: 1.0)
        case .runsAtAll: return .orange
        case .tbd:       return .secondary
        }
    }

    /// Numeric star count (out of 5) associated with this label.
    var defaultStars: Double {
        switch self {
        case .runsGreat: return 5.0
        case .runsWell:  return 3.5
        case .runsAtAll: return 2.0
        case .tbd:       return 0.0
        }
    }
}

/// A known Windows application in the crossovr catalog.
struct WindowsApp: Codable, Identifiable, Hashable {
    var id: String                      // slug, e.g. "steam"
    var name: String
    var stars: Double                   // 0.0 – 5.0
    var compatibility: CompatibilityLabel
    var category: AppCategory
    var sfSymbol: String                // SF Symbol used as fallback icon
    var iconColor: String               // hex colour for icon background, e.g. "#1b2838"
    var winetricksVerbs: [String]       // verbs to run before launching
    var defaultBackend: String?         // GraphicsBackend.rawValue override
    var installerURL: String?           // Direct download URL for the Windows installer .exe/.msi

    // MARK: - Helpers

    /// `Color` parsed from `iconColor` hex string.
    var parsedIconColor: Color {
        Color(hex: iconColor) ?? .gray
    }
}

enum AppCategory: String, Codable, CaseIterable {
    case gaming      = "Gaming"
    case launchers   = "Game Launchers"
    case productivity = "Productivity"
    case creative    = "Creative"
    case utilities   = "Utilities"
    case other       = "Other"
}

