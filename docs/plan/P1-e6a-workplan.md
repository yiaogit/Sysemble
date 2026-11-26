# P1-e6a 工作分解：Rosetta for Linux spike（决定 L2 封装路线）

> ADR 0002 §8 的 L2 需要让 arm64 guest 跑 x86_64 引擎镜像。本切片只回答一个问题：**VZ guest 里能否用 Apple Rosetta for Linux 翻译 x86_64 ELF，速度是否可接受**。成功 → E6b（podman + 预装 amd64 引擎镜像）；失败 → 退回 qemu-user-static 或 guest 内交叉构建。

- 日期：2026-11-26
- 基线：`8043070`
- 前置事实：宿主 `VZLinuxRosettaDirectoryShare.availability = installed`（本机实测）；VM 镜像 `engine/vm/image/build` 与 helper 已可用

> **状态：已完成（2026-11-26）**。宿主 Rosetta=installed；guest 内 binfmt 注册成功，静态 amd64 busybox 输出 `x86_64`；同实现开销 **1.44×**（184 ms vs 265 ms），跨实现对照 10.63× 已解释为 coreutils ARMv8 SHA 差异。结论：L2 走 engine-in-VM（方案 A），进入 E6b。证据：`engine/vm/spikes/README.md`、本机 `/tmp/e6a-out/`。

## 1. 方案

1. helper 增加 `--rosetta`：当 availability 为 installed 时，附加 `VZLinuxRosettaDirectoryShare`（virtiofs tag `rosetta`）；`probe --json` 增加 `rosetta` 字段。
2. helper 增加 `--job <name>`（默认仍为 `minimal-build.sh` 路径）：宿主 out 目录里放一个脚本，guest 的 `job.sh` 改为执行 `/export/<name>`；用于 spike/调试，不做任意宿主路径注入（只接受 basename）。
3. spike 脚本（guest 内，root）：
   - `apt-get install binfmt-support file`（guest 有 NAT）。
   - `mount -t virtiofs rosetta /mnt/rosetta`；确认 `/mnt/rosetta/rosetta` 存在。
   - `update-binfmts --install rosetta /mnt/rosetta/rosetta --magic <x86_64 ELF> --mask <...> --credentials yes --preserve yes --fix-binary yes`。
   - 执行宿主放入的静态 `busybox-amd64`，断言 `uname -m` = `x86_64`。
   - 记录 `/proc/sys/fs/binfmt_misc/rosetta` 与耗时。
4. 对照：同一 busybox 的 arm64 版本（或宿主 arm64 busybox）做 CPU/IO 基准，估算 Rosetta 开销。

## 2. 交付物

- `engine/vm/macos`：`--rosetta`、`--job`、probe 字段、单测、README。
- `engine/vm/spikes/rosetta-spike.sh`（guest 脚本，提交）与 `engine/vm/spikes/README.md`。
- 本机证据：spike 输出、binfmt 状态、耗时、`pgrep` 无残留。
- `docs/plan/P1-e6a-workplan.md`（本文件）。

## 3. 验收

| # | 检查 | 通过条件 |
|---|---|---|
| R1 | 宿主可用性 | probe 输出 `rosetta=installed` |
| R2 | 共享挂载 | guest 内 `/mnt/rosetta/rosetta` 存在 |
| R3 | binfmt 注册 | `/proc/sys/fs/binfmt_misc/rosetta` 为 enabled |
| R4 | 翻译执行 | `busybox-amd64 uname -m` → `x86_64`，exit 0 |
| R5 | 开销 | 记录基准；若 >10× arm64 则标记风险，不作为失败 |
| R6 | 降级 | Rosetta 不可用时给出 qemu-user 方案与结论 |
| R7 | 回归 | 现有 VM/桌面/根测试全过；不破坏默认 job |

## 4. 风险

1. Rosetta for Linux 只保证 Ubuntu；Debian trixie guest 可能缺某些库/内核特性。
2. `update-binfmts` 注册参数/magic 写错会静默失败；必须检查 `/proc`。
3. 动态链接的 amd64 程序还需要 guest 内 x86_64 库；本 spike 先用静态 busybox，E6b 再验证容器内动态二进制。
4. Rosetta 许可/宿主策略（MDM）可能禁用；probe 必须如实报告。
5. CI 无法跑（无嵌套虚拟化），证据仅本机；E6b 也需本机验证。

## 5. 非目标

- 不安装 podman、不导入引擎镜像（E6b）。
- 不改 `builders/**`、不做封装（E5）。
