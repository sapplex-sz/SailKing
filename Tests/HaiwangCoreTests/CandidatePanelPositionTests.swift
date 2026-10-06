import Foundation
import XCTest
@testable import HaiwangCore

final class CandidatePanelPositionTests: XCTestCase {
    private func isolated(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "com.haiwang.tests.PanelPosition.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    func testNewInstallFollowsCaretWithoutWritingAPosition() throws {
        try isolated { defaults in
            XCTAssertNil(CandidatePanelPosition.load(from: defaults))
            XCTAssertNil(defaults.object(forKey: CandidatePanelPosition.storageKey))
        }
    }

    func testNegativeCoordinatesAndDisplayIdentitySurviveAnotherReader() throws {
        try isolated { defaults in
            let value = CandidatePanelPosition(left: -1280, top: 760, displayID: 42)
            value.save(to: defaults)
            let data = try XCTUnwrap(defaults.data(forKey: CandidatePanelPosition.storageKey))
            XCTAssertEqual(try JSONDecoder().decode(CandidatePanelPosition.self, from: data), value)
            XCTAssertEqual(CandidatePanelPosition.load(from: defaults), value)
        }
    }

    func testMissingDisplayIdentityAndInvalidStorageAreHandled() throws {
        try isolated { defaults in
            defaults.set(Data(#"{"left":240,"top":600}"#.utf8), forKey: CandidatePanelPosition.storageKey)
            XCTAssertEqual(CandidatePanelPosition.load(from: defaults), .init(left: 240, top: 600))
            for corrupt in ["broken", "{}", #"{"left":"240","top":600}"#] {
                defaults.set(Data(corrupt.utf8), forKey: CandidatePanelPosition.storageKey)
                XCTAssertNil(CandidatePanelPosition.load(from: defaults))
            }
        }
    }

    func testNonFiniteWritesCannotReplaceAValidPosition() throws {
        try isolated { defaults in
            let valid = CandidatePanelPosition(left: 80, top: 480)
            valid.save(to: defaults)
            for invalid in [CandidatePanelPosition(left: .nan, top: 0), .init(left: 0, top: .infinity)] {
                invalid.save(to: defaults)
                XCTAssertEqual(CandidatePanelPosition.load(from: defaults), valid)
            }
        }
    }

    func testResetPreservesTypingAndTranslationPreferences() throws {
        try isolated { defaults in
            let typing = InputMethodPreferences(inputMode: .english, translationEnabled: true)
            typing.save(to: defaults)
            let languages = KeyboardPreferences(market: .japan, source: .automatic)
            languages.save(to: defaults)
            CandidatePanelPosition(left: 80, top: 480).save(to: defaults)
            CandidatePanelPosition.reset(in: defaults)
            XCTAssertNil(CandidatePanelPosition.load(from: defaults))
            XCTAssertEqual(InputMethodPreferences.load(from: defaults), typing)
            XCTAssertEqual(KeyboardPreferences.load(from: defaults), languages)
        }
    }
}
