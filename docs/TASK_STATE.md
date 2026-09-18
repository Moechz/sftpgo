# Task state

快照日期：2026-09-19 ｜ 当前版本：**2.7.5-4**（源码可复现构建版，已上真机）
最近实现：V6 拒审整改落地——deb 内二进制改为公开配方自建（D-015），
两次独立构建位级一致，真机升级回归全绿

## 1. 仓库状态

- GitHub `Moechz/sftpgo`（公开）；Release v2.7.5-3 已发，v2.7.5-4 待发
  （资产：双架构 deb + sha256 + VERIFICATION.md + 复现配方全套）
- 发布前已脱敏：内网主机名等不入库（历史压缩为单个初始提交）
- 待办：发 v2.7.5-4 → 附 V6 整改说明重提审（拒审信中哈希 58c4fc8b 实为
  上游二进制 fe9b7c96 的误引，回信时一并更正）

## 2. 完成情况

- [x] 上游调研（research/，已 gitignore）：web_root 原生子路径、webdavd prefix、
      DEFAULT_ADMIN 引导、proxy_mode≠HTTP 头透传（client_ip_proxy_header 才是）、
      templates 缺失 fatal / static 不内嵌——全部 macOS 二进制实测
- [x] 六文档骨架（AGENTS / HANDOFF / TASK_STATE / DESIGN_DECISIONS / CHANGELOG）
- [x] 打包工程：config.env + build.sh（fetch/stage/verify/deb）+ makedeb.sh +
      make-config.py + check_assets.py + Makefile
- [x] V6 整改（D-015）：源码可复现自建构建管线（repro-build.sh +
      Dockerfile.repro + VERIFICATION.md；REPRO.lock.<arch> 防篡改；
      REPRO_BUILD_HOST 私有构建机编排，主机名不入库）
- [x] verify 断言：config.ini JSON/互斥、23 语、init.d 单单元、ExecStart 无 $、
      端口三方一致（nginx conf ↔ sftpgo.json ↔ config.env）、ELF 架构防呆、
      Mach-O 混入检查、S8 零网络 grep、webui.bz2 含隐私入口
- [x] 真机验证（测试机，见 §3）

## 3. 最近一次真机验证（2026-09-17，测试机 / TOS 7 / x86_64）

| 项 | 结果 |
|---|---|
| apt install 2.7.5-1 | ✅ 一次成功；首管理员随机密码引导（安装输出 + 0600 凭据文件） |
| 服务状态 | ✅ active + enabled |
| 后端回环 8095 | ✅ 302 → /sftpgo/web/client/login（带前缀） |
| 平台路由 8181/sftpgo/ | ✅ 302 同上（端口保留） |
| /sftpgo 无斜杠 | ✅ 修复后 302 → :8181/sftpgo/（曾踩坑 13，加 exact location + absolute_redirect off） |
| WebDAV | ✅ PROPFIND 207 / PUT 201 / GET 回读一致（经 8181，/Volume1 落盘，ProtectSystem=full 写路径验证） |
| WebDAV 挂载点口径 | ✅ 即 /sftpgo/webdav/ + 用户凭据（无 /username/ 层级；文档已修正） |
| REST API | ✅ GET /sftpgo/api/v2/token（Basic Auth；POST 在 2.7.5 是 405——文档口径注意）+ 建用户 201 |
| WebAdmin 表单登录 | ✅ CSRF → POST 302 → users/json 含新建用户 |
| SFTP (2022) | ✅ pty 驱动 openssh sftp：登录/put/get/rm/ls 全通过 |
| 升级 2.7.5-1→-2 | ✅ active+enabled 保持、host key 指纹不变、配置未覆盖（坑 3 复查通过） |
| apt remove | ✅ 数据/配置/host key 保留 |
| apt purge | ✅ 全清（数据、应用目录含非清单文件、用户、无 /etc/sc.d 残留） |
| 监听面 | ✅ 8095/8096 仅 127.0.0.1；2022 全接口（设计如此） |
| host key 持久化 | ✅ /usr/local/sftpgo/id_*（PrivateTmp 教训：/tmp 路径不可作 home） |

产物哈希（最终构建，out/）：
- sftpgo_2.7.5-1_x86_64.deb（上架名 sftpgo_x86_64.deb）b3c6bcd7123eba1cd1758d0538ddf4ba706da2dbea80464a9e7a5ac8c8098b0e
- sftpgo_2.7.5-1_aarch64.deb（上架名 sftpgo_aarch64.deb）d85f625ceb5295074a1e35ac07961ab3527f3fb533343348d7689e25e93faf4d

当前 测试机 已装 2.7.5-1（全新安装态，含新引导的管理员）。

## 4. 测试环境状态

- 测试机（TOS 7，x86_64）：sftpgo 2.7.5-1 已安装且 active；测试用户/文件已清理；
  /Volume1/sftpgo-test 已删。机器访问方式见 ~/Documents/projects/SSH-MACHINES.md
- arm64 侧：产物已构建（上游 arm64 tarball 与官方 deb 交叉校验通过），**未在 arm 真机装机验证**

## 4.5 凭据可见性事故与根治（2026-09-18）

用户报告：应用中心路径下初始密码不可见（apt 输出不可见 + 0600 文件无权限）。
根治 = D-014：`create_default_admin: false`，无预置账号，空库时 WebAdmin
自动 302 到 `/web/admin/setup` 向导由用户自建管理员。`.lang` 23 语说明
「无默认账号密码，首次打开引导创建」。postinst 升级清理（json 归一 false +
env 删 DEFAULT_ADMIN 行）。真机验证：升级路径（admin 保留）+ 空库向导全流程
（302→setup→POST 建号→token 200）经 8181 反代全绿。

## 5. 开放问题

0. ~~502 事故~~ **已修复（-2）**：用户报告浏览 http://IP:8181/sftpgo/ 502；
   根因 = TOS 接管应用时把 /usr/local/sftpgo 属主规范回 root → sftpd
   无法生成 host key → fatal。修复 = D-013（host keys 预生成到数据目录 +
   应用目录只读化 + webui.bz2 归档卫生）。-2 已上 测试机 验证：升级迁移、
   双次重启、监听、路由全绿；arm64 待重出 -2 产物（build.sh 一键）。

1. **应用中心手动安装（坑 ⑨/UI 步骤）未做**——需要人在 TOS web 界面操作：
   应用中心 → 手动安装 → 上传 out/sftpgo_2.7.5-1_x86_64.deb，观察不卡进度、
   /etc/sc.d/sftpgo 非空、桌面图标生成。现象→处置见指南坑 11（含卡死 runbook）。
   → 下一步：由有 UI 权限的人执行一次并记录结果
2. **商店送审自查清单**（指南 §五 ⑪ review-standards 20 页）未逐项人工过——
   构建期已覆盖 S8/C 系等同款自动断言，送审前建议按官方镜像再人工对一遍
   （镜像位置：hermes-agent-webui/docs/official/）
3. ~~GitHub 发布~~ 已完成（Moechz/sftpgo，Release v2.7.5-3）
4. 升级上游版本的流程待演练一次（改 SFTPGO_VERSION → fetch 会重新固化新
   SHA256.lock.<arch>；上游 minor 变更通常无适配成本，Breaking 需对照
   DESIGN_DECISIONS 里的实验结论复核）

## 6. 发布闸门

- [x] 构建四阶段全绿 + make check
- [x] 真机功能全量验证（§3）
- [ ] 应用中心手动安装 UI 路径验证（开放问题 1）
- [ ] review-standards 人工对照（开放问题 2）
- [x] 公开仓库 + Release 资产 + sha256（2026-09-18 完成）

## 7. 建议的恢复顺序

1. 读 AGENTS.md → DESIGN_DECISIONS.md（实验结论都在）
2. `make check && ./build.sh` 确认工程可复现
3. 处理开放问题 1-3

## 8. 常用命令

```bash
./build.sh                     # 全流程构建（产物 out/）
make check                     # 静态自检
./build.sh info                # 版本/架构/端口一览
# 真机（测试机，uid 0 免 sudo）：
ssh 测试机 "systemctl status sftpgo --no-pager"
ssh 测试机 "journalctl -u sftpgo -n 50 --no-pager"
ssh 测试机 "cat /var/lib/sftpgo/INITIAL_ADMIN_CREDENTIALS.txt"
```
