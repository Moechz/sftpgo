#!/usr/bin/env python3
"""make-config.py — 上游默认 sftpgo.json → TOS 定制 sftpgo.json.example

用法: make-config.py <上游sftpgo.json> <输出路径> <httpd端口> <webdavd端口> <sftp端口> <数据目录>

定制点（对应 DESIGN_DECISIONS D-002/003/005/006/008）：
  - httpd:   127.0.0.1 回环、web_root=/sftpgo、X-Forwarded-For 客户端 IP 透传
  - webdavd: 127.0.0.1 回环、prefix=/sftpgo/webdav、同样透传
  - sftpd:   保持全部接口（端口由参数注入，默认 2022）
  - data_provider: sqlite 绝对路径 + backups 绝对路径 + create_default_admin=false
    （无管理员时 WebAdmin 自动跳首启向导，用户自建账号——D-014）
  - 其余字段保持上游默认（用户可自行改，升级不覆盖）
"""
import json
import sys

src, dst, httpd_port, webdavd_port, sftpd_port, data_dir = sys.argv[1:7]

cfg = json.load(open(src, encoding="utf-8"))

# ---- HTTP（WebAdmin / WebClient / REST API）----
b = cfg["httpd"]["bindings"][0]
b["address"] = "127.0.0.1"
b["port"] = int(httpd_port)
b["proxy_mode"] = 0                      # 0=禁用 PROXY protocol（L4，非 HTTP 头）
b["client_ip_proxy_header"] = "X-Forwarded-For"
b["client_ip_header_depth"] = 0          # 从右数第 0 个 = 单层可信代理下即真实客户端
b["proxy_allowed"] = ["127.0.0.1"]       # 仅信任本机 TOS nginx 传来的头
cfg["httpd"]["web_root"] = "/sftpgo"     # 原生子路径（D-002）

# ---- WebDAV ----
w = cfg["webdavd"]["bindings"][0]
w["address"] = "127.0.0.1"
w["port"] = int(webdavd_port)
w["prefix"] = "/sftpgo/webdav"
w["proxy_mode"] = 0
w["client_ip_proxy_header"] = "X-Forwarded-For"
w["client_ip_header_depth"] = 0
w["proxy_allowed"] = ["127.0.0.1"]

# ---- SFTP（对外核心功能）----
s = cfg["sftpd"]["bindings"][0]
s["port"] = int(sftpd_port)
s["address"] = ""                        # 全部接口
# host key 显式落在数据目录（D-013：/usr/local/sftpgo 会被 TOS 规范成 root 只读，
# 服务用户无法写入；postinst 以 root 预生成到 /var/lib/sftpgo/hostkeys/）
cfg["sftpd"]["host_keys"] = [
    "/var/lib/sftpgo/hostkeys/id_ed25519",
    "/var/lib/sftpgo/hostkeys/id_ecdsa",
    "/var/lib/sftpgo/hostkeys/id_rsa",
]

# ---- FTP 默认关闭（上游默认即 port 0 = 禁用；显式归零防上游变化）----
cfg["ftpd"]["bindings"][0]["port"] = 0

# ---- 数据面：sqlite 绝对路径 + 首管理员引导 ----
cfg["data_provider"]["driver"] = "sqlite"
cfg["data_provider"]["name"] = f"{data_dir}/sftpgo.db"
cfg["data_provider"]["backups_path"] = f"{data_dir}/backups"
# ---- 首启向导（D-014）：不自动建管理员；库中无管理员时 WebAdmin 登录页
# 自动 302 到 /web/admin/setup 向导，用户自己设用户名密码 ----
cfg["data_provider"]["create_default_admin"] = False

with open(dst, "w", encoding="utf-8") as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)
    f.write("\n")
print(f"sftpgo.json.example 已生成: {dst}")
