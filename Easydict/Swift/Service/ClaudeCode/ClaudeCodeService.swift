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
/// cross-query conversation state. The service overrides `contentStreamTranslate`
/// to slot into the `StreamService` pipeline — all accumulation, throttling,
/// and result management are handled by the base class.
@objc(EZClaudeCodeService)
class ClaudeCodeService: StreamService {
    // MARK: Public

    public override func serviceType() -> ServiceType {
        .claudeCode
    }

    public override func name() -> String {
        "Claude Code"
    }

    public override func apiKeyRequirement() -> ServiceAPIKeyRequirement {
        .cli
    }

    public override func cancelStream() {
        runner?.cancel()
        runner = nil
    }

    public override func configurationListItems() -> Any? {
        CLIServiceConfigurationView(service: self)
    }

    // MARK: Internal

    /// Spawns `claude -p <prompt>` and streams its stdout as raw text chunks.
    ///
    /// The base class `streamTranslate` handles chunk accumulation, `isStreamFinished`,
    /// `getFinalResultText`, and error propagation, so this method only needs to
    /// assemble the prompt and hand the stream to the runner.
    override func contentStreamTranslate(
        _ text: String,
        from: Language,
        to: Language
    )
        -> AsyncThrowingStream<String, Error> {
        let queryType = queryType(text: text, from: from, to: to)
        let chatQueryParam = ChatQueryParam(
            text: text,
            sourceLanguage: from,
            targetLanguage: to,
            queryType: queryType,
            enableSystemPrompt: true
        )

        // Flatten the structured chat messages into a single prompt string.
        // `claude -p` accepts a plain-text prompt, so role prefixes serve as
        // lightweight conversation framing for the few-shot examples.
        let prompt = chatMessageDicts(chatQueryParam)
            .map { "\($0.role.rawValue): \($0.content)" }
            .joined(separator: "\n\n")

        let currentRunner = ClaudeCodeCLIRunner()
        runner = currentRunner
        return currentRunner.run(prompt: prompt)
    }

    // MARK: Private

    private var runner: ClaudeCodeCLIRunner?
}
