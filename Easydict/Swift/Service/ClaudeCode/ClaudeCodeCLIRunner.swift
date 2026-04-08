//
//  ClaudeCodeCLIRunner.swift
//  Easydict
//
//  Created by Karl on 2026/04/07.
//  Copyright © 2026 izual. All rights reserved.
//

import Foundation

// MARK: - ClaudeCodeCLIRunner

/// Wraps a `claude -p` subprocess and yields streaming text deltas as an `AsyncThrowingStream<String, Error>`.
///
/// Uses `--output-format stream-json --include-partial-messages` so the CLI emits one JSON event
/// per line. The runner extracts `content_block_delta` text deltas and forwards them to callers,
/// giving token-by-token granularity identical to the Anthropic API SSE stream.
///
/// Each instance represents exactly one subprocess invocation. Create a new instance per translation request.
final class ClaudeCodeCLIRunner {
    // MARK: Lifecycle

    init() {}

    // MARK: Internal

    /// Parses a `ClaudeCodeError` from stderr content.
    static func parseError(from stderr: String) -> ClaudeCodeError {
        // Strip known macOS system noise that is not a real error.
        let cleaned = stderr
            .components(separatedBy: "\n")
            .filter { !$0.contains("MallocStackLogging") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let lower = cleaned.lowercased()
        if lower.contains("not logged in") || lower.contains("authentication") || lower.contains("login") {
            return .notLoggedIn
        }
        if lower.contains("rate limit") || lower.contains("quota") || lower.contains("usage limit") {
            return .quotaExceeded
        }
        return .cliError(message: cleaned)
    }

    /// Runs `claude -p` with optimised flags and streams text delta chunks as they arrive.
    ///
    /// The CLI emits one newline-delimited JSON object per event (`--output-format stream-json`).
    /// This method extracts `text_delta` text from each `content_block_delta` event, giving
    /// token-by-token granularity identical to the Anthropic API SSE stream.
    ///
    /// Token-reduction flags applied to every invocation:
    /// - `--system-prompt` — replaces the large Claude Code default system prompt with the
    ///   caller-supplied translation prompt, skipping all Claude Code tool/agent instructions.
    /// - `--tools ""` — disables all built-in tools so their descriptions never enter context.
    /// - `--strict-mcp-config` (without `--mcp-config`) — ignores the user's MCP server config,
    ///   preventing MCP tool descriptions from entering the context.
    /// - `--no-session-persistence` — skips session file I/O.
    ///
    /// - Parameters:
    ///   - prompt: The conversation prompt (user / assistant messages only, without system message).
    ///   - systemPrompt: Passed via `--system-prompt` to replace Claude Code's default system
    ///     prompt. `nil` omits the flag and leaves Claude Code's default in place.
    /// - Returns: A stream that yields text delta strings as they arrive from the CLI.
    func run(prompt: String, systemPrompt: String? = nil) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { [weak self] continuation in
            guard let self else {
                continuation.finish()
                return
            }

            Task {
                do {
                    let binaryPath = try Self.detectClaudeBinary()
                    self.logger = ClaudeCodeLogger(command: "\(binaryPath) -p <prompt>", prompt: prompt)

                    let process = Process()
                    let stdoutPipe = Pipe()
                    let stderrPipe = Pipe()

                    process.executableURL = URL(fileURLWithPath: binaryPath)
                    var arguments = [
                        "-p", prompt,
                        "--output-format", "stream-json",
                        "--include-partial-messages",
                        "--verbose",
                        "--no-session-persistence",
                        "--tools", "",         // disable all built-in tools
                        "--strict-mcp-config", // ignore user MCP config; no --mcp-config = no servers
                    ]
                    if let systemPrompt, !systemPrompt.isEmpty {
                        arguments += ["--system-prompt", systemPrompt]
                    }
                    process.arguments = arguments
                    process.standardOutput = stdoutPipe
                    process.standardError = stderrPipe
                    // Use a neutral working directory so claude does not scan user folders.
                    process.currentDirectoryURL = FileManager.default.temporaryDirectory

                    self.process = process

                    let startTime = Date()
                    var stderrBuffer = ""
                    // Incomplete JSON line carried over between readabilityHandler calls.
                    var lineBuffer = ""

                    // Read stderr asynchronously into a buffer.
                    stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                        let data = handle.availableData
                        if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                            stderrBuffer += text
                        }
                    }

                    // Read stdout line by line, parse each JSON event, and yield text deltas.
                    stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                        let data = handle.availableData
                        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                        self?.logger?.appendStdout(text)
                        lineBuffer += text

                        // Every complete line (all but the last element after splitting on \n)
                        // is a full JSON event. The last element is a partial line kept in the buffer.
                        let lines = lineBuffer.components(separatedBy: "\n")
                        for line in lines.dropLast() where !line.isEmpty {
                            if let delta = Self.extractTextDelta(from: line) {
                                continuation.yield(delta)
                            }
                        }
                        lineBuffer = lines.last ?? ""
                    }

                    process.terminationHandler = { [weak self] terminatedProcess in
                        // Flush any data that arrived after the last readabilityHandler call.
                        let remainingStdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                        if let text = String(data: remainingStdout, encoding: .utf8), !text.isEmpty {
                            self?.logger?.appendStdout(text)
                            lineBuffer += text
                        }
                        // Process any lines remaining in the buffer.
                        for line in lineBuffer.components(separatedBy: "\n") where !line.isEmpty {
                            if let delta = Self.extractTextDelta(from: line) {
                                continuation.yield(delta)
                            }
                        }

                        let remainingStderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                        if let text = String(data: remainingStderr, encoding: .utf8), !text.isEmpty {
                            stderrBuffer += text
                        }

                        let duration = Date().timeIntervalSince(startTime)
                        let exitCode = Int(terminatedProcess.terminationStatus)
                        self?.logger?.finish(stderr: stderrBuffer, exitCode: exitCode, duration: duration)

                        ClaudeCodeDebugLogger.shared.post(
                            "[EXIT] code=\(exitCode)  duration=\(String(format: "%.1f", duration))s"
                        )

                        if exitCode != 0 {
                            let error = Self.parseError(from: stderrBuffer)
                            continuation.finish(throwing: error)
                        } else {
                            continuation.finish()
                        }
                    }

                    try process.run()
                    self.logger?.start()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Terminates the subprocess if it is running.
    func cancel() {
        process?.terminate()
        process = nil
    }

    // MARK: Private

    private var process: Process?
    private var logger: ClaudeCodeLogger?

    /// Parses one newline-delimited JSON line from `--output-format stream-json` output and
    /// returns the text delta string when the line represents a `content_block_delta` event.
    ///
    /// All other event types (system, rate_limit, result, etc.) return `nil` and are skipped.
    private static func extractTextDelta(from line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let wrapper = try? JSONDecoder().decode(CLIStreamJSONLine.self, from: data),
              wrapper.type == "stream_event",
              let inner = wrapper.event,
              inner.type == "content_block_delta",
              let delta = inner.delta,
              delta.type == "text_delta",
              let text = delta.text
        else { return nil }
        return text
    }

    /// Returns the path to the first `claude` binary found on this machine.
    ///
    /// - Throws: `ClaudeCodeError.notInstalled` if no binary is found.
    private static func detectClaudeBinary() throws -> String {
        // 1. Try via login shell so PATH from ~/.zshrc / ~/.bash_profile is available.
        //    GUI apps do not inherit the user's shell PATH, so a plain `which` call fails.
        if let path = runViaLoginShell("which claude") {
            return path
        }
        // 2. Check common manual-install locations as fallback.
        let candidates = [
            "\(NSHomeDirectory())/.local/bin/claude",
            "\(NSHomeDirectory())/.claude/local/claude",
            "/usr/local/bin/claude",
            "/opt/homebrew/bin/claude",
        ]
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        throw ClaudeCodeError.notInstalled
    }

    /// Runs a command via the user's login shell, returning trimmed stdout or nil on failure.
    ///
    /// Uses `-l` (login) so the shell sources the user's profile and picks up their full PATH.
    private static func runViaLoginShell(_ command: String) -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-c", command]
        process.standardOutput = pipe
        process.standardError = Pipe() // suppress stderr
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return path?.isEmpty == false ? path : nil
        } catch {
            return nil
        }
    }

    /// Runs `which <name>` directly (without a login shell).
    ///
    /// Used by unit tests, which run in an environment where PATH is already set correctly.
    private static func runWhich(_ name: String) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [name]
        process.standardOutput = pipe
        process.standardError = Pipe() // suppress stderr
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return path?.isEmpty == false ? path : nil
        } catch {
            return nil
        }
    }
}

// MARK: - CLIStreamJSONLine

/// Outer wrapper for one newline-delimited event from `--output-format stream-json`.
private struct CLIStreamJSONLine: Decodable {
    /// Event category (e.g. `"stream_event"`, `"result"`, `"system"`).
    let type: String
    /// Present when `type == "stream_event"`. Contains the inner Anthropic SSE event payload.
    let event: CLIInnerEvent?
}

// MARK: - CLIInnerEvent

/// The inner Anthropic SSE event re-emitted inside a `stream_event` line.
private struct CLIInnerEvent: Decodable {
    /// SSE event type (e.g. `"content_block_delta"`, `"message_start"`).
    let type: String
    /// Present for `content_block_delta` events.
    let delta: CLITextDelta?
}

// MARK: - CLITextDelta

/// Delta payload for `content_block_delta` events.
private struct CLITextDelta: Decodable {
    /// Delta kind — only `"text_delta"` carries translatable content.
    let type: String
    /// The incremental text for `text_delta` deltas.
    let text: String?
}

// MARK: - ClaudeCodeLogger

/// Writes a structured log file for one `claude -p` invocation.
private final class ClaudeCodeLogger {
    // MARK: Lifecycle

    init(command: String, prompt: String) {
        self.command = command
        self.prompt = prompt

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        self.timestamp = formatter.string(from: Date())

        let fileFormatter = DateFormatter()
        fileFormatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let dateStr = fileFormatter.string(from: Date())
        let uuid = UUID().uuidString.lowercased()
        self.fileName = "\(dateStr)_\(uuid).log"
    }

    // MARK: Internal

    /// Call once after the process is launched to write the request header.
    func start() {
        let header = """
        [REQUEST] \(timestamp)
        Command: \(command)
        Prompt: \(prompt)
        ---
        [STDOUT]
        """
        write(header + "\n")
        ClaudeCodeDebugLogger.shared.post(header)
    }

    /// Call for every stdout chunk received during streaming.
    func appendStdout(_ text: String) {
        write(text)
        ClaudeCodeDebugLogger.shared.post(text)
    }

    /// Call once when the process terminates.
    func finish(stderr: String, exitCode: Int, duration: TimeInterval) {
        let footer = """

        [STDERR] \(stderr.isEmpty ? "(none)" : stderr)
        [EXIT] code=\(exitCode)  duration=\(String(format: "%.1f", duration))s
        """
        write(footer + "\n")
        ClaudeCodeDebugLogger.shared.post(footer)
        pruneOldLogs()
    }

    // MARK: Private

    /// Maximum number of log files to keep. Oldest files are deleted when exceeded.
    private static let maxLogFiles = 50

    private let command: String
    private let prompt: String
    private let timestamp: String
    private let fileName: String
    private let queue = DispatchQueue(label: "claude-code-logger", qos: .utility)

    private lazy var fileURL: URL? = {
        guard let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        let logDir = base
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Easydict")
            .appendingPathComponent("logs")
            .appendingPathComponent("claude-code")
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        return logDir.appendingPathComponent(fileName)
    }()

    /// Deletes the oldest log files in the log directory when the count exceeds `maxLogFiles`.
    private func pruneOldLogs() {
        guard let logDir = fileURL?.deletingLastPathComponent() else { return }
        queue.async {
            let fm = FileManager.default
            guard let urls = try? fm.contentsOfDirectory(
                at: logDir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: .skipsHiddenFiles
            ) else { return }

            let logFiles = urls.filter { $0.pathExtension == "log" }
            guard logFiles.count > Self.maxLogFiles else { return }

            // Sort oldest first.
            let sorted = logFiles.sorted { a, b in
                let dateA = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                let dateB = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return dateA < dateB
            }

            let deleteCount = sorted.count - Self.maxLogFiles
            sorted.prefix(deleteCount).forEach { try? fm.removeItem(at: $0) }
        }
    }

    private func write(_ text: String) {
        guard let url = fileURL else { return }
        queue.async {
            if let data = text.data(using: .utf8) {
                if FileManager.default.fileExists(atPath: url.path) {
                    if let handle = try? FileHandle(forWritingTo: url) {
                        handle.seekToEndOfFile()
                        handle.write(data)
                        try? handle.close()
                    }
                } else {
                    try? data.write(to: url, options: .atomic)
                }
            }
        }
    }
}

// MARK: - ClaudeCodeDebugLogger

/// Broadcasts log events via `NotificationCenter` so the debug window can observe them
/// without creating a retain cycle between the runner and the window.
final class ClaudeCodeDebugLogger {
    static let shared = ClaudeCodeDebugLogger()

    static let didAppendNotification = Notification.Name("ClaudeCodeDebugLogDidAppend")
    static let textKey = "text"

    /// Posts a log line to all observers (no-op in Release builds).
    func post(_ text: String) {
        #if DEBUG
        NotificationCenter.default.post(
            name: Self.didAppendNotification,
            object: nil,
            userInfo: [Self.textKey: text]
        )
        #endif
    }
}

// MARK: - Test Helpers

#if DEBUG
extension ClaudeCodeCLIRunner {
    /// Exposes the private `parseError` method for unit testing.
    static func testParseError(from stderr: String) -> ClaudeCodeError {
        parseError(from: stderr)
    }

    /// Exposes the private `runWhich` method for unit testing.
    static func testRunWhich(_ name: String) -> String? {
        runWhich(name)
    }
}
#endif

extension ClaudeCodeCLIRunner {
    /// Returns the detected `claude` binary path, or `nil` if not found.
    ///
    /// Uses the same login-shell detection as `run(prompt:)`.
    /// Used by the configuration view status row.
    static func detectBinaryPath() -> String? {
        try? detectClaudeBinary()
    }
}
