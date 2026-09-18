# 可复现性验证指南（V6 整改）

本仓库分发的 deb 包内 `usr/local/sftpgo/bin/sftpgo` **不是**上游预编译产物，
而是由本仓库公开配方从上游官方源码构建，任何人可独立复现并比对哈希。

## 三步验证

```bash
# 1) 准备本仓库（含 scripts/repro-build.sh）并进入构建环境之一：
#    a) 任意 Ubuntu 22.04 x86_64（gcc 11.4 / glibc 2.35）裸机
#    b) docker build -f Dockerfile.repro -t sftpgo-repro .

# 2) 构建并取哈希（方式 a）
./scripts/repro-build.sh /tmp/repro
sha256sum /tmp/repro/out/sftpgo_x86_64 /tmp/repro/out/sftpgo_aarch64
#    （方式 b）
docker run --rm -v "$PWD/out-repro":/out --entrypoint sh sftpgo-repro \
    -c 'repro-build.sh /work && cp /work/out/* /out/'
sha256sum out-repro/sftpgo_*

# 3) 与本 Release 分发的 deb 内二进制比对
ar x sftpgo_x86_64.deb && tar -xJf data.tar.xz ./usr/local/sftpgo/bin/sftpgo
sha256sum ./usr/local/sftpgo/bin/sftpgo
```

## 期望哈希（2.7.5-4）

| 产物 | sha256 |
|---|---|
| sftpgo_x86_64 | `5c5415f16611893f15b938c23a2cd5cb0df9b8b4f66654ea6fad9856b5b643b0` |
| sftpgo_aarch64 | `7a3932a2e0ecc73c48ac8838fc83662fcfe5c6050e597346f8dc8120c4c71816` |

## 配方锁定的全部变量

| 变量 | 值 | 来源 |
|---|---|---|
| 源码 | sftpgo v2.7.5（commit `9888a3d1`） | github.com/drakkan/sftpgo tag archive |
| 源码归档 sha256 | `224e75b1…57c9` | scripts/repro-build.sh |
| Go 工具链 | go1.25.12 linux/amd64 官方 tarball（sha256 锁定） | go.dev/dl |
| C 编译器 | gcc 11.4.0（本机 + aarch64-linux-gnu-gcc 交叉） | Ubuntu 22.04 apt |
| glibc | 2.35（= TOS 7 基座，产物动态链接它） | Ubuntu 22.04 |
| 构建命令 | 与上游 release.yml 完全一致（见下） | .github/workflows/release.yml |

构建命令（两架构同参数，仅 GOARCH/CC 不同）：

```
CGO_ENABLED=1 GOAMD64=v1 go build -buildvcs=false -trimpath \
  -tags nopgxregisterdefaulttypes,disable_grpc_modules \
  -ldflags "-s -w -X .../version.commit=9888a3d1 -X .../version.date=2026-07-17T16:58:46Z"
```

与上游 CI 的唯一偏差：上游把 `version.date` 注入为构建时刻（不可复现），
本配方固定为上游 tag 的提交时间戳（与官方二进制 buildinfo 一致，故自建
产物的 `version` 串与官方发布完全相同）。

## 关于与官方预编译二进制哈希不同的说明

官方 Release 二进制在其 CI（Ubuntu 18.04 + gcc-7）环境构建，与本地配方
（Ubuntu 22.04 + gcc 11.4 = TOS 7 基座）必然不同。可复现性的判据是
**「本配方在任意机器重建 → 与本包分发物位级一致」**，而非与官方 CI 产物
一致。Go 工具链、源码、构建参数与官方完全对齐，`go version -m` 的
模块依赖集与官方二进制逐项一致，可交叉印证。
