# Design Decisions — SFTPGo for TOS 7

> 只增不改；推翻旧决策时新增条目并标注 Superseded by。
> 以下所有"实验验证"均在 macOS arm64 二进制 v2.7.5 本地复现（research/test/），
> 行为与 Linux 构建一致（同源码同 tag）。

## 反代与打开方式

### D-001: External Open（新标签页）模式
**Decision:** config.ini 用 `open_path: true` + `path: "/sftpgo/"`，不出现 `type` 字段。
**Consequences:**
- 零子路径适配要求由 D-002 的 web_root 承担；iframe 的 X-Frame-Options/高度问题天然规避
- `recommend` 提交商店前必须 false；对齐 beszel 范本

### D-002: httpd 回环 + 原生 web_root 前缀保留反代
**Decision:** httpd 绑定 `127.0.0.1:8095`，`httpd.web_root: "/sftpgo"`；
nginx `location /sftpgo/ { proxy_pass http://127.0.0.1:8095; }`（proxy_pass 不带 URI，
前缀保留直通），**不用**剥前缀模式，也不用 proxy_redirect/sub_filter。
**Consequences:**
- 实验验证：`/sftpgo` → 302 `Location: /sftpgo/web/client/login`（带前缀）；登录页 HTML
  全部资源引用 `/sftpgo/static/...`；表单 action `/sftpgo/web/admin/login`；
  页内数据接口 `/sftpgo/web/admin/users/json`——全链路原生带前缀，零改写
- 排除方案：剥前缀 + proxy_redirect（重定向可修但 HTML 内绝对资源路径不可修）；
  sub_filter 改写 HTML（脆弱、SPA 常量难覆盖）
- REST API `/api/v2/` **不在** web_root 之下（实验验证 404）→ 由 D-004 单独处理
- 同 navidrome 的"前缀保留 + 应用原生 baseurl"模式（指南 §一.2）

### D-003: webdavd 独立回环端口 + prefix，nginx 最长前缀分流
**Decision:** webdavd 绑定 `127.0.0.1:8096`，binding `prefix: "/sftpgo/webdav"`；
nginx `location /sftpgo/webdav/ { proxy_pass http://127.0.0.1:8096; }`（前缀保留直通）。
**Consequences:**
- WebDAV 客户端挂载点：`http://<NAS>:8181/sftpgo/webdav/`（用户凭据认证后即进入各自 home，
  真机实测：PUT/PROPFIND/GET 全链路 207/201，无 /username/ 层级）
- webdavd 自身的 302（补尾斜杠）自带 prefix，浏览器/客户端不丢路径（实验验证 401 挑战正常）
- HTTP 家族服务全部藏于 TOS web 端口之后，不对外多开端口

### D-004: REST API 经剥前缀 location 暴露
**Decision:** nginx `location /sftpgo/api/ { proxy_pass http://127.0.0.1:8095/api/; }`。
**Consequences:**
- 脚本/自动化可用 `http://<NAS>:8181/sftpgo/api/v2/` 完整访问 REST API
- Web UI 不依赖此路由（页面内接口全在 /sftpgo/web/ 下，实验验证）

### D-005: SFTP 监听 0.0.0.0:2022，FTP 默认关闭
**Decision:** sftpd 保持上游默认 `port 2022, address ""`（全部接口）；
ftpd bindings 维持 port 0（禁用）。
**Consequences:**
- SFTP 是核心功能，SSH 协议无法经 TOS nginx（HTTP 反代）转发，必须独立端口
- 2022 避开 NAS 自身 sshd 22 端口；与 Docker 场景的惯例一致
- FTP/FTPS 需要被动端口段（默认 50000-50100）对外，默认关闭降低面；
  需要者按 env example 注释开启
- Web 面（D-002/003/004）仍严格遵守"回环 + 反代"的官方推荐模式

## 数据与账号

### D-006: sqlite 落 /var/lib/sftpgo，host key 落 config dir
**Decision:** `data_provider.name` 与 `backups_path` 用**绝对路径**
`/var/lib/sftpgo/sftpgo.db`、`/var/lib/sftpgo/backups`；
host key 不配置（自动生成于 `--config-dir` = /usr/local/sftpgo，持久化）。
**Consequences:**
- 实验验证：host key 首启生成 `id_ed25519/id_ecdsa/id_rsa(+.pub)` 于 config dir，
  重启不变 → SFTP 客户端不会遭遇 host key 变更告警
- 这些文件不在 dpkg 清单 → 升级保留；purge 时 postrm 清理
- 用户配置 `sftpgo.json` 与 `sftpgo.env` 同样不在清单（.example 首装复制，坑 2）

### D-007: deb 包名与上游官方 deb 同名 `sftpgo`
**Decision:** Package: sftpgo（= 上游 goreleaser 包名），不设 Conflicts/Replaces。
**Consequences:**
- 从上游官方 deb 升级到本包 = 天然 dpkg 升级路径（navidrome 坑 10 同款）
- 上游布局 /etc/sftpgo + /usr/bin/sftpgo 与本包 /usr/local/sftpgo 无文件冲突；
  若检测到 `/etc/sftpgo/sftpgo.db`（上游旧数据），postinst **只打印迁移提示不自动搬**
- 服务名同为 sftpgo.service，dpkg 直接替换单元文件

### D-008: 首管理员 postinst 随机密码引导
**Decision:** `data_provider.create_default_admin: true`；postinst 在**全新安装且无
DB 且 env 未配置**时生成 20 位随机密码写入 env（`SFTPGO_DEFAULT_ADMIN_USERNAME=admin`
+ `SFTPGO_DEFAULT_ADMIN_PASSWORD=...`），同时写
`/var/lib/sftpgo/INITIAL_ADMIN_CREDENTIALS.txt`（0600 root:root）并打印到安装输出。
**Consequences:**
- 实验验证：`create_default_admin` + 两个 env 变量在首启（无 admin 时）自动建号；
  已有 admin 则忽略 → 幂等安全
- WebAdmin 无网页端首管理员注册流程（登录需已有 admin），不引导即死锁
- 用户改密码后凭据文件不自动删（README 注明可删）

## 沙箱与文件访问

### D-009: ProtectSystem=full（非 strict）+ ReadWritePaths 白名单
**Decision:** unit 用 `ProtectSystem=full` + `ReadWritePaths=/usr/local/sftpgo /var/lib/sftpgo`
+ `ProtectHome=read-only`。
**Consequences:**
- SFTPGo 必须能**写**虚拟用户 home 所在的共享文件夹（/volume1 等 TOS 卷）；
  strict 会把全盘置 RO 导致上传 EROFS，/volumeX 路径打包期不可枚举 → 只能 full
  （full 仅 RO 化 /usr /boot /etc，/volumeX 可写）
- ReadWritePaths 打洞 /usr/local/sftpgo：首启生成 host key 必须可写 config dir（D-006）
- ProtectHome=read-only：可读（映射 /home 到虚拟用户时可下载），不可写；
  写 /home 的需求通过 drop-in 覆盖（README 说明）
- 与上游 unit（ProtectSystem=true）同级别，加 ProtectHome 与打洞

### D-010: static/templates/openapi 三目录随包分发
**Decision:** 从上游 tarball 原样带入 /usr/local/sftpgo/{static,templates,openapi}。
**Consequences:**
- 实验验证：templates 缺失 → 启动 fatal（reset-password.html 加载失败）；
  static 缺失 → 页面 HTML 仍可渲染（内嵌）但 CSS/JS/图片 404（资源不内嵌）；
  openapi → API 文档页用。三者必须随包（共 ~11.7MB，deb 压缩后可接受）
- 自定义品牌（branding）仍可由用户按官方文档替换 static 实现，升级会还原（dpkg 清单文件）

## 合规与商店

### D-011: lang 采用 23 语超集
**Decision:** 14 必需语 + ar-sa/cs-cz/he-il/id-id/nb-no/nl-nl/sv-se/th-th/vi-vn；
en-us/zh-cn/zh-hk 全文翻译，其余英文回退。
**Consequences:**
- 同时覆盖官方英文文档与真机两个 14 语口径（指南 §二）；多余键未见副作用（hermes 先例）

### D-012: 隐私政策可发现性
**Decision:** 隐私政策静态页随包（/usr/local/sftpgo/privacy/privacy-policy.html），
nginx `location /sftpgo/privacy/` alias 提供 `http://<IP>:8181/sftpgo/privacy/`；
webui.bz2 占位页内链接；.lang 的 important 字段提及路径；README 说明。
**Consequences:**
- SFTPGo 内嵌 WebAdmin 页脚无法注入链接（不改上游源码），故入口放在占位页 +
  应用商店介绍文案（lang）——满足"用户可发现"的合规语义（坑 21 教训）
- 政策内容：本包零遥测零外联（S8 同源事实），SFTPGo 自身 SMTP/WebHook/OIDC 等
  外联功能默认关闭、由管理员显式配置

### D-013: /usr/local 只读化，host keys 落数据目录（真机 502 事故复盘）
**Date:** 2026-09-17（测试机 真机事故驱动）
**Decision:**
1. `/usr/local/sftpgo` 全目录 root:root 只读使用，服务不得写任何东西进去；
   systemd `ReadWritePaths` 收紧为仅 `/var/lib/sftpgo`
2. SFTP host keys 由 postinst 以 root 用 ssh-keygen 预生成到
   `/var/lib/sftpgo/hostkeys/`（0600 sftpgo:sftpgo，目录 0700），
   `sftpd.host_keys` 在默认配置里显式列出
3. 升级迁移：旧版 `/usr/local/sftpgo/id_*` 如存在则 move（保指纹）；存量
   sftpgo.json 的空 `host_keys` 由 postinst python 合并补写（判空不能靠 grep
   ——上游默认就是 `"host_keys": []` 字面量）
4. webui.bz2 用 python tarfile 归一化 root:root + 过滤 `._*`/.DS_Store
   （macOS bsdtar 会把本机 uid 501 与 AppleDouble 垃圾打进成员）

**背景（真机实证，两坑叠加）：**
- 事故链：装时 postinst `chown -R sftpgo` 应用目录 → 首启以 sftpgo 用户在
  /usr/local 自动生成 host key 成功 → **TOS 接管应用（写 .userid/ROUTER，
  用户浏览应用中心或重启后）把应用目录属主规范回 root（部分文件 9999）**
  → 服务重启时 sftpd 无法写 host key → fatal 退出 → Web 面 502
- 次生发现：webui.bz2 曾用 bsdtar 打包，postinst 解压后应用目录出现
  uid 501 文件 + `._*` AppleDouble 垃圾（非 dpkg 管辖，purge 后残留）

**Consequences:**
- 应用目录属主被 TOS 重置不再是故障面（只读使用天然免疫）
- verify 阶段新增断言：pkgroot 无 `._*`/.DS_Store、webui.bz2 成员全
  root:root、example 配置含 host_keys、postinst 含 hostkeys 逻辑
- 用户若启用 HTTPS 自带证书，证书也应放 /var/lib/sftpgo 并在配置里引用


### D-014: 无预置账号，首启向导创建管理员（取代 D-008）
**Date:** 2026-09-18（用户实测反馈驱动：随机密码在应用中心安装路径下不可发现）
**Decision:**
- `data_provider.create_default_admin: false`；postinst 不写任何凭据/密码文件
- 空库时 SFTPGo 原生行为：`/web/admin/login` 自动 302 到 `/web/admin/setup`
  向导页，用户自定义管理员用户名与密码（真机实测经 8181 反代同样成立，
  302 Location 带端口）
- `.lang`（descript/release_note/important，23 语）明确写「无默认账号密码，
  首次打开引导创建」——应用中心详情页即说明，凭据可见性问题从根上消除
- 升级清理（postinst）：存量 json 的 `create_default_admin` 归一为 false；
  env 里旧版 DEFAULT_ADMIN 引导行删除（空库 + true + 缺 env 会 fatal）

**为什么废弃 D-008（随机密码 + 0600 文件）：**
- 应用中心安装路径下用户看不到 apt 输出、无 root 权限读 0600 文件，
  密码等于丢失；ssh 取回对普通 NAS 用户门槛过高
- 向导是上游原生能力（adminsetup.html），零打包侧状态、无文件残留
- 安全性不降反升：用户自设口令 vs 安装时随机串（会被写进 env/文件）

**实验注记：**
- setup POST 字段：username/password/confirm_password/_form_token
  （install_code/language 可省）；成功返回 302，失败 200 重渲染
- 本地测试曾持续 200/500：系残留进程占用 2022 使 serve 半死 + 删库未删
  -wal/-shm 致库损坏，非产品缺陷（换端口 + 连 wal 一起清后全绿）


## D-015 二进制改为源码可复现自建产物（V6 整改）

**日期**：2026-09-19 ｜ **状态**：已实施（2.7.5-4）

**背景**：TOS 审核 V6 拒审——deb 携带上游预编译 stripped 二进制，无「源码可审计」
映射；双渠道哈希互证只证明供应链一致，不构成可复现性证据。

**决策**：不再分发上游预编译二进制，改为 `scripts/repro-build.sh` 公开配方自建：

- 源码 = 上游官方 tag 归档（sha256 锁定，commit `9888a3d1`）
- 工具链 = go1.25.12 官方 tarball（sha256 锁定）+ gcc 11.4 + glibc 2.35
  （Ubuntu 22.04 = TOS 7 基座；构建时强制校验，漂移即拒绝）
- 构建命令 = 与上游 `.github/workflows/release.yml` 逐字一致；
  唯一偏差：`version.date` 固定为 tag 提交时间（上游注入构建时刻，不可复现）
- 可复现性判据：**任意机器按配方重建 → 与分发物位级一致**（两次独立构建
  x86_64 `5c5415f1…` / aarch64 `7a3932a2…` 已互证）
- 与官方 CI 产物哈希不同属预期（其环境为 Ubuntu 18.04/gcc-7）；
  版本串/依赖集与官方一致（`go version -m` 可交叉印证）

**管线变化**：
- fetch 阶段：下载源码归档（非二进制 tarball/deb）；自建产物入
  `build/downloads/repro/`，`REPRO_BUILD_HOST` 环境变量指定私有构建机
  （主机名不入库）；lock 语义迁移为 `REPRO.lock.<arch>`（源码+自建二进制）
- verify 新断言：staged 二进制哈希 == 自建产物；复现材料三件套必须在库
  （scripts/repro-build.sh / Dockerfile.repro / VERIFICATION.md）
- 审核者复现入口：仓库根 `VERIFICATION.md`（三步验证 + 期望哈希表）

**为什么不选纯 Go（CGO_ENABLED=0）**：sqlite 驱动为 mattn/go-sqlite3
（`//go:build !nosqlite && cgo`），关闭 CGO 将失去 sqlite 数据层，
或需换 bolt 存储引擎——变更产品数据层不属 V6 整改范围。
