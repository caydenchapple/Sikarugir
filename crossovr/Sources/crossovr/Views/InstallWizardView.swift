import SwiftUI
import UniformTypeIdentifiers

/// A multi-step wizard for installing a Windows .exe into a bottle.
struct InstallWizardView: View {
    @EnvironmentObject private var bottleManager: BottleManager
    @EnvironmentObject private var engineDownloader: EngineDownloader
    @Environment(\.dismiss) private var dismiss

    let bottle: Bottle
    /// When provided by the catalog install flow, the file-select step is skipped.
    var preloadedExeURL: URL? = nil

    enum Step: Int, CaseIterable {
        case selectFile   = 0
        case configure    = 1
        case installing   = 2
        case done         = 3
    }

    @State private var currentStep: Step = .selectFile
    @State private var selectedExeURL: URL?
    @State private var extraArgs: String = ""
    @State private var outputLines: [String] = []
    @State private var installError: String?
    @State private var installSuccess: Bool = false

    // Done-step state
    @State private var foundExes: [(url: URL, isGame: Bool)] = []
    @State private var selectedShortcutExe: URL?
    @State private var selectedExeIsGame: Bool = false
    @State private var shortcutName: String = ""
    @State private var shortcutSymbol: String = "app.fill"
    @State private var shortcutColor: String = "#5A6EAA"
    @State private var shortcutIsGame: Bool = false
    @State private var savedToLibrary: Bool = false
    @State private var launchAfterSave: Bool = false

    var engine: WineEngine? {
        engineDownloader.availableEngines.first { $0.id == bottle.engineID }
    }

    /// The up-to-date bottle from BottleManager (includes installedApps mutations).
    private var liveBottle: Bottle {
        bottleManager.bottles.first { $0.id == bottle.id } ?? bottle
    }

    var body: some View {
        VStack(spacing: 0) {
            stepIndicator
                .padding(.top, 20)
                .padding(.bottom, 16)

            Divider()

            Group {
                switch currentStep {
                case .selectFile:  selectFileStep
                case .configure:   configureStep
                case .installing:  installingStep
                case .done:        doneStep
                }
            }
            .padding(24)
            .frame(maxHeight: .infinity, alignment: .top)

            Divider()
            navigationButtons
                .padding(16)
        }
        .frame(width: 540, height: 520)
        .onAppear {
            if let url = preloadedExeURL {
                selectedExeURL = url
                currentStep = .configure
            }
        }
    }

    // MARK: - Step indicator

    private var stepIndicator: some View {
        HStack(spacing: 0) {
            ForEach(Step.allCases, id: \.rawValue) { step in
                HStack(spacing: 4) {
                    ZStack {
                        Circle()
                            .fill(step.rawValue <= currentStep.rawValue ? Color.accentColor : Color.secondary.opacity(0.2))
                            .frame(width: 24, height: 24)
                        Text("\(step.rawValue + 1)")
                            .font(.caption.bold())
                            .foregroundStyle(step.rawValue <= currentStep.rawValue ? .white : .secondary)
                    }
                    Text(stepLabel(step))
                        .font(.caption)
                        .foregroundStyle(step == currentStep ? .primary : .secondary)
                }
                if step != Step.allCases.last {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.3))
                        .frame(height: 1)
                        .padding(.horizontal, 8)
                }
            }
        }
        .padding(.horizontal, 24)
    }

    private func stepLabel(_ step: Step) -> String {
        switch step {
        case .selectFile:  return "Select"
        case .configure:   return "Configure"
        case .installing:  return "Install"
        case .done:        return "Done"
        }
    }

    // MARK: - Step views

    private var selectFileStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Select Installer")
                .font(.title3.bold())
            Text("Choose the Windows .exe or .msi file you want to install into \"\(bottle.name)\".")
                .foregroundStyle(.secondary)

            HStack {
                if let url = selectedExeURL {
                    Image(systemName: "doc.fill")
                        .foregroundStyle(Color.accentColor)
                    Text(url.lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("No file selected")
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button("Browse…") { browseForExe() }
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2), lineWidth: 1))

            Text("Installing in: \(bottle.name)  ·  Engine: \(engine?.displayName ?? "—")")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var configureStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Configure Installation")
                .font(.title3.bold())

            LabeledContent("Installer") {
                Text(selectedExeURL?.lastPathComponent ?? "—")
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Bottle") {
                Text(bottle.name)
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Backend") {
                Text(bottle.backend.displayName)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Extra arguments (optional)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("/silent /norestart", text: $extraArgs)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }
        }
    }

    private var installingStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Installing…")
                    .font(.title3.bold())
                Spacer()
                ProgressView().scaleEffect(0.8)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(outputLines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(line.hasPrefix("ERR") ? .red : .primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Color.clear.frame(height: 1).id("console-bottom")
                    }
                    .padding(8)
                }
                .frame(maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .onChange(of: outputLines.count) { _ in
                    withAnimation { proxy.scrollTo("console-bottom") }
                }
            }

            if let error = installError {
                Text(error).font(.callout).foregroundStyle(.red)
            }
        }
    }

    // MARK: - Done step (fully revamped)

    private var doneStep: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Status header
                HStack(spacing: 12) {
                    Group {
                        if installSuccess && installError == nil {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        } else if installSuccess && installError != nil {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        } else {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                        }
                    }
                    .font(.system(size: 40))
                    VStack(alignment: .leading, spacing: 2) {
                        Group {
                            if installSuccess && installError == nil {
                                Text("Installation Complete")
                            } else if installSuccess && installError != nil {
                                Text("Installer Finished with Warning")
                            } else {
                                Text("Installation Failed")
                            }
                        }
                        .font(.title3.bold())
                        Text(installError ?? "Installed into \"\(bottle.name)\"")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                if installSuccess {
                    Divider()

                    if savedToLibrary {
                        // Confirmation card
                        VStack(spacing: 12) {
                            HStack(spacing: 6) {
                                Image(systemName: "wand.and.stars")
                                Text("Auto-added from install")
                            }
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.green)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.green.opacity(0.12))
                            .clipShape(Capsule())

                            Image(systemName: "checkmark.seal.fill")
                                .font(.system(size: 36))
                                .foregroundStyle(.green)
                            Text("\"\(shortcutName)\" added to your library!")
                                .font(.headline)
                            Text(shortcutIsGame
                                 ? "You can now launch it from Home or the Games tab."
                                 : "You can now launch it from the Home screen.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(20)
                        .background(Color.green.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    } else {
                        // Exe picker
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Add to Your Library")
                                .font(.headline)
                            Text("Select the app's main executable so you can launch it from the Home screen.")
                                .font(.callout)
                                .foregroundStyle(.secondary)

                            if foundExes.isEmpty {
                                HStack(spacing: 8) {
                                    ProgressView().scaleEffect(0.7)
                                    Text("Scanning for installed apps…")
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                }
                            } else {
                                ScrollView {
                                    VStack(spacing: 4) {
                                        ForEach(foundExes.indices, id: \.self) { index in
                                            let item = foundExes[index]
                                            exeRow(url: item.url, isGame: item.isGame, isSelected: selectedShortcutExe == item.url)
                                        }
                                    }
                                }
                                .frame(maxHeight: 160)
                                .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                                .clipShape(RoundedRectangle(cornerRadius: 8))

                                if selectedShortcutExe != nil {
                                    VStack(alignment: .leading, spacing: 8) {
                                        Divider()
                                        Text("Shortcut name:")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        TextField("App name", text: $shortcutName)
                                            .textFieldStyle(.roundedBorder)

                                        Toggle(isOn: $shortcutIsGame) {
                                            Label("This is a game", systemImage: "gamecontroller")
                                                .font(.callout)
                                        }
                                        .toggleStyle(.switch)
                                        .controlSize(.small)

                                        Button {
                                            saveToLibrary()
                                        } label: {
                                            Label("Add to Library", systemImage: "plus.app.fill")
                                                .frame(maxWidth: .infinity)
                                                .font(.body.weight(.semibold))
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .disabled(shortcutName.trimmingCharacters(in: .whitespaces).isEmpty)
                                    }
                                }
                            }

                            // Manual browse button if scan found nothing useful
                            Button {
                                browseForShortcutExe()
                            } label: {
                                Label("Browse for executable manually…", systemImage: "folder")
                                    .font(.callout)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.accentColor)
                        }
                        .padding(14)
                        .background(Color(nsColor: .controlBackgroundColor).opacity(0.4))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func exeRow(url: URL, isGame: Bool, isSelected: Bool) -> some View {
        Button {
            selectedShortcutExe = url
            selectedExeIsGame = isGame
            shortcutIsGame = isGame
            if shortcutName.isEmpty {
                shortcutName = url.deletingPathExtension().lastPathComponent
            }
            if isGame {
                shortcutSymbol = "gamecontroller.fill"
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isGame ? "gamecontroller.fill" : "doc.fill")
                    .foregroundStyle(isSelected ? .white : (isGame ? .green : .secondary))
                VStack(alignment: .leading, spacing: 1) {
                    Text(url.deletingPathExtension().lastPathComponent)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(isSelected ? .white : .primary)
                    Text(relativeExePath(url))
                        .font(.caption.monospaced())
                        .foregroundStyle(isSelected ? .white.opacity(0.8) : .secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                if isGame {
                    Text("Game")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(isSelected ? .white : .green)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background((isSelected ? .white : Color.green).opacity(0.15))
                        .clipShape(Capsule())
                }
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.white)
                        .font(.caption.bold())
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isSelected ? Color.accentColor : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Navigation buttons

    private var navigationButtons: some View {
        HStack {
            if currentStep != .done {
                Button("Cancel") { dismiss() }
            }
            Spacer()
            switch currentStep {
            case .selectFile:
                Button("Next") { currentStep = .configure }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedExeURL == nil)
            case .configure:
                Button("Back") { currentStep = .selectFile }
                Button("Install") { startInstall() }
                    .buttonStyle(.borderedProminent)
            case .installing:
                EmptyView()
            case .done:
                if installSuccess, let exeURL = selectedShortcutExe, !savedToLibrary {
                    Button("Launch Now") { launchNow(exeURL) }
                        .buttonStyle(.bordered)
                }
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - Helpers

    private func browseForExe() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            UTType(filenameExtension: "exe") ?? .data,
            UTType(filenameExtension: "msi") ?? .data
        ]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK {
            selectedExeURL = panel.url
        }
    }

    private func browseForShortcutExe() {
        let panel = NSOpenPanel()
        panel.directoryURL = liveBottle.driveCURL
        panel.allowedContentTypes = [UTType(filenameExtension: "exe") ?? .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            selectedShortcutExe = url
            shortcutName = url.deletingPathExtension().lastPathComponent
        }
    }

    private func startInstall() {
        guard let exeURL = selectedExeURL, let engine = engine else { return }
        currentStep = .installing
        outputLines.removeAll()
        installError = nil

        let isMSI = exeURL.pathExtension.lowercased() == "msi"
        
        // Build arguments
        let extra = extraArgs.trimmingCharacters(in: .whitespaces)
        var allArgs: [String] = []
        if isMSI {
            allArgs = ["/i", exeURL.path, "/qn"]  // /qn = quiet install for MSI
        } else {
            allArgs = extra.isEmpty ? [] : extra.components(separatedBy: " ")
        }

        Task {
            do {
                let stream = try WineManager.shared.launchExecutable(
                    at: exeURL, bottle: bottle, engine: engine, extraArgs: allArgs
                )
                for await output in stream {
                    switch output {
                    case .stdout(let line):
                        await MainActor.run { outputLines.append(line) }
                    case .stderr(let line):
                        await MainActor.run { outputLines.append("ERR: \(line)") }
                    case .exit(let code):
                        await MainActor.run {
                            outputLines.append("Exited with code \(code)")
                            // Many online installers (e.g. SteamSetup.exe) launch a
                            // bootstrapper and exit with code 1 as normal behaviour.
                            // Treat any exit as "potentially succeeded" and always scan
                            // for newly installed executables. Only surface the exit code
                            // as a warning — not a hard failure — so the user can still
                            // add the app to their library if files were installed.
                            let hardFailure = code < 0  // -1 means Wine itself failed to start
                            installSuccess = !hardFailure
                            if code > 0 {
                                installError = "Installer exited with code \(code) — this may be normal for online installers. Check below for installed apps."
                            } else if hardFailure {
                                installError = "Wine failed to start. Check that your engine is installed correctly."
                            }
                            currentStep = .done
                            bottleManager.refreshInstalledApps(for: liveBottle)
                            scanForExecutables()
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    installError = error.localizedDescription
                    installSuccess = false
                    currentStep = .done
                }
            }
        }
    }

    /// Scans drive_c/Program Files for .exe files (depth ≤ 3).
    /// Returns executables with a flag indicating if it's likely a game.
    private func scanForExecutables() {
        let driveC = liveBottle.driveCURL
        Task.detached(priority: .userInitiated) {
            var results: [(url: URL, isGame: Bool)] = []
            let searchDirs = [
                driveC.appendingPathComponent("Program Files"),
                driveC.appendingPathComponent("Program Files (x86)")
            ]
            let fm = FileManager.default
            
            // Keywords that suggest this is a GAME (not a launcher/app)
            let gameIndicators = [
                "game", "play", "run", "launch",
                // Common game executables
                "cs2", "csgo", "dota", "fortnite", "valorant", "apex",
                "pubg", "minecraft", "gta", "witcher", "skyrim", "fallout",
                "cod", "battlefield", "overwatch", "rocketleague", "rl",
                "rainbow", "siege", "r6", "apex", "legends",
                // Game platform specific patterns
                "-win", "_game", "-game", "game_launcher"
            ]
            
            // Keywords that suggest this is a LAUNCHER/APP (not a game)
            let launcherIndicators = [
                "launcher", "steam", "epic", "gog", "galaxy",
                "origin", "ea", "uplay", "ubisoft", "battle.net", "battlenet",
                "support", "center", "client", "helper"
            ]

            let hardBlockExecutables: Set<String> = [
                // Windows/system apps that should never be auto-selected
                "wmplayer", "iexplore", "explorer", "regedit", "notepad",
                "wordpad", "write", "mspaint", "calc", "taskmgr",
                "rundll32", "wineboot", "winedbg"
            ]

            let bottleTokens: [String] = bottle.name
                .lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count >= 3 }
            
            for dir in searchDirs {
                guard fm.fileExists(atPath: dir.path) else { continue }
                if let enumerator = fm.enumerator(
                    at: dir,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                ) {
                    for case let url as URL in enumerator {
                        // Limit depth
                        let relative = url.path.replacingOccurrences(of: dir.path, with: "")
                        let depth = relative.components(separatedBy: "/").count - 1
                        if depth > 4 { enumerator.skipDescendants(); continue }
                        if url.pathExtension.lowercased() == "exe" {
                            // Skip installers, updaters, uninstallers, and helper executables
                            let name = url.deletingPathExtension().lastPathComponent.lowercased()
                            let skip = [
                                // Installers and setups
                                "install", "setup", "installer", "bootstrapper", "launcher_setup",
                                "setuplauncher", "selfextractor", "selfextract", "extract",
                                // Updates and patches
                                "update", "updater", "patch", "patcher", "upgrade",
                                // Uninstallers
                                "uninstall", "uninst", "uninstaller", "remove",
                                // Redistributables and prerequisites
                                "redist", "vcredist", "dxsetup", "dotnet", "prerequisite",
                                "windowsinstaller", "msiexec", "regsvr32",
                                // Helpers and support tools
                                "crash", "crashhandler", "crashreport", "crashreporter",
                                "helper", "supporttool", "diagnostic", "repair",
                                // Temporary or cache files
                                "temp", "tmp", "cache",
                                // Downloaders
                                "downloader", "downloadhelper"
                            ]
                            if !skip.contains(where: { name.contains($0) }) &&
                                !hardBlockExecutables.contains(name) &&
                                !url.path.lowercased().contains("/windows media player/") {
                                // Determine if this is likely a game
                                let isGame = gameIndicators.contains(where: { name.contains($0) }) &&
                                            !launcherIndicators.contains(where: { name.contains($0) })
                                // Score candidate; prioritize executables matching bottle name tokens.
                                var score = 0
                                for token in bottleTokens {
                                    if name.contains(token) { score += 120 }
                                    if url.path.lowercased().contains("/\(token)/") { score += 40 }
                                }
                                if isGame { score += 30 }
                                results.append((url: url, isGame: isGame || score >= 140))
                            }
                        }
                    }
                }
            }
            let sorted = results.sorted { lhs, rhs in
                // Prefer paths that look relevant to current bottle name
                let lhsName = lhs.url.deletingPathExtension().lastPathComponent.lowercased()
                let rhsName = rhs.url.deletingPathExtension().lastPathComponent.lowercased()
                let lhsMatches = bottleTokens.reduce(0) { $0 + (lhsName.contains($1) ? 1 : 0) }
                let rhsMatches = bottleTokens.reduce(0) { $0 + (rhsName.contains($1) ? 1 : 0) }
                if lhsMatches != rhsMatches { return lhsMatches > rhsMatches }
                return lhs.url.lastPathComponent < rhs.url.lastPathComponent
            }
            await MainActor.run {
                foundExes = sorted
                // Auto-select the first game if found, otherwise first app
                if let firstGame = sorted.first(where: { $0.isGame }) {
                    selectedShortcutExe = firstGame.url
                    selectedExeIsGame = true
                    shortcutIsGame = true
                    shortcutName = firstGame.url.deletingPathExtension().lastPathComponent
                    shortcutSymbol = "gamecontroller.fill"
                    // Whisky-style flow: auto-pin detected primary game entry.
                    saveToLibrary()
                } else if let first = sorted.first {
                    selectedShortcutExe = first.url
                    selectedExeIsGame = first.isGame
                    shortcutIsGame = first.isGame
                    shortcutName = first.url.deletingPathExtension().lastPathComponent
                    if first.isGame {
                        shortcutSymbol = "gamecontroller.fill"
                    }
                    // If no game marker exists, still auto-pin the best candidate.
                    saveToLibrary()
                }
            }
        }
    }

    private func saveToLibrary() {
        guard let exeURL = selectedShortcutExe else { return }
        let trimmedName = shortcutName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        let app = InstalledApp(
            name: trimmedName,
            exePath: exeURL.path,
            sfSymbol: shortcutIsGame ? "gamecontroller.fill" : shortcutSymbol,
            iconColor: shortcutColor,
            isGame: shortcutIsGame
        )
        try? bottleManager.addApp(app, to: liveBottle)
        savedToLibrary = true
    }

    private func launchNow(_ exeURL: URL) {
        guard let eng = engine else { return }
        Task {
            _ = try? WineManager.shared.launchExecutable(at: exeURL, bottle: liveBottle, engine: eng)
        }
    }

    private func relativeExePath(_ url: URL) -> String {
        let prefix = liveBottle.prefixURL.path
        var p = url.path
        if p.hasPrefix(prefix) { p.removeFirst(prefix.count) }
        return p
    }
}
