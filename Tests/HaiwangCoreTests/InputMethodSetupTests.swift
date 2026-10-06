import XCTest
@testable import HaiwangCore

final class InputMethodSetupTests: XCTestCase {
    private func readyStatus() -> InputMethodSetupStatus {
        var status = InputMethodSetupStatus()
        status.installed = true
        status.registered = true
        status.parentEnabled = true
        status.modeEnabled = true
        return status
    }

    private func verifiedPractice() -> InputMethodPractice {
        var practice = InputMethodPractice()
        practice.menuConfirmed = true
        practice.recordInsertion("你好", selectedSourceID: InputMethodPreferences.systemSourceID, marked: false)
        return practice
    }

    func testFirstLaunchAndDeferralDoNotReportCompletion() {
        var progress = InputMethodOnboardingProgress()
        XCTAssertTrue(progress.shouldPresentAutomatically)
        progress.deferSetup()
        XCTAssertFalse(progress.shouldPresentAutomatically)
        XCTAssertFalse(progress.completed)
    }

    func testSetupStartsAtTheActualMissingRequirement() {
        var status = InputMethodSetupStatus()
        XCTAssertEqual(status.suggestedStep, .install)
        status.installed = true
        XCTAssertEqual(status.suggestedStep, .enable)
        status.registered = true
        status.modeEnabled = true
        XCTAssertFalse(status.enabled, "Default mode enablement cannot replace adding its parent")
        status.parentEnabled = true
        XCTAssertEqual(status.suggestedStep, .practice)
        status.updateAvailable = true
        XCTAssertEqual(status.suggestedStep, .install)
        XCTAssertFalse(status.canPractice)
    }

    func testUnavailableSystemQueryCannotUnlockSetupCompletion() {
        var status = readyStatus()
        status.queryAvailable = false
        var progress = InputMethodOnboardingProgress()
        XCTAssertFalse(progress.complete(status: status, practice: verifiedPractice()))
        XCTAssertFalse(progress.completed)
    }

    func testWrongKeyboardMarkedTextPasteAndEnglishDoNotCountAsPinyinPractice() {
        var practice = InputMethodPractice()
        practice.recordInsertion("你好", selectedSourceID: "com.apple.inputmethod.SCIM.ITABC", marked: false)
        practice.recordInsertion("你好", selectedSourceID: InputMethodPreferences.systemSourceID, marked: true)
        practice.recordInsertion("你好", selectedSourceID: InputMethodPreferences.systemSourceID, marked: false, pasted: true)
        practice.recordInsertion("nihao", selectedSourceID: InputMethodPreferences.systemSourceID, marked: false)
        XCTAssertFalse(practice.verified)
        practice.recordInsertion("你好", selectedSourceID: InputMethodPreferences.systemSourceID, marked: false)
        XCTAssertTrue(practice.verified)
    }

    func testSuccessfulPracticeCanFinishWithoutChangingTheCurrentKeyboard() {
        var status = readyStatus()
        status.selected = false // The user may switch back after trying the keyboard.
        var progress = InputMethodOnboardingProgress()
        XCTAssertFalse(progress.complete(status: status, practice: .init()))
        XCTAssertTrue(progress.complete(status: status, practice: verifiedPractice()))
        XCTAssertTrue(progress.completed)
        XCTAssertFalse(progress.shouldPresentAutomatically)
    }

    func testRemovalOrUpdateAfterPracticeKeepsSetupIncomplete() {
        var progress = InputMethodOnboardingProgress()
        var status = readyStatus()
        status.installed = false
        XCTAssertFalse(progress.complete(status: status, practice: verifiedPractice()))
        status.installed = true
        status.parentEnabled = false
        XCTAssertFalse(progress.complete(status: status, practice: verifiedPractice()))
        status.parentEnabled = true
        status.updateAvailable = true
        XCTAssertFalse(progress.complete(status: status, practice: verifiedPractice()))
    }

    func testAPISuccessAndTypingCannotReplaceCheckingTheVisibleInputMenu() {
        var progress = InputMethodOnboardingProgress()
        var practice = verifiedPractice()
        practice.menuConfirmed = false
        XCTAssertFalse(progress.complete(status: readyStatus(), practice: practice))
        practice.menuConfirmed = true
        XCTAssertTrue(progress.complete(status: readyStatus(), practice: practice))
    }

    func testBuildComparisonOffersUpdatesWithoutDowngrading() {
        XCTAssertTrue(InputMethodBuild(version: "0.3.3", build: "6").isOlder(than: .init(version: "0.3.4", build: "7")))
        XCTAssertTrue(InputMethodBuild(version: "0.3.4", build: "7").isOlder(than: .init(version: "0.3.4", build: "10")))
        XCTAssertFalse(InputMethodBuild(version: "0.3.12", build: "1").isOlder(than: .init(version: "0.3.4", build: "7")))
        XCTAssertFalse(InputMethodBuild(version: "0.3.4", build: "7").isOlder(than: .init(version: "0.3.4", build: "7")))
    }

    func testProgressSurvivesRelaunchWithoutSavingPracticeTextOrChangingOtherPreferences() throws {
        let suite = "com.haiwang.tests.setup." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("keep this", forKey: "unrelated")
        var progress = InputMethodOnboardingProgress()
        progress.deferSetup()
        progress.save(to: defaults)
        XCTAssertEqual(InputMethodOnboardingProgress.load(from: defaults), progress)
        XCTAssertTrue(progress.complete(status: readyStatus(), practice: verifiedPractice()))
        progress.save(to: defaults)
        XCTAssertTrue(InputMethodOnboardingProgress.load(from: defaults).completed)
        XCTAssertFalse(String(decoding: try XCTUnwrap(defaults.data(forKey: InputMethodOnboardingProgress.storageKey)), as: UTF8.self).contains("你好"))
        XCTAssertEqual(defaults.string(forKey: "unrelated"), "keep this")
    }

    func testCorruptOrUnknownProgressRestartsSafely() {
        let suite = "com.haiwang.tests.setup." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        for value in ["broken", "{\"completed\":true,\"deferred\":false,\"schema\":99}"] {
            defaults.set(Data(value.utf8), forKey: InputMethodOnboardingProgress.storageKey)
            XCTAssertTrue(InputMethodOnboardingProgress.load(from: defaults).shouldPresentAutomatically)
        }
    }
}
