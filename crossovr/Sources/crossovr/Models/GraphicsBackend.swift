import Foundation

/// The Direct3D-to-Metal (or software) translation layer used by a bottle.
enum GraphicsBackend: String, CaseIterable, Codable, Identifiable {
    case d3dMetal = "D3DMetal"
    case dxmt     = "DXMT"
    case dxvk     = "DXVK"
    case vkd3d    = "VKD3D"
    case wineD3D  = "WineD3D"

    var id: String { rawValue }

    var displayName: String { rawValue }

    var description: String {
        switch self {
        case .d3dMetal:
            return "Apple's Game Porting Toolkit translator (D3D11/12 → Metal). Apple Silicon + macOS 14+ only."
        case .dxmt:
            return "DXMT Direct3D 10/11 → Metal translator. macOS 14+ recommended."
        case .dxvk:
            return "DXVK Direct3D 9/10/11 → Vulkan (via MoltenVK). Broad compatibility."
        case .vkd3d:
            return "VKD3D-Proton Direct3D 12 → Vulkan (via MoltenVK). Best for DX12 games."
        case .wineD3D:
            return "Wine's built-in OpenGL renderer. Most compatible, but slowest for 3D."
        }
    }

    /// Whether this backend requires Apple Silicon.
    var requiresAppleSilicon: Bool {
        switch self {
        case .d3dMetal: return true
        case .dxmt:     return true
        default:        return false
        }
    }

    /// Minimum macOS version required (as an integer tuple for comparison).
    var minimumMacOSVersion: (major: Int, minor: Int) {
        switch self {
        case .d3dMetal: return (14, 0)
        case .dxmt:     return (14, 0)
        case .dxvk:     return (13, 0)
        case .vkd3d:    return (13, 0)
        case .wineD3D:  return (13, 0)
        }
    }

    /// Environment variables to inject when launching Wine with this backend.
    var environmentOverrides: [String: String] {
        switch self {
        case .d3dMetal:
            return [
                "D3DMETAL_ENABLED": "1",
                "MTL_HUD_ENABLED": "0"
            ]
        case .dxmt:
            return [
                "DXMT_ENABLE": "1",
                "DXVK_ENABLE_NVAPI": "0"
            ]
        case .dxvk:
            return [
                "DXVK_ASYNC": "1",
                "DXVK_STATE_CACHE": "1"
            ]
        case .vkd3d:
            return [
                "VKD3D_CONFIG": "dxr11,dxr",
                "VKD3D_FEATURE_LEVEL": "12_2"
            ]
        case .wineD3D:
            return [:]
        }
    }
}
