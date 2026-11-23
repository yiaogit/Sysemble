# P0-d1 工作分解：桌面镜像启动（XFCE）

> P0-c1 已闭环：GPT + ESP + GRUB EFI + OVMF 启动，CI 通过。
> 本切片：把"能启动的服务器"推进到"能启动的桌面"。ISO/安装器留给 P0-d2/P0-d3。

- 日期：2026-11-23
- 基线提交：`32d183c`
- 为什么先做桌面而不是 ISO：桌面镜像复用 P0-c 的磁盘/GRUB/UEFI 路径，风险最低；ISO + Calamares 是独立的两步，随后做。

---

## 1. 范围

| 做 | 不做 |
|---|---|
| XFCE 桌面 rootfs（`xfce4` + `lightdm`） | KDE（后续单独验，渲染更重） |
| `systemd.unit=graphical.target` 启动 | live ISO / squashfs / xorriso |
| QEMU `-vga virtio` + 2 GB 内存 | Calamares / 安装到磁盘 |
| 8 条断言：firmware/grub/kernel/systemd/login/DM/Xorg/graphical | 真实硬件 / GPU |

**为什么 XFCE**：CI 无 KVM，Plasma + llvmpipe 在 TCG 下过慢且易崩；XFCE + LightDM 足以证明"桌面栈能起来"，KDE 留到有硬件加速的环境。

## 2. artifact 扩展（v1 兼容）

```json
"desktop": {"session": "xfce", "display_manager": "lightdm"},
"boot": {
  "mode": "uefi",
  "graphical": true,
  "memory_mb": 2048,
  "cmdline": "root=/dev/vda2 rw console=ttyS0 rootfstype=ext4 systemd.unit=graphical.target",
  ...
}
```

- builder 从 `plan.packages` 推断：含 `lightdm`→lightdm、`sddm`→sddm、`gdm3`→gdm；同时含 `xfce4`/`plasma-desktop`/`gnome-shell` 推断 session。
- 有 DM：`graphical=true`、`memory_mb=2048`、cmdline 用 `graphical.target`；
- 无 DM：`graphical=false`、`memory_mb=1024`、cmdline 用 `multi-user.target`（P0-c 行为不变）。
- `desktop` 对象仅在检测到 DM 时出现。

## 3. boot-check 扩展

- `-m` 取 `boot.memory_mb`（默认 1024）。
- `graphical=true` 时追加 `-vga virtio`，并增加 3 条断言：
  - `boot.display_manager`：日志含 `lightdm` / `sddm` / `gdm`
  - `boot.xorg`：日志含 `X.Org X Server` 或 `Xorg`
  - `boot.graphical`：日志含 `Reached target Graphical Interface` 或 `graphical.target`
- 证据 assertions 数量随模式变化：kernel 3 / uefi 5 / uefi+graphical 8。
- kernel 模式忽略 graphical 字段。

## 4. CI

新增 job `desktop-smoke`（ubuntu-latest，40 min）：

```
apt: 同 boot-smoke（+ xserver 不需要，镜像内自带）
cargo run -p sysemble-cli -- plan examples/debian-xfce.yaml > plan.json
sudo build.sh --plan plan.json --out out --execute
sudo chown -R ...
boot-check.sh --artifact out/artifact.json --timeout 600 --json
upload artifact: boot-evidence-desktop
```

## 5. 工作分解

| ID | 任务 | 产出 | 负责 |
|---|---|---|---|
| W1 | builder 桌面推断 + cmdline + memory + artifact | `builders/debian/**` | SA-builder4 |
| W2 | boot-check graphical 模式 + 3 断言 + 测试 | `tools/boot-check.sh`、`tools/tests/**` | SA-boot3 |
| W3 | `examples/debian-xfce.yaml` + CI desktop job | `examples/**`、`.github/**` | 主线程 |
| W4 | 独立验收 | `docs/acceptance/P0-d1.md` | SA-verify4 |

## 6. 验收

| # | 检查 | 通过条件 |
|---|---|---|
| D1 | 回归 | P0-a/b/c 全部测试仍过 |
| D2 | 无 DM 计划 | artifact graphical=false、cmdline multi-user、5 断言 |
| D3 | 有 DM 计划 | artifact desktop/lightdm、graphical=true、memory=2048、8 断言 |
| D4 | 离线断言 | canned 图形日志 8 pass；缺 Xorg 则 fail |
| D5 | **CI desktop-smoke** | job 绿；日志含 LightDM、X.Org、Graphical Interface、login |
| D6 | 边界 | 变更只在允许目录 |

## 7. 风险

1. LightDM/Xorg 在 `-vga virtio` + TCG 下可能起不来；CI 失败则改 `-vga std` 或加 `nomodeset` 对照。
2. XFCE 会话未登录（LightDM 等待），只证明 DM/X 起来，不证明用户会话；Plasma/XFCE session 留到 P0-d3。
3. 桌面 rootfs 更大（~1.5 GB），构建时间增加 1–2 分钟。
4. `systemd.unit=graphical.target` 与 serial getty 共存；login 断言仍应通过。
