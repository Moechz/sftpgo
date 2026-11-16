# Changelog

## 2.7.5-4（2026-09-19）—— 源码可复现构建（V6 整改）

### Changed
- **deb 内 sftpgo 二进制改为公开配方自建**（`scripts/repro-build.sh`）：
  上游源码 + go1.25.12 + gcc 11.4/glibc 2.35（Ubuntu 22.04 = TOS 7 基座），
  任何人可按 `VERIFICATION.md` 三步复现并哈希比对（V6 拒审整改落地）
  - x86_64 `5c5415f16611893f15b938c23a2cd5cb0df9b8b4f66654ea6fad9856b5b643b0`
  - aarch64 `7a3932a2e0ecc73c48ac8838fc83662fcfe5c6050e597346f8dc8120c4c71816`
- build.sh fetch 重写：上游源码归档（sha256 锁定）取代二进制 tarball；
  供应链 lock 迁移为 REPRO.lock.<arch>；新增 manifest/buildinfo 注入断言
- verify 新增：staged 二进制 == 自建产物哈希、复现材料三件套在库
- 新增审核者材料：`VERIFICATION.md`（复现指南）+ `Dockerfile.repro`（一键环境）

### Verified
- 真机（TOS 7 x86_64）2.7.5-3 → 2.7.5-4 升级：装机二进制哈希 = 自建产物；
  Web 反代 302 / admin token 200 / 三端口监听正常


## 2.7.5-3 — 2026-09-18

### Changed
- **废弃随机密码引导，改用上游原生首启向导（D-014）**：不再预置任何账号；
  首次打开应用自动引导创建管理员（用户名/密码自定），应用描述（.lang 23 语）
  明确说明"无默认账号密码"——解决应用中心安装路径下初始凭据不可发现的问题

### Fixed
- 升级清理：存量配置 `create_default_admin` 归一为 false、env 移除旧版
  DEFAULT_ADMIN 引导行（旧组合在空库重启时会 fatal）

## 2.7.5-2 — 2026-09-17

### Fixed
- **修复 TOS 接管应用后服务 fatal → Web 面 502**（真机事故）：TOS 会把
  /usr/local/<app> 属主规范回 root，服务用户无法在应用目录自动生成 SFTP
  host key；改为 postinst 预生成到 /var/lib/sftpgo/hostkeys/，应用目录彻底
  只读化（ReadWritePaths 收紧为仅数据目录），升级自动迁移旧 key 与配置
- **修复 webui.bz2 携带 macOS 痕迹**：改用 python tarfile 归一化 root:root，
  消除 uid 501 文件与 AppleDouble `._*` 垃圾（含旧版遗留清理）
- 构建期新增归档卫生断言（垃圾零容忍 + 成员属主校验）

## 2.7.5-1 — 2026-09-17

### Added
- 首个 TOS 7 应用中心封装：SFTPGo（SFTP/WebDAV/FTPS + WebAdmin/WebClient）
  - 集成模式：External Open（新标签页），Web 入口 https://<NAS>:8181/sftpgo/
  - SFTP 端口 2022 对外；8095/8096 全回环，经 TOS nginx 最长前缀分流
    （/sftpgo/ 前缀保留直通 + /sftpgo/api/ 剥前缀 + /sftpgo/webdav/ prefix 绑定）
  - 安装即用：随机密码引导首个管理员（凭据 0600 存 /var/lib/sftpgo/）
  - sqlite 数据落 /var/lib/sftpgo/；host key 落 /usr/local/sftpgo/（升级不变）
  - systemd 沙箱：ProtectSystem=full + ReadWritePaths 白名单 + PrivateTmp
  - 23 语言超集；AGPL-3.0 文档与隐私政策页随包
  - deb 与上游官方包同名（sftpgo），支持官方 deb → 本包直接升级
- 双架构产物：x86_64 / aarch64（二进制与上游官方 deb 哈希互证）

### Changed
- （首版，无变更项）

### Fixed
- （首版，无修复项）
