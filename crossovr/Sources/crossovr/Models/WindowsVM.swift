import Foundation

enum WindowsVMState: String, Codable, CaseIterable {
    case stopped
    case running
    case suspended
}

enum VMGuestOS: String, Codable, CaseIterable {
    case windows11Arm
    case linuxUbuntuArm

    var displayName: String {
        switch self {
        case .windows11Arm: return "Windows 11 (ARM64)"
        case .linuxUbuntuArm: return "Linux (Ubuntu ARM64)"
        }
    }
}

/// Persistent metadata for a real Windows VM configuration.
struct WindowsVM: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var isoPath: String
    var diskImagePath: String
    var cpuCount: Int
    var memoryMB: Int
    var guestOS: VMGuestOS
    var state: WindowsVMState
    var hasCompletedInstall: Bool
    var bootProfileVersion: Int
    var createdAt: Date
    var lastBootedAt: Date?

    var folderURL: URL {
        URL(fileURLWithPath: diskImagePath).deletingLastPathComponent()
    }

    var isoURL: URL { URL(fileURLWithPath: isoPath) }
    var diskURL: URL { URL(fileURLWithPath: diskImagePath) }

    init(
        name: String,
        isoPath: String,
        diskImagePath: String,
        cpuCount: Int,
        memoryMB: Int,
        guestOS: VMGuestOS = .windows11Arm
    ) {
        self.id = UUID()
        self.name = name
        self.isoPath = isoPath
        self.diskImagePath = diskImagePath
        self.cpuCount = cpuCount
        self.memoryMB = memoryMB
        self.guestOS = guestOS
        self.state = .stopped
        self.hasCompletedInstall = false
        self.bootProfileVersion = 2
        self.createdAt = Date()
        self.lastBootedAt = nil
    }

    enum CodingKeys: String, CodingKey {
        case id, name, isoPath, diskImagePath, cpuCount, memoryMB, guestOS, state, hasCompletedInstall, bootProfileVersion, createdAt, lastBootedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        isoPath = try c.decode(String.self, forKey: .isoPath)
        diskImagePath = try c.decode(String.self, forKey: .diskImagePath)
        cpuCount = try c.decode(Int.self, forKey: .cpuCount)
        memoryMB = try c.decode(Int.self, forKey: .memoryMB)
        guestOS = try c.decodeIfPresent(VMGuestOS.self, forKey: .guestOS) ?? .windows11Arm
        state = try c.decode(WindowsVMState.self, forKey: .state)
        hasCompletedInstall = try c.decode(Bool.self, forKey: .hasCompletedInstall)
        bootProfileVersion = try c.decodeIfPresent(Int.self, forKey: .bootProfileVersion) ?? 1
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        lastBootedAt = try c.decodeIfPresent(Date.self, forKey: .lastBootedAt)
    }
}

