import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct VMSetupView: View {
    @Environment(\.dismiss) private var dismiss
    let onCreate: (String, VMGuestOS, URL?, Int, Int, Int) -> Void

    @State private var name = "Windows 11"
    @State private var guestOS: VMGuestOS = .windows11Arm
    @State private var isoURL: URL?
    @State private var diskGB: Int = 96
    @State private var cpuCount: Int = 4
    @State private var memoryMB: Int = 8192
    @State private var showAdvanced = false
    @AppStorage("defaultWindowsISOPath") private var defaultWindowsISOPath: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Create VM")
                    .font(.title2.bold())
                Spacer()
            }
            .padding([.top, .horizontal], 20)
            .padding(.bottom, 14)

            Divider()

            Form {
                Section("Quick Setup") {
                    Picker("OS", selection: $guestOS) {
                        ForEach(VMGuestOS.allCases, id: \.self) { os in
                            Text(os.displayName).tag(os)
                        }
                    }

                    TextField("Name", text: $name)
                        .textFieldStyle(.roundedBorder)

                    if guestOS == .windows11Arm {
                        HStack {
                            Text(isoURL?.lastPathComponent ?? "Choose Windows 11 ISO (one-time)")
                                .foregroundStyle(isoURL == nil ? .secondary : .primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button("Choose ISO…") { chooseISO() }
                        }

                        if isoURL == nil {
                            Button {
                                openWindowsISODownloadPage()
                            } label: {
                                Label("Download Windows ISO", systemImage: "arrow.down.circle")
                            }
                            .buttonStyle(.bordered)
                        }
                    } else {
                        Label("Ubuntu ARM64 ISO will be downloaded automatically.", systemImage: "arrow.down.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Text(guestOS == .windows11Arm
                         ? "After you choose ISO once, future VMs only need name + Create."
                         : "Linux VM setup is one-click: name + Create.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Toggle("Customize resources (advanced)", isOn: $showAdvanced)
                }

                if showAdvanced {
                    Section("Resources") {
                        Stepper("Disk: \(diskGB) GB", value: $diskGB, in: 40...512, step: 8)
                        Stepper("CPU Cores: \(cpuCount)", value: $cpuCount, in: 2...16, step: 1)
                        Stepper("Memory: \(memoryMB / 1024) GB", value: $memoryMB, in: 4096...32768, step: 1024)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)
                Button("Create VM") {
                    onCreate(
                        name.trimmingCharacters(in: .whitespacesAndNewlines),
                        guestOS,
                        isoURL,
                        diskGB,
                        cpuCount,
                        memoryMB
                    )
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                    (guestOS == .windows11Arm && isoURL == nil)
                )
            }
            .padding(16)
        }
        .frame(width: 560, height: 420)
        .onAppear {
            // Auto-reuse last chosen ISO for one-click VM creation.
            if isoURL == nil, !defaultWindowsISOPath.isEmpty {
                let url = URL(fileURLWithPath: defaultWindowsISOPath)
                if FileManager.default.fileExists(atPath: url.path) {
                    isoURL = url
                }
            }
        }
        .onChange(of: guestOS) { os in
            if os == .linuxUbuntuArm {
                name = "Ubuntu Linux"
            } else if name == "Ubuntu Linux" {
                name = "Windows 11"
            }
        }
    }

    private func chooseISO() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "iso") ?? .data]
        if panel.runModal() == .OK {
            isoURL = panel.url
            if let p = panel.url?.path {
                defaultWindowsISOPath = p
            }
        }
    }

    private func openWindowsISODownloadPage() {
        guard let url = URL(string: "https://www.microsoft.com/software-download/windows11") else { return }
        NSWorkspace.shared.open(url)
    }
}

