import Foundation

/// Reads hardware and OS information relevant to Wine and Metal backend availability.
final class SystemDetector: ObservableObject {
    static let shared = SystemDetector()

    @Published private(set) var cpuArchitecture: CPUArchitecture = .unknown
    @Published private(set) var macOSVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    @Published private(set) var rosettaAvailable: Bool = false

    enum CPUArchitecture {
        case intel       // x86_64
        case appleSilicon // arm64 (M-series)
        case unknown
    }

    private init() {
        detect()
    }

    // MARK: - Public queries

    var isAppleSilicon: Bool { cpuArchitecture == .appleSilicon }
    var isIntel: Bool        { cpuArchitecture == .intel }

    var macOSVersionString: String {
        let v = macOSVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    /// Returns true if a specific Metal backend is usable on this system.
    func isBackendAvailable(_ backend: GraphicsBackend) -> Bool {
        let minOS = backend.minimumMacOSVersion
        let meetsOS = macOSVersion.majorVersion > minOS.major ||
                      (macOSVersion.majorVersion == minOS.major && macOSVersion.minorVersion >= minOS.minor)
        if backend.requiresAppleSilicon {
            return isAppleSilicon && meetsOS
        }
        return meetsOS
    }

    /// Returns the best available backend for this system (preference order).
    var recommendedBackend: GraphicsBackend {
        let preference: [GraphicsBackend] = [.d3dMetal, .dxmt, .dxvk, .vkd3d, .wineD3D]
        return preference.first { isBackendAvailable($0) } ?? .wineD3D
    }

    // MARK: - Detection

    private func detect() {
        cpuArchitecture = detectCPU()
        rosettaAvailable = detectRosetta()
    }

    private func detectCPU() -> CPUArchitecture {
        var sysinfo = utsname()
        uname(&sysinfo)
        let machine = withUnsafeBytes(of: &sysinfo.machine) { rawPtr -> String in
            let ptr = rawPtr.bindMemory(to: CChar.self)
            return String(cString: ptr.baseAddress!)
        }
        if machine.hasPrefix("arm64") {
            return .appleSilicon
        } else if machine.hasPrefix("x86_64") {
            return .intel
        }
        return .unknown
    }

    private func detectRosetta() -> Bool {
        guard isAppleSilicon else {
            // On Intel, Rosetta is not applicable.
            return false
        }
        // Try to execute a trivial x86_64 binary — if it succeeds Rosetta is installed.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/arch")
        task.arguments = ["-x86_64", "/usr/bin/true"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError  = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// Prompts the user to install Rosetta 2 via `softwareupdate` if not present.
    func installRosetta(completion: @escaping (Bool) -> Void) {
        guard isAppleSilicon && !rosettaAvailable else {
            completion(rosettaAvailable)
            return
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/softwareupdate")
        task.arguments = ["--install-rosetta", "--agree-to-license"]
        task.terminationHandler = { [weak self] process in
            let success = process.terminationStatus == 0
            DispatchQueue.main.async {
                if success { self?.rosettaAvailable = true }
                completion(success)
            }
        }
        try? task.run()
    }

    /// Checks whether an x86_64 Wine binary can run on this machine.
    var canRunX86Wine: Bool {
        isIntel || rosettaAvailable
    }
}
