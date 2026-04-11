//
//  ClaudeCodeCLIRunner.swift
//  Easydict
//
//  Created by Karl on 2026/04/07.
//  Copyright © 2026 izual. All rights reserved.
//

import Foundation

// MARK: - ClaudeCodeRunner

/// Wraps a `claude -p` subprocess and yields streaming text deltas as an `AsyncThrowingStream<String, Error>`.
///
/// Uses `--output-format stream-json --include-partial-messages` so the CLI emits one JSON event
/// per line. The runner extracts `content_block_delta` text deltas and forwards them to callers,
/// giving token-by-token granularity identical to the Anthropic API SSE stream.
///
/// Each instance represents exactly one subprocess invocation. Create a new instance per translation request.
final class ClaudeCodeRunner: @unchecked Sendable {
    // MARK: Lifecycle

    init() {}

    // MARK: Internal

    /// Token usage populated when the subprocess terminates normally.
    /// `nil` if the process has not yet finished or the `result` event was absent.
    private(set) var tokenUsage: CLITokenUsage?

    /// Runs `which <name>` directly (without a login shell).
    ///
    /// Used by unit tests, which run in an environment where PATH is already set correctly.
    static func runWhich(_ name: String) -> String? {
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
    /// - `--setting-sources ""` — skips loading all settings files (user/project/local), which
    ///   prevents plugins (e.g. superpowers) from registering their SessionStart hooks.
    ///   Credentials are still read from the keychain, so OAuth authentication is unaffected.
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

            // Use Task.detached to break out of any inherited actor context (e.g. @MainActor).
            // The call chain that reaches here is typically initiated from the main thread,
            // so a plain Task { } would run on the main actor and block the UI when
            // detectClaudeBinary() spawns a login shell on the first invocation.
            Task.detached(priority: .userInitiated) { [weak self] in
                // One decoder per invocation, shared across all readabilityHandler calls.
                // Avoids the per-line JSONDecoder allocation on the hot streaming path.
                let decoder = JSONDecoder()
                do {
                    let binaryPath = try Self.detectClaudeBinary()
                    #if AGENT_CLI_DEBUG
                    self?.logger = ClaudeCodeLogger(command: "\(binaryPath) -p <prompt>", prompt: prompt)
                    #endif

                    let process = Process()
                    let stdoutPipe = Pipe()
                    let stderrPipe = Pipe()

                    process.executableURL = URL(fileURLWithPath: binaryPath)
                    process.arguments = Self.buildArguments(prompt: prompt, systemPrompt: systemPrompt)
                    process.standardOutput = stdoutPipe
                    process.standardError = stderrPipe
                    // Use a neutral working directory so claude does not scan user folders.
                    process.currentDirectoryURL = FileManager.default.temporaryDirectory

                    self?.process = process

                    let startTime = Date()
                    var stderrBuffer = ""
                    // Accumulates only non-delta stdout lines for post-exit error/usage detection.
                    // Excludes content_block_delta events to bound memory usage.
                    var stdoutControlBuffer = ""
                    // Incomplete JSON line carried over between readabilityHandler calls.
                    var lineBuffer = ""

                    // Read stderr asynchronously into a buffer (capped at 1 MB).
                    stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                        let data = handle.availableData
                        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                        Self.ioQueue.async {
                            let maxSize = 1_048_576 // 1 MB
                            if stderrBuffer.utf8.count + text.utf8.count <= maxSize {
                                stderrBuffer += text
                            } else {
                                stderrBuffer = String((stderrBuffer + text).suffix(maxSize))
                            }
                        }
                    }

                    // Read stdout line by line, parse each JSON event, and yield text deltas.
                    // Only non-delta lines are kept in stdoutControlBuffer for error/usage parsing.
                    stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                        let data = handle.availableData
                        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                        let capturedLogger = self?.logger
                        Self.ioQueue.async {
                            capturedLogger?.appendStdout(text)
                            lineBuffer += text

                            // Every complete line (all but the last element after splitting on \n)
                            // is a full JSON event. The last element is a partial line kept in the buffer.
                            let lines = lineBuffer.components(separatedBy: "\n")
                            for line in lines.dropLast() where !line.isEmpty {
                                if let delta = extractTextDelta(from: line, decoder: decoder) {
                                    continuation.yield(delta)
                                } else {
                                    // Retain control events (result, rate_limit_event, system) for
                                    // post-exit error detection and token-usage parsing.
                                    stdoutControlBuffer += line + "\n"
                                }
                            }
                            lineBuffer = lines.last ?? ""
                        }
                    }

                    process.terminationHandler = { [weak self] terminatedProcess in
                        // Nil out handlers to stop new deliveries from the OS.
                        stdoutPipe.fileHandleForReading.readabilityHandler = nil
                        stderrPipe.fileHandleForReading.readabilityHandler = nil

                        // Capture isCancelled by value NOW, while self may still exist.
                        // ClaudeCodeService.cancelStream() sets runner = nil immediately, so
                        // self can be deallocated before ioQueue.async runs, making
                        // self?.isCancelled evaluate as nil (i.e. false) even after cancellation.
                        let wasCancelled = self?.isCancelled == true

                        // Read remaining pipe data synchronously on the termination-handler queue
                        // before dispatching to ioQueue, so the OS pipe buffer is drained promptly.
                        let remainingStdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                        let remainingStderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

                        let exitCode = Int(terminatedProcess.terminationStatus)
                        // Capture logger strongly so it outlives the weak self reference.
                        let capturedLogger = self?.logger

                        Self.ioQueue.async { [weak self] in
                            if let text = String(data: remainingStdoutData, encoding: .utf8), !text.isEmpty {
                                capturedLogger?.appendStdout(text)
                                lineBuffer += text
                            }

                            // Process any lines remaining in the line buffer.
                            for line in lineBuffer.components(separatedBy: "\n") where !line.isEmpty {
                                if let delta = extractTextDelta(from: line, decoder: decoder) {
                                    continuation.yield(delta)
                                } else {
                                    stdoutControlBuffer += line + "\n"
                                }
                            }

                            if let text = String(data: remainingStderrData, encoding: .utf8), !text.isEmpty {
                                let maxSize = 1_048_576
                                if stderrBuffer.utf8.count + text.utf8.count <= maxSize {
                                    stderrBuffer += text
                                } else {
                                    stderrBuffer = String((stderrBuffer + text).suffix(maxSize))
                                }
                            }

                            let duration = Date().timeIntervalSince(startTime)
                            capturedLogger?.finish(stderr: stderrBuffer, exitCode: exitCode, duration: duration)

                            // Parse token usage from the `result` event in the control-line buffer.
                            self?.tokenUsage = parseTokenUsage(from: stdoutControlBuffer)

                            ClaudeCodeDebugLogger.shared.post(
                                "[EXIT] code=\(exitCode)  duration=\(String(format: "%.1f", duration))s"
                            )

                            if exitCode != 0, !wasCancelled {
                                let error = parseError(fromStdout: stdoutControlBuffer, stderr: stderrBuffer)
                                continuation.finish(throwing: error)
                            } else {
                                // Either success or user-initiated cancellation — finish cleanly.
                                continuation.finish()
                            }
                        }
                    }

                    // Guard against launching after cancellation that arrived during setup.
                    // cancel() can only terminate a process it already knows about; if it
                    // ran before self?.process was assigned, the subprocess would still launch.
                    guard self?.isCancelled != true else {
                        continuation.finish()
                        return
                    }
                    try process.run()
                    self?.logger?.start()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Terminates the subprocess if it is running.
    func cancel() {
        isCancelled = true
        process?.terminate()
        process = nil
    }

    // MARK: Private

    /// Cached path from the first successful `detectClaudeBinary()` call.
    /// Avoids spawning a login shell on every translation request.
    private static var cachedBinaryPath: String?
    private static let cacheLock = NSLock()

    /// Shared serial queue for all I/O handler dispatches across invocations.
    /// Reusing one queue avoids the overhead of creating a new DispatchQueue per translation.
    private static let ioQueue = DispatchQueue(
        label: "com.easydict.claude-code-runner-io",
        qos: .userInitiated
    )

    private var process: Process?
    private var logger: ClaudeCodeLogger?
    /// Set to `true` by `cancel()` so the termination handler can distinguish
    /// a user-initiated stop from a real CLI failure.
    private var isCancelled = false

    /// Builds the argument list for a `claude -p` invocation.
    ///
    /// Extracted from `run()` to keep that method within the line-length limit.
    private static func buildArguments(prompt: String, systemPrompt: String?) -> [String] {
        var arguments = [
            "-p", prompt,
            "--output-format", "stream-json",
            "--include-partial-messages",
            "--no-session-persistence",
            "--tools", "", // disable all built-in tools
            "--strict-mcp-config", // ignore user MCP config; no --mcp-config = no servers
            "--setting-sources", "", // skip all settings files to prevent plugin hooks
        ]
        #if AGENT_CLI_DEBUG
        arguments.append("--verbose")
        #endif
        if let systemPrompt, !systemPrompt.isEmpty {
            arguments += ["--system-prompt", systemPrompt]
        }
        return arguments
    }

    /// Returns the path to the first `claude` binary found on this machine.
    ///
    /// The result is cached after the first successful lookup so the login-shell
    /// invocation only happens once per app session.
    ///
    /// - Throws: `ClaudeCodeError.notInstalled` if no binary is found.
    private static func detectClaudeBinary() throws -> String {
        // Fast path: return cached value without acquiring the lock.
        if let cached = cachedBinaryPath {
            return cached
        }
        // Slow path: acquire lock, re-check (double-checked locking), then resolve.
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached = cachedBinaryPath {
            return cached
        }
        // 1. Try via login shell so PATH from ~/.zshrc / ~/.bash_profile is available.
        //    GUI apps do not inherit the user's shell PATH, so a plain `which` call fails.
        //    Login shells may emit banner text or alias output before the actual path, so
        //    split by newline and find the first line that is an executable file.
        if let raw = runViaLoginShell("which claude") {
            let validated = raw
                .components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty && FileManager.default.isExecutableFile(atPath: $0) }
            if let path = validated {
                cachedBinaryPath = path
                return path
            }
        }
        // 2. Check common manual-install locations as fallback.
        let candidates = [
            "\(NSHomeDirectory())/.local/bin/claude",
            "\(NSHomeDirectory())/.claude/local/claude",
            "/usr/local/bin/claude",
            "/opt/homebrew/bin/claude",
        ]
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            cachedBinaryPath = candidate
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
}

extension ClaudeCodeRunner {
    /// Returns the detected `claude` binary path, or `nil` if not found.
    ///
    /// Uses the same login-shell detection as `run(prompt:)`.
    /// Used by the configuration view status row.
    static func detectBinaryPath() -> String? {
        try? detectClaudeBinary()
    }
}
