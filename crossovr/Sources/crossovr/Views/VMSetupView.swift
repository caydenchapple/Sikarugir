import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct VMSetupView: View {
    @Environment(\.dismiss) private var dismiss
    let onCreate: (String, URL, Int, Int, Int) -> Void

    @State private var name = "Windows 11"
    @State private var isoURL: URL?
    @State private var diskGB: Int = 96
    @State private var cpuCount: Int = 4
    @State private var memoryMB: Int = 8192

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Create Real Windows VM")
                    .font(.title2.bold())
                Spacer()
            }
            .padding([.top, .horizontal], 20)
            .padding(.bottom, 14)

            Divider()

            Form {
                Section("VM") {
                    TextField("Name", text: $name)
                        .textFieldStyle(.roundedBorder)

                    HStack {
                        Text(isoURL?.lastPathComponent ?? "No ISO selected")
                            .foregroundStyle(isoURL == nil ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Choose ISO…") { chooseISO() }
                    }
                }

                Section("Resources") {
                    Stepper("Disk: \(diskGB) GB", value: $diskGB, in: 40...512, step: 8)
                    Stepper("CPU Cores: \(cpuCount)", value: $cpuCount, in: 2...16, step: 1)
                    Stepper("Memory: \(memoryMB / 1024) GB", value: $memoryMB, in: 4096...32768, step: 1024)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)
                Button("Create VM") {
                    guard let isoURL else { return }
                    onCreate(
                        name.trimmingCharacters(in: .whitespacesAndNewlines),
                        isoURL,
                        diskGB,
                        cpuCount,
                        memoryMB
                    )
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isoURL == nil)
            }
            .padding(16)
        }
        .frame(width: 560, height: 420)
    }

    private func chooseISO() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "iso") ?? .data]
        if panel.runModal() == .OK {
            isoURL = panel.url
        }
    }
}

