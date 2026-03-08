import Foundation
import Combine

@MainActor
final class WindowsVMManager: ObservableObject {
    static let shared = WindowsVMManager()

    @Published private(set) var vms: [WindowsVM] = []
    @Published private(set) var runningVMIDs: Set<UUID> = []
    @Published var lastErrorMessage: String?
    @Published private(set) var launchDiagnostics: [UUID: String] = [:]
    @Published var lastRecoveredVMID: UUID?
    @Published private(set) var isPreparingLinuxISO = false

    private var runningRunners: [UUID: ProcessRunner] = [:]
    private var autoRecoveryAttempts: [UUID: Int] = [:]

    private let vmsRoot: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support
            .appendingPathComponent("crossovr")
            .appendingPathComponent("VMs")
    }()
    private let ubuntuLinuxISOURL = URL(string: "https://cdimage.ubuntu.com/releases/24.04/release/ubuntu-24.04.2-live-server-arm64.iso")!

    private init() {
        loadAllVMs()
    }

    private struct UEFIFirmwarePaths {
        let codePath: String
        let varsTemplatePath: String
    }

    private struct VMLaunchPlan {
        let vm: WindowsVM
        let qemuPath: String
        let args: [String]
        let diagnostics: String
    }

    // MARK: - Public

    func loadAllVMs() {
        guard let items = try? FileManager.default.contentsOfDirectory(at: vmsRoot, includingPropertiesForKeys: nil) else {
            vms = []
            return
        }

        vms = items.compactMap { folder in
            let config = folder.appendingPathComponent("vm.json")
            guard FileManager.default.fileExists(atPath: config.path) else { return nil }
            guard let data = try? Data(contentsOf: config) else { return nil }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard var vm = try? decoder.decode(WindowsVM.self, from: data) else { return nil }
            // Safety: process state can't be trusted across app restarts.
            if vm.state == .running {
                vm.state = .stopped
                try? save(vm)
            }
            if vm.bootProfileVersion < 2 {
                vm.bootProfileVersion = 2
                try? save(vm)
            }
            // Sanity checks for persisted paths.
            guard !vm.diskImagePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            guard !vm.isoPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return vm
        }
        .sorted { $0.createdAt < $1.createdAt }
    }

    func createVM(
        name: String,
        guestOS: VMGuestOS,
        isoURL: URL?,
        diskSizeGB: Int,
        cpuCount: Int,
        memoryMB: Int
    ) throws -> WindowsVM {
        let resolvedISOURL: URL
        switch guestOS {
        case .windows11Arm:
            guard let isoURL else {
                throw NSError(domain: "WindowsVMManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Windows ISO is required."])
            }
            resolvedISOURL = isoURL
        case .linuxUbuntuArm:
            guard let isoURL else {
                throw NSError(domain: "WindowsVMManager", code: 11, userInfo: [NSLocalizedDescriptionKey: "Linux ISO is not ready yet. Please wait for download."])
            }
            resolvedISOURL = isoURL
        }

        guard FileManager.default.fileExists(atPath: resolvedISOURL.path) else {
            throw NSError(domain: "WindowsVMManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "ISO file does not exist."])
        }

        let vmID = UUID()
        let folder = vmsRoot.appendingPathComponent(vmID.uuidString)
        let disk = folder.appendingPathComponent("disk.img")

        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Guard against accidental overwrite/recreate.
        if FileManager.default.fileExists(atPath: disk.path) {
            throw NSError(domain: "WindowsVMManager", code: 2, userInfo: [NSLocalizedDescriptionKey: "Disk image already exists."])
        }

        // Create sparse disk image file for persistent VM storage.
        let bytes = UInt64(max(20, diskSizeGB)) * 1024 * 1024 * 1024
        FileManager.default.createFile(atPath: disk.path, contents: nil)
        let handle = try FileHandle(forWritingTo: disk)
        try handle.truncate(atOffset: bytes)
        try handle.close()

        var vm = WindowsVM(
            name: name,
            isoPath: resolvedISOURL.path,
            diskImagePath: disk.path,
            cpuCount: cpuCount,
            memoryMB: memoryMB,
            guestOS: guestOS
        )
        vm.id = vmID
        try save(vm)

        vms.append(vm)
        return vm
    }

    func prepareLinuxInstallerISO() async throws -> URL {
        let target = linuxISOCachePath()
        if FileManager.default.fileExists(atPath: target.path) {
            return target
        }

        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        isPreparingLinuxISO = true
        defer { isPreparingLinuxISO = false }

        let (tempURL, response) = try await URLSession.shared.download(from: ubuntuLinuxISOURL)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw NSError(
                domain: "WindowsVMManager",
                code: 12,
                userInfo: [NSLocalizedDescriptionKey: "Failed downloading Ubuntu ISO (HTTP \(http.statusCode))."]
            )
        }
        if FileManager.default.fileExists(atPath: target.path) {
            try? FileManager.default.removeItem(at: tempURL)
            return target
        }
        try FileManager.default.moveItem(at: tempURL, to: target)
        return target
    }

    func start(_ vm: WindowsVM) {
        guard !runningVMIDs.contains(vm.id) else { return }
        do {
            let plan = try buildLaunchPlan(for: vm)
            launchDiagnostics[vm.id] = plan.diagnostics

            let runner = ProcessRunner(
                executableURL: URL(fileURLWithPath: plan.qemuPath),
                arguments: plan.args
            )
            runningRunners[vm.id] = runner
            runningVMIDs.insert(vm.id)

            Task {
                var vmToRetry: WindowsVM?
                do {
                    _ = try await runner.run()
                } catch {
                    await MainActor.run {
                        vmToRetry = self.handleLaunchFailure(error, for: plan.vm)
                    }
                }
                await MainActor.run {
                    self.runningVMIDs.remove(vm.id)
                    self.runningRunners.removeValue(forKey: vm.id)
                    self.update(vm.id) {
                        $0.state = .stopped
                    }
                    if let vmToRetry {
                        self.lastErrorMessage = "Auto-repaired boot profile. Retrying..."
                        self.start(vmToRetry)
                    }
                }
            }

            update(vm.id) {
                $0.state = .running
                $0.lastBootedAt = Date()
                $0.bootProfileVersion = 2
            }
            autoRecoveryAttempts[vm.id] = 0
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func stop(_ vm: WindowsVM) {
        runningRunners[vm.id]?.terminate()
        runningRunners.removeValue(forKey: vm.id)
        runningVMIDs.remove(vm.id)
        update(vm.id) { $0.state = .stopped }
    }

    func resume(_ vm: WindowsVM) {
        // Current backend resumes by starting from persistent disk state.
        start(vm)
    }

    func markInstallComplete(_ vm: WindowsVM, completed: Bool) {
        update(vm.id) { $0.hasCompletedInstall = completed }
    }

    /// Resets firmware boot state and local installer mapping for a VM.
    @discardableResult
    func repairBoot(_ vm: WindowsVM, recreateIfNeeded: Bool = false) -> WindowsVM? {
        do {
            let current = vms.first(where: { $0.id == vm.id }) ?? vm
            try resetBootArtifacts(for: current)
            if !current.hasCompletedInstall {
                _ = try ensureLocalInstallISO(for: current, forceRefresh: true)
            }
            lastRecoveredVMID = current.id
            lastErrorMessage = "Boot profile repaired for \(current.name)."
            return current
        } catch {
            if recreateIfNeeded {
                do {
                    let recreated = try recreateVM(vm)
                    lastRecoveredVMID = recreated.id
                    lastErrorMessage = "VM was recreated with a clean boot profile."
                    return recreated
                } catch {
                    lastErrorMessage = "Failed to recreate VM: \(error.localizedDescription)"
                    return nil
                }
            }
            lastErrorMessage = "Boot repair failed: \(error.localizedDescription)"
            return nil
        }
    }

    /// Recreates a VM with the same settings and clean firmware state.
    @discardableResult
    func recreateVM(_ vm: WindowsVM) throws -> WindowsVM {
        let current = vms.first(where: { $0.id == vm.id }) ?? vm
        stop(current)

        let rescueISO = try prepareRecreateISO(from: current)
        let diskGB = max(40, Int((diskSizeBytes(for: current) / 1024 / 1024 / 1024)))
        let created = try createVM(
            name: current.name,
            guestOS: current.guestOS,
            isoURL: rescueISO,
            diskSizeGB: diskGB,
            cpuCount: current.cpuCount,
            memoryMB: current.memoryMB
        )

        // Remove the old VM folder/state once replacement is created.
        try? FileManager.default.removeItem(at: current.folderURL)
        if let idx = vms.firstIndex(where: { $0.id == current.id }) {
            vms.remove(at: idx)
        }
        autoRecoveryAttempts[current.id] = nil
        return created
    }

    func revealDisk(_ vm: WindowsVM) {
        let path = vm.diskURL.path
        Task {
            _ = try? await ProcessRunner.shell("open -R \"\(path)\"")
        }
    }

    func deleteVM(_ vm: WindowsVM) throws {
        let current = vms.first(where: { $0.id == vm.id }) ?? vm
        stop(current)
        if FileManager.default.fileExists(atPath: current.folderURL.path) {
            try FileManager.default.removeItem(at: current.folderURL)
        }
        vms.removeAll { $0.id == current.id }
        runningRunners.removeValue(forKey: current.id)
        runningVMIDs.remove(current.id)
        launchDiagnostics.removeValue(forKey: current.id)
        autoRecoveryAttempts.removeValue(forKey: current.id)
        if lastRecoveredVMID == current.id {
            lastRecoveredVMID = nil
        }
    }

    func diskSizeBytes(for vm: WindowsVM) -> Int64 {
        (try? vm.diskURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
    }

    // MARK: - Private

    private func save(_ vm: WindowsVM) throws {
        try FileManager.default.createDirectory(at: vm.folderURL, withIntermediateDirectories: true)
        let file = vm.folderURL.appendingPathComponent("vm.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(vm)
        try data.write(to: file, options: .atomicWrite)
    }

    private func update(_ id: UUID, mutate: (inout WindowsVM) -> Void) {
        guard let idx = vms.firstIndex(where: { $0.id == id }) else { return }
        mutate(&vms[idx])
        try? save(vms[idx])
    }

    private func buildLaunchPlan(for vm: WindowsVM) throws -> VMLaunchPlan {
        var workingVM = vm
        let installerISOPath = resolveInstallerISOPath(for: workingVM)

        guard FileManager.default.fileExists(atPath: workingVM.diskImagePath) else {
            throw NSError(domain: "WindowsVMManager", code: 4, userInfo: [NSLocalizedDescriptionKey: "VM disk image not found."])
        }

        if let installerISOPath {
            workingVM.isoPath = installerISOPath
        }

        if !workingVM.hasCompletedInstall &&
            (installerISOPath == nil || !FileManager.default.fileExists(atPath: installerISOPath!)) {
            throw NSError(domain: "WindowsVMManager", code: 5, userInfo: [NSLocalizedDescriptionKey: "Windows ISO not found for installation boot."])
        }

        let qemu = try locateQEMU()
        let firmware = try locateUEFIFirmware()
        let varsPath = try ensurePerVMFirmwareVars(for: workingVM, templatePath: firmware.varsTemplatePath)

        // Known-good UTM-like ARM launch profile with persistent firmware vars.
        var args: [String] = [
            "-accel", "hvf",
            "-machine", "virt,highmem=on",
            "-cpu", "host",
            "-smp", "\(max(2, workingVM.cpuCount))",
            "-m", "\(max(2048, workingVM.memoryMB))",
            "-drive", "if=pflash,format=raw,readonly=on,file=\(firmware.codePath)",
            "-drive", "if=pflash,format=raw,file=\(varsPath)",
            "-display", "cocoa,show-cursor=on",
            "-device", "qemu-xhci",
            "-device", "usb-kbd",
            "-device", "usb-tablet",
            "-netdev", "user,id=net0",
            "-device", "virtio-net-pci,netdev=net0",
            "-drive", "if=none,id=system,file=\(workingVM.diskImagePath),format=raw",
            "-device", "virtio-blk-pci,drive=system,bootindex=1"
        ]

        if workingVM.hasCompletedInstall {
            args += ["-device", "virtio-gpu-pci"]
            if let installerISOPath {
                // Keep installer media attached as low-priority fallback so blank disks
                // recover into setup instead of dropping to UEFI shell.
                args += ["-drive", "if=none,id=installer,file=\(installerISOPath),media=cdrom,readonly=on"]
                args += ["-device", "usb-storage,drive=installer,removable=true,bootindex=2"]
            }
            args += ["-boot", "menu=on"]
        } else if let installerISOPath {
            args += ["-device", "ramfb"]
            args += ["-drive", "if=none,id=installer,file=\(installerISOPath),media=cdrom,readonly=on"]
            args += ["-device", "usb-storage,drive=installer,removable=true,bootindex=0"]
            if workingVM.guestOS == .windows11Arm {
                // Auto-attach an answer file that bypasses TPM/SecureBoot checks in setup.
                let unattendedDir = try ensureUnattendedDirectory(for: workingVM)
                args += ["-drive", "if=none,id=autounattend,file=fat:rw:\(unattendedDir.path),format=raw,readonly=on"]
                args += ["-device", "usb-storage,drive=autounattend,removable=true,bootindex=3"]
            }
            args += ["-boot", "menu=on"]
        }

        let diagnostics = [
            "QEMU: \(qemu)",
            "Firmware code: \(firmware.codePath)",
            "Firmware vars: \(varsPath)",
            "Guest OS: \(workingVM.guestOS.displayName)",
            "Disk: \(workingVM.diskImagePath)",
            "Installer ISO: \(installerISOPath ?? "<none>")",
            "Args: \(args.joined(separator: " "))"
        ].joined(separator: "\n")

        return VMLaunchPlan(vm: workingVM, qemuPath: qemu, args: args, diagnostics: diagnostics)
    }

    private func resolveInstallerISOPath(for vm: WindowsVM) -> String? {
        if let local = existingLocalInstallISO(for: vm) {
            if vm.isoPath != local.path {
                update(vm.id) { $0.isoPath = local.path }
            }
            return local.path
        }

        let source = URL(fileURLWithPath: vm.isoPath)
        if FileManager.default.fileExists(atPath: source.path) {
            return try? ensureLocalInstallISO(for: vm)
        }

        // Stored ISO path can become stale after repair/recreate cycles.
        guard let fallbackISO = discoverFallbackISO(for: vm.guestOS) else { return nil }
        update(vm.id) { $0.isoPath = fallbackISO.path }
        return try? ensureLocalInstallISO(for: vm)
    }

    private func existingLocalInstallISO(for vm: WindowsVM) -> URL? {
        let local = vm.folderURL.appendingPathComponent("install.iso")
        guard FileManager.default.fileExists(atPath: local.path) else { return nil }
        return local
    }

    private func handleLaunchFailure(_ error: Error, for vm: WindowsVM) -> WindowsVM? {
        let message = error.localizedDescription
        guard !vm.hasCompletedInstall else {
            lastErrorMessage = message
            return nil
        }

        let attempts = autoRecoveryAttempts[vm.id, default: 0]
        guard attempts < 1, shouldAutoRecover(from: message) else {
            lastErrorMessage = message
            return nil
        }
        autoRecoveryAttempts[vm.id] = attempts + 1

        guard let recovered = repairBoot(vm, recreateIfNeeded: true) else {
            return nil
        }
        return recovered
    }

    private func shouldAutoRecover(from message: String) -> Bool {
        let lowered = message.lowercased()
        let signatures = [
            "process exited with code 1",
            "failed to lock byte",
            "display output is not active",
            "uefi",
            "boot",
            "cdrom",
            "open gl support was not enabled"
        ]
        return signatures.contains(where: { lowered.contains($0) })
    }

    private func locateQEMU() throws -> String {
        let candidates = [
            "/opt/homebrew/bin/qemu-system-aarch64",
            "/usr/local/bin/qemu-system-aarch64"
        ]
        if let existing = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            return existing
        }
        throw NSError(
            domain: "WindowsVMManager",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: "qemu-system-aarch64 not found. Install QEMU (brew install qemu)."]
        )
    }

    private func locateUEFIFirmware() throws -> UEFIFirmwarePaths {
        let codeCandidates = [
            "/opt/homebrew/share/qemu/edk2-aarch64-code.fd",
            "/opt/homebrew/share/qemu/edk2-arm-code.fd",
            "/usr/local/share/qemu/edk2-aarch64-code.fd",
            "/usr/local/share/qemu/edk2-arm-code.fd",
            "/usr/local/share/qemu/QEMU_EFI.fd"
        ]
        let varsCandidates = [
            "/opt/homebrew/share/qemu/edk2-arm-vars.fd",
            "/opt/homebrew/share/qemu/edk2-aarch64-vars.fd",
            "/usr/local/share/qemu/edk2-arm-vars.fd",
            "/usr/local/share/qemu/edk2-aarch64-vars.fd"
        ]

        guard let code = codeCandidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            throw NSError(
                domain: "WindowsVMManager",
                code: 7,
                userInfo: [NSLocalizedDescriptionKey: "ARM UEFI firmware code not found for QEMU. Reinstall QEMU with Homebrew (brew install qemu)."]
            )
        }

        guard let varsTemplate = varsCandidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            throw NSError(
                domain: "WindowsVMManager",
                code: 9,
                userInfo: [NSLocalizedDescriptionKey: "ARM UEFI vars template not found for QEMU. Reinstall QEMU with Homebrew (brew install qemu)."]
            )
        }

        return UEFIFirmwarePaths(codePath: code, varsTemplatePath: varsTemplate)
    }

    private func ensurePerVMFirmwareVars(for vm: WindowsVM, templatePath: String) throws -> String {
        let varsPath = vm.folderURL.appendingPathComponent("UEFI_VARS.fd")
        if !FileManager.default.fileExists(atPath: varsPath.path) {
            try FileManager.default.copyItem(at: URL(fileURLWithPath: templatePath), to: varsPath)
        }
        return varsPath.path
    }

    private func ensureLocalInstallISO(for vm: WindowsVM, forceRefresh: Bool = false) throws -> String {
        let source = URL(fileURLWithPath: vm.isoPath)
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw NSError(
                domain: "WindowsVMManager",
                code: 6,
                userInfo: [NSLocalizedDescriptionKey: "Windows ISO not found at \(source.path)."]
            )
        }

        let localISO = vm.folderURL.appendingPathComponent("install.iso")
        let fm = FileManager.default

        if forceRefresh, fm.fileExists(atPath: localISO.path) {
            try fm.removeItem(at: localISO)
        }

        // Always prefer per-VM install media path to avoid lock contention with Downloads ISO.
        if !fm.fileExists(atPath: localISO.path) {
            try fm.createDirectory(at: vm.folderURL, withIntermediateDirectories: true)
            if source.path == localISO.path {
                throw NSError(
                    domain: "WindowsVMManager",
                    code: 8,
                    userInfo: [NSLocalizedDescriptionKey: "VM install ISO is missing at \(localISO.path). Re-select ISO."]
                )
            }
            try fm.copyItem(at: source, to: localISO)
        }

        if vm.isoPath != localISO.path {
            update(vm.id) { $0.isoPath = localISO.path }
        }
        return localISO.path
    }

    private func resetBootArtifacts(for vm: WindowsVM) throws {
        let vars = vm.folderURL.appendingPathComponent("UEFI_VARS.fd")
        let localISO = vm.folderURL.appendingPathComponent("install.iso")
        if FileManager.default.fileExists(atPath: vars.path) {
            try FileManager.default.removeItem(at: vars)
        }
        if FileManager.default.fileExists(atPath: localISO.path) {
            try FileManager.default.removeItem(at: localISO)
        }
        autoRecoveryAttempts[vm.id] = nil
    }

    private func prepareRecreateISO(from vm: WindowsVM) throws -> URL {
        let iso = URL(fileURLWithPath: vm.isoPath)
        if !iso.path.hasPrefix(vm.folderURL.path), FileManager.default.fileExists(atPath: iso.path) {
            return iso
        }

        let rescue = vmsRoot.appendingPathComponent("recovery-\(vm.id.uuidString).iso")
        if FileManager.default.fileExists(atPath: iso.path) {
            if FileManager.default.fileExists(atPath: rescue.path) {
                try FileManager.default.removeItem(at: rescue)
            }
            try FileManager.default.copyItem(at: iso, to: rescue)
            return rescue
        }
        if let fallback = discoverFallbackISO(for: vm.guestOS) {
            return fallback
        }
        throw NSError(
            domain: "WindowsVMManager",
            code: 10,
            userInfo: [NSLocalizedDescriptionKey: "Unable to locate installer ISO for VM recreation. Re-select ISO in New VM."]
        )
    }

    private func discoverFallbackISO(for guestOS: VMGuestOS) -> URL? {
        let fm = FileManager.default
        let downloads = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first
        let searchRoots: [URL] = [downloads, vmsRoot].compactMap { $0 }
        var candidates: [URL] = []

        for root in searchRoots {
            guard let items = try? fm.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for url in items where url.pathExtension.lowercased() == "iso" {
                let name = url.lastPathComponent.lowercased()
                let isMatch: Bool
                switch guestOS {
                case .windows11Arm:
                    isMatch = name.contains("win") || name.contains("windows") || name.contains("arm")
                case .linuxUbuntuArm:
                    isMatch = name.contains("ubuntu") || name.contains("linux") || name.contains("arm64")
                }
                if isMatch {
                    candidates.append(url)
                }
            }
        }

        guard !candidates.isEmpty else { return nil }
        return candidates.sorted { lhs, rhs in
            let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return l > r
        }.first
    }

    private func linuxISOCachePath() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support
            .appendingPathComponent("crossovr")
            .appendingPathComponent("ISOs")
            .appendingPathComponent("ubuntu-24.04.2-live-server-arm64.iso")
    }

    private func ensureUnattendedDirectory(for vm: WindowsVM) throws -> URL {
        let dir = vm.folderURL.appendingPathComponent("autounattend")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <unattend xmlns="urn:schemas-microsoft-com:unattend">
          <settings pass="windowsPE">
            <component name="Microsoft-Windows-Setup" processorArchitecture="arm64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
              <RunSynchronous>
                <RunSynchronousCommand wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
                  <Order>1</Order>
                  <Path>reg add HKLM\\SYSTEM\\Setup\\LabConfig /v BypassTPMCheck /t REG_DWORD /d 1 /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
                  <Order>2</Order>
                  <Path>reg add HKLM\\SYSTEM\\Setup\\LabConfig /v BypassSecureBootCheck /t REG_DWORD /d 1 /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
                  <Order>3</Order>
                  <Path>reg add HKLM\\SYSTEM\\Setup\\LabConfig /v BypassRAMCheck /t REG_DWORD /d 1 /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
                  <Order>4</Order>
                  <Path>reg add HKLM\\SYSTEM\\Setup\\LabConfig /v BypassCPUCheck /t REG_DWORD /d 1 /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
                  <Order>5</Order>
                  <Path>reg add HKLM\\SYSTEM\\Setup\\LabConfig /v BypassStorageCheck /t REG_DWORD /d 1 /f</Path>
                </RunSynchronousCommand>
              </RunSynchronous>
            </component>
          </settings>
        </unattend>
        """
        try xml.write(to: dir.appendingPathComponent("Autounattend.xml"), atomically: true, encoding: .utf8)
        return dir
    }
}

