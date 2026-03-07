import SwiftUI

struct EngineManagerView: View {
    @EnvironmentObject private var engineDownloader: EngineDownloader
    @EnvironmentObject private var systemDetector: SystemDetector

    @State private var filterInstalled: Bool = false

    var displayedEngines: [WineEngine] {
        let all = engineDownloader.availableEngines
        if filterInstalled { return all.filter { $0.isInstalled } }
        return all
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if displayedEngines.isEmpty {
                emptyState
            } else {
                List(displayedEngines) { engine in
                    EngineRow(engine: engine)
                        .environmentObject(engineDownloader)
                        .environmentObject(systemDetector)
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Engines")
    }

    private var toolbar: some View {
        HStack {
            Toggle("Installed only", isOn: $filterInstalled)
                .toggleStyle(.checkbox)
                .font(.callout)
            Spacer()
            Button {
                engineDownloader.loadManifest()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .font(.callout)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "gearshape.2")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("No engines found")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct EngineRow: View {
    @EnvironmentObject private var engineDownloader: EngineDownloader
    @EnvironmentObject private var systemDetector: SystemDetector

    let engine: WineEngine

    var state: EngineDownloadState {
        engineDownloader.downloadStates[engine.id] ?? .idle
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "gearshape.fill")
                .foregroundStyle(engine.isInstalled ? .green : .secondary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(engine.displayName)
                        .font(.body.weight(.medium))
                    if engine.isInstalled {
                        Text("Installed")
                            .font(.caption.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.15))
                            .foregroundStyle(.green)
                            .clipShape(Capsule())
                    }
                }

                HStack(spacing: 6) {
                    Text("macOS \(engine.minMacOSVersion)+")
                    Text("·")
                    Text(engine.supportedArch.map(\.rawValue).joined(separator: ", "))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            actionButton
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var actionButton: some View {
        switch state {
        case .idle:
            Button("Download") {
                Task { await engineDownloader.download(engine: engine) }
            }
            .buttonStyle(.borderedProminent)
            .font(.callout)

        case .downloading(let progress):
            HStack(spacing: 8) {
                ProgressView(value: progress)
                    .frame(width: 100)
                    .tint(Color.accentColor)
                Text("\(Int(progress * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)
            }

        case .extracting:
            HStack(spacing: 6) {
                ProgressView()
                    .scaleEffect(0.7)
                Text("Extracting…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .installed:
            Button("Remove") {
                try? engineDownloader.uninstall(engine: engine)
            }
            .buttonStyle(.bordered)
            .font(.callout)
            .foregroundStyle(.red)

        case .failed(let msg):
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
                Text("Failed")
                    .font(.caption)
                    .foregroundStyle(.red)
                Button("Retry") {
                    Task { await engineDownloader.download(engine: engine) }
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
            .help(msg)
        }
    }
}
