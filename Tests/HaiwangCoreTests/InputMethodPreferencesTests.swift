import Foundation
import XCTest
@testable import HaiwangCore

final class InputMethodPreferencesTests: XCTestCase {
    private func withIsolatedDefaults(_ test: (UserDefaults) throws -> Void) throws {
        let suite = "com.haiwang.inputmethod.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try test(defaults)
    }

    func testNewInstallationStartsInOrdinaryPinyinMode() throws {
        try withIsolatedDefaults { defaults in
            XCTAssertEqual(InputMethodPreferences.load(from: defaults), .init(inputMode: .pinyin, translationEnabled: false))
            XCTAssertNil(defaults.object(forKey: InputMethodPreferences.storageKey), "Loading defaults must not change stored settings.")
        }
    }

    func testTypingModeAndTranslationBehaviorPersistIndependently() throws {
        try withIsolatedDefaults { defaults in
            for mode in InputMethodInputMode.allCases {
                for translationEnabled in [false, true] {
                    let chosen = InputMethodPreferences(inputMode: mode, translationEnabled: translationEnabled)
                    chosen.save(to: defaults)
                    XCTAssertEqual(InputMethodPreferences.load(from: defaults), chosen)
                }
            }
        }
    }

    func testSavedPreferencesAreVisibleToASeparateDefaultsReader() throws {
        let suite = "com.haiwang.inputmethod.tests.\(UUID().uuidString)"
        let writer = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { writer.removePersistentDomain(forName: suite) }
        let chosen = InputMethodPreferences(inputMode: .english, translationEnabled: true)
        chosen.save(to: writer)
        let reader = try XCTUnwrap(UserDefaults(suiteName: suite))
        XCTAssertEqual(InputMethodPreferences.load(from: reader), chosen)
    }

    func testTypingLanguagesShareOneStableSystemInputSource() {
        XCTAssertEqual(InputMethodInputMode.pinyin.systemID, "com.haiwang.inputmethod.Haiwang.pinyin")
        XCTAssertEqual(InputMethodInputMode.english.systemID, InputMethodInputMode.pinyin.systemID)
        XCTAssertEqual(Set(InputMethodInputMode.allCases.map(\.systemID)).count, 1)
        XCTAssertEqual(InputMethodPreferences.legacyEnglishSourceID, "com.haiwang.inputmethod.Haiwang.english")
        XCTAssertNotEqual(InputMethodPreferences.systemSourceID, InputMethodPreferences.legacyEnglishSourceID)
        for mode in InputMethodInputMode.allCases {
            XCTAssertFalse(mode.title.isEmpty)
            XCTAssertNotEqual(mode.systemID, "com.haiwang.inputmethod.Haiwang")
        }
    }

    func testCorruptMissingOrUnknownFieldsReturnSafeOrdinaryDefaults() throws {
        try withIsolatedDefaults { defaults in
            let corruptValues = [
                Data([0xff, 0xfe]),
                Data("not JSON".utf8),
                Data("{}".utf8),
                Data(#"{"inputMode":"futureMode","translationEnabled":true}"#.utf8),
                Data(#"{"inputMode":"pinyin"}"#.utf8),
                Data(#"{"translationEnabled":true}"#.utf8),
                Data(#"{"inputMode":"pinyin","translationEnabled":"true"}"#.utf8)
            ]
            for data in corruptValues {
                defaults.set(data, forKey: InputMethodPreferences.storageKey)
                XCTAssertEqual(InputMethodPreferences.load(from: defaults), InputMethodPreferences())
            }
            defaults.set("wrong storage type", forKey: InputMethodPreferences.storageKey)
            XCTAssertEqual(InputMethodPreferences.load(from: defaults), InputMethodPreferences())
        }
    }

    func testInputMethodPreferencesNeverReplaceWorkspaceLanguagesOrOtherSettings() throws {
        try withIsolatedDefaults { defaults in
            let workspace = KeyboardPreferences(market: .japan, source: .french)
            workspace.save(to: defaults)
            defaults.set(true, forKey: "onboarding-complete")
            for mode in InputMethodInputMode.allCases {
                let chosen = InputMethodPreferences(inputMode: mode, translationEnabled: true)
                chosen.save(to: defaults)
                XCTAssertEqual(KeyboardPreferences.load(from: defaults), workspace)
                XCTAssertTrue(defaults.bool(forKey: "onboarding-complete"))
                XCTAssertEqual(InputMethodPreferences.load(from: defaults), chosen)
            }
            KeyboardPreferences(market: .germany, source: .automatic).save(to: defaults)
            XCTAssertEqual(InputMethodPreferences.load(from: defaults), .init(inputMode: .english, translationEnabled: true))
        }
    }

    func testValidSaveRepairsCorruptInputMethodStorage() throws {
        try withIsolatedDefaults { defaults in
            defaults.set(Data("broken".utf8), forKey: InputMethodPreferences.storageKey)
            let chosen = InputMethodPreferences(inputMode: .english, translationEnabled: false)
            chosen.save(to: defaults)
            XCTAssertEqual(InputMethodPreferences.load(from: defaults), chosen)
            let data = try XCTUnwrap(defaults.data(forKey: InputMethodPreferences.storageKey))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(json["inputMode"] as? String, "english")
            XCTAssertEqual(json["translationEnabled"] as? Bool, false)
        }
    }
}
