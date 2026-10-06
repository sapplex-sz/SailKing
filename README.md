# 出海王输入法 · SailKing

Mac 系统输入法：中文拼音、英文直输，以及确认后上屏的翻译输入。

支持 **macOS 26+、Apple Silicon**。当前版本 **0.3.6 (9)**。安装包正在完成正式签名与 Apple 公证，尚未公开分发。

## 安装

公证完成后，安装包会发布在 [GitHub Releases](https://github.com/sapplex-sz/SailKing/releases)。

1. 打开安装镜像，把 **出海王输入法.app** 拖到“应用程序”并打开。
2. 在新手设置中安装输入法组件，再打开“系统设置 → 键盘 → 文本输入 → 编辑 → ＋”。
3. 在“简体中文”中添加 **出海王输入法**，从右上角输入法菜单选中它。
4. 在试打框输入 `nihao`，按空格确认“你好”。普通拼音和英文不需要下载模型。

只需添加一个输入源。App 不额外占用菜单栏图标。

## 使用

| 操作 | 快捷键 |
|---|---|
| 中文拼音 / 英文直输 | 轻按 Shift |
| 普通输入 / 翻译输入 | Control + Shift + T |
| 选词 | 空格、数字或点击候选 |
| 翻译预览 / 确认译文上屏 | 依次按两次 Return |
| 工作台翻译 | Command + Return |
| 全局翻译面板 | Option + Space |

翻译时先完成原文，再预览译文，核对后确认。失败保留原文；确认译文不会向宿主应用发送 Return。候选窗口可拖动并记住位置，也可恢复跟随光标。

Mac 翻译使用 Apple 设备端翻译或本地 Hy-MT2 模型，原文不发送到翻译 API。首次准备语言包或下载模型需要网络；可用语言取决于实际安装内容。默认本地模型约 462 MB，需下载完成并通过校验后才能使用。翻译结果仍需核对。

## 卸载

先切换到 ABC，在系统键盘设置中选中出海王并点“−”。退出 App，将 `~/Library/Input Methods/海王输入法键盘.app` 和“应用程序”里的出海王 App 移到废纸篓。模型、词库与偏好保留。输入法组件的内部文件名保留旧名称以兼容更新。

完整步骤见 [安装与卸载](docs/INSTALLATION.md)。隐私说明见 [PRIVACY.md](PRIVACY.md)。

## 从源码构建

需要 Xcode 26+、Xcode 命令行工具、XcodeGen 和 Python 3。项目配置以 `project.yml` 为准，生成的 Xcode 项目不纳入版本管理。

```bash
bash scripts/fetch-rime.sh
bash scripts/build-macos.sh
open "$HOME/Library/Developer/Haiwang/Preview/出海王输入法.app"
```

构建在本机非 iCloud 缓存中进行。若当前登录会话已经启用出海王，构建会先停止，以免 Xcode 的重复登记移除现有键盘入口；请在独立用户会话中构建。已有产物可直接打包，无需重新构建。开发产物使用本机测试签名；该签名不适合公开分发。正式发布另行使用 Developer ID 和 Apple 公证，不改变 Bundle ID 或输入法内部安装路径。

仓库提供 macOS arm64 原生运行时。需要自行重建时，安装 CMake 后运行 `bash scripts/build-runtime.sh`。运行时和 Rime 的版本、下载地址及校验值固定在构建脚本与清单中。

```bash
swift test --scratch-path "$HOME/Library/Developer/Haiwang/CoreTests"
bash Tests/WorkspaceSmoke/run.sh
bash Tests/CandidatePanelSmoke/run.sh
bash Tests/OnboardingSmoke/run.sh
bash Tests/RimeSmoke/run.sh
bash Tests/InputMethodSmoke/run.sh
bash Tests/InputMethodIPC/run.sh
```

测试使用隔离的偏好和模拟客户端，不能代替系统菜单、真实输入框或其他应用的实际兼容性检查。

## 范围与许可

macOS 原生输入法支持中文拼音和英文。仓库还包含实验性的 iOS 翻译工作台，尚无 iOS 系统键盘扩展；本次只发布 Mac 版。

本项目原创代码使用 [MIT License](LICENSE)。第三方引擎、词库、模型与品牌素材的权利分别按 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) 说明处理。船长鲸标识的设计来源见 [标识记录](Resources/Branding/SailKing-Design.md)。

反馈问题请使用 [GitHub Issues](https://github.com/sapplex-sz/SailKing/issues)。技术支持：sapplex@icloud.com。
