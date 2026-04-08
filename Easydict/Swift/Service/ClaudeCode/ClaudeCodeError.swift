//
//  ClaudeCodeError.swift
//  Easydict
//
//  Created by Karl on 2026/04/07.
//  Copyright © 2026 izual. All rights reserved.
//

import Foundation

/// Errors that can occur when invoking the Claude Code CLI.
enum ClaudeCodeError: Error, LocalizedError, Equatable {
    /// The `claude` binary was not found in any known location.
    case notInstalled
    /// The CLI exited with an authentication error.
    case notLoggedIn
    /// The CLI exited with a quota / rate-limit error.
    case quotaExceeded
    /// The CLI exited with a non-zero code for an unrecognised reason.
    case cliError(message: String)

    // MARK: Internal

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            String(localized: "service.claude_code.not_installed")
        case .notLoggedIn:
            String(localized: "service.claude_code.not_logged_in")
        case .quotaExceeded:
            String(localized: "service.claude_code.quota_exceeded")
        case let .cliError(message):
            String(localized: "service.claude_code.cli_error \(message)")
        }
    }
}
