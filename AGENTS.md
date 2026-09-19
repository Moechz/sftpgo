# AGENTS.md — SFTPGo for TOS 7（项目宪法）

## 1. 项目是什么

把上游 [SFTPGo](https://github.com/drakkan/sftpgo)（SFTP/FTP/FTPS/WebDAV/HTTP 文件传输服务器，
AGPL-3.0，Go 静态二进制，自带 WebAdmin + WebClient）封装成 **TOS 7 应用中心规范的 deb 包**。

- 目标平台：TerraMaster TOS 7（Ubuntu 22.04 基座，systemd 249 / dpkg amd64 & arm64）
- 打包规范：`~/Documents/projects/TOS-DEB-PACKAGING-GUIDE.md`（**动手前必读**，36 条硬坑）
- 上游版本：2.7.5（config.env 中定义，升级只改那里 + 重跑 fetch）
- 参考范本：`~/Documents/projects/Beszel`（Go 静态二进制 + External Open 同款骨架）

## 2. 新会话阅读顺序

```
AGENTS.md → HANDOFF.md → docs/TASK_STATE.md → docs/DESIGN_DECISIONS.md → docs/CHANGELOG.md → README.md
```

## 3. 架构摘要

1. **打开方式**：External Open（新标签页），`open_path: /sftpgo/`，config.ini 无 `type` 字段
2. **Web 面（WebAdmin/WebClient/REST API/WebDAV）全部走回环 + TOS nginx 反代**：
   - httpd `127.0.0.1:8095`，**原生 `web_root: "/sftpgo"`**（上游内建子路径支持，页面/资源/
     重定向全部自带前缀——实验验证，见 D-002）
   - webdavd `127.0.0.1:8096`，`prefix: "/sftpgo/webdav"`，nginx 最长前缀分流
   - REST API 经 `location /sftpgo/api/`（剥前缀）暴露在 `http://<IP>:8181/sftpgo/api/v2/`
3. **SFTP 监听 `0.0.0.0:2022`**（核心功能必须对外；FTP 默认关闭，env 可开）
4. **数据**：sqlite `/var/lib/sftpgo/sftpgo.db`；SFTP host key 由 postinst 预生成在
   `/var/lib/sftpgo/hostkeys/`（D-013：/usr/local 会被 TOS 规范成 root 只读，
   服务用户不能在那里生成/写入；升级不变，客户端不弹 host key 变更）
5. **包名 `sftpgo` 与上游官方 deb 同名** → 对上游 deb 是天然 dpkg 升级路径，不设 Conflicts
6. **首管理员**：无预置账号——空库时 WebAdmin 自动跳首启向导（D-014），
   `create_default_admin: false`；postinst 不写任何凭据
7. static/templates/openapi 三个目录必须随包（模板缺失启动 fatal、静态资源非内嵌——D-010）

## 4. 目录布局与禁止触碰路径

```
├── build.sh / makedeb.sh / Makefile / config.env   # 构建工程（四阶段）
├── assets/            # 包内容模板（改这里）
├── scripts/           # check_assets / make-config / verify-payload
├── docs/              # 六文档之三（TASK_STATE / DESIGN_DECISIONS / CHANGELOG）
├── research/          # 上游调研原始材料（不入 git）——验证结论已沉淀进 DESIGN_DECISIONS
├── build/             # 构建中间产物（可随时 rm -rf）
└── out/               # 产物 deb（可重建）
```

**禁止触碰**：`build/downloads/SHA256.lock`（仅由 fetch 阶段写入；手改 = 供应链校验失效）；
`research/`（原始证据，只读）。

## 5. 开发约定

- 打包脚本 `#!/usr/bin/env bash` + `set -euo pipefail`；文本资产 LF + 无 BOM（构建期统一清洗）
- ExecStart **永远写死参数**（坑 1）；用户可变项走 EnvironmentFile，且默认注释
- 生命周期脚本幂等：App Center 安装与手动 `apt install` 两条路径行为必须一致
- 版本号三处一致：config.ini / DEBIAN/control / .lang（verify 阶段断言）
- **迭代号永不零填充**（`-01 == -1`，dpkg 数值比较）

## 6. 如何构建 / 测试

```bash
cd ~/Documents/projects/sftpgo
./build.sh            # fetch（源码+自建产物）→ stage → verify → deb
make check            # 语法 + 资产静态自检（无需网络）
./build.sh info       # 查看当前版本/架构/产物路径
```

- **二进制来源（D-015）**：`scripts/repro-build.sh` 自建（源码可复现，
  V6 整改）；macOS 本机构建时设 `REPRO_BUILD_HOST=<构建机>`（私有配置，
  严禁入库；建议同时 export `REPRO_GOPROXY` 走国内代理）
- 升级上游版本：只改 repro-build.sh 头部常量（源码/Go 哈希 + commit/date）
  → 重跑 → 期望哈希更新进 VERIFICATION.md + docs

## 7. 真机验证

按 TOS-DEB-PACKAGING-GUIDE §五清单执行；测试机 `ssh 测试机`（不加 sudo，uid 0）。
**手动 apt 装好 ≠ 应用中心装好**——上架前必须走一遍应用中心手动安装（坑 11）。

## 8. Git 规则

- 提交信息：`<类型>: <摘要>`（feat/fix/docs/build）
- 上架仓库公开，**内网 IP / 主机名 / 密码不入库**（research/ 已 gitignore，坑 20）

## 9. 硬性技术约束

- 服务以专用非 root 用户 `sftpgo` 运行（preinst 创建，三处一致：config.ini/unit/preinst）
- systemd 单元不配 Restart/RestartSec（生命周期归应用中心）；init.d/ 只放一个主服务
- nginx 配置 `nginx -t` 失败必须回滚（坑 5）
- 沙箱：ProtectSystem=**full**（不是 strict——必须可写共享文件夹 /volumeX 上传文件）+
  ReadWritePaths=/usr/local/sftpgo /var/lib/sftpgo；ProtectHome=read-only（D-009）
- deb 脚本零网络操作（S8 红线，坑 15；verify 阶段 grep 断言）

## 10. 已定决策要点索引

D-001 External Open ｜ D-002 web_root 原生前缀反代 ｜ D-003 webdavd prefix 分流 ｜
D-004 REST API 剥前缀路由 ｜ D-005 SFTP 2022 对外 ｜ D-006 sqlite+host key 布局 ｜
D-007 与上游 deb 同包名 ｜ D-008 首管理员引导 ｜ D-009 沙箱=full 而非 strict ｜
D-010 static/templates/openapi 随包 ｜ D-011 23 语超集 ｜ D-012 隐私政策可发现性
（全文见 docs/DESIGN_DECISIONS.md）

## 11. 版本同步清单

一次用户可见改动必须同时更新：`config.env`（SFTPGO_VERSION / PKG_RELEASE）→
config.ini / control / .lang（构建期注入）→ `docs/CHANGELOG.md` → `docs/TASK_STATE.md`。
Release tag = `v<完整版本>`（如 v2.7.5-1），资产 `<appid>_<platform>.deb` + `.sha256`。
