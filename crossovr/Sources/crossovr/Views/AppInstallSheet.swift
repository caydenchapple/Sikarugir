import SwiftUI

/// Sheet shown when the user taps a known app in the catalog.
/// Automatically downloads the installer and launches Wine — no file picker needed.
struct AppInstallSheet: View {
    let app: WindowsApp

    @EnvironmentObject private var engineDownloader: EngineDownloader
    @EnvironmentObject private var bottleManager: BottleManager
    @EnvironmentObject private var systemDetector: SystemDetector

    @Environment(\.dismiss) private var dismiss

    // Config fields
    @State private var bottleName: String
    @State private var selectedEngineID: String = ""
    @State private var selectedBackend: GraphicsBackend
    @State private var selectedArch: BottleArch = .win64
    @State private var useRosetta: Bool = false
    @State private var customStoragePath: String? = nil

    // Flow state
    @State private var phase: Phase = .config
    @State private var downloadProgress: Double = 0
    @State private var downloadedExeURL: URL?
    @State private var createdBottle: Bottle?
    @State private var errorMessage: String?

    enum Phase {
        case config       // bottle config form
        case downloading  // fetching the installer
        case installing   // InstallWizardView active
        case failed       // download or create error
    }

    init(app: WindowsApp) {
        self.app = app
        _bottleName     = State(initialValue: app.name)
        _selectedBackend = State(initialValue:
            GraphicsBackend(rawValue: app.defaultBackend ?? "") ?? .dxvk
        )
    }

    var body: some View {
        switch phase {
        case .config:
            configSheet
        case .downloading:
            downloadingView
        case .installing:
            if let bottle = createdBottle, let exeURL = downloadedExeURL {
                InstallWizardView(bottle: bottle, preloadedExeURL: exeURL)
                    .environmentObject(bottleManager)
                    .environmentObject(engineDownloader)
            }
        case .failed:
            failedView
        }
    }

    // MARK: - Config sheet

    private var configSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            // App header
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(app.parsedIconColor)
                        .frame(width: 52, height: 52)
                    Image(systemName: app.sfSymbol)
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(app.name)
                        .font(.title2.bold())
                    HStack(spacing: 6) {
                        StarRatingView(stars: app.stars)
                        Text(app.compatibility.rawValue)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(app.compatibility.color)
                    }
                }
                Spacer()
                // Show "auto-install" badge when we have a URL
                if app.installerURL != nil {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down.circle.fill")
                        Text("Auto-install")
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.green.opacity(0.12))
                    .clipShape(Capsule())
                }
            }
            .padding([.horizontal, .top], 20)
            .padding(.bottom, 16)

            Divider()

            Form {
                Section("Bottle") {
                    TextField("Bottle name", text: $bottleName)
                        .textFieldStyle(.roundedBorder)
                    Picker("Architecture", selection: $selectedArch) {
                        ForEach(BottleArch.allCases, id: \.self) { arch in
                            Text(arch.rawValue == "win64" ? "64-bit (win64)" : "32-bit (win32)").tag(arch)
                        }
                    }
                }

                Section("Engine") {
                    if engineDownloader.installedEngines.isEmpty {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            Text("No engines installed. Download one from the Engines section first.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    } else {
                        Picker("Wine Engine", selection: $selectedEngineID) {
                            ForEach(engineDownloader.installedEngines) { e in
                                Text(e.displayName).tag(e.id)
                            }
                        }
                    }
                }

                Section("Graphics Backend") {
                    Picker("Backend", selection: $selectedBackend) {
                        ForEach(GraphicsBackend.allCases) { b in
                            Text(b.displayName).tag(b)
                                .disabled(!systemDetector.isBackendAvailable(b))
                        }
                    }
                    Text(selectedBackend.description)
                        .font(.caption).foregroundStyle(.secondary)
                }

                if !app.winetricksVerbs.isEmpty {
                    Section("Pre-install Components") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("These will be installed automatically before the app:")
                                .font(.caption).foregroundStyle(.secondary)
                            FlowLayout(spacing: 6) {
                                ForEach(app.winetricksVerbs, id: \.self) { verb in
                                    Text(verb)
                                        .font(.caption.monospaced())
                                        .padding(.horizontal, 8).padding(.vertical, 3)
                                        .background(Color(nsColor: .controlBackgroundColor))
                                        .clipShape(Capsule())
                                        .overlay(Capsule().stroke(Color(nsColor: .separatorColor), lineWidth: 1))
                                }
                            }
                        }
                    }
                }

                if systemDetector.isAppleSilicon {
                    Section("Apple Silicon") {
                        Toggle("Run via Rosetta 2 (x86_64)", isOn: $useRosetta)
                    }
                }

                Section("Storage") {
                    HStack(spacing: 8) {
                        Image(systemName: "folder")
                            .foregroundStyle(.secondary)
                        Text(customStoragePath.map { URL(fileURLWithPath: $0).deletingLastPathComponent().lastPathComponent } ?? "Default (App Support)")
                            .foregroundStyle(customStoragePath == nil ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Choose…") { chooseStorage() }
                            .font(.caption)
                        if customStoragePath != nil {
                            Button("Reset") { customStoragePath = nil }
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                    Text("Choose a custom folder on your Mac (e.g. an external drive).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            if let err = errorMessage {
                Text(err).foregroundStyle(.red).font(.callout).padding(.horizontal, 20)
            }

            Divider()

            HStack(spacing: 10) {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape)
                    .buttonStyle(.bordered)
                // Primary CTA changes label based on whether we can auto-download
                Button(app.installerURL != nil ? "Download & Install" : "Install \(app.name)…") {
                    beginInstall()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(selectedEngineID.isEmpty || bottleName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(16)
        }
        .frame(width: 480)
        .onAppear {
            selectedEngineID = engineDownloader.installedEngines.first?.id ?? ""
            let appDefault = GraphicsBackend(rawValue: app.defaultBackend ?? "")
            selectedBackend = appDefault.flatMap {
                systemDetector.isBackendAvailable($0) ? $0 : nil
            } ?? systemDetector.recommendedBackend
        }
    }

    // MARK: - Downloading view

    private var downloadingView: some View {
        VStack(spacing: 24) {
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(app.parsedIconColor)
                    .frame(width: 64, height: 64)
                Image(systemName: app.sfSymbol)
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(.white)
            }

            VStack(spacing: 8) {
                Text("Downloading \(app.name)…")
                    .font(.title3.bold())
                Text("Fetching the installer from the official source.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 6) {
                ProgressView(value: downloadProgress)
                    .frame(width: 300)
                    .tint(Color.accentColor)
                Text("\(Int(downloadProgress * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 420, height: 280)
        .padding(32)
    }

    // MARK: - Failed view

    private var failedView: some View {
        VStack(spacing: 20) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.red)
            Text("Download Failed")
                .font(.title2.bold())
            Text(errorMessage ?? "An unknown error occurred.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            HStack(spacing: 10) {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)
                Button("Retry") { phase = .config }
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(width: 420)
        .padding(32)
    }

    // MARK: - Install logic

    private func chooseStorage() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose Folder"
        panel.message = "Select where this bottle's data will be stored."
        if panel.runModal() == .OK, let url = panel.url {
            // We'll create a subfolder named after a placeholder UUID; the real ID is assigned at create time.
            customStoragePath = url.path
        }
    }

    private func beginInstall() {
        errorMessage = nil
        // Create the bottle first
        do {
            var bottle = try bottleManager.createBottle(
                name: bottleName.trimmingCharacters(in: .whitespaces),
                engineID: selectedEngineID,
                backend: selectedBackend,
                arch: selectedArch,
                useRosetta: useRosetta && systemDetector.isAppleSilicon
            )
            // Apply custom storage if chosen
            if let base = customStoragePath {
                try bottleManager.setCustomRoot(URL(fileURLWithPath: base).appendingPathComponent(bottle.id.uuidString).path, for: bottle)
                bottle = bottleManager.bottles.first(where: { $0.id == bottle.id }) ?? bottle
            }
            createdBottle = bottle
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        if let urlString = app.installerURL, let url = URL(string: urlString) {
            // Auto-download the installer
            phase = .downloading
            Task { await downloadInstaller(from: url) }
        } else {
            // No known URL — open file picker via InstallWizardView's select step
            downloadedExeURL = nil
            phase = .installing
        }
    }

    private func downloadInstaller(from url: URL) async {
        let filename = "\(app.id)-installer.\(url.pathExtension.isEmpty ? "exe" : url.pathExtension)"
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(filename)

        // Clean up any stale temp file
        try? FileManager.default.removeItem(at: destination)

        var progressObs: NSKeyValueObservation?

        do {
            let result = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
                let task = URLSession.shared.downloadTask(with: url) { tmpURL, _, error in
                    progressObs?.invalidate()
                    if let error = error { cont.resume(throwing: error); return }
                    guard let tmpURL else { cont.resume(throwing: URLError(.unknown)); return }
                    do {
                        try FileManager.default.moveItem(at: tmpURL, to: destination)
                        cont.resume(returning: destination)
                    } catch { cont.resume(throwing: error) }
                }
                progressObs = task.progress.observe(\.fractionCompleted, options: [.new]) { p, _ in
                    DispatchQueue.main.async { self.downloadProgress = p.fractionCompleted }
                }
                task.resume()
            }
            await MainActor.run {
                downloadedExeURL = result
                phase = .installing
            }
        } catch {
            progressObs?.invalidate()
            await MainActor.run {
                errorMessage = error.localizedDescription
                phase = .failed
                if let bottle = createdBottle {
                    try? bottleManager.deleteBottle(bottle)
                    createdBottle = nil
                }
            }
        }
    }
}
