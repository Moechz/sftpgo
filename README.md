# sftpgo-for-tos

> TerraMaster TOS 7 App Center — **Docker application** package for
> [SFTPGo](https://github.com/drakkan/sftpgo).

## What this is

A four-file TOS Docker application archive (`sftpgodocker.tar.gz`) that installs
SFTPGo on TOS 7 through the App Center:

- `config.ini` — TOS application metadata (`application_type: docker`, id `sftpgodocker`)
- `sftpgodocker.lang` — 23-language superset (TOS requires 14)
- `sftpgodocker.svg` — application icon (10678 bytes, 1 SVG elements)
- `docker-compose.yml` — one service, image `drakkan/sftpgo:v2.7.6`

## How it works

| | |
|---|---|
| Container image | `drakkan/sftpgo:v2.7.6` (Docker Hub, used unmodified) |
| Open | `http://<NAS-IP>:8165/` (container port 8080) |
| Runs as | non-root, `user: "1000:1000"` |
| Persistent data | `/var/lib/sftpgo` → `/Volume1/DockerAppData/sftpgodocker/data`, `/srv/sftpgo` → `/Volume1/DockerAppData/sftpgodocker/srv` |
| Logs | `docker logs sftpgodocker` (stdout/stderr) |

`/var/lib/sftpgo` keeps the SQLite database and configuration; `/srv/sftpgo` (mounted from `.../srv`) is the default storage root for users.

## Design highlights

- **Non-root.** `user: "1000:1000"`; verified on real hardware (the container reports uid 1000).
- **Fixed image tag, never `:latest`**, Docker Hub only, no `privileged`, no `network_mode: host`, and no Docker socket, no `cap_add`.
- **Health check** probing the service on container port 8080.
- **Deterministic build**: GNU tar with uid/gid 0 and zeroed timestamps, gzip without a timestamp, plus the review-standards self-check above.
- **Runs as uid 1000.** The image's own user matches the TOS application user.
- **Web admin only.** Only the HTTP admin/API port is published; add mappings if you need SFTP or WebDAV.

## Privacy

This application runs entirely on your NAS. It does not include analytics, telemetry or advertising SDKs, and the packaging contains no code that sends data to the packager. Data is only exchanged with the services you configure yourself (for example media servers, notification endpoints or model APIs), and only from the container. Everything the application stores lives in the application data folder described above; removing the app with its data deletes it.

## Third-party components

The package runs the upstream image `drakkan/sftpgo:v2.7.6` unmodified. Its components and their licences are those of the upstream project (https://github.com/drakkan/sftpgo), which is distributed under **AGPL-3.0**. No upstream source code is redistributed in this repository; only the four packaging files are original work.

## Runtime file manifest

Everything the application writes on the NAS lives inside its own data
directory; the container-internal `/tmp` is discarded with the container. The
table lists what is created and how it behaves. Nothing else is written.

| Path | Purpose | Created when | Growth bound | Lifecycle |
|---|---|---|---|---|
| `/Volume1/DockerAppData/sftpgodocker/data` | SFTPGo application data (everything the container writes outside /tmp) | on first start / on demand | bounded by your own data | persistent; kept on uninstall unless you ask to delete it |
| `/Volume1/DockerAppData/sftpgodocker/srv` | SFTPGo application data (everything the container writes outside /tmp) | on first start / on demand | bounded by your own data | persistent; kept on uninstall unless you ask to delete it |

## Third-party services (API disclosure)

The developer operates no server in this path. The app contacts only the services you
configure, plus (optionally) an update check and the image registry.

| Service | Endpoint | Data sent | Destination / region |
|---|---|---|---|
| Services you configure in the app | the address you enter | only the data that feature needs | normally your own LAN or the provider you chose |
| Update check (if enabled) | the upstream project's release feed | current version string | GitHub, US |

Full table: [PRIVACY.md](PRIVACY.md) §6.

## Licence and attributions

| Component | Licence | Notes |
|---|---|---|
| SFTPGo | AGPL-3.0 | upstream application |
| This packaging | GPL-3.0 (see `LICENSE`) | TOS metadata, units, scripts, translations, icon |

“SFTPGo”, “TerraMaster” and “TOS” are trademarks of their respective owners. This is an
independent community package by Moechz. Full details: [NOTICE.md](NOTICE.md).

## Build

```bash
scripts/build.sh                  # -> out/sftpgodocker.tar.gz + .sha256
scripts/build.sh 2.7.6-2   # packaging iteration bump
scripts/build.sh 2.7.6-1 aarch64
```

The build stages the four files, substitutes the version/platform placeholders,
removes CRLF/BOM/AppleDouble, then runs
`tools/verify.py`, a review-standards self-check (archive layout, JSON validity,
required fields, 14+ language coverage, version consistency, Docker-Hub-only
images, fixed tag, reserved/recommended host ports, non-root user, per-service
healthcheck/TZ/restart, data path below the application data root, never the
`/Volume*` wildcard, comment-free sequence blocks, `x-app-meta` position, no
literal secrets and the SVG size/element limits).

## Local verification

```bash
./TOSAppSelfTestingTool -c out/sftpgodocker.tar.gz   # official spec check
bash test/install-and-verify.sh                  # on-device E2E (needs root)
```

> Docker applications cannot be side-loaded through the App Center's manual
> install page (it accepts `.deb` only); the official self-testing tool's `-i`
> mode or `docker compose` are the only ways to install one for testing.

## Store submission checklist

1. Public GitHub repo (code + README only).
2. Release **tag `v2.7.6-1`**, assets `sftpgodocker.tar.gz` +
   `sftpgodocker.tar.gz.sha256` (Docker asset naming: `<app_id>.tar.gz`, **no
   platform suffix**).
3. Developer platform → Add Application: ID `sftpgodocker`, package type Docker,
   repository URL, architecture `x86_64`.
4. Version Management → Add Version `2.7.6-1` → automated validation → review.


## Limitations

- Default credentials admin/password must be changed on first login.
- SFTP and WebDAV ports are not published by this package.
- The UI is plain HTTP; use a TLS reverse proxy before exposing it to the internet.

---

Packaged for TOS 7 by Moechz. Upstream image used unmodified from Docker Hub.

## Support

- Email: moechz@163.com
- Privacy: [PRIVACY.md](PRIVACY.md) · Licence: [NOTICE.md](NOTICE.md)
