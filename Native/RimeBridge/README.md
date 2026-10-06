# HaiWang Rime bridge

`HQPinyinEngine.h/.m` is an independent Objective-C wrapper around the BSD-licensed
official librime C API. No Squirrel source is included.

## Build and packaging

- Run `scripts/fetch-rime.sh` to fetch checksum-pinned official macOS Universal binaries
  (librime 1.17.0), editable upstream Pinyin data and attribution files. No Homebrew
  dependency or system input-source changes are made.
- Compile `HQPinyinEngine.m` with ARC and header search path
  `Vendor/librime/dist/include`. Import `HQPinyinEngine.h` in the Swift bridging header.
- Link `-L Vendor/librime/dist/lib -lrime` and Foundation.
- Copy `Vendor/librime/dist/lib/librime.1.17.0.dylib` to your app as
  `Contents/Frameworks/librime.1.dylib`. Add `@executable_path/../Frameworks` to rpaths.
  It depends only on macOS's libSystem and libc++, verified with `otool -L`.
- Copy the **whole** `Vendor/RimeData` into `Contents/Resources/RimeData`, including
  `build/`, `opencc/`, editable YAML/text dictionaries and `default.custom.yaml`.
- Include `Vendor/licenses` and `Vendor/THIRD_PARTY_NOTICES.md` with the app.
- Optional Lua/grammar/predict dylibs are deliberately not shipped or required.

## Swift interface

```swift
let engine = HQPinyinEngine(sharedDataPath: bundledRimeDataPath,
                            userDataPath: appSupportRimePath)
guard engine.available else { /* Show engine.errorDescription */ return }
let handled = engine.processKey(110, mask: 0) // n
let markedPinyin: String = engine.preedit
let candidateStrings: [String] = engine.candidates
let highlightedIndex: Int = engine.highlightedCandidateIndex // -1 when empty
let composing: Bool = engine.isComposing
_ = engine.selectCandidate(0)
if let chineseText = engine.takeCommit() { /* Append to source-language buffer */ }
engine.clear()
```

Use one engine per IMK input session, but identical shared/user directories in a
single process. Input operations are short and synchronized across sessions; call
them on the UI thread. Initial deployment is synchronous, so create the first
engine during setup before handling keys. Prebuilt data avoids dictionary recompilation.
The mutable user path should be this app's own Application Support directory,
never `~/Library/Rime`. Rime saves learned Chinese candidate choices there.
The bridge never calls network services and does not log typed text.

`processKey` takes X11/Rime key symbols, **not** macOS physical keyboard codes:
ASCII 32 for space; `0xff08` backspace; `0xff0d` return; `0xff1b` escape;
`0xff51`/`0xff53` left/right; `0xff52`/`0xff54` up/down;
`0xff55`/`0xff56` page up/down. Shift, Control, Alt masks are 1, 4, 8. Let the host
handle Command shortcuts. `selectCandidate` uses the zero-based current page index.
Selection may commit only part of a phrase; always re-read composition and candidates.
Use `highlightedCandidateIndex` to render the candidate currently selected by Rime.
It is the zero-based current-page index, or `-1` when there are no candidates.
Arrow keys update it; space confirms that highlighted candidate. `clear()` resets it.
`takeCommit` consumes committed text once, independently of current preedit.

## Verification

`Tests/RimeSmoke/run.sh` compiles the actual bridge and runs the actual bundled
engine offline. It verifies `nihao → 你好`, `kuajing → 跨境`, `zhongwen → 中文`,
candidate selection, backspace, cancellation, out-of-bounds indices, exactly-once
commit retrieval, arrow-key highlight/space confirmation agreement and independent
concurrent sessions. It uses fresh isolated test
user directories under `Tests/RimeSmoke/.build/`.

## Local learning and privacy wording

The bundled configuration leaves Rime's user dictionary enabled. When the user
confirms Chinese candidates, Rime stores Chinese words or composed phrases,
their Pinyin codes, usage counts and ranking/recency statistics in
`<userDataPath>/luna_pinyin.userdb/`. This can retain parts of the source text;
it is not limited to anonymous aggregate counts. Some entries can use the
dictionary's internal traditional-Chinese form before simplified output conversion.
The LevelDB files are not encrypted by this bridge. Test dictionary files have
been inspected and contain the selected test phrases and Pinyin codes.

Candidate confirmation is the learning event. It can occur before translation
or insertion into the destination app, so cancelling a translation afterward
does not undo learned entries. `clear()` cancels only the current composition
and unconsumed commit; it does not erase the user dictionary. The engine has no
upload/network path. Translation requests are a separate app-layer data flow
and must be described according to the chosen provider.

Suggested user-facing text:

> 中文拼音会在本机用户词库中保存你确认过的词语、短语及相关拼音和使用频次，
> 用于改善候选词排序；其中可能包含你输入的内容。这些学习数据不会由拼音引擎上传。
> 取消当前输入或翻译不会清除已有的学习记录。翻译服务如何处理原文，取决于你选择的服务。

Do not describe the current configuration as “不保存输入内容” or “不留痕”.
Do not advertise a learning-data deletion control unless the app implements one.
Evidence: upstream [UserDictionary::UpdateEntry and default enable_user_dict](https://github.com/rime/librime/blob/1.17.0/src/rime/dict/user_dictionary.cc),
[ScriptTranslator phrase learning](https://github.com/rime/librime/blob/1.17.0/src/rime/gear/script_translator.cc), and
[Memory::OnCommit](https://github.com/rime/librime/blob/1.17.0/src/rime/gear/memory.cc).
