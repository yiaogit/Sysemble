# P1-e1 工作分解：引擎可用性探测

> P1-e 的完整形态是 macOS/Windows 上的 Linux 引擎 VM。上下文预算内先做**第一步**：让 app 明确知道“当前能不能真实构建”，而不是让 Build 按钮以 exit 3 失败。

- 日期：2026-11-24
- 基线提交：`6f25752`

## 1. 命令契约

```rust
engine_info() -> Result<EngineInfo, String>
```

```json
{
  "kind": "local|none",
  "available": false,
  "platform": "macos|linux|windows",
  "reason": "real builds need the engine VM, which is not implemented yet (P1-e2)"
}
```

- Linux：`geteuid()==0` 且 `mmdebstrap`/`sgdisk` 在 PATH → `kind=local, available=true`；否则 `available=false` + 具体缺失项。
- macOS/Windows：`kind=none, available=false`，reason 含 `engine VM`。
- docker/ssh 引擎在 P1-e2 再加，本切片只占位说明。

## 2. UI

- 顶部状态栏显示 `Engine: local` 或 `Engine unavailable — <reason>`。
- `Build`（execute）按钮在不可用时**禁用**，tooltip 显示 reason；`Dry run` 始终可用。
- 启动时调用 `engine_info`。

## 3. 验收

| # | 检查 | 通过条件 |
|---|---|---|
| K1 | 命令 | macOS 返回 `kind=none, available=false`，reason 含 `engine VM` |
| K2 | UI | 不可用时 Build 禁用；Dry run 可用 |
| K3 | 回归 | 桌面 16 + 根 61 全过 |
| K4 | CI | desktop-check 绿 |

## 4. 风险

1. Linux 探测依赖 `geteuid`（已有 libc 依赖）。
2. 只做能力探测，不做 VM；文档必须写清 P1-e2 未实现。
