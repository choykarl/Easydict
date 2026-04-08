//
//  ClaudeCodeCLIRunnerTests.swift
//  EasydictTests
//
//  Created by Karl on 2026/04/07.
//  Copyright © 2026 izual. All rights reserved.
//

@testable import Easydict
import Testing

@Suite("ClaudeCodeCLIRunner")
struct ClaudeCodeCLIRunnerTests {
    // MARK: - parseError (stderr-only) tests

    @Test("parseError returns notLoggedIn when stderr contains 'not logged in'")
    func parseErrorNotLoggedIn() {
        let error = ClaudeCodeRunner.testParseError(from: "Error: not logged in")
        #expect(error == .notLoggedIn)
    }

    @Test("parseError returns notLoggedIn when stderr contains 'authentication'")
    func parseErrorAuthentication() {
        let error = ClaudeCodeRunner.testParseError(from: "authentication failed")
        #expect(error == .notLoggedIn)
    }

    @Test("parseError returns quotaExceeded when stderr contains 'rate limit'")
    func parseErrorRateLimit() {
        let error = ClaudeCodeRunner.testParseError(from: "rate limit exceeded")
        #expect(error == .quotaExceeded(message: nil))
    }

    @Test("parseError returns quotaExceeded when stderr contains 'usage limit'")
    func parseErrorUsageLimit() {
        let error = ClaudeCodeRunner.testParseError(from: "usage limit reached")
        #expect(error == .quotaExceeded(message: nil))
    }

    @Test("parseError returns cliError for unknown stderr")
    func parseErrorUnknown() {
        let message = "something went wrong"
        let error = ClaudeCodeRunner.testParseError(from: message)
        #expect(error == .cliError(message: message))
    }

    // MARK: - parseError (stdout + stderr) tests

    @Test("parseError detects rate_limit_event in stdout and returns quotaExceeded")
    func parseErrorRateLimitEventInStdout() {
        let rateLimitLine = #"{"type":"rate_limit_event","rate_limit_info":{"status":"rejected"}}"#
        let resultLine =
            #"{"type":"result","subtype":"success","is_error":true,"result":"You've hit your limit \u00b7 resets 3am","#
                + #""duration_ms":100,"num_turns":1,"total_cost_usd":0,"usage":{},"modelUsage":{}}"#
        let stdout = rateLimitLine + "\n" + resultLine
        let error = ClaudeCodeRunner.testParseError(fromStdout: stdout, stderr: "")
        #expect(error == .quotaExceeded(message: "You've hit your limit · resets 3am"))
    }

    @Test("parseError returns quotaExceeded with nil message when result text is missing")
    func parseErrorRateLimitEventNoMessage() {
        let rateLimitLine = #"{"type":"rate_limit_event","rate_limit_info":{"status":"rejected"}}"#
        let error = ClaudeCodeRunner.testParseError(fromStdout: rateLimitLine, stderr: "")
        #expect(error == .quotaExceeded(message: nil))
    }

    @Test("parseError falls back to stderr when stdout has no rate_limit_event")
    func parseErrorFallsBackToStderr() {
        let error = ClaudeCodeRunner.testParseError(fromStdout: "", stderr: "not logged in")
        #expect(error == .notLoggedIn)
    }

    // MARK: - runWhich tests

    @Test("runWhich finds /bin/sh which always exists on macOS")
    func runWhichFindsShell() {
        let path = ClaudeCodeRunner.testRunWhich("sh")
        #expect(path != nil)
        #expect(path?.contains("/sh") == true)
    }

    @Test("runWhich returns nil for a binary that does not exist")
    func runWhichMissingBinary() {
        let path = ClaudeCodeRunner.testRunWhich("__nonexistent_binary_xyz__")
        #expect(path == nil)
    }
}
