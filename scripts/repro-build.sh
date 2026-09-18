#!/usr/bin/env bash
# ============================================================================
# SFTPGo 可复现源码构建配方（TOS 审核 V6 整改）
#
# 目的：任何人可在公开源码 + 本配方上重建出与本包分发的二进制位级一致的
#       产物（sha256 比对即验证），满足「源码可审计形态」要求。
#
# 环境要求（配方锁定的全部外部变量，缺一不可）：
#   - Ubuntu 22.04 x86_64（与 TOS 7 同基座；gcc 11.4 / glibc 2.35）
#   - gcc 11.4.0                （apt: gcc）
#   - aarch64-linux-gnu-gcc 11.4（apt: gcc-aarch64-linux-gnu；交叉构建 arm64 用）
#   - Go 1.25.12（官方二进制发行包，见下方 SHA256；与本脚本同仓的 Dockerfile
#     可在任意有 Docker 的机器上一键复现本环境）
#
# 构建命令与上游 release.yml（prepare-linux job）完全一致，仅有一处偏差：
#   - 上游注入 version.date = 构建时刻（不可复现）；本配方固定为上游 tag
#     v2.7.5 的提交时间戳，使任意时刻重建结果一致。
#
# 用法：
#   ./repro-build.sh [工作目录]     # 默认 /tmp/sftpgo-repro
#   产出: <工作目录>/out/sftpgo_x86_64、sftpgo_aarch64、manifest.txt
# ============================================================================
set -euo pipefail

# ---- 锁定常量（升级上游版本时只改这里）----
SFTPGO_VERSION="2.7.5"
SRC_COMMIT="9888a3d1"                       # 上游 tag v2.7.5 的 commit 前 8 位
SRC_DATE="2026-07-17T16:58:46Z"             # 上游 tag 提交时间（UTC）
SRC_URL="https://github.com/drakkan/sftpgo/archive/refs/tags/v${SFTPGO_VERSION}.tar.gz"
SRC_SHA256="224e75b16607567b8fe2ae37a3a75a61ec52e7eccdf6b46a28df5f65131757c9"
GO_VERSION="1.25.12"
GO_SHA256_AMD64="234828b7a89e0e303d2556310ee549fbcf253d28de937bac3da13d6294262ac1"
GO_SHA256_ARM64="8b5884aef89600aef5b0b051fb971f11f49bb996521e911f30f02a66884f7bd2"  # 审核者在 arm 机器复现用
GCC_PIN="11.4"                 # 编译代码生成相关的版本护栏（Ubuntu 22.04 仓库内微版本不变）
GLIBC_PIN="2.35"               # 链接目标 glibc（Ubuntu 22.04 / TOS 7 基座）
LDFLAGS="-s -w -X github.com/drakkan/sftpgo/v2/internal/version.commit=${SRC_COMMIT} -X github.com/drakkan/sftpgo/v2/internal/version.date=${SRC_DATE}"
BUILDTAGS="nopgxregisterdefaulttypes,disable_grpc_modules"

WORK="${1:-/tmp/sftpgo-repro}"
OUT="$WORK/out"
mkdir -p "$WORK" "$OUT"

# ---- 工具链自检 ----
GO_BIN="${GO_BIN:-/usr/local/go/bin/go}"
command -v "$GO_BIN" >/dev/null 2>&1 || { echo "缺少 Go ${GO_VERSION}（安装：https://go.dev/dl/ 或用同仓 Dockerfile）" >&2; exit 1; }
[ "$("$GO_BIN" version)" = "go version go${GO_VERSION} linux/amd64" ] || { echo "Go 版本不是 ${GO_VERSION} linux/amd64" >&2; exit 1; }
for t in gcc aarch64-linux-gnu-gcc; do command -v "$t" >/dev/null || { echo "缺少 $t（apt install gcc gcc-aarch64-linux-gnu）" >&2; exit 1; }; done
# 工具链护栏（环境漂移直接拒绝，而不是产出哈希不同的二进制）
case "$(gcc -dumpfullversion -dumpversion)" in
  "${GCC_PIN}".*) : ;;
  *) echo "gcc 版本非 ${GCC_PIN}.x（got $(gcc -dumpfullversion -dumpversion)），与配方不符" >&2; exit 1 ;;
esac
gl_ver=$(ldd --version | head -1 || true)
case "$gl_ver" in *"${GLIBC_PIN}"*) : ;; *) echo "glibc 非 ${GLIBC_PIN}（got $gl_ver），与配方不符" >&2; exit 1 ;; esac

export GOTOOLCHAIN=local          # 禁自动升级工具链
export GOAMD64=v1                 # 固定基准指令集（Go 默认 v1，显式声明防环境差异）
export CGO_ENABLED=1
[ -n "${GOPROXY:-}" ] || export GOPROXY="https://proxy.golang.org,direct"

# ---- 源码获取与校验 ----
SRC_TGZ="$WORK/sftpgo-${SFTPGO_VERSION}.tar.gz"
if [ ! -f "$SRC_TGZ" ] || ! echo "${SRC_SHA256}  $SRC_TGZ" | sha256sum -c - >/dev/null 2>&1; then
  echo "==> 下载源码 ${SRC_URL}"
  curl -fL --retry 5 --retry-delay 2 --connect-timeout 15 -o "$SRC_TGZ" "$SRC_URL"
fi
echo "${SRC_SHA256}  $SRC_TGZ" | sha256sum -c -
SRC_DIR="$WORK/src"
rm -rf "$SRC_DIR"; mkdir -p "$SRC_DIR"
tar -xzf "$SRC_TGZ" -C "$SRC_DIR" --strip-components=1

# ---- 构建（双架构；命令 = 上游 release.yml）----
cd "$SRC_DIR"
echo "==> 构建 x86_64（本机 gcc）"
"$GO_BIN" build -buildvcs=false -trimpath -tags "$BUILDTAGS" -ldflags "$LDFLAGS" -o "$OUT/sftpgo_x86_64"
echo "==> 构建 aarch64（交叉 gcc）"
GOARCH=arm64 CC=aarch64-linux-gnu-gcc "$GO_BIN" build -buildvcs=false -trimpath -tags "$BUILDTAGS" -ldflags "$LDFLAGS" -o "$OUT/sftpgo_aarch64"

# ---- 产物清单（可复现映射的证据文件）----
cd "$OUT"
sha256sum sftpgo_x86_64 sftpgo_aarch64 > manifest.txt
{
  echo "recipe       : repro-build.sh (this repo)"
  echo "source       : sftpgo v${SFTPGO_VERSION} (commit ${SRC_COMMIT})"
  echo "source sha256: ${SRC_SHA256}"
  echo "go toolchain : go${GO_VERSION} linux/amd64 (official tarball)"
  echo "go sha256    : ${GO_SHA256_AMD64}"
  echo "c compiler   : $(gcc -dumpfullversion -dumpversion) / $(aarch64-linux-gnu-gcc -dumpfullversion -dumpversion)"
  echo "build flags  : CGO_ENABLED=1 GOAMD64=v1 -buildvcs=false -trimpath -tags ${BUILDTAGS}"
  echo "ldflags      : ${LDFLAGS}"
} >> manifest.txt
cat manifest.txt
