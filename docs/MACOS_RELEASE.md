# Mac 安装包发布

公开分发使用 Developer ID 签名与 Apple 公证的 DMG。App 包含输入法组件；镜像中只展示 App、Applications 入口与简短安装说明。

## 从已有产物打包

`scripts/package-release.sh` 默认读取 `~/Library/Developer/Haiwang/Preview/出海王输入法.app`，不启动 Xcode、不安装 App，也不登记新输入源。输出放在本机 `~/Library/Developer/Haiwang/ReleasePackages/` 的独立目录，不覆盖原有安装或上一次安装包。

正式签名需要钥匙串中可用的 **Developer ID Application 证书及配套私钥**。单独的 `.cer`、App Store Connect `.p8` 或 iOS Distribution 证书不能替代该身份。

```bash
security find-identity -v -p codesigning
bash scripts/package-release.sh --identity "Developer ID Application: Your Name (TEAMID)" --notary-profile "SailKing"
```

`--notary-profile` 使用已存储的 notarytool 凭证。可用 `xcrun notarytool store-credentials --help` 查看 Apple ID 或 App Store Connect API Key 的配置方式；签名与公证凭证应保留在钥匙串或仓库之外，不提交源代码。

可通过 `--app` 指定已有 App，`--output` 指定非云盘的本机输出目录，`--keychain` 指定签名钥匙串，`--notary-keychain` 指定公证凭证所在钥匙串。

## 发布条件

打包程序按以下顺序处理：

1. 检查 App、输入法组件的标识、版本、架构与原有签名，确认完整安装载荷。
2. 复制已有 App，在副本中按依赖顺序签名 Rime 库、安装查询工具和输入法组件，启用 Hardened Runtime 与安全时间戳。
3. 单独公证输入法并附票，再签名与公证主 App。组件先附票再封装主 App，避免修改主 App 的资源签名。
4. 生成 DMG，签名、公证并附票；分别确认 Apple 返回 `Accepted`、附票有效、系统安全检查与嵌套签名通过。
5. 输出无预览后缀的正式 DMG、`SHA256SUMS.txt` 与发布记录。

公证失败会停止流程并保留记录。只签名但未公证的产物带 `.UNNOTARIZED.dmg` 后缀；开发产物带 `.DEVELOPMENT.dmg` 后缀，两者均不作为正式公开安装包。

开发预览可显式制作：

```bash
bash scripts/package-release.sh --development
```

该操作使用本机测试签名，不提交 Apple 公证。只用于本机打包与镜像内容检查。

## GitHub Release

先保存 Release 草稿，说明版本、系统要求、功能变化与安装步骤。只有正式 DMG 已完成上述验证后，才上传正式 DMG 与校验文件并发布 Release，更新 README 中的下载状态。不要把安装包上传成功当作签名或公证成功。

在干净用户会话中检查从 DMG 拖入 App、首次组件安装、系统键盘添加、真实拼音试打、翻译确认与更新。自动化检查不能代替其他应用的实际输入兼容性验证。
