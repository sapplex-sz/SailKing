# InputMethodSmoke

Run `bash Tests/InputMethodSmoke/run.sh` on macOS 26+ with Xcode command-line tools and the project's already-fetched fixed-version Rime assets.

This builds the **actual** `HaiwangInputController.swift`, `CandidatePanel.swift`, Objective-C Rime bridge, and `HaiwangCore` into an isolated, locally signed test `.app`. A Swift `NSObject` implements the actual `IMKTextInput` protocol with an in-memory document, UTF-16 selection, and marked ranges. A deferred offline provider controls translation completions and errors; the production translation path is replaced by a stub that throws if reached. Candidate window presentation is disabled through the controller's DEBUG-only hook. No UI automation, system input-source registration/selection, real translation/model download, or network service is used.

Each harness uses a unique `UserDefaults` suite and removes only that test suite afterward. All Rime sessions use one fresh isolated user directory for that run, required by librime's process-wide data-path initialization. Builds, dictionary files, and the result log remain under a fresh `~/Library/Developer/Haiwang/InputMethodSmoke/run.*` directory; override the parent with `HAIWANG_INPUTMETHOD_SMOKE_ROOT` pointing to a non-cloud local directory. The real user's shared preferences, keyboard selection, and Rime dictionary are not changed.

Covered behavior:

- Real Pinyin `nihao + Space` commits `你好` and clears host marking.
- Numeric candidates 2, 6, 9 and Up/Down + Space agree with displayed Rime candidates.
- Ordinary client commit, deactivation, mode change, and client replacement retain source in the old document.
- Both Shift keys switch Chinese/English within one stable system source ID; uppercase letters, held/both Shift keys, password input, and cross-client releases do not toggle. The menu and Control+Shift+Space also switch internally, with autorepeat suppression and language persistence across activation.
- Mixed Chinese/English translation drafts survive mode switching; the candidate panel button switches language, automatic source detection handles mixed text, and late responses from cancelled requests cannot become previews.
- UTF-16 selected-text replacement preserves a Unicode prefix/suffix and uses the actual caret for candidate anchoring.
- Translation source remains marked; only a second independent Return commits a prepared preview. Return autorepeat never accepts/sends it.
- Escape, focus/client changes, deactivation, and late responses do not silently commit source or stale output.
- Changes to target/model cancel the old preview and spinner; failures preserve source; the actual input-method menu's client dictionary supports original output.
- 2000-character overflow retains whole Unicode graphemes across recovery and direct original output.
- Unicode source editing/recovery preserves the suffix; Command/Control/Option shortcuts pass through and the dedicated translation shortcut leaves the typing language unchanged.
- TIS Password/Roman modes pass through, never translate password text, and mode preferences remain independent of workspace languages.

Exit 0 means all smoke groups passed. Exit 77 and `SKIP` mean another desktop process had secure input enabled, so ordinary/translation behavior was **not tested**. The test does not disable secure input. Other failures exit nonzero with a `FAIL` diagnostic.

These tests prove controller behavior with a protocol-faithful in-memory client and the actual engine. They do not replace real TIS registration/selection checks or real-editor testing in TextEdit, browsers, and messaging apps, nor prove the local model/Apple translation quality or language availability.
