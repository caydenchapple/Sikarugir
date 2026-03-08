import SwiftUI

struct RealWindowsView: View {
    @StateObject private var vmManager = WindowsVMManager.shared
    @State private var selectedVMID: UUID?
    @State private var showSetup = false

    private var selectedVM: WindowsVM? {
        vmManager.vms.first(where: { $0.id == selectedVMID }) ?? vmManager.vms.first
    }

    var body: some View {
        NavigationSplitView {
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
        } detail: {
            if let vm = selectedVM {
                vmDetail(vm)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "desktopcomputer")
                        .font(.system(size: 44))
                        .foregroundStyle(.secondary)
                    Text("No Windows VM")
                        .font(.title3.bold())
                    Text("Create a VM to install real Windows 11.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Real Windows")
        .sheet(isPresented: $showSetup) {
            VMSetupView { name, iso, diskGB, cpu, ram in
                do {
                    let vm = try vmManager.createVM(
                        name: name,
                        isoURL: iso,
                        diskSizeGB: diskGB,
                        cpuCount: cpu,
                        memoryMB: ram
                    )
                    selectedVMID = vm.id
                } catch {
                    vmManager.lastErrorMessage = error.localizedDescription
                }
            }
        }
        .alert("VM Error", isPresented: Binding(
            get: { vmManager.lastErrorMessage != nil },
            set: { if !$0 { vmManager.lastErrorMessage = nil } }
        )) {
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
    }

    @ViewBuilder
    private func vmDetail(_ vm: WindowsVM) -> some View {
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
                    .disabled(vmManager.runningVMIDs.contains(vm.id))

                    Button {
                        vmManager.stop(vm)
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .buttonStyle(.bordered)
                    .disabled(!vmManager.runningVMIDs.contains(vm.id))

                    Button {
                        vmManager.resume(vm)
                    } label: {
                        Label("Resume", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
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
                    }
                }

                Text("Setup once and reuse forever: installed apps/games/logins stay in this VM disk.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
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

