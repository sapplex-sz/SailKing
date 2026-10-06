# 出海王下载网站

公开入口：**https://sailking.157-137-190-198.sslip.io/**

纯静态页面，沿用船长鲸 Logo 和现有公开截图。截图来源见 [图片说明](../docs/images/README.md)。Mac 为实际运行截图，Windows 为 App 渲染的组件预览；页面标注了两者的来源。网站没有账户、统计脚本或服务器端翻译功能，安装包从同一甲骨文服务器直接下载。

## 本地构建与预览

```sh
python3 website/build.py --installer /absolute/path/SailKing-0.4.0-preview.1-Windows-x64.exe
python3 -m http.server 8766 --bind 127.0.0.1 --directory build/website
```

构建检查安装包文件名、大小、SHA-256、页面版本、站内链接与素材引用。安装包和生成目录不提交 Git。更新时先修改 `release.json` 与页面中的下载信息，再使用经过发布验证的安装包构建。

## 服务器部署

服务器沿用已有 Caddy 和 HAProxy，网站不新增后台进程。独立目录为 `/var/www/sailking/`：

- `releases/`：静态页面版本；`current` 原子指向当前版本。
- `downloads/`：版本化安装包与校验清单，旧版本下载文件保留。
- `/root/sailking-site-backups/`：仅管理员可读取的部署前配置备份和上一版指向。

`deploy/Caddyfile.site` 只定义本网站。部署时将已构建页面（排除 `downloads/`）打包为 `site.tar.gz`，连同 `release.json`、此 Caddy 片段、`deploy/activate.py` 和安装包上传到服务器的临时目录，再运行：

```sh
sudo python3 /path/to/upload/activate.py --upload /path/to/upload
```

激活脚本检查安装包、备份配置、验证 Caddy / HAProxy，新增本域名的 SNI 路由并切换静态版本。其他域名、认证和后台服务保持原配置；配置验证失败时不激活，重载失败时恢复原配置和原站点指向。SSH 密钥、连接密码等应保留在项目之外，不写进页面或脚本。

独立入口使用 `sslip.io` 的 IP 映射域名，TLS 证书由 Caddy 自动管理。以后换自有域名时需同步 DNS、Caddy 域名、HAProxy 路由、页面元数据、`release.json` 和 README。

## 发布检查

检查桌面与手机宽度、截图切换与放大、安装步骤切换、FAQ、二维码、键盘焦点与 Escape 关闭弹窗。公网检查首页与素材、证书、下载文件完整 SHA-256、HTTP Range 续传、校验清单，以及已有网站和服务状态。下载说明必须保留实际版本、签名状态与验证边界；Mac 未签名开发镜像不作为正式下载提供。
