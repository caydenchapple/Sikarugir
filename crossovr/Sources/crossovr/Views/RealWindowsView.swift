import SwiftUI

struct RealWindowsView: View {
    @StateObject private var vmManager = WindowsVMManager.shared
    @State private var selectedVMID: UUID?
    @State private var showSetup = false
    @State private var pendingDeleteVM: WindowsVM?

    private var selectedVM: WindowsVM? {
        vmManager.vms.first(where: { $0.id == selectedVMID }) ?? vmManager.vms.first
    }

    private var isErrorPresented: Binding<Bool> {
        Binding(
            get: { vmManager.lastErrorMessage != nil },
            set: { if !$0 { vmManager.lastErrorMessage = nil } }
        )
    }

    var body: some View {
        NavigationSplitView { sidebar } detail: { detail }
        .navigationTitle("Real Windows")
        .sheet(isPresented: $showSetup) {
            VMSetupView(onCreate: createVM)
        }
        .confirmationDialog(
            "Delete this Real Windows VM?",
            isPresented: Binding(
                get: { pendingDeleteVM != nil },
                set: { if !$0 { pendingDeleteVM = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete VM", role: .destructive) {
                guard let vm = pendingDeleteVM else { return }
                do {
                    try vmManager.deleteVM(vm)
                    selectedVMID = vmManager.vms.first?.id
                } catch {
                    vmManager.lastErrorMessage = error.localizedDescription
                }
                pendingDeleteVM = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDeleteVM = nil
            }
        } message: {
            if let vm = pendingDeleteVM {
                let diskSize = ByteCountFormatter.string(
                    fromByteCount: vmManager.diskSizeBytes(for: vm),
                    countStyle: .file
                )
                Text("""
                This permanently removes the VM disk and configuration.
                Disk: \(vm.diskURL.path)
                Size: \(diskSize)
                """)
            } else {
                Text("This permanently removes the VM disk and configuration.")
            }
        }
        .alert("VM Error", isPresented: isErrorPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(vmManager.lastErrorMessage ?? "Unknown error")
        }
        .onAppear {
            vmManager.loadAllVMs()
            if selectedVMID == nil {
                selectedVMID = vmManager.vms.first?.id
            }
        }
        .onChange(of: vmManager.lastRecoveredVMID) { recovered in
            if let recovered {
                selectedVMID = recovered
            }
        }
    }

    private var sidebar: some View {
        List(selection: $selectedVMID) {
            Section("REAL WINDOWS VMS") {
                ForEach(vmManager.vms) { vm in
                    Label(vm.name, systemImage: vm.state == .running ? "display.and.arrow.down" : "desktopcomputer")
                        .tag(vm.id)
                }
            }
        }
        .listStyle(.sidebar)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showSetup = true
                } label: {
                    Label("New VM", systemImage: "plus")
                }
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let vm = selectedVM {
            vmDetail(vm)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
                Text("No Windows VM")
                    .font(.title3.bold())
                Text("Create a VM to install Windows or Linux.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func vmDetail(_ vm: WindowsVM) -> some View {
        let isRunning = vmManager.runningVMIDs.contains(vm.id)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(vm.name).font(.title2.bold())
                        Text("State: \(vm.state.rawValue.capitalized)")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    statusBadge(vm)
                }

                HStack(spacing: 10) {
                    Button {
                        vmManager.start(vm)
                    } label: {
                        Label("Start", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isRunning)

                    Button {
                        vmManager.stop(vm)
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .buttonStyle(.bordered)
                    .disabled(!isRunning)

                    Button {
                        vmManager.resume(vm)
                    } label: {
                        Label("Resume", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        if let repaired = vmManager.repairBoot(vm, recreateIfNeeded: false) {
                            selectedVMID = repaired.id
                        }
                    } label: {
                        Label("Repair Boot", systemImage: "wrench.and.screwdriver")
                    }
                    .buttonStyle(.bordered)
                    .disabled(isRunning)

                    Button(role: .destructive) {
                        if let recreated = vmManager.repairBoot(vm, recreateIfNeeded: true) {
                            selectedVMID = recreated.id
                        }
                    } label: {
                        Label("Recreate VM", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.bordered)
                    .disabled(isRunning)

                    Button(role: .destructive) {
                        pendingDeleteVM = vm
                    } label: {
                        Label("Delete VM", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                    .disabled(isRunning)
                }

                GroupBox("Diagnostics") {
                    VStack(alignment: .leading, spacing: 8) {
                        LabeledContent("ISO") {
                            Text(vm.isoURL.path)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        LabeledContent("Disk") {
                            Text(vm.diskURL.path)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        LabeledContent("Disk Size") {
                            Text(ByteCountFormatter.string(fromByteCount: vmManager.diskSizeBytes(for: vm), countStyle: .file))
                                .foregroundStyle(.secondary)
                        }
                        LabeledContent("CPU / Memory") {
                            Text("\(vm.cpuCount) cores / \(vm.memoryMB / 1024) GB")
                                .foregroundStyle(.secondary)
                        }
                        if let booted = vm.lastBootedAt {
                            LabeledContent("Last Booted") {
                                Text(booted.formatted(date: .abbreviated, time: .shortened))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        LabeledContent("Install Status") {
                            Toggle("Windows installed", isOn: Binding(
                                get: { vm.hasCompletedInstall },
                                set: { vmManager.markInstallComplete(vm, completed: $0) }
                            ))
                            .labelsHidden()
                        }

                        HStack(spacing: 8) {
                            Button("Reveal Disk in Finder") {
                                vmManager.revealDisk(vm)
                            }
                            .buttonStyle(.bordered)
                        }

                        if let details = vmManager.launchDiagnostics[vm.id] {
                            Divider()
                            Text("Last Launch Profile")
                                .font(.caption.bold())
                            Text(details)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }

                Text("Setup once and reuse forever: installed apps/games/logins stay in this VM disk.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
        }
    }

    private func createVM(name: String, guestOS: VMGuestOS, iso: URL?, diskGB: Int, cpu: Int, ram: Int) {
        Task {
            do {
                let resolvedISO: URL?
                if guestOS == .linuxUbuntuArm, iso == nil {
                    resolvedISO = try await vmManager.prepareLinuxInstallerISO()
                } else {
                    resolvedISO = iso
                }

                let vm = try vmManager.createVM(
                    name: name,
                    guestOS: guestOS,
                    isoURL: resolvedISO,
                    diskSizeGB: diskGB,
                    cpuCount: cpu,
                    memoryMB: ram
                )
                await MainActor.run {
                    selectedVMID = vm.id
                }
            } catch {
                await MainActor.run {
                    vmManager.lastErrorMessage = error.localizedDescription
                }
            }
        }
    }

    @ViewBuilder
    private func statusBadge(_ vm: WindowsVM) -> some View {
        let running = vmManager.runningVMIDs.contains(vm.id)
        Text(running ? "Running" : "Stopped")
            .font(.caption.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background((running ? Color.green : Color.secondary).opacity(0.15))
            .foregroundStyle(running ? .green : .secondary)
            .clipShape(Capsule())
    }
}

