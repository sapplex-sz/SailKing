# 候选窗口测试

运行 `bash Tests/CandidatePanelSmoke/run.sh`。脚本在非 iCloud 本地目录构建独立测试应用，直接编译生产 `CandidatePanel.swift` 和 `HaiwangCore`。

14 项检查覆盖九个短候选的紧凑尺寸、程序定位不产生固定偏好、重新创建控制器恢复位置、长译文扩展保持顶部、取消固定、长词换行保留全部九个候选、负坐标显示器、越界钳制及屏幕底部的光标跟随。运行不会显示窗口，不修改真实用户偏好或词库。输出三张原生窗口快照及 `panel-validation.json`。

同一测试 App 不带 `--test` 启动时显示生产候选窗口，使用隔离偏好域 `com.haiwang.tests.CandidatePanelReview` 和固定虚构候选。可用鼠标验证标题／原文拖动、关闭重开保持位置、翻译展开和取消固定。原生交互记录见 `docs/Validation/sailking-panel-gui-2026-10-05.json`。这项测试使用实际窗口实现，但不代替物理键盘在微信等编辑器中的输入法端到端验证。
