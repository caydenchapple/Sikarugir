import Foundation

enum WindowsVMState: String, Codable, CaseIterable {
    case stopped
    case running
    case suspended
}

/// Persistent metadata for a real Windows VM configuration.
struct WindowsVM: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var isoPath: String
    var diskImagePath: String
    var cpuCount: Int
    var memoryMB: Int
    var state: WindowsVMState
    var hasCompletedInstall: Bool
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
        memoryMB: Int
    ) {
        self.id = UUID()
        self.name = name
        self.isoPath = isoPath
        self.diskImagePath = diskImagePath
        self.cpuCount = cpuCount
        self.memoryMB = memoryMB
        self.state = .stopped
        self.hasCompletedInstall = false
        self.createdAt = Date()
        self.lastBootedAt = nil
    }
}

