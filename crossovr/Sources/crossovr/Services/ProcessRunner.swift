import Foundation

/// Output emitted line-by-line from a running process.
enum ProcessOutput {
    case stdout(String)
    case stderr(String)
    case exit(Int32)
}

/// Errors thrown by ProcessRunner.
enum ProcessRunnerError: Error, LocalizedError {
    case executableNotFound(String)
    case launchFailed(Error)
    case nonZeroExit(Int32, String)

    var errorDescription: String? {
        switch self {
        case .executableNotFound(let path):
            return "Executable not found: \(path)"
        case .launchFailed(let underlying):
            return "Failed to launch process: \(underlying.localizedDescription)"
        case .nonZeroExit(let code, let stderr):
            return "Process exited with code \(code).\n\(stderr)"
        }
    }
}

/// Runs a subprocess and streams its stdout/stderr output asynchronously.
final class ProcessRunner {

    private let executableURL: URL
    private let arguments: [String]
    private let environment: [String: String]
    private let currentDirectoryURL: URL?

    private(set) var process: Process?

    init(executableURL: URL,
         arguments: [String] = [],
         environment: [String: String] = [:],
         currentDirectoryURL: URL? = nil) {
        self.executableURL       = executableURL
        self.arguments           = arguments
        self.environment         = environment
        self.currentDirectoryURL = currentDirectoryURL
    }

    // MARK: - Async streaming run

    /// Runs the process and delivers output line-by-line via an AsyncStream.
    func stream() throws -> AsyncStream<ProcessOutput> {
        guard FileManager.default.fileExists(atPath: executableURL.path) else {
            throw ProcessRunnerError.executableNotFound(executableURL.path)
        }

        let task = Process()
        task.executableURL = executableURL
        task.arguments = arguments

        var env = ProcessInfo.processInfo.environment
        for (key, value) in environment { env[key] = value }
        task.environment = env

        if let cwd = currentDirectoryURL {
            task.currentDirectoryURL = cwd
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        task.standardOutput = stdoutPipe
        task.standardError  = stderrPipe

        self.process = task

        return AsyncStream { continuation in
            // Stream stdout
            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                if let text = String(data: data, encoding: .utf8) {
                    text.components(separatedBy: "\n")
                        .filter { !$0.isEmpty }
                        .forEach { continuation.yield(.stdout($0)) }
                }
            }

            // Stream stderr
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                if let text = String(data: data, encoding: .utf8) {
                    text.components(separatedBy: "\n")
                        .filter { !$0.isEmpty }
                        .forEach { continuation.yield(.stderr($0)) }
                }
            }

            task.terminationHandler = { process in
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                continuation.yield(.exit(process.terminationStatus))
                continuation.finish()
            }

            do {
                try task.run()
            } catch {
                continuation.yield(.exit(-1))
                continuation.finish()
            }
        }
    }

    // MARK: - Await-all (fire-and-collect)

    /// Runs the process to completion, returning all stdout/stderr as strings.
    @discardableResult
    func run() async throws -> (stdout: String, stderr: String) {
        var stdoutLines: [String] = []
        var stderrLines: [String] = []
        var exitCode: Int32 = 0

        for await output in try stream() {
            switch output {
            case .stdout(let line): stdoutLines.append(line)
            case .stderr(let line): stderrLines.append(line)
            case .exit(let code):   exitCode = code
            }
        }

        let stdoutText = stdoutLines.joined(separator: "\n")
        let stderrText = stderrLines.joined(separator: "\n")

        if exitCode != 0 {
            throw ProcessRunnerError.nonZeroExit(exitCode, stderrText)
        }
        return (stdoutText, stderrText)
    }

    /// Sends SIGTERM to the running process.
    func terminate() {
        process?.terminate()
    }

    /// Sends SIGKILL — guaranteed termination even if the process ignores SIGTERM.
    func forceTerminate() {
        guard let p = process, p.isRunning else { return }
        kill(p.processIdentifier, SIGKILL)
    }

    // MARK: - Convenience factory for shell commands

    /// Runs a simple shell command string via `/bin/zsh -c`.
    static func shell(_ command: String,
                      environment: [String: String] = [:]) async throws -> String {
        let runner = ProcessRunner(
            executableURL: URL(fileURLWithPath: "/bin/zsh"),
            arguments: ["-c", command],
            environment: environment
        )
        let (stdout, _) = try await runner.run()
        return stdout
    }
}
