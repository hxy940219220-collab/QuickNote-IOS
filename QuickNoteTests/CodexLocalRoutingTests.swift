import Security
import XCTest
@testable import QuickNote

final class CodexLocalRoutingTests: XCTestCase {
    func testInitialSourceDecisionWaitsForCodexVerificationAndPreservesExistingChoices() {
        XCTAssertNil(AIDefaultSourceDecision.persistInitialChoice(
            saved: .automatic, apiConfiguration: .empty, codexVerified: false
        ))
        XCTAssertEqual(AIDefaultSourceDecision.persistInitialChoice(
            saved: .automatic, apiConfiguration: .empty, codexVerified: true
        ), .codex)
        XCTAssertEqual(AIDefaultSourceDecision.persistInitialChoice(
            saved: .automatic, apiConfiguration: .configured, codexVerified: true
        ), .routedAPI)
        XCTAssertNil(AIDefaultSourceDecision.persistInitialChoice(
            saved: .automatic, apiConfiguration: .unreadable, codexVerified: true
        ))
        XCTAssertNil(AIDefaultSourceDecision.persistInitialChoice(
            saved: .routedAPI, apiConfiguration: .empty, codexVerified: true
        ))
        XCTAssertEqual(AIDefaultSourceDecision.resolve(saved: .system, apiConfiguration: .configured), .system)
        XCTAssertEqual(AIDefaultSourceDecision.resolve(saved: .api(.second), apiConfiguration: .empty), .api(.second))
        XCTAssertEqual(AIDefaultSourceDecision.resolve(saved: .automatic, apiConfiguration: .unreadable), .routedAPI)
    }

    @MainActor
    func testEveryAutomaticFeatureUsesCodexWithoutAPIKeys() throws {
        try withStore { store, _, _ in
            XCTAssertEqual(store.codexPreferences, CodexLocalPreferences())
            XCTAssertNil(store.codexPreferences.modelOverride)
            for feature in AIFeature.allCases {
                guard case .codex(let preferences) = store.resolvedSource(for: feature) else {
                    XCTFail("Expected Codex for \(feature)")
                    continue
                }
                XCTAssertEqual(preferences.effort, "low")
                XCTAssertEqual(store.dataDestinationDescription(for: feature), "发送至 Codex（ChatGPT 账号）")
            }
            XCTAssertEqual(store.defaultFeatureSource, .automatic)
            store.considerVerifiedCodexDefault()
            XCTAssertEqual(store.defaultFeatureSource, .codex)
        }
    }

    @MainActor
    func testExplicitAPISelectionWithNoKeysDoesNotUseVerifiedCodex() throws {
        try withStore { store, _, _ in
            store.defaultSourceSelection = .api
            store.considerVerifiedCodexDefault()

            XCTAssertEqual(store.defaultSourceSelection, .api)
            for feature in AIFeature.allCases {
                guard case .api(let routes) = store.resolvedSource(for: feature) else {
                    XCTFail("Expected API for \(feature)")
                    continue
                }
                XCTAssertTrue(routes.isEmpty)
            }
        }
    }

    @MainActor
    func testSwitchingBackToAPIRestoresTheLegacySource() throws {
        try withStore(apiKeys: ["0": "synthetic-first", "1": "synthetic-second"]) { store, defaults, keychain in
            defaults.set("api.1", forKey: "ai.source.default")
            XCTAssertEqual(store.defaultSourceSelection, .api)
            store.defaultSourceSelection = .codex

            let reopened = AIConfigurationStore(defaults: defaults, keychain: keychain)
            XCTAssertEqual(reopened.defaultSourceSelection, .codex)
            reopened.defaultSourceSelection = .api
            XCTAssertEqual(reopened.defaultFeatureSource, .api(.second))
            XCTAssertEqual(reopened.fixedDefaultAPIProfile, .second)
            guard case .api(let routes) = reopened.resolvedSource(for: .selection) else {
                return XCTFail("Expected the saved API profile")
            }
            XCTAssertEqual(routes.map(\.slot), [.second])

            reopened.useRoutedAPIByDefault()
            XCTAssertNil(reopened.fixedDefaultAPIProfile)
            guard case .api(let preferredRoutes) = reopened.resolvedSource(for: .selection) else {
                return XCTFail("Expected the preferred API route")
            }
            XCTAssertEqual(preferredRoutes.map(\.slot), [.first])
        }
    }

    @MainActor
    func testAppleTextChoicePreservesImageRoutesAndPerFeatureOverrides() throws {
        try withStore(apiKeys: ["0": "synthetic-first"]) { store, _, _ in
            store.saveInputModalities([.text, .image], for: .first)
            store.defaultSourceSelection = .api
            store.apiDefaultTextSource = .apple
            store.setFeatureSource(.routedAPI, for: .formatting)

            guard case .system = store.resolvedSource(for: .selection) else {
                return XCTFail("Expected Apple for inherited text")
            }
            guard case .api(let imageRoutes) = store.resolvedSource(for: .screenshot) else {
                return XCTFail("Expected API for inherited images")
            }
            XCTAssertEqual(imageRoutes.map(\.slot), [.first])
            guard case .api(let textRoutes) = store.resolvedSource(for: .formatting) else {
                return XCTFail("Expected the explicitly selected API route")
            }
            XCTAssertEqual(textRoutes.map(\.slot), [.first])

            store.defaultSourceSelection = .codex
            guard case .codex = store.resolvedSource(for: .selection) else {
                return XCTFail("Expected Codex after switching the default")
            }
            store.setFeatureSource(.system, for: .voiceOrganization)
            guard case .system = store.resolvedSource(for: .voiceOrganization) else {
                return XCTFail("Expected the per-feature Apple choice to override Codex")
            }
        }
    }

    @MainActor
    func testLegacyAppleDefaultRemainsAppleUntilTheUserChangesIt() throws {
        try withStore(apiKeys: ["0": "synthetic-first"]) { store, defaults, _ in
            defaults.set("system", forKey: "ai.source.default")
            store.considerVerifiedCodexDefault()
            XCTAssertEqual(store.defaultSourceSelection, .api)
            XCTAssertEqual(store.apiDefaultTextSource, .apple)
            guard case .system = store.resolvedSource(for: .selection),
                  case .system = store.resolvedSource(for: .screenshot) else {
                return XCTFail("Expected both modalities to preserve the legacy Apple selection")
            }
            store.apiDefaultTextSource = .api
            guard case .api(let routes) = store.resolvedSource(for: .selection) else {
                return XCTFail("Expected the newly selected API route")
            }
            XCTAssertEqual(routes.map(\.slot), [.first])
        }
    }

    @MainActor
    func testExplicitSourcesStaySelectedAndPersistWithoutChangingAPIRouting() throws {
        try withStore(apiKeys: ["0": "synthetic-first", "1": "synthetic-second"]) { store, defaults, keychain in
            store.automaticFallback = true
            guard case .api(let legacyRoutes) = store.resolvedSource(for: .selection) else {
                return XCTFail("Expected configured API routes in automatic mode")
            }
            XCTAssertEqual(legacyRoutes.map(\.slot), [.first, .second])

            let preferences = CodexLocalPreferences(executablePath: "/tmp/synthetic-codex",
                                                   model: "synthetic-model", effort: "medium")
            store.codexPreferences = preferences
            store.defaultFeatureSource = .codex
            store.setFeatureSource(.api(.second), for: .selection)
            store.setFeatureSource(.api(.first), for: .screenshot)
            store.setFeatureSource(.system, for: .noteQuestion)

            let reopened = AIConfigurationStore(defaults: defaults, keychain: keychain)
            guard case .api(let selectedRoutes) = reopened.resolvedSource(for: .selection) else {
                return XCTFail("Expected the selected API profile")
            }
            XCTAssertEqual(selectedRoutes.map(\.slot), [.second])
            guard case .api(let unsupportedRoutes) = reopened.resolvedSource(for: .screenshot) else {
                return XCTFail("Expected the selected API to report no image route")
            }
            XCTAssertTrue(unsupportedRoutes.isEmpty)
            guard case .system = reopened.resolvedSource(for: .noteQuestion) else {
                return XCTFail("Expected Apple local model selection to persist")
            }
            reopened.setFeatureSource(nil, for: .selection)
            guard case .codex(let restored) = reopened.resolvedSource(for: .selection) else {
                return XCTFail("Expected the inherited default to select Codex")
            }
            XCTAssertEqual(restored, preferences)
            XCTAssertEqual(reopened.preferredSlot(for: .text), .first)
        }
    }

    @MainActor
    func testAnUnreadableVaultDoesNotChooseCodexAutomatically() throws {
        try withStore(keychainStatus: errSecAuthFailed) { store, _, _ in
            if case .codex = store.resolvedSource(for: .selection) {
                XCTFail("An unreadable vault is not an empty vault")
            }
            store.setFeatureSource(.codex, for: .selection)
            guard case .codex = store.resolvedSource(for: .selection) else {
                return XCTFail("An explicit Codex selection is independent of API key access")
            }
        }
    }

    @MainActor
    private func withStore(
        apiKeys: [String: String] = [:],
        keychainStatus: OSStatus = errSecSuccess,
        _ check: (AIConfigurationStore, UserDefaults, APIKeyKeychain) throws -> Void
    ) throws {
        let suite = "QuickNoteTests.CodexLocalRouting.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let data = try JSONEncoder().encode(apiKeys)
        let keychain = APIKeyKeychain(copyMatching: { _, output in
            guard keychainStatus == errSecSuccess else { return keychainStatus }
            guard !apiKeys.isEmpty else { return errSecItemNotFound }
            output.pointee = data as CFData
            return errSecSuccess
        })
        try check(AIConfigurationStore(defaults: defaults, keychain: keychain), defaults, keychain)
    }
}
