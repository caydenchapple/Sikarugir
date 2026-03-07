import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var catalog: AppCatalogManager
    @EnvironmentObject private var engineDownloader: EngineDownloader
    @EnvironmentObject private var bottleManager: BottleManager
    @EnvironmentObject private var systemDetector: SystemDetector

    @State private var searchQuery: String = ""
    @State private var selectedApp: WindowsApp?
    @State private var showUnlistedInstall: Bool = false
    @State private var launchingApp: InstalledApp?
    @State private var launchError: String?
    @State private var showLaunchError: Bool = false

    private var displayedApps: [WindowsApp] {
        catalog.filteredApps(query: searchQuery)
    }

    /// All installed app shortcuts across every bottle (filtered by search query).
    private var installedApps: [(app: InstalledApp, bottle: Bottle)] {
        bottleManager.bottles.flatMap { bottle in
            bottle.installedApps.map { (app: $0, bottle: bottle) }
        }.filter { pair in
            searchQuery.isEmpty || pair.app.name.localizedCaseInsensitiveContains(searchQuery)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                headerSection
                    .padding(.horizontal, 32)
                    .padding(.top, 28)
                    .padding(.bottom, 20)

                // MY APPS — only shown when apps are installed (and not searching catalog only)
                if !installedApps.isEmpty {
                    myAppsSection
                        .padding(.horizontal, 32)
                        .padding(.bottom, 24)
                }

                if displayedApps.isEmpty && searchQuery.isEmpty {
                    EmptyView()
                } else if displayedApps.isEmpty {
                    emptySearchResult
                } else {
                    popularSection
                        .padding(.horizontal, 32)
                }
            }
            .padding(.bottom, 32)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(item: $selectedApp) { app in
            AppInstallSheet(app: app)
                .environmentObject(engineDownloader)
                .environmentObject(bottleManager)
                .environmentObject(systemDetector)
        }
        .sheet(isPresented: $showUnlistedInstall) {
            UnlistedInstallSheet()
                .environmentObject(engineDownloader)
                .environmentObject(bottleManager)
                .environmentObject(systemDetector)
        }
        .alert("Launch Error", isPresented: $showLaunchError, presenting: launchError) { _ in
            Button("OK") {}
        } message: { msg in
            Text(msg)
        }
    }

    // MARK: - MY APPS section

    private var myAppsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("MY APPS")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .tracking(0.8)
                Spacer()
            }

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 130, maximum: 160), spacing: 14)],
                spacing: 14
            ) {
                ForEach(installedApps, id: \.app.id) { pair in
                    InstalledAppCard(app: pair.app, bottleName: pair.bottle.name)
                        .onTapGesture(count: 2) { launchInstalledApp(pair.app, in: pair.bottle) }
                        .contextMenu {
                            Button {
                                launchInstalledApp(pair.app, in: pair.bottle)
                            } label: {
                                Label("Launch", systemImage: "play.fill")
                            }
                            Divider()
                            Button(role: .destructive) {
                                try? bottleManager.removeApp(pair.app, from: pair.bottle)
                            } label: {
                                Label("Remove from Library", systemImage: "trash")
                            }
                        }
                }
            }
        }
    }

    private func launchInstalledApp(_ app: InstalledApp, in bottle: Bottle) {
        guard let engine = engineDownloader.availableEngines.first(where: { $0.id == bottle.engineID }) else {
            launchError = "No Wine engine found for bottle \"\(bottle.name)\". Go to the Engines section to download one."
            showLaunchError = true
            return
        }
        Task {
            do {
                _ = try WineManager.shared.launchInstalledApp(
                    app,
                    bottle: bottle,
                    engine: engine
                )
            } catch {
                await MainActor.run {
                    launchError = error.localizedDescription
                    showLaunchError = true
                }
            }
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Install a Windows Application")
                .font(.system(size: 26, weight: .bold))

            HStack(spacing: 12) {
                // Search field
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                    TextField("Search", text: $searchQuery)
                        .textFieldStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                )
                .frame(maxWidth: 340)

                Spacer()

                // Unlisted app link
                HStack(spacing: 4) {
                    Text("Can't find what you're looking for?")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                    Button("Install an unlisted application") {
                        showUnlistedInstall = true
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .font(.callout)
                }
            }
        }
    }

    // MARK: - Popular apps grid

    private var popularSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(searchQuery.isEmpty ? "Popular Applications" : "Search Results")
                .font(.title3.bold())

            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 1), GridItem(.flexible(), spacing: 1)],
                spacing: 1
            ) {
                ForEach(displayedApps) { app in
                    AppCatalogCard(app: app)
                        .onTapGesture { selectedApp = app }
                }
            }
            .background(Color(nsColor: .separatorColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            )
        }
    }

    // MARK: - Empty state

    private var emptySearchResult: some View {
        VStack(spacing: 14) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 44))
                .foregroundStyle(.tertiary)
            Text("No applications found")
                .font(.title3.bold())
                .foregroundStyle(.secondary)
            Text("Try a different search term, or install an unlisted application.")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            Button("Install an unlisted application") {
                showUnlistedInstall = true
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }
}

// MARK: - App Catalog Card

struct AppCatalogCard: View {
    let app: WindowsApp

    @State private var isHovered: Bool = false

    var body: some View {
        HStack(spacing: 14) {
            // Icon
            appIcon

            // Info
            VStack(alignment: .leading, spacing: 4) {
                Text(app.name)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)

                HStack(spacing: 5) {
                    StarRatingView(stars: app.stars)
                    Text(app.compatibility.rawValue)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .opacity(isHovered ? 1 : 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            isHovered
                ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.15)
                : Color(nsColor: .windowBackgroundColor)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .cursor(.pointingHand)
    }

    private var appIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(app.parsedIconColor)
                .frame(width: 44, height: 44)
            Image(systemName: app.sfSymbol)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.white)
        }
    }
}

// MARK: - Star Rating View

struct StarRatingView: View {
    let stars: Double

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<5) { i in
                starImage(for: i)
                    .font(.system(size: 11))
                    .foregroundStyle(Color(red: 1.0, green: 0.75, blue: 0.0))
            }
        }
    }

    private func starImage(for index: Int) -> Image {
        let threshold = Double(index) + 1.0
        if stars >= threshold {
            return Image(systemName: "star.fill")
        } else if stars >= Double(index) + 0.5 {
            return Image(systemName: "star.leadinghalf.filled")
        } else {
            return Image(systemName: "star")
        }
    }
}

// MARK: - Cursor helper

extension View {
    func cursor(_ cursor: NSCursor) -> some View {
        self.onHover { inside in
            if inside { cursor.push() } else { NSCursor.pop() }
        }
    }
}

// MARK: - Unlisted install sheet (simple wrapper around InstallWizardView)

struct UnlistedInstallSheet: View {
    @EnvironmentObject private var engineDownloader: EngineDownloader
    @EnvironmentObject private var bottleManager: BottleManager
    @EnvironmentObject private var systemDetector: SystemDetector

    @Environment(\.dismiss) private var dismiss

    @State private var createdBottle: Bottle?
    @State private var showWizard: Bool = false

    // Quick bottle creation fields
    @State private var bottleName: String = "New Bottle"
    @State private var selectedEngineID: String = ""
    @State private var selectedBackend: GraphicsBackend = .dxvk
    @State private var selectedArch: BottleArch = .win64
    @State private var useRosetta: Bool = false
    @State private var customStoragePath: String? = nil
    @State private var errorMessage: String?

    var body: some View {
        if showWizard, let bottle = createdBottle {
            InstallWizardView(bottle: bottle)
                .environmentObject(bottleManager)
                .environmentObject(engineDownloader)
        } else {
            configForm
        }
    }

    private var configForm: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "app.badge")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                Text("Install an Unlisted Application")
                    .font(.title2.bold())
                Spacer()
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
                        Text("No engines installed — go to Engines in Settings to download one.")
                            .foregroundStyle(.secondary).font(.callout)
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
                        }
                    }
                }
                Section("Storage") {
                    HStack(spacing: 8) {
                        Image(systemName: "folder").foregroundStyle(.secondary)
                        Text(customStoragePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Default (App Support)")
                            .foregroundStyle(customStoragePath == nil ? .secondary : .primary)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Choose…") { chooseStorage() }.font(.caption)
                        if customStoragePath != nil {
                            Button("Reset") { customStoragePath = nil }.font(.caption).foregroundStyle(.red)
                        }
                    }
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
                Button("Next") { createAndContinue() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(bottleName.trimmingCharacters(in: .whitespaces).isEmpty ||
                              selectedEngineID.isEmpty)
            }
            .padding(16)
        }
        .frame(width: 460)
        .onAppear {
            selectedEngineID = engineDownloader.installedEngines.first?.id ?? ""
            selectedBackend  = systemDetector.recommendedBackend
        }
    }

    private func chooseStorage() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose Folder"
        if panel.runModal() == .OK, let url = panel.url {
            customStoragePath = url.path
        }
    }

    private func createAndContinue() {
        do {
            var bottle = try bottleManager.createBottle(
                name: bottleName.trimmingCharacters(in: .whitespaces),
                engineID: selectedEngineID,
                backend: selectedBackend,
                arch: selectedArch,
                useRosetta: useRosetta
            )
            if let base = customStoragePath {
                try bottleManager.setCustomRoot(URL(fileURLWithPath: base).appendingPathComponent(bottle.id.uuidString).path, for: bottle)
                bottle = bottleManager.bottles.first(where: { $0.id == bottle.id }) ?? bottle
            }
            createdBottle = bottle
            showWizard = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - InstalledAppCard

struct InstalledAppCard: View {
    let app: InstalledApp
    let bottleName: String

    @State private var isHovered = false

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(app.parsedIconColor)
                    .frame(width: 60, height: 60)
                    .shadow(color: app.parsedIconColor.opacity(0.4), radius: 6, x: 0, y: 3)
                Image(systemName: app.sfSymbol)
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(.white)
            }

            VStack(spacing: 3) {
                Text(app.name)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                Text(bottleName)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if isHovered {
                Text("Double-click to launch")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.accentColor)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.06), radius: 4, x: 0, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isHovered ? Color.accentColor.opacity(0.5) : Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 1)
        )
        .scaleEffect(isHovered ? 1.03 : 1.0)
        .animation(.spring(response: 0.2, dampingFraction: 0.7), value: isHovered)
        .onHover { isHovered = $0 }
    }
}
