import SwiftUI
import AppKit

// MARK: - App Routing

enum AppRoute: Hashable {
    case home
    case games
    case bottle(Bottle)
    case engines
    case settings
}

// MARK: - Root Content View

struct ContentView: View {
    @EnvironmentObject private var bottleManager: BottleManager
    @EnvironmentObject private var engineDownloader: EngineDownloader
    @EnvironmentObject private var systemDetector: SystemDetector
    @EnvironmentObject private var catalog: AppCatalogManager

    @State private var route: AppRoute = .home

    var body: some View {
        NavigationSplitView {
            CrossOvrSidebar(route: $route)
        } detail: {
            detailView
        }
        .navigationSplitViewStyle(.balanced)
    }

    @ViewBuilder
    private var detailView: some View {
        switch route {
        case .home:
            HomeView()
                .environmentObject(catalog)
                .environmentObject(engineDownloader)
                .environmentObject(bottleManager)
                .environmentObject(systemDetector)
        case .games:
            GamesView()
                .environmentObject(bottleManager)
                .environmentObject(engineDownloader)
        case .bottle(let b):
            BottleDetailView(bottle: b)
                .id(b.id)
        case .engines:
            EngineManagerView()
        case .settings:
            SettingsView()
        }
    }
}

// MARK: - Sidebar

struct CrossOvrSidebar: View {
    @Binding var route: AppRoute

    @EnvironmentObject private var bottleManager: BottleManager
    @EnvironmentObject private var engineDownloader: EngineDownloader
    @EnvironmentObject private var systemDetector: SystemDetector
    @EnvironmentObject private var catalog: AppCatalogManager

    @State private var showInstallHome: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            // Logo
            logoHeader

            Divider()
                .opacity(0.4)

            // Navigation list
            List(selection: $route) {
                // Home
                Label("Home", systemImage: "house.fill")
                    .tag(AppRoute.home)
                    .padding(.vertical, 2)

                // Games library
                Label("Games", systemImage: "gamecontroller.fill")
                    .tag(AppRoute.games)
                    .padding(.vertical, 2)

                // Bottles section
                if !bottleManager.bottles.isEmpty {
                    Section {
                        ForEach(bottleManager.bottles) { bottle in
                            BottleSidebarRow(bottle: bottle)
                                .tag(AppRoute.bottle(bottle))
                                .contextMenu {
                                    Button(role: .destructive) {
                                        try? bottleManager.deleteBottle(bottle)
                                        if case .bottle(let current) = route, current.id == bottle.id {
                                            route = .home
                                        }
                                    } label: {
                                        Label("Delete Bottle", systemImage: "trash")
                                    }
                                }
                        }
                    } header: {
                        Text("BOTTLES")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .tracking(0.8)
                    }
                }

                // Engine manager (hidden under a divider at bottom of list)
                Section {
                    Label("Engines", systemImage: "gearshape.2")
                        .tag(AppRoute.engines)
                        .padding(.vertical, 2)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("ADVANCED")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .tracking(0.8)
                }
            }
            .listStyle(.sidebar)

            Divider()
                .opacity(0.4)

            // Install button at bottom
            Button {
                route = .home
            } label: {
                Label("Install", systemImage: "plus.app.fill")
                    .frame(maxWidth: .infinity)
                    .font(.body.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(12)
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 220)
    }

    private var logoHeader: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.accentColor)
                    .frame(width: 32, height: 32)
                Image(systemName: "wineglass.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
            }
            Text("crossovr")
                .font(.system(size: 17, weight: .bold))
                .tracking(-0.3)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Bottle sidebar row

struct BottleSidebarRow: View {
    let bottle: Bottle

    var body: some View {
        Label {
            Text(bottle.name)
                .lineLimit(1)
        } icon: {
            Image(systemName: "wineglass")
        }
        .padding(.vertical, 1)
    }
}

