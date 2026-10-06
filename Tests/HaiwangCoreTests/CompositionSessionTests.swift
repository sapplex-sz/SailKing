import XCTest
@testable import HaiwangCore

final class CompositionSessionTests: XCTestCase {
    func testTranslationIsOnlyConsumedOnExplicitConfirmationAndOnlyOnce() throws {
        var session = CompositionSession()
        session.setSource("您好，订单已经发出。")
        let token = try XCTUnwrap(session.beginTranslation())

        XCTAssertNil(session.takeTranslation(), "An in-flight request cannot be committed.")
        XCTAssertTrue(session.finish("  Your order has shipped.\n", revision: token))
        XCTAssertEqual(session.source, "您好，订单已经发出。", "Preview must retain the editable source.")
        XCTAssertEqual(session.translation, "Your order has shipped.")

        XCTAssertEqual(session.takeTranslation(), "Your order has shipped.")
        XCTAssertNil(session.takeTranslation(), "Repeated Return/click must not duplicate text.")
        XCTAssertTrue(session.source.isEmpty)
        XCTAssertNil(session.pendingRevision)
        XCTAssertNil(session.errorMessage)
        XCTAssertFalse(session.finish("Duplicate response", revision: token))
    }

    func testEditingRejectsAnOldResultAndOldErrorWithoutDamagingNewRequest() throws {
        var session = CompositionSession()
        session.setSource("一件")
        let oldToken = try XCTUnwrap(session.beginTranslation())

        session.append("改为两件")
        let newToken = try XCTUnwrap(session.beginTranslation())
        XCTAssertNotEqual(oldToken, newToken)
        XCTAssertFalse(session.finish("One item", revision: oldToken))
        session.fail("Old request timed out", revision: oldToken)

        XCTAssertEqual(session.source, "一件改为两件")
        XCTAssertEqual(session.pendingRevision, newToken)
        XCTAssertNil(session.errorMessage)
        XCTAssertNil(session.takeTranslation())
        XCTAssertTrue(session.finish("Change one item to two items", revision: newToken))
    }

    func testRepeatedRequestsAcceptOnlyTheNewestResponseEvenWhenSourceIsUnchanged() throws {
        var session = CompositionSession()
        session.setSource("谢谢")
        let first = try XCTUnwrap(session.beginTranslation())
        let second = try XCTUnwrap(session.beginTranslation())

        XCTAssertFalse(session.finish("Stale translation", revision: first))
        XCTAssertEqual(session.pendingRevision, second)
        XCTAssertTrue(session.finish("Thank you", revision: second))
        session.fail("Late error", revision: first)
        XCTAssertFalse(session.finish("Another stale translation", revision: first))
        XCTAssertEqual(session.translation, "Thank you")
        XCTAssertNil(session.errorMessage)
    }

    func testInvalidationPreservesDraftButPreventsPendingOrPreparedTextFromBeingCommitted() throws {
        var session = CompositionSession()
        session.setSource("请保留这份草稿")
        let pending = try XCTUnwrap(session.beginTranslation())

        // A market or focus change must invalidate any request tied to the previous context.
        session.invalidate()
        XCTAssertFalse(session.finish("Old destination", revision: pending))
        XCTAssertNil(session.takeTranslation())
        XCTAssertEqual(session.source, "请保留这份草稿")

        let prepared = try XCTUnwrap(session.beginTranslation())
        XCTAssertTrue(session.finish("Keep this draft", revision: prepared))
        session.invalidate()
        XCTAssertNil(session.takeTranslation(), "A preview from the previous context cannot be inserted.")
        XCTAssertEqual(session.source, "请保留这份草稿")
    }

    func testResetPreventsOldFocusRequestFromRestoringOrCommittingText() throws {
        var session = CompositionSession()
        session.setSource("旧输入框的草稿")
        let oldFocusToken = try XCTUnwrap(session.beginTranslation())
        session.reset()

        session.setSource("新输入框的草稿")
        let currentToken = try XCTUnwrap(session.beginTranslation())
        XCTAssertFalse(session.finish("Text for the old input field", revision: oldFocusToken))
        session.fail("Old input field failed", revision: oldFocusToken)

        XCTAssertEqual(session.source, "新输入框的草稿")
        XCTAssertEqual(session.pendingRevision, currentToken)
        XCTAssertNil(session.takeTranslation())
        XCTAssertNil(session.errorMessage)
    }

    func testEmptyOrWhitespaceResultPreservesSourceAndAllowsRetry() throws {
        for output in ["", " ", "\n\t\u{00A0}"] {
            var session = CompositionSession()
            session.setSource("需要保留的正文")
            let token = try XCTUnwrap(session.beginTranslation())

            XCTAssertFalse(session.finish(output, revision: token))
            XCTAssertEqual(session.source, "需要保留的正文")
            XCTAssertNil(session.pendingRevision)
            XCTAssertNil(session.takeTranslation())
            XCTAssertFalse(try XCTUnwrap(session.errorMessage).isEmpty)

            let retry = try XCTUnwrap(session.beginTranslation())
            XCTAssertNil(session.errorMessage)
            XCTAssertTrue(session.finish("Retained text", revision: retry))
        }
    }

    func testFailedRequestCanBeRetriedWithoutLosingSourceOrAcceptingItsLateResult() throws {
        var session = CompositionSession()
        session.setSource("订单 #A12，金额 19.99")
        let failedToken = try XCTUnwrap(session.beginTranslation())
        session.fail("语言包尚未就绪", revision: failedToken)

        XCTAssertEqual(session.source, "订单 #A12，金额 19.99")
        XCTAssertNil(session.pendingRevision)
        XCTAssertEqual(session.errorMessage, "语言包尚未就绪")
        XCTAssertNil(session.takeTranslation())

        let retryToken = try XCTUnwrap(session.beginTranslation())
        XCTAssertNil(session.errorMessage)
        XCTAssertFalse(session.finish("Late result from failed request", revision: failedToken))
        XCTAssertTrue(session.finish("Order #A12, amount 19.99", revision: retryToken))
        XCTAssertEqual(session.takeTranslation(), "Order #A12, amount 19.99")
    }

    func testDuplicateCompletionOrLateFailureCannotReplaceAnAcceptedPreview() throws {
        var session = CompositionSession()
        session.setSource("你好")
        let token = try XCTUnwrap(session.beginTranslation())
        XCTAssertTrue(session.finish("Hello", revision: token))

        XCTAssertFalse(session.finish("Unexpected replacement", revision: token))
        session.fail("Unexpected late error", revision: token)
        XCTAssertEqual(session.translation, "Hello")
        XCTAssertNil(session.errorMessage)
    }

    func testSourceEditClearsPreparedTranslationAndPreservesUnicodeGraphemesWhenDeleting() throws {
        for character in ["👨‍👩‍👧‍👦", "🇨🇳", "👍🏽", "e\u{0301}", "好"] {
            var session = CompositionSession()
            session.setSource("订单" + character)
            let token = try XCTUnwrap(session.beginTranslation())
            XCTAssertTrue(session.finish("Preview", revision: token))

            session.deleteBackward()
            XCTAssertEqual(session.source, "订单", "Backspace should remove one user-perceived character: \(character)")
            XCTAssertNil(session.takeTranslation())
            XCTAssertFalse(session.finish("Late preview", revision: token))
        }
    }

    func testDeletingTheEntireDraftAndDeletingAgainDoesNotCreateARequest() {
        var session = CompositionSession()
        session.append("👩🏽‍💻")
        session.deleteBackward()
        session.deleteBackward()

        XCTAssertTrue(session.source.isEmpty)
        XCTAssertNil(session.beginTranslation())
        XCTAssertNil(session.pendingRevision)
        XCTAssertNil(session.takeTranslation())
    }

    func testLengthLimitKeepsWholeUnicodeCharactersForReplacementAndAppend() {
        var session = CompositionSession()
        let grapheme = "👩🏽‍💻"
        let full = String(repeating: grapheme, count: session.maximumLength)
        session.setSource(full + "额外内容")
        XCTAssertEqual(session.source, full)
        XCTAssertEqual(session.source.count, session.maximumLength)

        session.deleteBackward()
        session.append("🇨🇳不能再加入的内容")
        XCTAssertEqual(session.source, String(repeating: grapheme, count: session.maximumLength - 1) + "🇨🇳")
        XCTAssertEqual(session.source.count, session.maximumLength)
    }

    func testWhitespaceOnlyDraftIsNotSentAndLineBreaksInsideRealOutputArePreserved() throws {
        var session = CompositionSession()
        session.setSource(" \t\n\u{00A0}")
        XCTAssertNil(session.beginTranslation())
        XCTAssertNil(session.pendingRevision)

        session.setSource("第一行\n第二行")
        let token = try XCTUnwrap(session.beginTranslation())
        XCTAssertTrue(session.finish("\nFirst line\n\nSecond line\n", revision: token))
        XCTAssertEqual(session.takeTranslation(), "First line\n\nSecond line")
    }

    func testCursorEditingInTheMiddleUsesWholeUnicodeCharacters() {
        var session = CompositionSession()
        session.setSource("订👨‍👩‍👧‍👦单🇨🇳")
        XCTAssertEqual(session.cursor, 4)
        session.moveCursor(by: -2)
        session.insert("👍🏽")
        XCTAssertEqual(session.source, "订👨‍👩‍👧‍👦👍🏽单🇨🇳")
        XCTAssertEqual(session.cursor, 3)

        session.deleteBackward()
        XCTAssertEqual(session.source, "订👨‍👩‍👧‍👦单🇨🇳")
        XCTAssertEqual(session.cursor, 2)
        session.deleteBackward()
        XCTAssertEqual(session.source, "订单🇨🇳")
        XCTAssertEqual(session.cursor, 1)
    }

    func testCursorClampsToDraftBoundsAndBackspaceAtStartDoesNothing() {
        var session = CompositionSession()
        session.setSource("保留正文")
        session.moveCursor(by: -100)
        XCTAssertEqual(session.cursor, 0)
        session.deleteBackward()
        XCTAssertEqual(session.source, "保留正文")
        XCTAssertEqual(session.cursor, 0)

        session.insert("请")
        XCTAssertEqual(session.source, "请保留正文")
        XCTAssertEqual(session.cursor, 1)
        session.moveCursor(by: 100)
        XCTAssertEqual(session.cursor, session.source.count)
        session.reset()
        XCTAssertEqual(session.cursor, 0)
    }

    func testCursorNavigationInvalidatesPendingAndReadyTranslationWithoutDiscardingDraft() throws {
        var session = CompositionSession()
        session.setSource("可以修改这份草稿")
        let oldToken = try XCTUnwrap(session.beginTranslation())
        session.moveCursor(by: -1)
        XCTAssertFalse(session.finish("Old position", revision: oldToken))
        XCTAssertEqual(session.source, "可以修改这份草稿")

        let freshToken = try XCTUnwrap(session.beginTranslation())
        XCTAssertTrue(session.finish("Editable draft", revision: freshToken))
        session.moveCursor(by: -1)
        XCTAssertNil(session.takeTranslation())
        XCTAssertEqual(session.source, "可以修改这份草稿")
    }

    func testInsertingAtLengthLimitPreservesExistingSuffixAndUnicodeBoundary() {
        var session = CompositionSession()
        let start = String(repeating: "字", count: session.maximumLength - 2)
        session.setSource(start + "尾")
        session.moveCursor(by: -1)
        session.insert("👩🏽‍💻多余")
        XCTAssertEqual(session.source, start + "👩🏽‍💻尾")
        XCTAssertEqual(session.cursor, session.maximumLength - 1)
        session.insert("不应覆盖后面的字")
        XCTAssertEqual(session.source, start + "👩🏽‍💻尾")
        XCTAssertLessThanOrEqual(session.cursor, session.source.count)
    }

    func testCombiningMarkAndEmojiJoinerCannotLeaveCursorBeyondTheNewCharacterCount() {
        var accent = CompositionSession()
        accent.setSource("e")
        accent.insert("\u{0301}")
        XCTAssertEqual(accent.source, "e\u{0301}")
        XCTAssertEqual(accent.cursor, 1, "An inserted combining mark can merge into the preceding grapheme.")

        var emoji = CompositionSession()
        emoji.setSource("👩💻")
        emoji.moveCursor(by: -1)
        emoji.insert("\u{200D}")
        XCTAssertEqual(emoji.source, "👩‍💻")
        XCTAssertEqual(emoji.cursor, 1, "A joiner can merge graphemes on both sides of the insertion point.")
    }
}
