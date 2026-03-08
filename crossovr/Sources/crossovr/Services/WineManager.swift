import Foundation
import Combine

/// Manages Wine process lifecycle: prefix initialisation, app launch, winetricks, and wineserver.
@MainActor
final class WineManager: ObservableObject {
    static let shared = WineManager()

    @Published private(set) var runningProcesses: [UUID: ProcessRunner] = [:]
    @Published private(set) var outputLog: [UUID: [String]] = [:]

    private let detector = SystemDetector.shared

    // MARK: - Wine environment

    /// Builds the environment dictionary for a given bottle.
    func environment(for bottle: Bottle, engine: WineEngine) -> [String: String] {
        var env: [String: String] = ProcessInfo.processInfo.environment

        // Force the macOS native Wine driver (winemac.drv) instead of X11.
        // When DISPLAY is set (inherited from the shell), Wine falls back to the X11
        // driver which loses macOS clipboard, drag-and-drop, and IME integration.
        // Unsetting it ensures winemac.drv is used, giving full Cmd+C/Cmd+V support.
        env.removeValue(forKey: "DISPLAY")

        // Core Wine environment
        env["WINEPREFIX"]   = bottle.prefixPath
        env["WINEARCH"]     = bottle.arch.rawValue
        env["WINE"]         = engine.wineBinaryPath.path
        env["WINESERVER"]   = engine.wineServerBinaryPath.path
        env["WINEDEBUG"]    = "-all"
        env["WINEDLLOVERRIDES"] = "mscoree=d;mshtml=d"

        // Enable winemac.drv clipboard sync with the macOS pasteboard.
        // This wires up Ctrl+C/Ctrl+V inside Wine to sync with Cmd+C/Cmd+V on macOS.
        env["WINE_DISABLE_FAST_XCOPY"] = "1"

        // For .app-bundle style engines (Gcenx builds), add bundled lib paths so
        // the wine binary can locate its shared libraries at runtime.
        let wineLibDir = engine.localPath.appendingPathComponent("Contents/Resources/wine/lib").path
        let wineLibWineDir = engine.localPath.appendingPathComponent("Contents/Resources/wine/lib/wine").path
        if FileManager.default.fileExists(atPath: wineLibDir) {
            let existing = env["DYLD_FALLBACK_LIBRARY_PATH"] ?? ""
            env["DYLD_FALLBACK_LIBRARY_PATH"] = "\(wineLibDir):\(wineLibWineDir):\(existing)"
        }

        // Apply backend-specific overrides
        for (key, value) in bottle.backend.environmentOverrides {
            env[key] = value
        }

        // DXVK / VKD3D need MoltenVK
        if bottle.backend == .dxvk || bottle.backend == .vkd3d {
            let libDir = engine.localPath.appendingPathComponent("Contents/Resources/wine/lib").path
            let existing = env["DYLD_LIBRARY_PATH"] ?? ""
            env["DYLD_LIBRARY_PATH"] = "\(libDir):\(existing)"
            env["MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS"] = "1"
        }

        // Force GPU rendering for DXMT/D3DMetal
        if bottle.backend == .dxmt || bottle.backend == .d3dMetal {
            env["MTL_HUD_ENABLED"] = "0"
            env["CA_RENDERER_ALLOW_SOFTWARE"] = "NO"
        }

        return env
    }

    // MARK: - Prefix initialisation

    /// Initialises a fresh WINEPREFIX for a bottle (runs `wineboot --init`).
    func initPrefix(for bottle: Bottle, engine: WineEngine) async throws {
        let wineExe = resolvedWineBinary(engine: engine, useRosetta: bottle.useRosetta)
        let env = environment(for: bottle, engine: engine)

        try FileManager.default.createDirectory(at: bottle.prefixURL,
                                                withIntermediateDirectories: true)

        let runner = ProcessRunner(
            executableURL: wineExe,
            arguments: ["wineboot", "--init"],
            environment: env
        )
        try await runner.run()
    }

    // MARK: - Launch Windows executable

    /// Launches a `.exe` inside the given bottle and streams its output.
    @discardableResult
    func launchExecutable(
        at exeURL: URL,
        bottle: Bottle,
        engine: WineEngine,
        extraArgs: [String] = []
    ) throws -> AsyncStream<ProcessOutput> {
        let wineExe = resolvedWineBinary(engine: engine, useRosetta: bottle.useRosetta)
        let env = environment(for: bottle, engine: engine)

        var args = [exeURL.path] + extraArgs
        // On ARM64 with Rosetta, the `arch` wrapper handles the arch switch; wine is still the first
        // process arg when we use the arch-wrapper exe path.
        if bottle.useRosetta && detector.isAppleSilicon {
            args = [engine.wineBinaryPath.path, exeURL.path] + extraArgs
        }

        let runner = ProcessRunner(
            executableURL: wineExe,
            arguments: args,
            environment: env,
            currentDirectoryURL: exeURL.deletingLastPathComponent()
        )

        let sessionID = bottle.id
        runningProcesses[sessionID] = runner
        outputLog[sessionID] = []

        return try runner.stream()
    }

    /// Launches an installed library entry.
    /// Supports direct executable paths and Steam game URIs (steam://rungameid/<id>).
    @discardableResult
    func launchInstalledApp(
        _ app: InstalledApp,
        bottle: Bottle,
        engine: WineEngine
    ) throws -> AsyncStream<ProcessOutput> {
        if let appID = steamGameID(from: app.exePath) {
            let steamExe = try resolveSteamExecutable(in: bottle)
            return try launchExecutable(
                at: steamExe,
                bottle: bottle,
                engine: engine,
                extraArgs: ["-applaunch", appID]
            )
        }
        return try launchExecutable(
            at: URL(fileURLWithPath: app.exePath),
            bottle: bottle,
            engine: engine
        )
    }

    /// Opens a Windows shell desktop (explorer) inside the bottle.
    @discardableResult
    func launchWindowsDesktop(
        bottle: Bottle,
        engine: WineEngine
    ) throws -> AsyncStream<ProcessOutput> {
        let explorerPath = bottle.driveCURL.appendingPathComponent("windows/explorer.exe")
        if FileManager.default.fileExists(atPath: explorerPath.path) {
            return try launchExecutable(at: explorerPath, bottle: bottle, engine: engine)
        }
        // Fallback to explorer command resolved by Wine.
        return try launchExecutable(
            at: URL(fileURLWithPath: "explorer"),
            bottle: bottle,
            engine: engine
        )
    }

    // MARK: - Run winetricks verb

    /// Runs a winetricks verb inside a bottle (e.g. `vcrun2019`, `dotnet48`).
    func runWinetricks(verb: String, bottle: Bottle, engine: WineEngine) async throws {
        let winetricksPath = try locateWinetricks()
        let env = environment(for: bottle, engine: engine)

        let runner = ProcessRunner(
            executableURL: URL(fileURLWithPath: winetricksPath),
            arguments: ["-q", verb],
            environment: env
        )
        try await runner.run()
    }

    // MARK: - Kill wineserver

    /// Hard-kills all Wine processes inside a bottle's prefix, then signals wineserver to exit.
    func killWineServer(bottle: Bottle, engine: WineEngine) {
        // SIGKILL the live runner for this bottle first so the stream exits immediately.
        runningProcesses[bottle.id]?.forceTerminate()
        runningProcesses.removeValue(forKey: bottle.id)

        // Tell wineserver to shut down (handles any orphaned processes).
        let env = environment(for: bottle, engine: engine)
        let runner = ProcessRunner(
            executableURL: engine.wineServerBinaryPath,
            arguments: ["-k"],
            environment: env
        )
        Task { try? await runner.run() }
    }

    // MARK: - Helpers

    private func resolvedWineBinary(engine: WineEngine, useRosetta: Bool) -> URL {
        guard useRosetta && detector.isAppleSilicon else {
            return engine.wineBinaryPath
        }
        // Wrap with `arch -x86_64` to run the x86_64 Wine under Rosetta 2
        return URL(fileURLWithPath: "/usr/bin/arch")
    }

    private func locateWinetricks() throws -> String {
        // Prefer a bundled copy, then fall back to PATH
        let bundled = Bundle.main.path(forResource: "winetricks", ofType: nil)
        if let bundled = bundled { return bundled }

        // Try Homebrew location
        let homebrew = "/opt/homebrew/bin/winetricks"
        if FileManager.default.fileExists(atPath: homebrew) { return homebrew }

        let homebrewIntel = "/usr/local/bin/winetricks"
        if FileManager.default.fileExists(atPath: homebrewIntel) { return homebrewIntel }

        throw ProcessRunnerError.executableNotFound("winetricks (install via `brew install winetricks`)")
    }

    private func steamGameID(from value: String) -> String? {
        guard value.lowercased().hasPrefix("steam://rungameid/") else { return nil }
        return value.components(separatedBy: "/").last?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func resolveSteamExecutable(in bottle: Bottle) throws -> URL {
        let candidates = [
            bottle.driveCURL.appendingPathComponent("Program Files (x86)/Steam/steam.exe"),
            bottle.driveCURL.appendingPathComponent("Program Files/Steam/steam.exe")
        ]
        if let existing = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            return existing
        }
        throw ProcessRunnerError.executableNotFound("Steam executable in bottle \(bottle.name)")
    }
}
