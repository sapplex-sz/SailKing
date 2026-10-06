# Third-party notices

The root MIT license applies to SailKing's original application, UI, bridge, and build-script code. It does not replace upstream licenses for third-party components or dictionaries.

- **librime 1.17.0**: BSD-3-Clause. Supporting libraries and exact Pinyin data revisions are listed in [Vendor/THIRD_PARTY_NOTICES.md](Vendor/THIRD_PARTY_NOTICES.md). Original license texts are in `Vendor/licenses/`.
- **Rime Pinyin and dictionary data**: LGPL-3.0. The original editable YAML and text files, source archive URLs, revision pins and checksums are included. Application-specific changes are in `Vendor/RimeData/default.custom.yaml`. The upstream licenses remain in effect.
- **llama.cpp and supporting runtime code**: MIT and the notices included in `Runtime/Licenses/` and `Resources/Licenses/`. The pinned source and compatibility patch are documented in [Runtime/README.md](Runtime/README.md).
- **Tencent Hy-MT2**: Apache-2.0. Model weights are downloaded separately; their license is preserved in `Resources/Licenses/HyMT2.txt`. Model source revisions and SHA-256 values are specified in `Sources/HaiwangCore/EngineConfiguration.swift`.
- **SailKing captain-whale artwork**: Generated artwork and the prompts are included in `Resources/Branding/`. The code license does not grant trademark rights or imply ownership of unrelated characters, logos or upstream brands. Distribution does not imply upstream endorsement.

The Mac app includes runtime license files. Its input-method component includes both the Rime notices and editable dictionary sources. Third-party source archive downloads and local generated dictionary indexes are excluded from Git; reproduce them with `scripts/fetch-rime.sh`.

The Windows preview additionally bundles the MSVC x64 librime distribution, app-local Microsoft Visual C++ runtime files, and the self-contained .NET 10 WPF runtime. These Microsoft runtime components retain their own licenses and notices; they are not relicensed under the project's MIT license. The installer contains editable Rime data, its upstream license files, the Hy-MT2 license, and the runtime notices. Windows TSF reference sources and pinned dependency hashes are described in [windows/UPSTREAM.md](windows/UPSTREAM.md).
