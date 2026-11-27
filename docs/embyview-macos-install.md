# EmbyView macOS 构建、签名与双机安装指南

本文档说明 EmbyView macOS ARM64 Release 候选包的构建、目标机持久签名、本机与远程双机安装/更新/回退及验收口径。所有主机名与证书身份均通过运行时参数或本机配置注入，不写入仓库。

## 1. 构建 Release 候选包

入口脚本：`scripts/embyview/build-macos.sh`。

- **工作日（CI 优先）**：推送后等待 GitHub Actions `build.yml` 完成，拉取未签名归档并生成 `release-candidate.json`：
  ```bash
  scripts/embyview/build-macos.sh --source ci --ci-run-id <run-id>
  ```
- **休息日 / Actions 额度用尽（本地构建）**：直接在本机执行 ARM64 Release 构建并打包：
  ```bash
  scripts/embyview/build-macos.sh --source local
  ```

脚本在输出目录（默认 `build/embyview-release/`）生成 `EmbyView.app`、`EmbyView-macos-arm64-unsigned.zip`、`SHA256SUMS` 与 `release-candidate.json`，并强制校验：
- 锁文件无漂移（`pubspec.lock`、`Package.resolved`、`macos/Packages/Whisper/Package.swift`）；
- `CFBundleIdentifier` 为 `io.github.ump45nose.embyview`、版本号匹配 `pubspec.yaml`、二进制为 `arm64`；
- Release AOT 快照符号完整（无 Debug `kernel_blob.bin`）；
- 已内嵌 `FlutterMacOS.framework`、`App.framework`、`Aether*.framework` 与 `whisper.framework`。

## 2. 目标机持久签名配置

每台目标 Mac 需在各自本机维护独立的持久代码签名证书，**私钥仅留在当前机器钥匙串中，不跨机复制**，严禁使用 ad-hoc（`-`）签名。

1. 在目标机初始化持久签名证书（首次执行自动生成 10 年期本地 Code Signing 证书并导入默认登录钥匙串）：
   ```bash
   scripts/embyview/sign-macos.sh --ensure-identity
   ```
2. 如需自定义身份或钥匙串，在目标机写入 `~/.config/embyview/signing.env`（不入库）：
   ```bash
   EMBYVIEW_SIGN_IDENTITY="EmbyView Local Signing"
   # EMBYVIEW_SIGN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
   ```

`sign-macos.sh` 对所有嵌套 Mach-O 与框架自底向上重签，附加 `macos/Runner/Release.entitlements`，校验叶子证书 SHA-1 与权限声明，并在传入 `--previous-app` 时核验 `designated requirement` 连续性。

## 3. 双机安装、更新与回退

入口脚本：`scripts/embyview/install-macos.sh`，固定安装路径为 `~/Applications/EmbyView.app`，备份目录默认为 `~/Library/Application Support/EmbyViewInstaller/backups/previous.app`。

- **本机安装 / 更新（由候选包自动签名并校验连续性）**：
  ```bash
  scripts/embyview/install-macos.sh \
    --candidate build/embyview-release/release-candidate.json \
    --report build/embyview-release/install-local.json
  ```
- **远程 Mac 安装 / 更新（经 SSH 传输脚本、entitlements 与归档并在目标机就地签名）**：
  ```bash
  scripts/embyview/install-macos.sh \
    --host <ssh-host> \
    --candidate build/embyview-release/release-candidate.json \
    --report build/embyview-release/install-remote.json
  ```
- **直接安装已签名 App**：改用 `--app <path/to/signed/EmbyView.app>`（可选 `--identity <name-or-sha1>` 仅用于 `--candidate` 模式）。
- **仅签名安装不启动**：传入 `--skip-launch` 可完成验签与原子替换，跳过 `open -n` 启动及窗口检测（适用于无人值守预装或延迟启动场景）。
- **保住钥匙串访问**：若钥匙串中已有 `flutter_secure_storage_service` 条目（如 `embyview.*` 密钥及登录凭据），通过 `secrets run` 注入 `EMBYVIEW_KEYCHAIN_PASSWORD`（本机与 `--host` 远程安装均经标准输入安全透传，不落盘、不打印），脚本会在安装或回退后自动解锁钥匙串并将这些条目的访问控制与分区列表（`cdhash`）更新为新安装包。
- **回退**：替换后若验签或启动检查失败且存在备份，脚本自动恢复 `previous.app` 并重新核验；也可手动回退：
  ```bash
  scripts/embyview/install-macos.sh --rollback [--host <ssh-host>]
  ```

脚本在 stdout（及 `--report` 文件）输出结构化 `InstallResult` JSON，记录版本、验签、连续性、桌面会话、进程 PID、可见窗口数与回退状态。

## 4. 启动、授权连续性与验收口径

- **窗口可见性**：仅在目标机存在当前用户控制台桌面会话与 `WindowServer` 时执行 `open -n`，10 秒内通过 CoreGraphics 检测目标路径进程的可见常规窗口；无桌面会话时如实返回 `desktopSessionAvailable: false`、`windowVisible: false`，不将“进程存在”误判为“窗口可见”。
- **业务与播放验证**：确认主窗口正常渲染、Emby 登录态与媒体库可加载、音视频播放正常。
- **二次同签名更新连续性**：同签名身份二次更新后，脚本确认 `continuityVerified: true`（`designatedRequirement` 连续），随后人工核验业务态（`authorizationContinuity`）：免重新登录、钥匙串凭据可读、已授权 NAS/本地目录安全书签有效、局域网访问权限无需重复授权。
- **听写模型策略**：离线听写模型不随安装包分发，首次开启听写功能时按需下载至应用沙盒数据目录，并在二次更新后复用。
