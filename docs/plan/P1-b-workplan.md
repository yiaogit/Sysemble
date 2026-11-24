# P1-b 工作分解：桌面壳接构建控制

> P1-a 已有 Tauri 窗口 + validate/plan。本切片让桌面 app 能**启动构建、看日志、取消**。

- 日期：2026-11-24
- 基线提交：`29505ae`
- 关键约束：本机 macOS 无 root/Linux，`--execute` 会失败；因此 P1-b 先支持 **dry-run 构建**（本机可跑、可测），真实 execute 留给 P1-e 的引擎 VM。

---

## 1. 命令契约

```rust
start_build(spec_path: String, out_dir: String, mode: String) -> Result<BuildStarted, String>
  // mode: "dry-run" | "execute"

get_build(id: String) -> Result<BuildStatus, String>
cancel_build(id: String) -> Result<(), String>
get_build_log(id: String, tail_lines: Option<u32>) -> Result<String, String>
```

```json
BuildStarted { "id": "...", "plan_path": "...", "log_path": "..." }
BuildStatus  { "state": "running|exited|failed|cancelled", "exit_code": null|i32,
               "started_at": "...", "finished_at": null|"..." }
```

- 后端流程：`resolve_plan(load_spec(spec))` → 写 `<out>/plan.json` → 启动
  `bash <repo>/builders/debian/build.sh --plan <out>/plan.json --out <out> --dry-run|--execute`。
- 子进程 stdout/stderr 合并写 `<out>/build.log`；状态保存在 `Mutex<HashMap>`。
- `get_build_log` 返回末尾 N 行（默认 200）。
- 取消：kill 子进程，state=cancelled。
- 错误：spec 无效/out 不可写/builder 不存在 → 可读字符串。

## 2. UI

- 新增输出目录输入（默认 `~/.sysemble/builds/<spec-name>`？简化为 `./out`）。
- 按钮：`Dry run`、`Build`、`Cancel`；状态徽标（running/exited/failed/cancelled）+ exit code。
- 日志面板：等宽字体，1 秒轮询 `get_build_log`，自动滚到底。
- `Build`（execute）在 macOS 会失败：UI 必须显示 builder 的 stderr 与 exit code，不得静默。

## 3. 测试

- `start_build` 用 `mode=dry-run`、`examples/minimal-debian.yaml`，临时 out：
  - 等待退出，exit_code=0；
  - 日志含 `Dry run complete`；
  - `get_build` state=exited；
  - `get_build_log` 含 `Stages (planned)`。
- `mode` 非法 → Err。
- 不存在的 spec → Err。
- `cancel_build`：启动一个 `sleep`? builder 太快；用 fake builder 入口（`SYMBLE_BUILDER` 环境变量覆盖脚本路径）测试取消。
- 桌面 crate 测试数增加；根 workspace 不受影响。

## 4. CI

沿用 `desktop-check`（check + test）。不需要新 job。

## 5. 验收

| # | 检查 | 通过条件 |
|---|---|---|
| I1 | 本地 `cargo test --manifest-path` | 含 dry-run 集成测试 |
| I2 | CI `Desktop app (check)` | 绿 |
| I3 | 命令契约 | 前后端名称/参数一致 |
| I4 | 失败可见 | execute 在 macOS 显示 builder 错误与 exit code |
| I5 | 回归 | 根 61 + P0 smoke 全过 |

## 6. 风险

1. Tauri command 并发：用 `Mutex` + `Arc`，避免死锁（不要在持锁时 join）。
2. 子进程输出量大：写文件，不在内存累计。
3. 轮询 1s：前端 `setInterval`，停止条件 state != running。
4. macOS 上 execute 失败是预期，不是 bug。
5. 路径含空格：Command 参数直接传，不拼 shell。
