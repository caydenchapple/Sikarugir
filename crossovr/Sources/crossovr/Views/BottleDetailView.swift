import SwiftUI
import UniformTypeIdentifiers

struct BottleDetailView: View {
    @EnvironmentObject private var bottleManager: BottleManager
    @EnvironmentObject private var engineDownloader: EngineDownloader
    @EnvironmentObject private var systemDetector: SystemDetector

    var bottle: Bottle

    @State private var editedBottle: Bottle
    @State private var showInstallWizard = false
    @State private var showWinetricksSheet = false
    @State private var isEditing = false
    @State private var saveError: String?
    @State private var outputLines: [String] = []
    @State private var isRunning = false
    @State private var showOutputConsole = false
    @State private var showDeleteConfirm = false
    @State private var showAddAppSheet = false

    init(bottle: Bottle) {
        self.bottle = bottle
        _editedBottle = State(initialValue: bottle)
    }

    var engine: WineEngine? {
        engineDownloader.availableEngines.first { $0.id == editedBottle.engineID }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerSection
                Divider()
                configSection
                Divider()
                actionsSection
                // Installed apps for this bottle
                let liveApps = bottleManager.bottles.first(where: { $0.id == editedBottle.id })?.installedApps ?? []
                if !liveApps.isEmpty {
                    Divider()
                    installedAppsSection(liveApps)
                }
                if showOutputConsole {
                    Divider()
                    consoleSection
                }
            }
            .padding(24)
        }
        .navigationTitle(editedBottle.name)
        .toolbar { toolbarContent }
        .sheet(isPresented: $showInstallWizard) {
            InstallWizardView(bottle: editedBottle)
                .environmentObject(bottleManager)
                .environmentObject(engineDownloader)
        }
        .sheet(isPresented: $showWinetricksSheet) {
            WinetricksSheet(bottle: editedBottle)
                .environmentObject(engineDownloader)
        }
        .sheet(isPresented: $showAddAppSheet) {
            AddAppShortcutSheet(bottle: editedBottle)
                .environmentObject(bottleManager)
        }
        .confirmationDialog(
            "Delete \"\(editedBottle.name)\"?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete Bottle", role: .destructive) {
                deleteBottle()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete the bottle and all of its contents. This cannot be undone.")
        }
        .onChange(of: bottle) { newVal in
            editedBottle = newVal
        }
    }

    private func deleteBottle() {
        do {
            try bottleManager.deleteBottle(editedBottle)
        } catch {
            saveError = error.localizedDescription
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(spacing: 16) {
            Image(systemName: "wineglass.fill")
                .font(.system(size: 44))
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 4) {
                if isEditing {
                    TextField("Bottle name", text: $editedBottle.name)
                        .font(.title2.bold())
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 280)
                } else {
                    Text(editedBottle.name)
                        .font(.title2.bold())
                }
                Text("Created \(editedBottle.createdAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    // MARK: - Configuration

    private var configSection: some View {
        GroupBox("Configuration") {
            Form {
                LabeledContent("Engine") {
                    if isEditing {
                        Picker("", selection: $editedBottle.engineID) {
                            ForEach(engineDownloader.installedEngines) { e in
                                Text(e.displayName).tag(e.id)
                            }
                        }
                        .labelsHidden()
                    } else {
                        Text(engine?.displayName ?? editedBottle.engineID)
                    }
                }

                LabeledContent("Graphics Backend") {
                    if isEditing {
                        Picker("", selection: $editedBottle.backend) {
                            ForEach(GraphicsBackend.allCases) { b in
                                Text(b.displayName).tag(b)
                                    .disabled(!systemDetector.isBackendAvailable(b))
                            }
                        }
                        .labelsHidden()
                    } else {
                        HStack {
                            Text(editedBottle.backend.displayName)
                            if editedBottle.backend.requiresAppleSilicon && !systemDetector.isAppleSilicon {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                    .help("This backend requires Apple Silicon.")
                            }
                        }
                    }
                }

                LabeledContent("Architecture") {
                    if isEditing {
                        Picker("", selection: $editedBottle.arch) {
                            ForEach(BottleArch.allCases, id: \.self) { a in
                                Text(a.rawValue).tag(a)
                            }
                        }
                        .labelsHidden()
                    } else {
                        Text(editedBottle.arch.rawValue)
                    }
                }

                if systemDetector.isAppleSilicon {
                    LabeledContent("Rosetta 2") {
                        if isEditing {
                            Toggle("", isOn: $editedBottle.useRosetta)
                                .labelsHidden()
                        } else {
                            Text(editedBottle.useRosetta ? "Enabled" : "Disabled")
                        }
                    }
                }

                LabeledContent("Storage Location") {
                    if isEditing {
                        HStack(spacing: 6) {
                            Text(editedBottle.customRootPath ?? "Default (App Support)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Button("Choose…") { chooseStorageLocation() }
                                .font(.caption)
                            if editedBottle.customRootPath != nil {
                                Button("Reset") { editedBottle.customRootPath = nil }
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                        }
                    } else {
                        Text(editedBottle.customRootPath ?? "Default")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                LabeledContent("Prefix Path") {
                    Text(editedBottle.prefixPath)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .formStyle(.grouped)
        }
    }

    // MARK: - Actions

    private var actionsSection: some View {
        GroupBox("Actions") {
            HStack(spacing: 12) {
                Button {
                    showInstallWizard = true
                } label: {
                    Label("Install App…", systemImage: "arrow.down.app")
                }
                .buttonStyle(.borderedProminent)
                .disabled(engine == nil)

                Button {
                    showWinetricksSheet = true
                } label: {
                    Label("Winetricks…", systemImage: "wrench.and.screwdriver")
                }
                .disabled(engine == nil)

                Button {
                    runWinecfg()
                } label: {
                    Label("Wine Config", systemImage: "slider.horizontal.3")
                }
                .disabled(engine == nil || isRunning)

                Button {
                    runExplorer()
                } label: {
                    Label("Explorer", systemImage: "folder.fill.badge.plus")
                }
                .disabled(engine == nil || isRunning)

                Button {
                    openWindowsDesktop()
                } label: {
                    Label("Open Windows Desktop", systemImage: "desktopcomputer")
                }
                .disabled(engine == nil || isRunning)

                Button {
                    refreshInstalledApps()
                } label: {
                    Label("Refresh Apps", systemImage: "arrow.clockwise")
                }
                .disabled(isRunning)

                Spacer()

                Button {
                    killWineServer()
                } label: {
                    Label("Kill Server", systemImage: "stop.circle")
                }
                .foregroundStyle(.red)
                .disabled(engine == nil)
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Installed Apps

    @ViewBuilder
    private func installedAppsSection(_ apps: [InstalledApp]) -> some View {
        GroupBox {
            VStack(spacing: 0) {
                ForEach(apps) { app in
                    HStack(spacing: 12) {
                        // Icon
                        ZStack {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(app.parsedIconColor)
                                .frame(width: 36, height: 36)
                            Image(systemName: app.sfSymbol)
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(.white)
                        }
                        // Name + path
                        VStack(alignment: .leading, spacing: 2) {
                            Text(app.name)
                                .font(.callout.weight(.semibold))
                            Text(app.exePath)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        // Launch button
                        Button {
                            launchInstalledApp(app)
                        } label: {
                            Label("Launch", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(engine == nil)

                        // Remove button
                        Button(role: .destructive) {
                            try? bottleManager.removeApp(app, from: editedBottle)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.red)
                    }
                    .padding(.vertical, 8)
                    if app.id != apps.last?.id {
                        Divider()
                    }
                }
            }
            .padding(.vertical, 4)
        } label: {
            HStack {
                Text("Installed Apps")
                Spacer()
                Button {
                    showAddAppSheet = true
                } label: {
                    Label("Add App…", systemImage: "plus")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }
        }
    }

    private func launchInstalledApp(_ app: InstalledApp) {
        guard let eng = engine else { return }
        showOutputConsole = true
        isRunning = true
        outputLines.append("Launching \(app.name)…")

        Task {
            do {
                let stream = try WineManager.shared.launchInstalledApp(
                    app,
                    bottle: editedBottle,
                    engine: eng
                )
                for await output in stream {
                    switch output {
                    case .stdout(let line): await MainActor.run { outputLines.append(line) }
                    case .stderr(let line): await MainActor.run { outputLines.append("ERR: \(line)") }
                    case .exit(let code):   await MainActor.run {
                        outputLines.append("Exited (\(code))")
                        isRunning = false
                    }
                    }
                }
            } catch {
                await MainActor.run {
                    outputLines.append("Error: \(error.localizedDescription)")
                    isRunning = false
                }
            }
        }
    }

    // MARK: - Console

    private var consoleSection: some View {
        GroupBox {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(outputLines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(line.hasPrefix("ERR") ? .red : .primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(8)
                }
                .onChange(of: outputLines.count) { _ in
                    withAnimation { proxy.scrollTo("bottom") }
                }
            }
            .frame(height: 160)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        } label: {
            HStack {
                Text("Output Console")
                Spacer()
                if isRunning {
                    ProgressView().scaleEffect(0.6)
                }
                Button {
                    outputLines.removeAll()
                    showOutputConsole = false
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .destructiveAction) {
            Button(role: .destructive) {
                showDeleteConfirm = true
            } label: {
                Label("Delete Bottle", systemImage: "trash")
                    .foregroundStyle(.red)
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if isEditing {
                Button("Cancel") {
                    editedBottle = bottle
                    isEditing = false
                }
                Button("Save") {
                    saveChanges()
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button {
                    isEditing = true
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
            }
        }
    }

    // MARK: - Helpers

    private func saveChanges() {
        do {
            try bottleManager.updateBottle(editedBottle)
            isEditing = false
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func chooseStorageLocation() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose Storage Folder"
        panel.message = "Select a folder to store this bottle's data."
        if panel.runModal() == .OK, let url = panel.url {
            editedBottle.customRootPath = url.appendingPathComponent(editedBottle.id.uuidString).path
        }
    }

    private func runWinecfg() {
        guard let engine = engine else { return }
        Task {
            await runWineProgram("winecfg", engine: engine)
        }
    }

    private func runExplorer() {
        guard let engine = engine else { return }
        Task {
            await runWineProgram("explorer", engine: engine)
        }
    }

    private func openWindowsDesktop() {
        guard let engine = engine else { return }
        showOutputConsole = true
        isRunning = true
        outputLines.append("Opening Windows desktop shell…")
        Task {
            do {
                let stream = try WineManager.shared.launchWindowsDesktop(
                    bottle: editedBottle,
                    engine: engine
                )
                for await output in stream {
                    switch output {
                    case .stdout(let line): await MainActor.run { outputLines.append(line) }
                    case .stderr(let line): await MainActor.run { outputLines.append("ERR: \(line)") }
                    case .exit(let code): await MainActor.run { outputLines.append("Exited (\(code))") }
                    }
                }
            } catch {
                await MainActor.run {
                    outputLines.append("Error: \(error.localizedDescription)")
                }
            }
            await MainActor.run { isRunning = false }
        }
    }

    private func refreshInstalledApps() {
        bottleManager.refreshInstalledApps(for: editedBottle)
        outputLines.append("Refreshed installed apps for \(editedBottle.name).")
    }

    private func runWineProgram(_ program: String, engine: WineEngine) async {
        showOutputConsole = true
        isRunning = true
        outputLines.append("Launching \(program)…")

        do {
            let stream = try WineManager.shared.launchExecutable(
                at: URL(fileURLWithPath: program),
                bottle: editedBottle,
                engine: engine
            )
            for await output in stream {
                switch output {
                case .stdout(let line): await MainActor.run { outputLines.append(line) }
                case .stderr(let line): await MainActor.run { outputLines.append("ERR: \(line)") }
                case .exit(let code):   await MainActor.run { outputLines.append("Exited (\(code))") }
                }
            }
        } catch {
            outputLines.append("Error: \(error.localizedDescription)")
        }
        isRunning = false
    }

    private func killWineServer() {
        guard let engine = engine else { return }
        WineManager.shared.killWineServer(bottle: editedBottle, engine: engine)
        isRunning = false
        showOutputConsole = true
        outputLines.append("Killed wineserver.")
    }
}

// MARK: - Add App Shortcut sheet

struct AddAppShortcutSheet: View {
    let bottle: Bottle
    @EnvironmentObject private var bottleManager: BottleManager
    @Environment(\.dismiss) private var dismiss

    @State private var appName: String = ""
    @State private var exePath: String = ""
    @State private var sfSymbol: String = "app.fill"
    @State private var iconColorHex: String = "#5A6EAA"
    @State private var isGame: Bool = false

    private var isValid: Bool {
        !appName.trimmingCharacters(in: .whitespaces).isEmpty &&
        !exePath.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Add App Shortcut")
                    .font(.title2.bold())
                Spacer()
            }
            .padding([.horizontal, .top], 20)
            .padding(.bottom, 16)
            Divider()
            Form {
                Section("App Details") {
                    TextField("App name", text: $appName)
                        .textFieldStyle(.roundedBorder)
                }
                Section("Executable") {
                    HStack {
                        TextField("Path to .exe inside bottle", text: $exePath)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                        Button("Browse…") { browse() }
                    }
                    Text("Tip: executables are usually inside the bottle's drive_c/Program Files folder.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Icon") {
                    TextField("SF Symbol name", text: $sfSymbol)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        TextField("Icon color (hex)", text: $iconColorHex)
                            .textFieldStyle(.roundedBorder)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color(hex: iconColorHex) ?? .accentColor)
                            .frame(width: 24, height: 24)
                    }
                }
                Section {
                    Toggle("This is a game", isOn: $isGame)
                } footer: {
                    Text("Games appear in the Games section of the sidebar.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack(spacing: 10) {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.bordered)
                Button("Add to Library") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isValid)
            }
            .padding(16)
        }
        .frame(width: 460)
    }

    private func browse() {
        let panel = NSOpenPanel()
        panel.directoryURL = bottle.driveCURL
        panel.allowedContentTypes = [UTType(filenameExtension: "exe") ?? .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            exePath = url.path
            if appName.isEmpty { appName = url.deletingPathExtension().lastPathComponent }
        }
    }

    private func save() {
        let app = InstalledApp(
            name: appName.trimmingCharacters(in: .whitespaces),
            exePath: exePath.trimmingCharacters(in: .whitespaces),
            sfSymbol: isGame ? "gamecontroller.fill" : (sfSymbol.isEmpty ? "app.fill" : sfSymbol),
            iconColor: iconColorHex,
            isGame: isGame
        )
        try? bottleManager.addApp(app, to: bottle)
        dismiss()
    }
}

// MARK: - Winetricks sheet

struct WinetricksSheet: View {
    @EnvironmentObject private var engineDownloader: EngineDownloader
    let bottle: Bottle

    @Environment(\.dismiss) private var dismiss

    @State private var verb: String = ""
    @State private var isRunning: Bool = false
    @State private var output: [String] = []
    @State private var error: String?

    private let commonVerbs = [
        "vcrun2019", "vcrun2022", "dotnet48", "dotnet6", "d3dx9",
        "d3dcompiler_47", "directx9", "xna40", "corefonts", "tahoma"
    ]

    var engine: WineEngine? {
        engineDownloader.availableEngines.first { $0.id == bottle.engineID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Winetricks")
                .font(.title2.bold())
                .padding(.top, 4)

            HStack {
                TextField("Verb (e.g. vcrun2019)", text: $verb)
                    .textFieldStyle(.roundedBorder)
                Button("Run") { runVerb() }
                    .disabled(verb.trimmingCharacters(in: .whitespaces).isEmpty || isRunning || engine == nil)
                    .buttonStyle(.borderedProminent)
            }

            Text("Common verbs:")
                .font(.caption)
                .foregroundStyle(.secondary)

            FlowLayout(spacing: 6) {
                ForEach(commonVerbs, id: \.self) { v in
                    Button(v) { verb = v }
                        .buttonStyle(.bordered)
                        .font(.caption)
                }
            }

            if !output.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(output.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(8)
                }
                .frame(height: 140)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            if let err = error {
                Text(err).foregroundStyle(.red).font(.callout)
            }

            HStack {
                if isRunning { ProgressView().scaleEffect(0.7) }
                Spacer()
                Button("Close") { dismiss() }
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func runVerb() {
        guard let engine = engine else { return }
        isRunning = true
        error = nil
        output.append("Running: winetricks \(verb)")
        Task {
            do {
                try await WineManager.shared.runWinetricks(verb: verb.trimmingCharacters(in: .whitespaces),
                                                           bottle: bottle, engine: engine)
                await MainActor.run { output.append("Done."); isRunning = false }
            } catch {
                await MainActor.run {
                    self.error = error.localizedDescription
                    isRunning = false
                }
            }
        }
    }
}

// MARK: - Simple flow layout for chips

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0

        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            totalHeight = y + rowHeight
        }
        return CGSize(width: maxWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX && x > bounds.minX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }
    }
}
