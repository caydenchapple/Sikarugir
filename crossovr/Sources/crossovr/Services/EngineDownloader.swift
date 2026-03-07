import Foundation
import Combine

/// Download state for a single engine.
enum EngineDownloadState: Equatable {
    case idle
    case downloading(progress: Double)  // 0.0 – 1.0
    case extracting
    case installed
    case failed(String)
}

/// Manages downloading, extracting, and inventorying Wine engine builds.
@MainActor
final class EngineDownloader: ObservableObject {
    static let shared = EngineDownloader()

    @Published private(set) var availableEngines: [WineEngine] = []
    @Published var downloadStates: [String: EngineDownloadState] = [:]

    private let enginesRoot: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support
            .appendingPathComponent("crossovr")
            .appendingPathComponent("Engines")
    }()

    private var activeTasks: [String: URLSessionDownloadTask] = [:]
    private var progressObservations: [String: NSKeyValueObservation] = [:]

    private init() {
        loadManifest()
        refreshInstallationStatus()
    }

    // MARK: - Manifest

    /// Loads the bundled engines.json manifest.
    func loadManifest() {
        guard let url = Bundle.module.url(forResource: "engines", withExtension: "json") else {
            // Fallback: look next to the executable (useful during development)
            loadManifestFromDisk()
            return
        }
        decodeManifest(from: url)
    }

    private func loadManifestFromDisk() {
        // Development fallback — look in the Sources/Resources directory
        let devPath = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/engines.json")
        guard FileManager.default.fileExists(atPath: devPath.path) else { return }
        decodeManifest(from: devPath)
    }

    private func decodeManifest(from url: URL) {
        guard let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        if let engines = try? decoder.decode([WineEngine].self, from: data) {
            availableEngines = engines
            refreshInstallationStatus()
        }
    }

    // MARK: - Installation status

    /// Re-checks which engines are already installed on disk.
    func refreshInstallationStatus() {
        availableEngines = availableEngines.map { engine in
            var copy = engine
            copy.isInstalled = FileManager.default.fileExists(atPath: engine.localPath.path)
            if copy.isInstalled {
                downloadStates[engine.id] = .installed
            }
            return copy
        }
    }

    var installedEngines: [WineEngine] {
        availableEngines.filter { $0.isInstalled }
    }

    // MARK: - Download

    /// Downloads and extracts the given engine, reporting progress via `downloadStates`.
    func download(engine: WineEngine) async {
        guard downloadStates[engine.id] != .installed else { return }
        downloadStates[engine.id] = .downloading(progress: 0)

        do {
            let tarball = try await downloadTarball(engine: engine)
            downloadStates[engine.id] = .extracting
            try await extractTarball(tarball, to: engine.localPath)
            try? FileManager.default.removeItem(at: tarball)    // cleanup download
            markInstalled(engine: engine)
        } catch {
            downloadStates[engine.id] = .failed(error.localizedDescription)
        }
    }

    // MARK: - Uninstall

    func uninstall(engine: WineEngine) throws {
        guard FileManager.default.fileExists(atPath: engine.localPath.path) else { return }
        try FileManager.default.removeItem(at: engine.localPath)
        downloadStates[engine.id] = .idle
        refreshInstallationStatus()
    }

    // MARK: - Private helpers

    private func downloadTarball(engine: WineEngine) async throws -> URL {
        let engineID = engine.id
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(engineID).tar.xz")

        if FileManager.default.fileExists(atPath: tmpURL.path) {
            try FileManager.default.removeItem(at: tmpURL)
        }

        return try await withCheckedThrowingContinuation { continuation in
            let task = URLSession.shared.downloadTask(with: engine.downloadURL) { [weak self] localURL, _, error in
                // Clean up progress observation on the main thread
                DispatchQueue.main.async { self?.progressObservations.removeValue(forKey: engineID) }

                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let localURL else {
                    continuation.resume(throwing: URLError(.unknown))
                    return
                }
                do {
                    try FileManager.default.moveItem(at: localURL, to: tmpURL)
                    continuation.resume(returning: tmpURL)
                } catch {
                    continuation.resume(throwing: error)
                }
            }

            // KVO-based progress — fires on a background thread, dispatch to main for UI updates
            progressObservations[engineID] = task.progress.observe(
                \.fractionCompleted, options: [.new]
            ) { [weak self] progress, _ in
                DispatchQueue.main.async {
                    self?.downloadStates[engineID] = .downloading(progress: progress.fractionCompleted)
                }
            }

            activeTasks[engineID] = task
            task.resume()
        }
    }

    private func extractTarball(_ tarball: URL, to destination: URL) async throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let runner = ProcessRunner(
            executableURL: URL(fileURLWithPath: "/usr/bin/tar"),
            arguments: [
                "-xJf", tarball.path,           // -J = xz compressed
                "-C", destination.path,
                "--strip-components=1"           // drop the top-level dir in the archive
            ]
        )
        try await runner.run()
    }

    private func markInstalled(engine: WineEngine) {
        downloadStates[engine.id] = .installed
        if let idx = availableEngines.firstIndex(where: { $0.id == engine.id }) {
            availableEngines[idx].isInstalled = true
        }
    }
}
