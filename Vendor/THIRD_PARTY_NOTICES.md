# Third-party components in 海王输入法

The application integrates the official [librime](https://github.com/rime/librime)
1.17.0 macOS Universal release, commit `33e7814`. librime is provided under the
BSD 3-Clause license. The application's bridge is independently written and
does not include Squirrel source code.

The official release statically includes supporting libraries. Their license
texts and attribution notices are in `licenses/`: Boost (Boost Software License
1.0), glog (BSD 3-Clause), LevelDB (BSD 3-Clause), yaml-cpp (MIT), marisa-trie
(BSD 2-Clause option of its dual license), OpenCC (Apache 2.0), darts-clone
(BSD 2-Clause), and utf8cpp (Boost Software License 1.0). Optional Rime plugin
dylibs are not part of this application.

Chinese conversion dictionaries and configuration are provided by the following
Rime projects under LGPL version 3, with their original license and readme files
in the corresponding subdirectory of `licenses/`:

| Data project | Exact source revision |
|---|---|
| [rime-luna-pinyin](https://github.com/rime/rime-luna-pinyin) | `56b934b099dfbeab842320f13aa8b461a6ab3e42` |
| [rime-essay](https://github.com/rime/rime-essay) | `054920de4f54c9e5994276a96a4fc2a35cb51aa3` |
| [rime-prelude](https://github.com/rime/rime-prelude) | `082425ea0684bca36474415d4a0e8db9b016487e` |
| [rime-stroke](https://github.com/rime/rime-stroke) | `1e8fff9b9494ddec23b0cbc526bcfd8171a6fd48` |

Original editable YAML dictionaries and `essay.txt` accompany the application
alongside their derived `build/` files. The only application-specific override is
`RimeData/default.custom.yaml`, which selects the simplified Chinese scheme,
shows nine candidates and disables the schema switcher's global shortcuts.
Upstream dictionary contents have not been edited. OpenCC conversion data is
included from the matching official librime dependency archive.

`rime-manifest.json` records the exact source archive URLs and SHA-256 checksums.
`license-sources.json` records the license text retrieval URLs and checksums;
license text tag names do not claim the exact versions of statically linked
dependencies. The original source archives are retained in `Vendor/downloads`
for reproducibility and can also be retrieved using `scripts/fetch-rime.sh`.
Full GPL version 3 text is included because LGPL version 3 incorporates it.
