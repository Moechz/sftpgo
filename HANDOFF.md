# Handoff — sftpgo 打包项目

更新：2026-09-17（首版完成，真机验证通过，剩余 UI/发布步骤见下）

## 30 秒上下文

把 SFTPGo（AGPL-3.0 文件传输服务器）打包成 TOS 7 应用中心 deb。工程完整、
真机功能全量验证通过（详见 docs/TASK_STATE.md §3 表格）。当前卡在三个
「需要人」的步骤：应用中心 UI 手动安装验证、review-standards 人工对照、
公开仓库与 Release 发布。

## 文档地图

| 文档 | 内容 |
|---|---|
| README.md | 用户视角：入口地址表、端口、文件布局、权限、安全建议 |
| AGENTS.md | 项目宪法：构建命令、路径约定、修改须知（新会话必读） |
| docs/DESIGN_DECISIONS.md | 12 条架构决策（D-001~D-012）+ 上游行为实验依据 |
| docs/TASK_STATE.md | 状态快照：完成度、真机验证表、开放问题、发布闸门 |
| docs/CHANGELOG.md | 版本日志 |

外部知识库（不在本仓库）：
- `~/Documents/projects/TOS-DEB-PACKAGING-GUIDE.md` — 打包规范 + 30 硬坑
- `~/Documents/projects/SSH-MACHINES.md` — 测试机（测试机）访问方式

## 冷启动命令

```bash
cd ~/Documents/projects/sftpgo
cat AGENTS.md docs/DESIGN_DECISIONS.md     # 必读
make check && ./build.sh                    # 确认可复现（产物 out/）
```

## 剩余工作（按优先级）

1. **应用中心手动安装验证（需 TOS web UI）**
   测试机 已用 apt 装好并验证功能；另需走一遍 UI 路径：
   应用中心 → 手动安装 → 上传 deb。注意现在 NAS 上已装 2.7.5-1，
   UI 上传同版本会走「重装」；观察安装进度不卡死即可。
   卡死处置 runbook 见指南坑 11。
2. **送审前自查**：对照 hermes-agent-webui/docs/official/ 的
   review-standards（20 页清单）逐项过；构建期自动断言已覆盖 S8/C 系。
3. ~~发布~~ 已完成：GitHub Moechz/sftpgo + Release v2.7.5-3（双架构 deb + sha256）。
   剩余按商店后台表单提交（审核样例、权限说明、截图等），资产用 Release 链接。
4. （可选）arm 真机装机冒烟：产物 aarch64.deb 已构建未上机。

## 上游版本升级流程

1. `config.env` 改 SFTPGO_VERSION → `./build.sh`（fetch 会重新固化新
   SHA256.lock.<arch>，需人眼核对来源仍为官方 release）
2. 首次安装新版本会因 templates 结构变化失败启动 → 检查
   `journalctl -u sftpgo`；缺目录就同步 `assets/config.ini.in` 的 FILES 段
3. Breaking change 对照 DESIGN_DECISIONS 里的实验结论复核
   （web_root 前缀、webdavd prefix、client_ip 头、DEFAULT_ADMIN 引导）

## 卸载/回滚

apt remove sftpgo（保数据）→ apt purge sftpgo（全清含数据）。
服务异常先看 journalctl；完全无法启动可 dpkg -P 后重装（数据在
/var/lib/sftpgo 可先备份）。
