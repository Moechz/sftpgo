# SFTPGo for TerraMaster TOS 7

[SFTPGo](https://github.com/drakkan/sftpgo)（AGPL-3.0）的 TOS 应用中心 deb 封装：
SFTP / WebDAV / FTP/S / HTTP/S 文件传输服务器，内置 WebAdmin 管理端与 WebClient 用户端，
支持本地目录与云存储（S3 兼容 / GCS / Azure）后端。

## 快速上手

安装完成后**没有任何预置账号**：首次打开 `https://<NAS的IP>:8181/sftpgo/`
会自动进入初始化向导，由你自定义管理员用户名与密码（应用中心的应用
说明里同样写明了这一点）。

| 入口 | 地址 |
|---|---|
| 初始化向导（首次） | `https://<NAS的IP>:8181/sftpgo/`（自动引导创建管理员） |
| WebAdmin 管理端 | `https://<NAS的IP>:8181/sftpgo/web/admin/login` |
| WebClient 用户端 | `https://<NAS的IP>:8181/sftpgo/web/client/login` |
| WebDAV 挂载 | `http://<NAS的IP>:8181/sftpgo/webdav/`（用户凭据，各自独立根） |
| REST API | `http://<NAS的IP>:8181/sftpgo/api/v2/` |
| SFTP | `sftp -P 2022 <用户名>@<NAS的IP>` |
| 隐私政策 | `https://<NAS的IP>:8181/sftpgo/privacy/` |

TOS 桌面点击应用图标即在新标签页打开。首次使用建议：

1. 按向导创建管理员（用户名密码自定；建议随后在个人资料中开启两步验证）
2. 「用户」→ 新建虚拟用户，home 目录指向 TOS 共享文件夹（如 `/Volume1/<共享名>`）
3. 按需给 sftpgo 系统用户授权（见下）

## 端口与网络

| 端口 | 用途 | 监听面 |
|---|---|---|
| 8095 | WebAdmin / WebClient / REST API 后端 | 仅 127.0.0.1（经 TOS nginx 反代） |
| 8096 | WebDAV 后端 | 仅 127.0.0.1（经 TOS nginx 反代） |
| 2022 | SFTP（核心功能） | 全部接口（按需在防火墙/路由器放行） |

FTP 默认关闭（`/usr/local/sftpgo/sftpgo.env` 里有开启注释）。Web 流量全部经
TOS web 端口 8181 的 `/sftpgo/` 路由，不对外多开端口。

## 文件与数据

| 路径 | 内容 | 卸载行为 |
|---|---|---|
| `/usr/local/sftpgo/bin/sftpgo` | 上游官方静态二进制（与官方 deb 哈希互证） | 随包 |
| `/usr/local/sftpgo/static,templates,openapi/` | Web UI 资源（升级会还原，可自定义品牌） | 随包 |
| `/usr/local/sftpgo/sftpgo.json` | 主配置（首装从 `.example` 生成，**升级不覆盖**） | 保留 |
| `/usr/local/sftpgo/sftpgo.env` | 环境变量覆盖（端口/FTP/防暴力破解等） | 保留 |
| `/var/lib/sftpgo/hostkeys/id_*` | SFTP host key（安装时预生成，升级不变，客户端不告警） | remove 保留 / purge 删除 |
| `/var/lib/sftpgo/sftpgo.db` | SQLite 数据库（用户/管理员/事件规则/分享） | remove 保留 / purge 删除 |

改配置后：`systemctl restart sftpgo`。

## 权限：让虚拟用户能读写共享文件夹

服务以专用系统用户 `sftpgo` 运行。虚拟用户 home 指向 TOS 共享文件夹时，
该文件夹需要对 sftpgo 可读写。两种做法：

```bash
# A. TOS ACL（推荐）：控制面板 → 共享文件夹 → 权限，把 sftpgo 加入可读写列表
#    （应用专用用户会出现在「应用用户」中）
# B. 命令行：把 sftpgo 加入共享文件夹的属组（示例）
sudo usermod -aG <共享文件夹组> sftpgo && sudo systemctl restart sftpgo
```

沙箱说明：unit 使用 `ProtectSystem=full`（非 strict），因此 `/Volume1` 等
共享卷可写；`/home` 只读（需要写入 /home 映射时，自建 drop-in 覆盖：
`/etc/systemd/system/sftpgo.service.d/override.conf` 写入
`[Service]\nProtectHome=false` 后 `systemctl daemon-reload && systemctl restart sftpgo`）。

## 安全建议

- SFTP 对外暴露时，开启防暴力破解（env 里取消注释 `SFTPGO_COMMON__DEFENDER__*`）
- 传输加密：TOS 侧 8181 若配置了 HTTPS 则全链路加密；SFTP 天然加密
- 深度定制（云存储、事件规则、OIDC、邮件）直接编辑 `sftpgo.json`，
  参考 [官方文档](https://docs.sftpgo.com)

## 与上游官方 deb 的关系

本包与上游 goreleaser 包同名 `sftpgo`：从官方 deb 升级到本包是普通 dpkg
升级（服务单元自动替换）。上游数据在 `/etc/sftpgo/sftpgo.db`，本包数据在
`/var/lib/sftpgo/`——升级时安装器会打印迁移提示，需手动复制一次。

## 构建

```bash
./build.sh            # 产物在 out/（fetch → stage → verify → deb）
make check            # 静态自检（无需网络）
# TARGET_ARCH 在 config.env 切换 amd64 / arm64
```

打包规范与硬坑知识库见 `~/Documents/projects/TOS-DEB-PACKAGING-GUIDE.md`；
本项目决策台账见 `docs/DESIGN_DECISIONS.md`。

## 许可

上游 AGPL-3.0（全文随包：`/usr/share/doc/sftpgo/copyright`）。本封装脚本
与新增资产同样以 AGPL-3.0 提供。
