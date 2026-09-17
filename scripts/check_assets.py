#!/usr/bin/env python3
"""check_assets.py — 上架前的资产静态自检（make check 调用，无需网络）

按 TOS 7 应用中心规范校验：
  1. assets/config.ini.in 渲染占位符后是合法 JSON 且互斥字段正确
  2. assets/sftpgo.lang 含 23 语超集（覆盖两个 14 语口径），UTF-8 无 BOM
  3. assets/ 下文本资产无 CRLF / BOM
  4. nginx conf 与 systemd unit 的关键红线（ExecStart 无 $、无 Restart）
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
fail = 0

REQUIRED_LANGS = ["zh-cn", "zh-hk", "en-us", "fr-fr", "de-de", "it-it", "es-es",
                  "hu-hu", "ja-jp", "ko-kr", "pl-pl", "ru-ru", "tr-tr", "pt-pt",
                  "ar-sa", "cs-cz", "he-il", "id-id", "nb-no", "nl-nl",
                  "sv-se", "th-th", "vi-vn"]

# ---------- 1. config.ini.in ----------
raw = (ROOT / "assets/config.ini.in").read_text(encoding="utf-8")
rendered = (raw.replace("@@VERSION@@", "0.0.0")
              .replace("@@PUBLISHER@@", "x")
              .replace("@@PLATFORM@@", "x86_64"))
try:
    cfg = json.loads(rendered)
    assert cfg["open_path"] is True and "type" not in cfg
    assert cfg["path"] == "/sftpgo/" and cfg["recommend"] is False
    print("config.ini.in: JSON 合法 + External Open 字段正确 ✓")
except Exception as e:  # noqa: BLE001
    print(f"config.ini.in: 校验失败 ✗ ({e})")
    fail = 1

# ---------- 2. lang ----------
lang_path = ROOT / "assets/sftpgo.lang"
data = lang_path.read_bytes()
if data.startswith(b"\xef\xbb\xbf"):
    print("lang: 含 BOM ✗")
    fail = 1
text = data.decode("utf-8")
found = re.findall(r"^\[([a-z]{2}-[a-z]{2})\]$", text, re.M)
missing = [t for t in REQUIRED_LANGS if t not in found]
if missing:
    print(f"lang: 缺少语言节 ✗ {missing}")
    fail = 1
else:
    print(f"lang: 23 语言超集齐全 ✓（共 {len(found)} 节）")

# ---------- 3. CRLF / BOM 扫描 ----------
for p in sorted((ROOT / "assets").rglob("*")):
    if not p.is_file() or p.suffix not in {".ini", ".in", ".lang", ".conf",
                                           ".service", ".env", ".sh", ".html",
                                           ".js", ".css", ".py", ".example"}:
        continue
    b = p.read_bytes()
    problems = []
    if b.startswith(b"\xef\xbb\xbf"):
        problems.append("BOM")
    if b"\r\n" in b or b"\r" in b:
        problems.append("CRLF")
    if problems:
        print(f"{p.relative_to(ROOT)}: {problems} ✗")
        fail = 1
print("文本资产 BOM/CRLF 扫描完成")

# ---------- 4. systemd / nginx 红线 ----------
unit = (ROOT / "assets/init.d/sftpgo.service").read_text(encoding="utf-8")
for pat, why in [(r"^Restart", "规范禁止 Restart"), (r"^ExecStart=.*\$", "ExecStart 禁变量展开")]:
    if re.search(pat, unit, re.M):
        print(f"sftpgo.service: {why} ✗")
        fail = 1
conf = (ROOT / "assets/nginx/sftpgo.conf").read_text(encoding="utf-8")
for need in ["location /sftpgo/webdav/", "location /sftpgo/api/", "location /sftpgo/",
             "location /sftpgo/privacy/", "client_max_body_size 0"]:
    if need not in conf:
        print(f"sftpgo.conf: 缺少 {need} ✗")
        fail = 1
print("systemd / nginx 红线检查完成")

sys.exit(fail)
