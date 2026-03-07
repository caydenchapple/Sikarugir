import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var bottleManager: BottleManager
    @EnvironmentObject private var engineDownloader: EngineDownloader
    @EnvironmentObject private var systemDetector: SystemDetector

    @AppStorage("defaultBackend")    private var defaultBackend: String = GraphicsBackend.dxvk.rawValue
    @AppStorage("defaultArch")       private var defaultArch: String    = BottleArch.win64.rawValue
    @AppStorage("wineDebugLevel")    private var wineDebugLevel: String = "-all"
    @AppStorage("enableEsync")       private var enableEsync: Bool      = true
    @AppStorage("enableMSync")       private var enableMSync: Bool      = false
    @AppStorage("showConsoleOnLaunch") private var showConsole: Bool    = false
    @StateObject private var appUpdates = AppUpdateService()

    private enum SettingsTab: String, CaseIterable {
        case general  = "General"
        case graphics = "Graphics"
        case advanced = "Advanced"
        case about    = "About"

        var icon: String {
            switch self {
            case .general:  return "gearshape"
            case .graphics: return "display"
            case .advanced: return "terminal"
            case .about:    return "info.circle"
            }
        }
    }

    @State private var selectedTab: SettingsTab = .general

    var body: some View {
        TabView(selection: $selectedTab) {
            ForEach(SettingsTab.allCases, id: \.self) { tab in
                tabContent(for: tab)
                    .tabItem {
                        Label(tab.rawValue, systemImage: tab.icon)
                    }
                    .tag(tab)
            }
        }
        .frame(width: 500, height: 360)
    }

    @ViewBuilder
    private func tabContent(for tab: SettingsTab) -> some View {
        switch tab {
        case .general:  generalTab
        case .graphics: graphicsTab
        case .advanced: advancedTab
        case .about:    aboutTab
        }
    }

    // MARK: - General

    private var generalTab: some View {
        Form {
            Section("New Bottle Defaults") {
                Picker("Architecture", selection: $defaultArch) {
                    ForEach(BottleArch.allCases, id: \.rawValue) { a in
                        Text(a.rawValue).tag(a.rawValue)
                    }
                }

                Picker("Graphics Backend", selection: $defaultBackend) {
                    ForEach(GraphicsBackend.allCases) { b in
                        Text(b.displayName)
                            .tag(b.rawValue)
                            .disabled(!systemDetector.isBackendAvailable(b))
                    }
                }
            }

            Section("System") {
                LabeledContent("CPU Architecture") {
                    Text(systemDetector.isAppleSilicon ? "Apple Silicon (arm64)" : "Intel (x86_64)")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("macOS Version") {
                    Text(systemDetector.macOSVersionString)
                        .foregroundStyle(.secondary)
                }
                if systemDetector.isAppleSilicon {
                    LabeledContent("Rosetta 2") {
                        HStack {
                            Text(systemDetector.rosettaAvailable ? "Installed" : "Not installed")
                                .foregroundColor(systemDetector.rosettaAvailable ? .secondary : .orange)
                            if !systemDetector.rosettaAvailable {
                                Button("Install…") {
                                    systemDetector.installRosetta { _ in }
                                }
                                .font(.caption)
                            }
                        }
                    }
                }
            }

            Section("UI") {
                Toggle("Show output console when launching apps", isOn: $showConsole)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Graphics

    private var graphicsTab: some View {
        Form {
            Section("Available Backends") {
                ForEach(GraphicsBackend.allCases) { backend in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(backend.displayName).font(.body.weight(.medium))
                                if !systemDetector.isBackendAvailable(backend) {
                                    Text("Unavailable")
                                        .font(.caption.bold())
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 2)
                                        .background(Color.orange.opacity(0.15))
                                        .foregroundStyle(.orange)
                                        .clipShape(Capsule())
                                }
                            }
                            Text(backend.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: systemDetector.isBackendAvailable(backend)
                              ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(systemDetector.isBackendAvailable(backend) ? .green : .red)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Advanced

    private var advancedTab: some View {
        Form {
            Section("Wine Debug") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("WINEDEBUG level")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("-all", text: $wineDebugLevel)
                        .font(.system(.body, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                    Text("Use \"-all\" to silence debug output. Use \"+loaders,+relay\" for verbose tracing.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Section("Sync Primitives") {
                Toggle("Enable ESYNC (eventfd-based synchronisation)", isOn: $enableEsync)
                Toggle("Enable MSYNC (shared memory sync, Valve extension)", isOn: $enableMSync)
                    .disabled(!enableEsync)
                Text("ESYNC and MSYNC reduce CPU overhead in multi-threaded Windows games. Requires a Wine build that supports them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Storage") {
                LabeledContent("Bottles directory") {
                    Text("~/Library/Application Support/crossovr/Bottles")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Engines directory") {
                    Text("~/Library/Application Support/crossovr/Engines")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Button("Reveal in Finder") {
                    let support = FileManager.default.urls(
                        for: .applicationSupportDirectory, in: .userDomainMask).first!
                    NSWorkspace.shared.open(support.appendingPathComponent("crossovr"))
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - About

    private var aboutTab: some View {
        VStack(spacing: 16) {
            Image(systemName: "wineglass.fill")
                .font(.system(size: 60))
                .foregroundStyle(Color.accentColor)

            Text("crossovr")
                .font(.title.bold())

            Text("An open-source CrossOver alternative for macOS.\nRun Windows applications on Intel and Apple Silicon.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .font(.callout)

            Divider()

            VStack(spacing: 6) {
                Link("Source code on GitHub", destination: URL(string: "https://github.com/Sikarugir-App/Sikarugir-foss-sources")!)
                Link("Report a bug", destination: URL(string: "https://github.com/Sikarugir-App/Sikarugir/issues")!)
                Link("D3DMetal License (Apple GPTK)", destination: URL(string: "https://developer.apple.com/games/")!)
            }
            .font(.callout)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("App Updates")
                        .font(.headline)
                    Spacer()
                    Text("Current: \(appUpdates.currentVersion)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 10) {
                    Button {
                        Task { await appUpdates.checkForUpdates() }
                    } label: {
                        Label("Check for Updates", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(appUpdates.isChecking)

                    if let latest = appUpdates.latestVersion,
                       latest != appUpdates.currentVersion,
                       appUpdates.updateURL != nil {
                        Button {
                            appUpdates.openUpdatePage()
                        } label: {
                            Label("Download \(latest)", systemImage: "square.and.arrow.down")
                        }
                        .buttonStyle(.bordered)
                    }
                }

                if !appUpdates.statusMessage.isEmpty {
                    Text(appUpdates.statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text("Bottles, Steam/Epic login sessions, and installed game files stay in Application Support and are preserved across app updates.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer()

            Text("Built with Swift + SwiftUI  ·  macOS 13+")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
