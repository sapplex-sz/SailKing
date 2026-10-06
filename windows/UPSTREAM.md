# Windows implementation references

The Windows code is an original implementation of the Microsoft TSF COM interfaces. It does not copy the Microsoft sample's table dictionary or publish its sample identity.

Before implementing it we inspected the [Microsoft IME sample](https://github.com/microsoft/Windows-classic-samples/tree/434f6002bdf9cf9829406c3ff2b33387982d6168/Samples/IME) at revision `434f6002bdf9cf9829406c3ff2b33387982d6168`, including activation/deactivation, registration/categories, keystrokes, composition and candidate handling. The repository license is MIT. The sample uses a table dictionary and has known custom-editor limitations described in its README; SailKing instead reuses the project's Rime Pinyin dictionaries through an isolated broker. The TSF DLL contains no model, network client or Rime engine.

- [IME requirements](https://learn.microsoft.com/en-us/windows/apps/develop/input/input-method-editor-requirements): TSF registration, modern app restrictions, DPI, and installation. AppContainer support is not advertised until its IPC permissions and host behavior have been tested.
- [RegisterProfile](https://learn.microsoft.com/en-us/windows/win32/api/msctf/nf-msctf-itfinputprocessorprofilemgr-registerprofile): one Simplified Chinese profile, enabled through supported TSF APIs. The installer never overwrites the default keyboard registry.
- [64-bit considerations](https://learn.microsoft.com/en-us/windows/win32/tsf/64-bit-considerations): both x86 and x64 TIPs communicate with the same per-user x64 broker.
- [librime 1.17.0](https://github.com/rime/librime/releases/tag/1.17.0): `rime-33e7814-Windows-msvc-x64.7z`, SHA-256 `7478c7caa4ff6b37de86daba1f7ce4a994a4f5ba24872a820fb2b3a9b01fed15`. Editable Rime data and their original license notices are included with the installer.
- llama.cpp is pinned to the existing runtime revision and archive hash. Windows uses the portable Q4 model; it does not claim support for the ARM-only legacy 1.25-bit kernel. Original notices are bundled.
- The WPF application publishes the .NET 10 LTS runtime with the installer. Users do not need Python, Ollama, Visual Studio or a separate .NET installation.

Update dependencies deliberately: change the pin and hash, rebuild both architecture clients, test Rime candidates and local translation, verify installation/COM activation/removal, and retest real editing hosts before promoting a preview.
