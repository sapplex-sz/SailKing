import Foundation
import XCTest
@testable import HaiwangCore

final class KeyboardPreferencesTests: XCTestCase {
    private func withIsolatedDefaults(_ test: (UserDefaults) throws -> Void) throws {
        let suite = "com.haiwang.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try test(defaults)
    }

    func testNewInstallationDetectsAnySourceLanguageWithoutAssumingChinese() throws {
        try withIsolatedDefaults { defaults in
            let initial = KeyboardPreferences.load(from: defaults)
            XCTAssertEqual(initial, KeyboardPreferences(market: .unitedStates, source: .automatic))
            XCTAssertNil(initial.source.languageIdentifier, "Automatic detection must reach the translator as an unspecified source.")
        }
    }

    func testEverySelectableMarketAndSourceSurvivesSavingAndLoading() throws {
        try withIsolatedDefaults { defaults in
            for source in SourceLanguage.allCases {
                for market in Market.allCases {
                    let chosen = KeyboardPreferences(market: market, source: source)
                    chosen.save(to: defaults)
                    XCTAssertEqual(KeyboardPreferences.load(from: defaults), chosen)
                }
            }
        }
    }

    func testRegionalMarketsDoNotCollapseIntoTheirSharedLanguageOnDisk() throws {
        try withIsolatedDefaults { defaults in
            for market in [Market.unitedStates, .unitedKingdom, .spain, .mexico] {
                KeyboardPreferences(market: market, source: .english).save(to: defaults)
                let reloaded = KeyboardPreferences.load(from: defaults)
                XCTAssertEqual(reloaded.market, market, "A chosen country must survive even when another country uses the same language.")
                XCTAssertEqual(reloaded.source, .english)
            }
        }
    }

    func testCorruptedOrUnknownSavedValuesFallBackWithoutCrashing() throws {
        try withIsolatedDefaults { defaults in
            let invalidValues = [
                Data([0xFF, 0xFE]),
                Data("not JSON".utf8),
                Data("{}".utf8),
                Data(#"{"market":"futureMarket","source":"en"}"#.utf8),
                Data(#"{"market":"japan","source":"futureLanguage"}"#.utf8)
            ]
            for data in invalidValues {
                defaults.set(data, forKey: KeyboardPreferences.storageKey)
                XCTAssertEqual(KeyboardPreferences.load(from: defaults), KeyboardPreferences())
            }
            defaults.set("unexpected storage type", forKey: KeyboardPreferences.storageKey)
            XCTAssertEqual(KeyboardPreferences.load(from: defaults), KeyboardPreferences())
        }
    }

    func testSavingValidPreferencesRecoversFromCorruptStorageAndRetainsOtherSettings() throws {
        try withIsolatedDefaults { defaults in
            defaults.set(Data("broken".utf8), forKey: KeyboardPreferences.storageKey)
            defaults.set(true, forKey: "onboarding-complete")

            let corrected = KeyboardPreferences(market: .japan, source: .english)
            corrected.save(to: defaults)

            XCTAssertEqual(KeyboardPreferences.load(from: defaults), corrected)
            XCTAssertTrue(defaults.bool(forKey: "onboarding-complete"))
        }
    }

    func testNonEnglishSourceAndTargetMappingsSurvivePersistenceWithoutAnIntermediateLanguage() throws {
        let pairs: [(SourceLanguage, Market, String, String)] = [
            (.french, .japan, "fr", "ja"),
            (.spanish, .germany, "es", "de"),
            (.arabic, .france, "ar", "fr"),
            (.hindi, .brazil, "hi", "pt")
        ]
        try withIsolatedDefaults { defaults in
            for (source, market, expectedSource, expectedTarget) in pairs {
                KeyboardPreferences(market: market, source: source).save(to: defaults)
                let loaded = KeyboardPreferences.load(from: defaults)
                XCTAssertEqual(loaded.source.languageIdentifier, expectedSource)
                XCTAssertEqual(loaded.market.languageIdentifier, expectedTarget)
                XCTAssertNotEqual(loaded.source, .chinese)
                XCTAssertNotEqual(loaded.source, .english)
            }
        }
    }

    func testAutomaticSourceIsSavedExplicitlyAndReloadsAsNilLanguageIdentifier() throws {
        try withIsolatedDefaults { defaults in
            KeyboardPreferences(market: .germany, source: .automatic).save(to: defaults)
            let data = try XCTUnwrap(defaults.data(forKey: KeyboardPreferences.storageKey))
            let stored = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
            XCTAssertEqual(stored["source"], "auto", "Auto-detection must persist as a mode, not the most recently detected language.")

            let loaded = KeyboardPreferences.load(from: defaults)
            XCTAssertEqual(loaded.source, .automatic)
            XCTAssertNil(loaded.source.languageIdentifier)
            XCTAssertEqual(loaded.market, .germany)
            XCTAssertEqual(loaded.market.languageIdentifier, "de")
        }
    }

    func testPreviouslySavedChineseAndEnglishChoicesRemainExplicitAfterDefaultChanges() throws {
        try withIsolatedDefaults { defaults in
            let legacyValues: [(String, SourceLanguage)] = [
                (#"{"market":"japan","source":"zh-Hans"}"#, .chinese),
                (#"{"market":"japan","source":"en"}"#, .english)
            ]
            for (json, expectedSource) in legacyValues {
                defaults.set(Data(json.utf8), forKey: KeyboardPreferences.storageKey)
                let loaded = KeyboardPreferences.load(from: defaults)
                XCTAssertEqual(loaded.source, expectedSource)
                XCTAssertEqual(loaded.market, .japan)
                XCTAssertNotNil(loaded.source.languageIdentifier)
            }
        }
    }

    func testScriptSpecificChineseChoicesRemainDistinctFromAutomaticDetection() throws {
        try withIsolatedDefaults { defaults in
            KeyboardPreferences(market: .taiwan, source: .chinese).save(to: defaults)
            var loaded = KeyboardPreferences.load(from: defaults)
            XCTAssertEqual(loaded.source.languageIdentifier, "zh-Hans")
            XCTAssertEqual(loaded.market.languageIdentifier, "zh-Hant")

            KeyboardPreferences(market: .china, source: .traditionalChinese).save(to: defaults)
            loaded = KeyboardPreferences.load(from: defaults)
            XCTAssertEqual(loaded.source.languageIdentifier, "zh-Hant")
            XCTAssertEqual(loaded.market.languageIdentifier, "zh-Hans")
        }
    }
}
