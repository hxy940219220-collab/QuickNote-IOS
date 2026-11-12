import Foundation
import XCTest
@testable import QuickNote

final class CodexAccountProtocolTests: XCTestCase {
    func testModelListUsesDisplayNameDefaultAndCatalogEfforts() throws {
        let response: CodexJSON = ["data": [
            ["id": "catalog-entry", "model": "synthetic-model", "displayName": "测试模型",
             "isDefault": true, "hidden": false, "defaultReasoningEffort": "medium",
             "supportedReasoningEfforts": [
                ["reasoningEffort": "medium"], ["reasoningEffort": "high"],
                ["reasoningEffort": "medium"], ["description": "missing effort"]
             ]],
            ["id": "fallback-model", "model": "", "displayName": ""],
            ["model": "hidden-model", "hidden": true],
            ["displayName": "Missing model ID"]
        ]]

        XCTAssertEqual(try CodexAppServer.parseModels(response), [
            .init(id: "synthetic-model", title: "测试模型", efforts: ["medium", "high"],
                  isDefault: true, defaultEffort: "medium"),
            .init(id: "fallback-model", title: "fallback-model", efforts: [], isDefault: false)
        ])
        XCTAssertEqual(try CodexAppServer.parseModels(["data": []]), [])
        XCTAssertThrowsError(try CodexAppServer.parseModels([:]))
    }

    func testQuotaUsesCodexBucketAndWindowDuration() {
        let response: CodexJSON = [
            "rateLimits": ["primary": ["windowDurationMins": 300, "usedPercent": 1]],
            "rateLimitsByLimitId": [
                "unrelated": ["primary": ["windowDurationMins": 300, "usedPercent": 99]],
                "codex": [
                    "primary": ["windowDurationMins": 10_080, "usedPercent": .number(31.25),
                                "resetsAt": 1_800_000_000],
                    "secondary": ["windowDurationMins": 300, "usedPercent": .number(104.25)]
                ]
            ]
        ]

        let limits = CodexRateLimits.parse(response)
        XCTAssertEqual(limits.fiveHour, .init(usedPercent: 104.25, resetsAt: nil))
        XCTAssertEqual(limits.weekly, .init(usedPercent: 31.25,
                                            resetsAt: Date(timeIntervalSince1970: 1_800_000_000)))
    }

    func testQuotaAcceptsLegacyCodexUsageAndLeavesUnknownWindowsEmpty() {
        let response: CodexJSON = ["rateLimits": [
            "limitId": .null,
            "primary": ["windowDurationMins": 300, "usedPercent": 0, "resetsAt": .null],
            "secondary": ["windowDurationMins": 60, "usedPercent": 15]
        ]]
        XCTAssertEqual(CodexRateLimits.parse(response),
                       .init(fiveHour: .init(usedPercent: 0, resetsAt: nil), weekly: nil))

        let unknown = CodexRateLimits(fiveHour: nil, weekly: nil)
        XCTAssertEqual(CodexRateLimits.parse([:]), unknown)
        XCTAssertEqual(CodexRateLimits.parse(["rateLimits": [
            "limitId": "unrelated", "primary": ["windowDurationMins": 300, "usedPercent": 10]
        ]]), unknown)
        XCTAssertEqual(CodexRateLimits.parse(["rateLimits": [
            "primary": ["windowDurationMins": 300, "usedPercent": -1],
            "secondary": ["windowDurationMins": 10_080]
        ]]), unknown)
    }

    func testAccountParserOnlyReturnsManagedChatGPTIdentity() {
        XCTAssertEqual(CodexAccount.parse(["account": [
            "type": "chatgpt", "email": "synthetic@example.test", "planType": "plus"
        ]]), .init(email: "synthetic@example.test", planType: "plus"))
        XCTAssertEqual(CodexAccount.parse(["account": ["type": "chatgpt", "email": .null]]),
                       .init(email: nil, planType: nil))
        XCTAssertNil(CodexAccount.parse(["account": ["type": "apiKey"]]))
        XCTAssertNil(CodexAccount.parse(["account": .null]))
    }

    func testManagedLoginOnlyOpensOfficialHTTPSOrigins() throws {
        let official = try XCTUnwrap(URL(string: "https://auth.openai.com/oauth/authorize"))
        XCTAssertTrue(CodexAppServer.isOfficialLoginURL(official))
        for address in [
            "http://auth.openai.com/oauth/authorize", "https://auth.openai.com.example.test/",
            "https://example.test@auth.openai.com/", "https://auth.openai.com:8443/"
        ] {
            XCTAssertFalse(CodexAppServer.isOfficialLoginURL(try XCTUnwrap(URL(string: address))))
        }
    }
}
