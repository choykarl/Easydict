//
//  ClaudeCodeServiceTests.swift
//  EasydictTests
//
//  Created by Karl on 2026/04/07.
//  Copyright © 2026 izual. All rights reserved.
//

@testable import Easydict
import Testing

@Suite("ClaudeCodeService")
struct ClaudeCodeServiceTests {
    @Test("serviceType returns .claudeCode")
    func serviceType() {
        let service = ClaudeCodeService()
        #expect(service.serviceType() == .claudeCode)
    }

    @Test("apiKeyRequirement returns .cli")
    func apiKeyRequirement() {
        let service = ClaudeCodeService()
        #expect(service.apiKeyRequirement() == .cli)
    }

    @Test("hasPrivateAPIKey always returns true")
    func hasPrivateAPIKey() {
        let service = ClaudeCodeService()
        #expect(service.hasPrivateAPIKey() == true)
    }

    @Test("isStream returns true")
    func isStream() {
        let service = ClaudeCodeService()
        #expect(service.isStream() == true)
    }

    @Test("name returns Claude Code")
    func serviceName() {
        let service = ClaudeCodeService()
        #expect(service.name() == "Claude Code")
    }

    @Test("QueryServiceFactory registers ClaudeCodeService")
    func factoryRegistration() {
        let service = QueryServiceFactory.shared.service(withTypeId: ServiceType.claudeCode.rawValue)
        #expect(service is ClaudeCodeService)
    }
}
