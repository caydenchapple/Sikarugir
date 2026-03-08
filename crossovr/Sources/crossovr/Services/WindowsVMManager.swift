import Foundation
import Combine

@MainActor
final class WindowsVMManager: ObservableObject {
    static let shared = WindowsVMManager()

    @Published private(set) var vms: [WindowsVM] = []
    @Published private(set) var runningVMIDs: Set<UUID> = []
    @Published var lastErrorMessage: String?

    private var runningRunners: [UUID: ProcessRunner] = [:]

    private let vmsRoot: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support
            .appendingPathComponent("crossovr")
            .appendingPathComponent("VMs")
    }()

    private init() {
        loadAllVMs()
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
            // Sanity checks for persisted paths.
            guard !vm.diskImagePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            guard !vm.isoPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return vm
        }
        .sorted { $0.createdAt < $1.createdAt }
    }

    func createVM(
        name: String,
        isoURL: URL,
        diskSizeGB: Int,
        cpuCount: Int,
        memoryMB: Int
    ) throws -> WindowsVM {
        guard FileManager.default.fileExists(atPath: isoURL.path) else {
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
            isoPath: isoURL.path,
            diskImagePath: disk.path,
            cpuCount: cpuCount,
            memoryMB: memoryMB
        )
        vm.id = vmID
        try save(vm)

        vms.append(vm)
        return vm
    }

    func start(_ vm: WindowsVM) {
        guard !runningVMIDs.contains(vm.id) else { return }
        do {
            var effectiveVM = vm
            var installISOPath: String?
            if !effectiveVM.hasCompletedInstall {
                installISOPath = try ensureLocalInstallISO(for: effectiveVM)
                if let installISOPath {
                    effectiveVM.isoPath = installISOPath
                }
            }

            guard FileManager.default.fileExists(atPath: effectiveVM.diskImagePath) else {
                throw NSError(domain: "WindowsVMManager", code: 4, userInfo: [NSLocalizedDescriptionKey: "VM disk image not found."])
            }
            if !effectiveVM.hasCompletedInstall &&
                (installISOPath == nil || !FileManager.default.fileExists(atPath: installISOPath!)) {
                throw NSError(domain: "WindowsVMManager", code: 5, userInfo: [NSLocalizedDescriptionKey: "Windows ISO not found for installation boot."])
            }
            let qemu = try locateQEMU()
            let uefiFirmware = try locateUEFIFirmware()
            var args: [String] = [
                "-accel", "hvf",
                "-machine", "virt,highmem=on",
                "-cpu", "host",
                "-smp", "\(max(2, effectiveVM.cpuCount))",
                "-m", "\(max(2048, effectiveVM.memoryMB))",
                "-bios", uefiFirmware,
                // Force native macOS display output so VM is not headless.
                "-display", "cocoa,show-cursor=on",
                // Use explicit drive IDs + device wiring for reliable boot ordering on ARM virt machine.
                "-drive", "if=none,id=vdisk,file=\(effectiveVM.diskImagePath),format=raw",
                "-device", "virtio-blk-pci,drive=vdisk,bootindex=1",
                "-device", "qemu-xhci",
                "-device", "usb-kbd",
                "-device", "usb-tablet",
                "-nic", "user,model=virtio-net-pci"
            ]

            // Use ISO as installation media until user marks install complete.
            if !effectiveVM.hasCompletedInstall {
                // Installer path: maximize compatibility and guaranteed video output.
                args += ["-device", "ramfb"]
                // Attach ISO as USB install media for broadest EDK2 visibility on ARM QEMU.
                args += ["-drive", "if=none,id=install,media=cdrom,readonly=on,file=\(installISOPath!)"]
                args += ["-device", "usb-storage,drive=install,bootindex=0"]
                // Keep boot menu enabled, but rely on bootindex for deterministic media priority.
                args += ["-boot", "menu=on"]
            } else {
                // Runtime path: non-GL virtio GPU works on QEMU builds without OpenGL support.
                args += ["-device", "virtio-gpu-pci"]
                // After install, boot from VM disk by default.
                args += ["-boot", "menu=on"]
            }

            let runner = ProcessRunner(
                executableURL: URL(fileURLWithPath: qemu),
                arguments: args
            )
            runningRunners[vm.id] = runner
            runningVMIDs.insert(vm.id)

            Task {
                do {
                    _ = try await runner.run()
                } catch {
                    await MainActor.run {
                        self.lastErrorMessage = error.localizedDescription
                    }
                }
                await MainActor.run {
                    self.runningVMIDs.remove(vm.id)
                    self.runningRunners.removeValue(forKey: vm.id)
                    self.update(vm.id) {
                        $0.state = .stopped
                    }
                }
            }

            update(vm.id) {
                $0.state = .running
                $0.lastBootedAt = Date()
            }
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

    func revealDisk(_ vm: WindowsVM) {
        let path = vm.diskURL.path
        Task {
            _ = try? await ProcessRunner.shell("open -R \"\(path)\"")
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

    private func locateUEFIFirmware() throws -> String {
        let candidates = [
            "/opt/homebrew/share/qemu/edk2-aarch64-code.fd",
            "/opt/homebrew/share/qemu/edk2-arm-code.fd",
            "/opt/homebrew/share/qemu/QEMU_EFI.fd",
            "/usr/local/share/qemu/edk2-aarch64-code.fd",
            "/usr/local/share/qemu/edk2-arm-code.fd",
            "/usr/local/share/qemu/QEMU_EFI.fd"
        ]
        if let existing = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            return existing
        }
        throw NSError(
            domain: "WindowsVMManager",
            code: 7,
            userInfo: [NSLocalizedDescriptionKey: "ARM UEFI firmware not found for QEMU. Reinstall QEMU with Homebrew (brew install qemu)."]
        )
    }

    private func ensureLocalInstallISO(for vm: WindowsVM) throws -> String {
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
}

