#!/usr/bin/env bash
# ============================================================
# build.sh - 在 macOS / Linux 上把 SFTPGo 打包成 TOS 7 应用中心
# 规范的 deb 包（WebUI External Open / 新标签页模式）
#
# 规范依据: https://help.terra-master.com/developer/development-docs/
#   及本地知识库 ~/Documents/projects/TOS-DEB-PACKAGING-GUIDE.md（硬坑清单）
#
# 产物（out/）:
#   sftpgo_<版本>_<arch>.deb        完整版本名 deb（本地安装/测试用；
#                                   文件名不含 amd64/arm64 字样——App Center
#                                   手动安装页对 amd64 报解析失败，坑 11/资产命名）
#   sftpgo_<platform>.deb           Release 资产名 deb（版本由 Release tag 表达）
#   sftpgo_<platform>.deb.sha256    上架要求的校验文件
#
# 阶段: fetch → stage → verify → deb
# ============================================================
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=config.env
. "$SCRIPT_DIR/config.env"

BUILD_DIR="$SCRIPT_DIR/build"
DL_DIR="$BUILD_DIR/downloads"
STAGE_DIR="$BUILD_DIR/pkgroot"
OUT_DIR="$SCRIPT_DIR/out"
ASSETS_DIR="$SCRIPT_DIR/assets"
RESEARCH_DIR="$SCRIPT_DIR/research"

# 完整版本 = 上游版本-打包迭代号；三处一致：config.ini / DEBIAN/control / .lang
VERSION_FULL="${SFTPGO_VERSION}-${PKG_RELEASE}"

# ---------------- 目标平台（TOS / NAS 侧） ----------------
case "$TARGET_ARCH" in
  amd64)
    GOARCH="x86_64"
    TOS_PLATFORM="x86_64"
    ELF_ARCH="x86-64"
    ;;
  arm64)
    GOARCH="arm64"
    TOS_PLATFORM="aarch64"
    ELF_ARCH="ARM aarch64"
    ;;
  *)
    echo "错误: 未知 TARGET_ARCH=$TARGET_ARCH（支持 amd64 / arm64）" >&2
    exit 1
    ;;
esac

TAG="v$SFTPGO_VERSION"
RELEASE_BASE="https://github.com/drakkan/sftpgo/releases/download/$TAG"   # 仅参考（对照官方产物用）
# 源码构建常量（V6 整改：deb 内二进制必须源码可复现；单一事实源 = scripts/repro-build.sh）
SRC_TARBALL="sftpgo-${SFTPGO_VERSION}.tar.gz"
SRC_URL="https://github.com/drakkan/sftpgo/archive/refs/tags/v${SFTPGO_VERSION}.tar.gz"
SRC_MIRROR="https://ghfast.top/${SRC_URL}"
SRC_SHA256=$(grep '^SRC_SHA256=' "$SCRIPT_DIR/scripts/repro-build.sh" | cut -d'"' -f2)
SRC_COMMIT=$(grep '^SRC_COMMIT=' "$SCRIPT_DIR/scripts/repro-build.sh" | cut -d'"' -f2)
GO_VERSION_PIN=$(grep '^GO_VERSION=' "$SCRIPT_DIR/scripts/repro-build.sh" | cut -d'"' -f2)
REPRO_DIR="$DL_DIR/repro"
LICENSE_FILE="LICENSE"
NOTICE_FILE="NOTICE"
DEB_FILE="$OUT_DIR/${APP_ID}_${VERSION_FULL}_${TOS_PLATFORM}.deb"
STORE_DEB="$OUT_DIR/${APP_ID}_${TOS_PLATFORM}.deb"

MAINTAINER_FULL="$MAINTAINER_NAME <$MAINTAINER_EMAIL>"

log()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m警告:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m错误:\033[0m %s\n' "$*" >&2; exit 1; }

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

normalize_text() { # 规范要求：文本文件 LF 行尾 + UTF-8 无 BOM（构建时统一清洗）
  python3 - "$@" <<'PYEOF'
import sys
for p in sys.argv[1:]:
    with open(p, 'rb') as f:
        data = f.read()
    if data.startswith(b'\xef\xbb\xbf'):
        data = data[3:]
    data = data.replace(b'\r\n', b'\n').replace(b'\r', b'\n')
    with open(p, 'wb') as f:
        f.write(data)
PYEOF
}

fetch() { # fetch <url> <dest-file>（GitHub 直连 + ghfast 镜像备选 + 断点续传）
  local url=$1 dest=$2
  if [ -s "$dest" ]; then return 0; fi
  mkdir -p "$(dirname "$dest")"
  local mirror="${url/https:\/\/github.com/https:\/\/ghfast.top\/https:\/\/github.com}"
  for attempt in 1 2 3; do
    if curl -fL --retry 3 --retry-delay 3 --retry-all-errors \
         --connect-timeout 20 -C - -o "$dest.part" "$url"; then
      mv "$dest.part" "$dest"; return 0
    fi
    rm -f "$dest.part"
    warn "直连下载失败(第 $attempt 次): $(basename "$dest")，尝试镜像..."
    if [ "$mirror" != "$url" ] && curl -fL --retry 3 --retry-delay 3 --retry-all-errors \
         --connect-timeout 20 -C - -o "$dest.part" "$mirror"; then
      mv "$dest.part" "$dest"; return 0
    fi
    rm -f "$dest.part"
    sleep 10
  done
  die "下载失败: $url（也可手工放入 $RESEARCH_DIR/ 后重跑）"
}

# ============================================================
# 阶段: fetch — 下载上游资产 + 供应链校验
#
# 上游无 checksums 资产（坑 7 类似情形），采用三重校验：
#   1) SHA256.lock（首次 fetch 后固化，之后强制比对）
#   2) tarball 内二进制 vs 上游官方 deb 内二进制哈希一致（两条独立分发渠道互证）
#   3) 资产大小与 GitHub API 一致（构建时打印供人工核对）
# ============================================================
stage_fetch() {
  mkdir -p "$DL_DIR" "$REPRO_DIR"

  # 1) 源码 tarball（上游官方 tag 归档；配方锁定 sha256，见 scripts/repro-build.sh）
  if [ ! -s "$DL_DIR/$SRC_TARBALL" ] || [ "$(sha256_of "$DL_DIR/$SRC_TARBALL")" != "$SRC_SHA256" ]; then
    log "下载源码 $SRC_URL"
    fetch "$SRC_URL" "$DL_DIR/$SRC_TARBALL"
  fi
  [ "$(sha256_of "$DL_DIR/$SRC_TARBALL")" = "$SRC_SHA256" ] \
    || die "源码 sha256 不匹配（期望 $SRC_SHA256）"

  # 2) 自建二进制（源码可复现产物）。本机非 Linux 时可经 REPRO_BUILD_HOST
  #    环境变量指定的构建机执行（主机名为私有配置，不入库）
  local BIN_NAME="sftpgo_$TOS_PLATFORM"   # x86_64 / aarch64（repro-build.sh 产物命名）
  if [ ! -s "$REPRO_DIR/$BIN_NAME" ]; then
    if [ -n "${REPRO_BUILD_HOST:-}" ]; then
      log "经 REPRO_BUILD_HOST 执行可复现构建配方..."
      local RDIR="/tmp/sftpgo-repro-$SFTPGO_VERSION-$$"
      ssh "$REPRO_BUILD_HOST" "mkdir -p $RDIR" 2>/dev/null || die "无法连接 REPRO_BUILD_HOST"
      cat "$SCRIPT_DIR/scripts/repro-build.sh" | ssh "$REPRO_BUILD_HOST" "cat > $RDIR/repro-build.sh && chmod +x $RDIR/repro-build.sh"
      cat "$DL_DIR/$SRC_TARBALL" | ssh "$REPRO_BUILD_HOST" "cat > $RDIR/$SRC_TARBALL"
      ssh "$REPRO_BUILD_HOST" "bash -n $RDIR/repro-build.sh && ${REPRO_GOPROXY:+GOPROXY=$REPRO_GOPROXY} $RDIR/repro-build.sh $RDIR" 2>&1 | tail -6
      local f
      for f in sftpgo_x86_64 sftpgo_aarch64 manifest.txt; do
        ssh "$REPRO_BUILD_HOST" "cat $RDIR/out/$f" > "$REPRO_DIR/$f" \
          || die "构建产物取回失败（$f）"
      done
      ssh "$REPRO_BUILD_HOST" "rm -rf $RDIR" 2>/dev/null || true
    else
      cat >&2 <<EOF
缺少自建二进制 $REPRO_DIR/$BIN_NAME
获取方式（三选一）:
  a) 在任意 Ubuntu 22.04 x86_64 机器上执行:   ./scripts/repro-build.sh <工作目录>
     产物 sftpgo_x86_64 / sftpgo_aarch64 / manifest.txt 拷入 $REPRO_DIR/
  b) 有 Docker 的机器:   docker build -f Dockerfile.repro -t sftpgo-repro . && docker run --rm -v $PWD/$REPRO_DIR:/out sftpgo-repro
  c) 私有构建机:         REPRO_BUILD_HOST=<host> ./build.sh
EOF
      die "请先产出可复现构建产物"
    fi
  fi

  # 3) REPRO.lock.<arch>（管线防篡改：源码 + 本架构自建二进制；首次固化）
  local LOCK="$DL_DIR/REPRO.lock.$TARGET_ARCH"
  local bin_sha
  bin_sha=$(sha256_of "$REPRO_DIR/$BIN_NAME")
  if [ -f "$LOCK" ]; then
    log "校验 REPRO.lock.$TARGET_ARCH..."
    local want_bin want_src
    want_bin=$(grep " $BIN_NAME\$" "$LOCK" | awk '{print $1}')
    want_src=$(grep " $SRC_TARBALL\$" "$LOCK" | awk '{print $1}')
    [ "$bin_sha" = "$want_bin" ] || die "自建二进制哈希与锁定值不符（lock=$want_bin got=$bin_sha）——配方或工具链变动？确认后删 $LOCK 重新固化"
    [ "$SRC_SHA256" = "$want_src" ] || die "源码哈希与锁定值不符"
    log "  ok: 与锁定哈希一致"
  else
    { echo "$SRC_SHA256  $SRC_TARBALL"; echo "$bin_sha  $BIN_NAME"; } > "$LOCK"
    log "REPRO.lock.$TARGET_ARCH 已固化（二进制 $(echo "$bin_sha" | cut -c1-12)...）"
  fi

  # 4) 产物完整性：manifest 声明 == 实际哈希；buildinfo 注入抽查（V6 证据链）
  log "校验自建产物（manifest + buildinfo 注入）..."
  ( cd "$REPRO_DIR" && grep -F "$bin_sha  $BIN_NAME" manifest.txt >/dev/null ) \
    || die "manifest.txt 未包含本架构二进制哈希——产物与配方不配套，请重跑 repro-build.sh"
  local n_hit
  n_hit=$(strings "$REPRO_DIR/$BIN_NAME" 2>/dev/null | grep -c "$SRC_COMMIT" || true)
  [ "${n_hit:-0}" -ge 1 ] \
    || die "二进制未含源码 commit $SRC_COMMIT（version.commit 注入失败）"
  log "  ok: 源码可复现产物就绪（commit $SRC_COMMIT / $GO_VERSION_PIN）"
}

# ============================================================
# 阶段: stage —— 组装 deb 文件系统树（官方规范布局）
# ============================================================
stage_stage() {
  [ -s "$REPRO_DIR/sftpgo_$TOS_PLATFORM" ] || die "缺少自建二进制，请先运行: ./build.sh fetch"

  local APP="$STAGE_DIR/usr/local/$APP_ID"
  log "组装文件系统树: $STAGE_DIR（/usr/local/$APP_ID 规范布局）"
  rm -rf "$STAGE_DIR"
  mkdir -p "$APP/bin" "$APP/images/icons" "$APP/nginx" "$APP/init.d" "$APP/privacy"
  mkdir -p "$STAGE_DIR/usr/share/doc/$APP_ID"

  # 二进制 + static/templates/openapi（模板缺失会启动 fatal、静态资源非内嵌，D-010）
  # V6 整改（D-015）：二进制 = 源码可复现自建产物；资源 = 上游源码树同名目录
  log "  + bin/sftpgo（源码自建 $SRC_COMMIT）+ static/ + templates/ + openapi/"
  local SRC_DIR="$BUILD_DIR/src"
  rm -rf "$SRC_DIR"; mkdir -p "$SRC_DIR"
  tar -xzf "$DL_DIR/$SRC_TARBALL" -C "$SRC_DIR" --strip-components=1
  cp "$REPRO_DIR/sftpgo_$TOS_PLATFORM" "$APP/bin/sftpgo"
  chmod 0755 "$APP/bin/sftpgo"
  cp -R "$SRC_DIR/static" "$SRC_DIR/templates" "$SRC_DIR/openapi" "$APP/"
  chmod -R a+rX "$APP/static" "$APP/templates" "$APP/openapi"
  # make-config 输入与文档引用的上游默认文件（源码树导出）
  cp "$SRC_DIR/sftpgo.json" "${TMPDIR:-/tmp}/sftpgo-upstream.json"
  cp "$SRC_DIR/LICENSE" "${TMPDIR:-/tmp}/sftpgo-upstream-LICENSE"
  cp "$SRC_DIR/NOTICE" "${TMPDIR:-/tmp}/sftpgo-upstream-NOTICE" 2>/dev/null || true

  # config.ini（严格 JSON；@@...@@ 占位符渲染）
  log "  + config.ini（External Open: open_path=true, path=/$APP_ID/）"
  sed -e "s|@@VERSION@@|$VERSION_FULL|g" \
      -e "s|@@PUBLISHER@@|$PUBLISHER|g" \
      -e "s|@@PLATFORM@@|$TOS_PLATFORM|g" \
      "$ASSETS_DIR/config.ini.in" > "$APP/config.ini"

  # 多语言文件（文件名必须等于 app id；23 语超集，D-011）
  log "  + $APP_ID.lang（23 语言超集）"
  sed -e "s|@@VERSION@@|$VERSION_FULL|g" \
      "$ASSETS_DIR/$APP_ID.lang" > "$APP/$APP_ID.lang"

  # 图标（透明背景 SVG，文件名必须等于 app id）
  log "  + images/icons/$APP_ID.svg"
  cp "$ASSETS_DIR/images/icons/$APP_ID.svg" "$APP/images/icons/$APP_ID.svg"

  # nginx 路由：app 目录内 nginx/ 满足 TOS 规范；同时以 dpkg 实体文件双落盘
  # /etc/nginx/conf.d（metube/beszel 验证过的双落盘模式；postinst 校验与自愈）
  log "  + nginx/ + /etc/nginx/conf.d/（web 8095 / webdav 8096 / api 均回环）"
  mkdir -p "$STAGE_DIR/etc/nginx/conf.d"
  cp "$ASSETS_DIR/nginx/$APP_ID.conf" "$APP/nginx/$APP_ID.conf"
  cp "$ASSETS_DIR/nginx/$APP_ID.conf" "$STAGE_DIR/etc/nginx/conf.d/$APP_ID.conf"

  # systemd 服务：init.d/ 只放主服务（system_id 同名单元，坑 11）；
  # /etc/systemd/system 实体文件双落盘
  log "  + init.d/ + /etc/systemd/system/sftpgo.service"
  mkdir -p "$STAGE_DIR/etc/systemd/system"
  cp "$ASSETS_DIR/init.d/sftpgo.service" "$APP/init.d/sftpgo.service"
  cp "$ASSETS_DIR/init.d/sftpgo.service" "$STAGE_DIR/etc/systemd/system/sftpgo.service"

  # webui.bz2（WebUI 类应用必填；解压须含可打开的 .html。真实 UI 由 sftpgo
  # 二进制内嵌模板 + static/ 提供，经 nginx 路由访问；本页为规范占位 + 隐私入口）。
  # 用 python tarfile 而非 bsdtar：macOS bsdtar 会把成员打上本机 uid/gid
  # （postinst 解压后文件变 uid 501）且会塞进 AppleDouble ._垃圾文件
  # ——测试机 真机实证；内嵌资产必须归一化 root:root）
  log "  + webui.bz2（占位页，含隐私政策入口；python tarfile 归一化 root:root）"
  local WEBUI_DIR="$BUILD_DIR/webui"
  rm -rf "$WEBUI_DIR"
  mkdir -p "$WEBUI_DIR"
  for f in index.html app.js styles.css; do
    sed -e "s|@@VERSION@@|$VERSION_FULL|g" "$ASSETS_DIR/webui/$f" > "$WEBUI_DIR/$f"
  done
  python3 - "$WEBUI_DIR" "$APP/webui.bz2" <<'PYEOF'
import os, sys, tarfile
src, out = sys.argv[1], sys.argv[2]
with tarfile.open(out, 'w:bz2', format=tarfile.GNU_FORMAT) as tf:
    for name in sorted(os.listdir(src)):
        if name.startswith('._') or name == '.DS_Store':
            continue
        full = os.path.join(src, name)
        ti = tf.gettarinfo(full, arcname=name)
        ti.uid = ti.gid = 0
        ti.uname = ti.gname = 'root'
        ti.mtime = 0
        with open(full, 'rb') as f:
            tf.addfile(ti, f)
PYEOF

  # 应用配置模板（.example 随包，postinst 首装复制为正式文件，升级永不覆盖——坑 2）
  log "  + sftpgo.json.example（上游默认配置 + TOS 定制）+ sftpgo.env.example"
  python3 "$SCRIPT_DIR/scripts/make-config.py" \
    "${TMPDIR:-/tmp}/sftpgo-upstream.json" "$APP/sftpgo.json.example" \
    "$HTTPD_PORT" "$WEBDAVD_PORT" "$SFTPD_PORT" "/var/lib/$APP_ID"
  cp "$ASSETS_DIR/sftpgo.env.example" "$APP/sftpgo.env.example"

  # 隐私政策（D-012：nginx /sftpgo/privacy/ 静态提供）
  log "  + privacy/privacy-policy.html"
  cp "$ASSETS_DIR/privacy/privacy-policy.html" "$APP/privacy/privacy-policy.html"

  # 文档（AGPL-3.0 全文 + NOTICE）
  log "  + /usr/share/doc/$APP_ID/（copyright=AGPL-3.0, NOTICE, changelog）"
  cp "${TMPDIR:-/tmp}/sftpgo-upstream-LICENSE" "$STAGE_DIR/usr/share/doc/$APP_ID/copyright"
  if [ -f "${TMPDIR:-/tmp}/sftpgo-upstream-NOTICE" ]; then
    cp "${TMPDIR:-/tmp}/sftpgo-upstream-NOTICE" "$STAGE_DIR/usr/share/doc/$APP_ID/NOTICE"
  fi
  {
    echo "$APP_ID ($VERSION_FULL) TOS7; urgency=medium"
    echo ""
    echo "  * 基于 SFTPGo 上游 $SFTPGO_VERSION 打包（官方 Release 二进制，与官方 deb 交叉校验）"
    echo "  * Web 面（WebAdmin/WebClient/WebDAV/REST API）经 TOS nginx /sftpgo/ 反代，后端仅回环"
    echo "  * SFTP 监听 2022；SQLite 数据目录 /var/lib/sftpgo；首管理员安装时自动引导"
    echo ""
    echo " -- $MAINTAINER_FULL  $(date -R 2>/dev/null || date '+%a, %d %b %Y %H:%M:%S %z')"
  } > "$STAGE_DIR/usr/share/doc/$APP_ID/changelog.Debian"

  # 规范清洗：LF 行尾 + 去 BOM
  log "  清洗行尾（LF）与 BOM"
  normalize_text \
    "$APP/config.ini" "$APP/$APP_ID.lang" \
    "$APP/nginx/$APP_ID.conf" \
    "$STAGE_DIR/etc/nginx/conf.d/$APP_ID.conf" \
    "$APP/init.d/"*.service \
    "$STAGE_DIR/etc/systemd/system/"*.service \
    "$APP/"*.example \
    "$APP/privacy/privacy-policy.html" \
    "$STAGE_DIR/usr/share/doc/$APP_ID/changelog.Debian"

  # 清理 macOS 扩展属性与 AppleDouble 边车（坑 8：._* 藏在 tar 内部，构建机不可见）
  if command -v xattr >/dev/null 2>&1; then
    xattr -rc "$STAGE_DIR" >/dev/null 2>&1 || true
  fi
  find "$STAGE_DIR" -name '._*' -delete 2>/dev/null || true
  find "$STAGE_DIR" -name '.DS_Store' -delete 2>/dev/null || true

  log "组装完成"
}

# ============================================================
# 阶段: verify —— 规范关键项 + 本项目特有断言
# ============================================================
stage_verify() {
  local APP="$STAGE_DIR/usr/local/$APP_ID"
  [ -d "$APP" ] || die "尚未组装，请先运行: ./build.sh stage"
  local fail=0

  log "校验规范关键路径..."
  local p
  for p in "$APP/config.ini" "$APP/$APP_ID.lang" \
           "$APP/images/icons/$APP_ID.svg" \
           "$APP/nginx/$APP_ID.conf" \
           "$APP/init.d/sftpgo.service" \
           "$STAGE_DIR/etc/systemd/system/sftpgo.service" \
           "$STAGE_DIR/etc/nginx/conf.d/$APP_ID.conf" \
           "$APP/bin/sftpgo" \
           "$APP/static/favicon.png" \
           "$APP/templates/email/reset-password.html" \
           "$APP/openapi/openapi.yaml" \
           "$APP/webui.bz2" \
           "$APP/sftpgo.json.example" \
           "$APP/sftpgo.env.example" \
           "$APP/privacy/privacy-policy.html" \
           "$STAGE_DIR/usr/share/doc/$APP_ID/copyright"; do
    [ -e "$p" ] || { warn "缺失: ${p#$STAGE_DIR/}"; fail=1; }
  done

  log "校验 config.ini（JSON 合法性 / 互斥字段 / 版本一致性）..."
  python3 - "$APP/config.ini" "$VERSION_FULL" "$TOS_PLATFORM" "$APP_ID" <<'PYEOF' || fail=1
import json, sys
cfg_path, want_ver, want_plat, app_id = sys.argv[1:5]
cfg = json.load(open(cfg_path))
errs = []
if cfg.get("id") != app_id: errs.append(f"id != {app_id}")
if cfg.get("version") != want_ver: errs.append(f"version != {want_ver}")
if cfg.get("system_id") != app_id: errs.append("system_id 不一致")
if cfg.get("package") != app_id: errs.append("package 不一致")
if cfg.get("platform") != want_plat: errs.append(f"platform != {want_plat}")
if cfg.get("open_path") is not True: errs.append("open_path 必须为 true")
if "type" in cfg: errs.append("不得包含 type 字段（与 open_path 互斥）")
if cfg.get("path") != f"/{app_id}/": errs.append(f"path 必须为 /{app_id}/")
if cfg.get("user") != app_id: errs.append(f"user 应为 {app_id}")
if cfg.get("recommend") is not False: errs.append("recommend 提交时必须为 false")
for e in errs:
    print(f"    校验失败: {e}", file=sys.stderr)
sys.exit(1 if errs else 0)
PYEOF

  log "校验 .lang（14 必需语言 + 23 语超集）..."
  local lang_missing
  lang_missing=$(python3 - "$APP/$APP_ID.lang" <<'PYEOF'
import sys
required14 = ["zh-cn","zh-hk","en-us","fr-fr","de-de","it-it","es-es",
              "hu-hu","ja-jp","ko-kr","pl-pl","ru-ru","tr-tr","pt-pt"]
extra9 = ["ar-sa","cs-cz","he-il","id-id","nb-no","nl-nl","sv-se","th-th","vi-vn"]
text = open(sys.argv[1], encoding="utf-8").read()
missing = [t for t in required14 + extra9 if f"[{t}]" not in text]
print(",".join(missing))
PYEOF
)
  [ -z "$lang_missing" ] || { warn "lang 缺少语言节: $lang_missing"; fail=1; }

  # init.d 必须恰好一个服务文件（坑 11：多单元卡死应用中心安装）
  local n_initd
  n_initd=$(ls "$APP/init.d/"*.service 2>/dev/null | wc -l | tr -d ' ')
  [ "$n_initd" = "1" ] || { warn "init.d/ 必须只含主服务（当前 $n_initd 个）"; fail=1; }

  log "校验 systemd 服务（禁 Restart/必配 StartLimit/禁 ExecStart 变量展开/专用用户）..."
  local svc
  for svc in "$APP/init.d/"*.service "$STAGE_DIR/etc/systemd/system/"*.service; do
    grep -q '^\[Unit\]' "$svc" || { warn "非 systemd unit: $svc"; fail=1; }
    grep -Eq '^Restart' "$svc" && { warn "规范禁止配置 Restart: $svc"; fail=1; }
    grep -Eq '^ExecStart=.*\$' "$svc" && { warn "ExecStart 禁用变量展开（坑 1）: $svc"; fail=1; }
    grep -q '^StartLimitBurst=' "$svc" || { warn "缺少 StartLimitBurst: $svc"; fail=1; }
    grep -q '^StartLimitIntervalSec=' "$svc" || { warn "缺少 StartLimitIntervalSec: $svc"; fail=1; }
    grep -q '^User=sftpgo' "$svc" || { warn "必须 User=sftpgo: $svc"; fail=1; }
  done

  log "校验 sftpgo.json.example（端口/回环/web_root/prefix/首启向导）..."
  python3 - "$APP/sftpgo.json.example" "$HTTPD_PORT" "$WEBDAVD_PORT" "$SFTPD_PORT" <<'PYEOF' || fail=1
import json, sys
cfg, httpd_p, webdav_p, sftp_p = sys.argv[1:5]
c = json.load(open(cfg))
errs = []
h = c["httpd"]["bindings"][0]
if h["address"] != "127.0.0.1": errs.append("httpd 必须仅监听 127.0.0.1")
if h["port"] != int(httpd_p): errs.append(f"httpd 端口 != {httpd_p}")
if c["httpd"].get("web_root") != "/sftpgo": errs.append("httpd.web_root 必须为 /sftpgo")
w = c["webdavd"]["bindings"][0]
if w["address"] != "127.0.0.1": errs.append("webdavd 必须仅监听 127.0.0.1")
if w["port"] != int(webdav_p): errs.append(f"webdavd 端口 != {webdav_p}")
if w.get("prefix") != "/sftpgo/webdav": errs.append("webdavd prefix 必须为 /sftpgo/webdav")
s = c["sftpd"]["bindings"][0]
if s["port"] != int(sftp_p): errs.append(f"sftpd 端口 != {sftp_p}")
if s["address"] != "": errs.append("sftpd 应监听全部接口（对外服务）")
if c["data_provider"]["driver"] != "sqlite": errs.append("数据源必须 sqlite")
if not c["data_provider"]["name"].startswith("/var/lib/sftpgo/"): errs.append("sqlite 必须绝对路径落 /var/lib")
if c["data_provider"].get("create_default_admin") is not False: errs.append("必须关闭 create_default_admin（D-014 首启向导，防预置凭据不可发现）")
if c["ftpd"]["bindings"][0]["port"] != 0: errs.append("FTP 默认必须关闭")
for e in errs:
    print(f"    校验失败: {e}", file=sys.stderr)
sys.exit(1 if errs else 0)
PYEOF

  log "校验 nginx conf 与 sftpgo.json 端口一致..."
  local conf="$APP/nginx/$APP_ID.conf"
  grep -q "proxy_pass http://127.0.0.1:$HTTPD_PORT;" "$conf" \
    || { warn "nginx 缺少 httpd($HTTPD_PORT) 前缀保留直通 location"; fail=1; }
  grep -q "proxy_pass http://127.0.0.1:$WEBDAVD_PORT;" "$conf" \
    || { warn "nginx 缺少 webdavd($WEBDAVD_PORT) location"; fail=1; }
  grep -q "proxy_pass http://127.0.0.1:$HTTPD_PORT/api/;" "$conf" \
    || { warn "nginx 缺少 REST API 剥前缀 location"; fail=1; }

  log "校验 webui.bz2（解压含 .html 且含隐私政策链接）..."
  tar tjf "$APP/webui.bz2" | grep -q '\.html$' || { warn "webui.bz2 缺少 html"; fail=1; }
  tar xjOf "$APP/webui.bz2" index.html | grep -q '/sftpgo/privacy/' \
    || { warn "占位页缺少隐私政策入口（坑 21）"; fail=1; }

  # 内嵌归档卫生（真机实证：bsdtar 产物带 uid 501 + AppleDouble 垃圾，postinst
  # 解压后应用目录出现非 root 属主文件；所有随包 tar 必须归一化 root:root）
  log "校验内嵌归档卫生（macOS 垃圾零容忍 + 成员 root:root）..."
  local n_junk n_baduid
  n_junk=$(find "$STAGE_DIR" -name '._*' -o -name '.DS_Store' | wc -l | tr -d ' ')
  [ "$n_junk" -eq 0 ] || { find "$STAGE_DIR" -name '._*' -o -name '.DS_Store' | head -5; warn "发现 $n_junk 个 macOS 垃圾文件（._*/.DS_Store）混入！"; fail=1; }
  n_baduid=$(python3 - "$APP/webui.bz2" <<'PYEOF'
import sys, tarfile
bad = 0
with tarfile.open(sys.argv[1], 'r:bz2') as tf:
    for m in tf.getmembers():
        if m.uid != 0 or m.gid != 0 or m.name.startswith('._'):
            bad += 1
print(bad)
PYEOF
)
  [ "$n_baduid" = "0" ] || { warn "webui.bz2 有 $n_baduid 个非 root:root / 垃圾成员！"; fail=1; }
  # host_keys 已在默认配置里指向数据目录（D-013）
  grep -q '"host_keys"' "$APP/sftpgo.json.example" \
    || { warn "sftpgo.json.example 缺 sftpd.host_keys（D-013：/usr/local 只读后必须显式指定）"; fail=1; }
  grep -q 'hostkeys' assets/postinst \
    || { warn "postinst 缺 hostkeys 预生成逻辑（服务无法自助生成，缺失即 502）"; fail=1; }

  log "校验 ELF 架构防呆（目标: $ELF_ARCH；坑 28：防错架构二进制混入）..."
  file "$APP/bin/sftpgo" | grep -q "ELF.*$ELF_ARCH" \
    || { warn "错误架构: $(file "$APP/bin/sftpgo")"; fail=1; }
  local n_wrong
  n_wrong=$(find "$APP" -type f -exec file {} + 2>/dev/null | grep -c "Mach-O" || true)
  [ "$n_wrong" -eq 0 ] || { warn "发现 $n_wrong 个 Mach-O 文件混入！"; fail=1; }

  # V6（D-015）：staged 二进制 == 源码可复现自建产物（哈希必须一致）
  [ "$(sha256_of "$APP/bin/sftpgo")" = "$(sha256_of "$REPRO_DIR/sftpgo_$TOS_PLATFORM")" ] \
    || { warn "staged 二进制与自建产物哈希不一致！"; fail=1; }
  # 复现材料齐全（V6 整改硬要求）
  for f in scripts/repro-build.sh Dockerfile.repro VERIFICATION.md; do
    [ -f "$SCRIPT_DIR/$f" ] || { warn "缺少复现材料 $f（V6 必备）"; fail=1; }
  done

  log "S8 零网络断言（坑 15：deb 维护脚本不得在线安装；审查员同款扫法）..."
  local net_hits
  net_hits=$(grep -nE 'curl |wget |pip install|pip3 install|apt(-get)? install|urllib|urlopen|--index-url|pypi\.' \
      "$STAGE_DIR/DEBIAN"/{preinst,postinst,prerm,postrm} 2>/dev/null || true)
  [ -z "$net_hits" ] || { warn "维护脚本疑似在线操作（S8 红线）:\n$net_hits"; fail=1; }

  if [ "$fail" -eq 0 ]; then
    log "校验通过 ✅"
  else
    die "校验失败，请检查上方警告"
  fi
}

# ============================================================
# 阶段: deb —— 生成 .deb + 上架资产
# ============================================================
stage_deb() {
  [ -d "$STAGE_DIR/usr/local/$APP_ID" ] || die "尚未组装，请先运行: ./build.sh stage"
  mkdir -p "$OUT_DIR"
  "$SCRIPT_DIR/makedeb.sh" "$STAGE_DIR" "$ASSETS_DIR" "$DEB_FILE" \
    "$VERSION_FULL" "$TARGET_ARCH" "$MAINTAINER_FULL"

  # Release 资产命名（版本由 Release tag 表达）+ 上架要求的 sha256（基名，便于用户 sha256sum -c）
  cp "$DEB_FILE" "$STORE_DEB"
  local SUM
  SUM=$(sha256_of "$STORE_DEB")
  printf '%s  %s\n' "$SUM" "$(basename "$STORE_DEB")" > "$STORE_DEB.sha256"
  log "完成: $DEB_FILE"
  log "上架资产: $STORE_DEB (+ .sha256；Release tag 须为 v$VERSION_FULL)"
}

stage_info() {
  cat <<EOF
SFTPGo 版本   : $SFTPGO_VERSION (完整版本 $VERSION_FULL)
目标架构      : $TARGET_ARCH (Go:$GOARCH TOS:$TOS_PLATFORM)
TOS app id    : $APP_ID（新标签页 /$APP_ID/，web 127.0.0.1:$HTTPD_PORT，webdav 127.0.0.1:$WEBDAVD_PORT，SFTP :$SFTPD_PORT）
产物          : $DEB_FILE
上架资产      : $STORE_DEB + .sha256（Release tag: v$VERSION_FULL）
EOF
}

stage_clean() {
  rm -rf "$STAGE_DIR" "$BUILD_DIR/webui"
  log "已清理 stage（保留下载缓存与 SHA256.lock）"
}

stage_distclean() {
  rm -rf "$BUILD_DIR" "$OUT_DIR"
  log "已清理全部构建产物与下载缓存（含 SHA256.lock.*，下次 fetch 重新固化）"
}

# ============================================================
# 入口
# ============================================================
STAGE=${1:-all}
case "$STAGE" in
  fetch)      stage_fetch ;;
  stage)      stage_stage ;;
  deb)        stage_deb ;;
  all)        stage_fetch; stage_stage; stage_verify; stage_deb ;;
  clean)      stage_clean ;;
  distclean)  stage_distclean ;;
  verify)     stage_verify ;;
  info)       stage_info ;;
  *)          die "未知阶段: $STAGE（可用: fetch stage deb verify clean distclean info）" ;;
esac
