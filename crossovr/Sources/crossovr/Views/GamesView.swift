import SwiftUI

/// Dedicated library view showing every installed game shortcut across all bottles.
struct GamesView: View {
    @EnvironmentObject private var bottleManager: BottleManager
    @EnvironmentObject private var engineDownloader: EngineDownloader

    @State private var searchQuery: String = ""
    @State private var launchError: String?
    @State private var showLaunchError: Bool = false
    @State private var runningAppIDs: Set<UUID> = []

    /// All (app, bottle) pairs where isGame == true, filtered by search.
    private var games: [(app: InstalledApp, bottle: Bottle)] {
        bottleManager.bottles.flatMap { bottle in
            bottle.installedApps
                .filter { $0.isGame }
                .map { (app: $0, bottle: bottle) }
        }.filter {
            searchQuery.isEmpty || $0.app.name.localizedCaseInsensitiveContains(searchQuery)
        }
    }

    var body: some View {
        Group {
            if games.isEmpty {
                emptyState
            } else {
                libraryGrid
            }
        }
        .navigationTitle("Games")
        .alert("Launch Error", isPresented: $showLaunchError, presenting: launchError) { _ in
            Button("OK") {}
        } message: { msg in
            Text(msg)
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: "gamecontroller")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("No Games Yet")
                .font(.title2.bold())
            Text("Install a game through the Home screen.\nWhen you save its shortcut, check **\"This is a game\"** to have it appear here.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Library grid

    private var libraryGrid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Search + header
                HStack(spacing: 12) {
                    Text("My Games")
                        .font(.system(size: 26, weight: .bold))
                    Spacer()
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
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color(nsColor: .separatorColor), lineWidth: 1))
                    .frame(maxWidth: 240)
                }
                .padding(.horizontal, 32)
                .padding(.top, 28)
                .padding(.bottom, 20)

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 130, maximum: 160), spacing: 14)],
                    spacing: 14
                ) {
                    ForEach(games, id: \.app.id) { pair in
                        GameCard(
                            app: pair.app,
                            bottleName: pair.bottle.name,
                            isRunning: runningAppIDs.contains(pair.app.id)
                        )
                        .onTapGesture(count: 2) {
                            launchGame(pair.app, in: pair.bottle)
                        }
                        .contextMenu {
                            Button {
                                launchGame(pair.app, in: pair.bottle)
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
                .padding(.horizontal, 32)
                .padding(.bottom, 32)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Launch

    private func launchGame(_ app: InstalledApp, in bottle: Bottle) {
        guard let engine = engineDownloader.availableEngines.first(where: { $0.id == bottle.engineID }) else {
            launchError = "No Wine engine found for bottle \"\(bottle.name)\"."
            showLaunchError = true
            return
        }
        runningAppIDs.insert(app.id)
        Task {
            do {
                let stream = try WineManager.shared.launchInstalledApp(
                    app,
                    bottle: bottle,
                    engine: engine
                )
                for await output in stream {
                    if case .exit = output {
                        await MainActor.run { runningAppIDs.remove(app.id) }
                    }
                }
            } catch {
                await MainActor.run {
                    runningAppIDs.remove(app.id)
                    launchError = error.localizedDescription
                    showLaunchError = true
                }
            }
        }
    }
}

// MARK: - GameCard

struct GameCard: View {
    let app: InstalledApp
    let bottleName: String
    let isRunning: Bool

    @State private var isHovered = false

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(app.parsedIconColor)
                    .frame(width: 60, height: 60)
                    .shadow(color: app.parsedIconColor.opacity(0.4), radius: 6, x: 0, y: 3)
                    .overlay(
                        // Running indicator dot
                        Group {
                            if isRunning {
                                VStack {
                                    HStack {
                                        Spacer()
                                        Circle()
                                            .fill(.green)
                                            .frame(width: 10, height: 10)
                                            .shadow(radius: 1)
                                    }
                                    Spacer()
                                }
                                .padding(4)
                            }
                        }
                    )
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
                .stroke(isHovered ? Color.accentColor.opacity(0.5) : Color.clear, lineWidth: 1)
        )
        .scaleEffect(isHovered ? 1.03 : 1.0)
        .animation(.spring(response: 0.2, dampingFraction: 0.7), value: isHovered)
        .onHover { isHovered = $0 }
    }
}
