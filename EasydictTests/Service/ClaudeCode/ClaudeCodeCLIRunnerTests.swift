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
    // MARK: - parseError tests

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
        #expect(error == .quotaExceeded)
    }

    @Test("parseError returns quotaExceeded when stderr contains 'usage limit'")
    func parseErrorUsageLimit() {
        let error = ClaudeCodeRunner.testParseError(from: "usage limit reached")
        #expect(error == .quotaExceeded)
    }

    @Test("parseError returns cliError for unknown stderr")
    func parseErrorUnknown() {
        let message = "something went wrong"
        let error = ClaudeCodeRunner.testParseError(from: message)
        #expect(error == .cliError(message: message))
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
