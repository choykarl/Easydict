//
//  ClaudeCodeService.swift
//  Easydict
//
//  Created by Karl on 2026/04/07.
//  Copyright © 2026 izual. All rights reserved.
//

import Foundation

// MARK: - ClaudeCodeService

/// A translation service that delegates to the locally installed `claude` CLI tool.
///
/// Each translation spawns a fresh `claude -p` subprocess, so there is no
/// cross-query conversation state.
@objc(EZClaudeCodeService)
class ClaudeCodeService: StreamService {
    // MARK: Public

    override public func serviceType() -> ServiceType {
        .claudeCode
    }

    override public func name() -> String {
        "Claude Code"
    }

    override public func apiKeyRequirement() -> ServiceAPIKeyRequirement {
        .cli
    }

    /// Always returns `true` so the parent's free-quota gate is never triggered.
    override public func hasPrivateAPIKey() -> Bool {
        true
    }

    override public func isStream() -> Bool {
        true
    }

    override public func cancelStream() {
        runner?.cancel()
        runner = nil
    }

    override public func configurationListItems() -> Any? {
        CLIServiceConfigurationView(service: self)
    }

    /// Translates text by running `claude -p` and streaming its stdout.
    override public func translateStream(
        _ text: String,
        from: Language,
        to: Language
    )
        -> AsyncThrowingStream<QueryResult, Error> {
        AsyncThrowingStream { [weak self] continuation in
            Task {
                guard let self else {
                    continuation.finish()
                    return
                }

                let queryType = self.queryType(text: text, from: from, to: to)

                let chatQueryParam = ChatQueryParam(
                    text: text,
                    sourceLanguage: from,
                    targetLanguage: to,
                    queryType: queryType,
                    enableSystemPrompt: true
                )

                // Assemble the full prompt from built-in or custom prompt settings.
                let messages = self.chatMessageDicts(chatQueryParam)
                let prompt = messages
                    .map { "\($0.role.rawValue): \($0.content)" }
                    .joined(separator: "\n\n")

                self.result.isStreamFinished = false

                let currentRunner = ClaudeCodeCLIRunner()
                self.runner = currentRunner

                var accumulatedText = ""

                do {
                    for try await chunk in currentRunner.run(prompt: prompt) {
                        try Task.checkCancellation()
                        accumulatedText += chunk
                        self.updateResultText(
                            accumulatedText,
                            queryType: queryType,
                            error: nil
                        ) { result in
                            continuation.yield(result)
                        }
                    }

                    self.result.isStreamFinished = true
                    let finalText = self.getFinalResultText(accumulatedText)
                    self.updateResultText(finalText, queryType: queryType, error: nil) { result in
                        continuation.yield(result)
                    }
                    continuation.finish()
                } catch {
                    self.result.isStreamFinished = true
                    let queryError = self.toQueryError(error)
                    self.updateResultText(accumulatedText, queryType: queryType, error: queryError) { result in
                        continuation.yield(result)
                    }
                    continuation.finish(throwing: queryError)
                }
            }
        }
    }

    // MARK: Private

    private var runner: ClaudeCodeCLIRunner?

    /// Converts a `ClaudeCodeError` (or any other error) into a `QueryError` with a visible prefix.
    private func toQueryError(_ error: Error) -> QueryError {
        let prefix = "⚠️ [Claude Code Error] "
        if let claudeError = error as? ClaudeCodeError {
            return QueryError(
                type: .api,
                message: prefix + (claudeError.errorDescription ?? claudeError.localizedDescription)
            )
        }
        return QueryError(type: .api, message: prefix + error.localizedDescription)
    }
}
