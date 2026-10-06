import Foundation

// A compile-only check that the documented Objective-C-to-Swift API imports correctly.
func verifyBridgeAPI(shared: String, user: String) {
    let engine = HQPinyinEngine(sharedDataPath: shared, userDataPath: user)
    let _: Bool = engine.available
    let _: Bool = engine.isComposing
    let _: String = engine.preedit
    let _: [String] = engine.candidates
    let _: Int = engine.highlightedCandidateIndex
    let _: String? = engine.errorDescription
    let _: Bool = engine.processKey(110, mask: 0)
    let _: Bool = engine.selectCandidate(0)
    let _: String? = engine.takeCommit()
    engine.clear()
}
