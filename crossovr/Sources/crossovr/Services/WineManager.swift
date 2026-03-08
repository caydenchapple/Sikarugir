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
        // Unsetting DISPLAY ensures winemac.drv is used, giving full Cmd+C/Cmd+V support.
        env.removeValue(forKey: "DISPLAY")

        // Core Wine environment
        env["WINEPREFIX"]  = bottle.prefixPath
        env["WINEARCH"]    = bottle.arch.rawValue
        env["WINE"]        = engine.wineBinaryPath.path
        env["WINESERVER"]  = engine.wineServerBinaryPath.path

        // Show fixme warnings but silence all other debug noise (matches Whisky).
        // Using "-all" hides real errors; "fixme-all" keeps only fixme suppressions.
        env["WINEDEBUG"]   = "fixme-all"

        // Suppress GStreamer debug spam (Whisky technique).
        env["GST_DEBUG"]   = "1"

        // Suppress Mono/Gecko download popups — the stubs are handled by Wine builtins.
        env["WINEDLLOVERRIDES"] = "mscoree=d;mshtml=d"

        // Enable winemac.drv pasteboard sync (Cmd+C / Cmd+V <-> Ctrl+C / Ctrl+V).
        env["WINE_DISABLE_FAST_XCOPY"] = "1"

        // Synchronisation primitives — both flags set simultaneously so D3DMetal
        // (which reads WINEESYNC) behaves correctly under MSYNC (Whisky technique).
        // MSYNC is a macOS-native futex replacement; significantly lower overhead
        // than ESYNC especially on Apple Silicon.
        env["WINEMSYNC"] = "1"
        env["WINEESYNC"] = "1"

        // For .app-bundle style engines (Gcenx builds), wire up the shared libraries.
        let wineLibDir     = engine.localPath.appendingPathComponent("Contents/Resources/wine/lib").path
        let wineLibWineDir = engine.localPath.appendingPathComponent("Contents/Resources/wine/lib/wine").path
        if FileManager.default.fileExists(atPath: wineLibDir) {
            let existingFallback = env["DYLD_FALLBACK_LIBRARY_PATH"] ?? ""
            env["DYLD_FALLBACK_LIBRARY_PATH"] = "\(wineLibDir):\(wineLibWineDir):\(existingFallback)"
        }

        // Apply backend-specific overrides
        for (key, value) in bottle.backend.environmentOverrides {
            env[key] = value
        }

        // DXVK / VKD3D: prefer native (n) then builtin (b) for D3D DLLs, plus MoltenVK.
        if bottle.backend == .dxvk || bottle.backend == .vkd3d {
            let libDir   = engine.localPath.appendingPathComponent("Contents/Resources/wine/lib").path
            let existing = env["DYLD_LIBRARY_PATH"] ?? ""
            env["DYLD_LIBRARY_PATH"] = "\(libDir):\(existing)"
            env["MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS"] = "1"
            // Tell Wine to load native DXVK DLLs before its own builtins (Whisky pattern).
            let dxvkOverrides = "dxgi,d3d9,d3d10core,d3d11=n,b"
            let existing2 = env["WINEDLLOVERRIDES"] ?? ""
            env["WINEDLLOVERRIDES"] = existing2.isEmpty ? dxvkOverrides : "\(existing2);\(dxvkOverrides)"
        }

        // D3DMetal / DXMT: force GPU, disable software renderer fallback.
        if bottle.backend == .dxmt || bottle.backend == .d3dMetal {
            env["MTL_HUD_ENABLED"]           = "0"
            env["CA_RENDERER_ALLOW_SOFTWARE"] = "NO"
        }

        return env
    }

    // MARK: - Prefix initialisation

    /// Initialises a fresh WINEPREFIX for a bottle.
    ///
    /// Matches Whisky's technique: run `winecfg -v win10` which both triggers
    /// Wine's prefix auto-creation AND sets the Windows compatibility version to
    /// Windows 10 in a single step. Non-zero exits are tolerated — Wine can
    /// exit non-zero during first-boot while still producing a valid prefix.
    func initPrefix(for bottle: Bottle, engine: WineEngine) async throws {
        let wineExe = resolvedWineBinary(engine: engine, useRosetta: bottle.useRosetta)
        var env = environment(for: bottle, engine: engine)
        // Ensure Mono/Gecko dialogs are suppressed so init is non-interactive.
        env["WINEDLLOVERRIDES"] = "mscoree=d;mshtml=d"

        try FileManager.default.createDirectory(at: bottle.prefixURL,
                                                withIntermediateDirectories: true)

        // winecfg -v win10: initialises the prefix AND sets Windows 10 compatibility.
        // This is how Whisky creates every bottle.
        let runner = ProcessRunner(
            executableURL: wineExe,
            arguments: ["winecfg", "-v", "win10"],
            environment: env
        )
        for await _ in try runner.stream() {}
    }

    // MARK: - Launch Windows executable

    /// Launches a `.exe` inside the given bottle and streams its output.
    /// Used by the install wizard where streaming stdout/stderr to the console
    /// is important. For launching already-installed apps, use `launchInstalledApp`
    /// which routes through `wine start /unix` (the Whisky pattern).
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

        return try runner.stream(logURL: makeLogURL(name: exeURL.lastPathComponent, bottle: bottle))
    }

    /// Launches an installed library entry using `wine start /unix <path>`.
    ///
    /// Using `start /unix` (Whisky's standard technique) routes the launch
    /// through Wine's Windows `start.exe`, which handles working-directory
    /// setup, file-association semantics, and Windows process startup correctly.
    /// `start.exe` itself exits immediately; the actual app runs as a detached
    /// Wine child process.
    ///
    /// Supports direct executable paths and Steam game URIs (steam://rungameid/<id>).
    @discardableResult
    func launchInstalledApp(
        _ app: InstalledApp,
        bottle: Bottle,
        engine: WineEngine
    ) throws -> AsyncStream<ProcessOutput> {
        if let appID = steamGameID(from: app.exePath) {
            let steamExe = try resolveSteamExecutable(in: bottle)
            return try launchViaStart(
                exeURL: steamExe,
                bottle: bottle,
                engine: engine,
                extraArgs: steamLaunchArgs(appID: appID)
            )
        }
        let exeURL = URL(fileURLWithPath: app.exePath)
        var extraArgs: [String] = []
        if isSteamExecutable(exeURL) { extraArgs.append("-no-cef-sandbox") }
        return try launchViaStart(exeURL: exeURL, bottle: bottle, engine: engine, extraArgs: extraArgs)
    }

    /// Launches an exe through `wine start /unix <path> [args]`.
    /// This is the recommended launch pattern from Whisky — `start /unix`
    /// handles Windows path semantics and detaches the child process cleanly.
    @discardableResult
    private func launchViaStart(
        exeURL: URL,
        bottle: Bottle,
        engine: WineEngine,
        extraArgs: [String] = []
    ) throws -> AsyncStream<ProcessOutput> {
        let wineExe = resolvedWineBinary(engine: engine, useRosetta: bottle.useRosetta)
        let env = environment(for: bottle, engine: engine)

        var args = ["start", "/unix", exeURL.path(percentEncoded: false)] + extraArgs
        if bottle.useRosetta && detector.isAppleSilicon {
            args = [engine.wineBinaryPath.path, "start", "/unix",
                    exeURL.path(percentEncoded: false)] + extraArgs
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

        return try runner.stream(logURL: makeLogURL(name: exeURL.lastPathComponent, bottle: bottle))
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

    // MARK: - Logging

    /// Returns a timestamped log URL under ~/Library/Logs/crossovr/ (Whisky pattern).
    private func makeLogURL(name: String, bottle: Bottle) -> URL {
        let logsDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("Logs/crossovr")
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let filename = "\(stamp)_\(bottle.name)_\(name).log"
        return logsDir.appendingPathComponent(filename)
    }

    private func isSteamExecutable(_ url: URL) -> Bool {
        url.deletingPathExtension().lastPathComponent.lowercased() == "steam"
    }

    private func steamLaunchArgs(appID: String) -> [String] {
        ["-no-cef-sandbox", "-applaunch", appID]
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
