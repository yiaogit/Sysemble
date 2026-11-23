# P0 工作分解与职责分配（主线程冻结版）

> 本文件由主线程维护：架构、接口、任务、验收标准。
> 子代理只实现自己名下的目录，不改本文件，不做 git 操作。

- 日期：2026-11-23
- 目标切片：**P0-a**（`validate` + `plan` + Debian 构建脚本 dry-run），不含真实镜像构建与 QEMU 启动。
- 仓库：`sysemble/`（本地）↔ https://github.com/yiaogit/Sysemble

---

## 1. 架构冻结

```
sysemble-cli  ──调用──▶  sysemble-core
   (参数/输出)              (spec 模型 / 校验 / 解析 / 计划)

builders/debian/build.sh ──读取──▶ plan.json（由 core 产出）
   （独立进程；不依赖 Rust 运行时）
```

- `sysemble-core` 不依赖 CLI，不读环境变量，不做 IO 之外的副作用。
- `sysemble-cli` 只做参数解析、调用 core、格式化输出；不含业务规则。
- `builders/debian/` 是独立 shell 脚本，输入是 `plan.json`，输出是构建步骤或镜像；不引用 Rust 代码。

## 2. 接口契约（冻结）

### 2.1 core 公共 API

```rust
pub const API_VERSION: &str = "sysemble/v1";

pub struct BuildSpec { /* serde，deny_unknown_fields */ }
pub fn load_spec(path: &Path) -> Result<BuildSpec, SpecError>;

pub enum Severity { Error, Warning }
pub struct Diagnostic {
    pub severity: Severity,
    pub code: String,     // 稳定短码，如 "spec.name.invalid"
    pub path: String,     // JSON Pointer 风格，如 "/system/hostname"
    pub message: String,
}
pub fn validate_spec(spec: &BuildSpec) -> Vec<Diagnostic>;

pub struct Plan { /* Serialize */ }
pub fn resolve_plan(spec: &BuildSpec) -> Result<Plan, PlanError>;
```

`Plan` 的 JSON（`sysemble plan --json` 输出）必须包含：

```json
{
  "apiVersion": "sysemble/plan/v1",
  "spec": "debian-kde-dev",
  "base": {"kind": "debian", "release": "trixie", "pin": "2026-11-01"},
  "target": {"arch": "x86_64", "outputs": ["qcow2", "iso"]},
  "packages": ["..."],
  "modules": [{"id": "desktop-plasma", "version": "0.1.0"}],
  "estimates": {"image_mb": 4300, "build_minutes": 38, "disk_mb": 12000},
  "warnings": [{"code": "...", "path": "...", "message": "..."}]
}
```

### 2.2 CLI 契约

| 命令 | 行为 | 退出码 |
|---|---|---|
| `sysemble validate <file> [--json]` | 解析 + 校验；人类可读或 JSON 诊断 | 0 无 error；1 有 error；2 用法/IO |
| `sysemble plan <file> [--json]` | 输出 Plan；默认 JSON 到 stdout | 0 成功；1 spec 无效；2 用法/IO |
| `sysemble version` | 版本 + API 版本 | 0 |
| `sysemble stages` | 生命周期 | 0 |

### 2.3 builder 契约

```
builders/debian/build.sh --plan <plan.json> --out <dir> [--dry-run] [--engine docker|native]
```

- `--dry-run`：校验 plan、打印阶段与包清单、退出 0；不写镜像。
- `--engine native`：要求 Linux + root + mmdebstrap；非 Linux 明确报错。
- `--engine docker`：用 `debian:trixie` 容器跑 mmdebstrap；macOS 可用。
- 任何情况下不得修改宿主系统。

## 3. 工作分解

| ID | 任务 | 产出 | 负责 | 依赖 |
|---|---|---|---|---|
| W1 | spec 模型 + 校验 + 解析器 + 单元测试 | `crates/sysemble-core/**` | SA-core | 无 |
| W2 | CLI 命令 + 集成测试 | `crates/sysemble-cli/**` | SA-cli | W1 |
| W3 | Debian 构建脚本 + dry-run + 文档 | `builders/debian/**` | SA-builder | 无（读 plan 契约） |
| W4 | 独立验收：黑盒测试 + 报告 | `tests/acceptance/**`、`docs/acceptance/P0.md` | SA-verify | W1–W3 |
| W5 | 集成、复核、提交、CI | 根 `Cargo.toml`、git、CI | 主线程 | W1–W4 |

## 4. 职责矩阵

| 目录 | 写入者 | 只读者 |
|---|---|---|
| `crates/sysemble-core/**` | SA-core | 其他 |
| `crates/sysemble-cli/**` | SA-cli | 其他 |
| `builders/**` | SA-builder | 其他 |
| `tests/acceptance/**`、`docs/acceptance/**` | SA-verify | 其他 |
| `docs/plan/**`、根 `Cargo.toml`、`.github/**` | 主线程 | 其他 |
| `spec/**`、`examples/**` | **冻结**，任何人不得修改 | 所有 |

冲突规则：子代理不得 `git add/commit/push`；不得改别人的目录；发现契约问题**停下来报告**，不要自行改契约。

## 5. 验收标准（总）

| # | 检查 | 命令 | 通过条件 |
|---|---|---|---|
| A1 | Rust 构建 | `cargo test --workspace` | 全部通过 |
| A2 | 示例通过 | `cargo run -p sysemble-cli -- validate examples/debian-kde-dev.yaml` | 退出 0 |
| A3 | 第二个示例 | 同上 `examples/minimal-alpine.yaml` | 退出 0 |
| A4 | 未知字段被拒 | 临时 spec 加 `bogus: 1` | 退出 1，诊断含 `bogus` |
| A5 | plan 结构 | `cargo run -p sysemble-cli -- plan examples/debian-kde-dev.yaml` | JSON 含 apiVersion/packages/estimates |
| A6 | plan 内容 | 同上 | packages 含 `plasma-desktop`、`sddm`、`firefox-esr` |
| A7 | schema 校验 | `python tools/validate.py` | 全部 ok |
| A8 | builder dry-run | `bash builders/debian/build.sh --plan /tmp/plan.json --out /tmp/out --dry-run` | 退出 0，打印阶段 |
| A9 | builder 安全 | 不带 `--dry-run` 在 macOS 且非 docker | 明确拒绝，非零退出 |
| A10 | CI | 推送后 GitHub Actions | 两个 job 绿 |

## 6. 子代理通用约束

1. 工作目录 `sysemble/`，只写自己名下目录。
2. 不使用 `git`；不修改 `spec/`、`examples/`、`docs/plan/`。
3. 本地 Rust 工具链：`/Users/yiao/Documents/linux软件设计框架/.tools/cargo/bin/cargo`，并设置
   `CARGO_HOME=/Users/yiao/Documents/linux软件设计框架/.tools/cargo`、
   `RUSTUP_HOME=/Users/yiao/Documents/linux软件设计框架/.tools/rustup`。
4. 自己跑通自己的验收命令，报告：改了哪些文件、跑了哪些命令、结果、偏差。
5. 做不到的写清楚，不要假装通过。

## 7. 主线程总体验证

1. 读 diff，确认没有越界修改。
2. 逐条跑 A1–A10。
3. 抽查：未知字段拒绝、plan 包清单、builder 非 Linux 拒绝。
4. 提交并推送；看 CI；失败则退回对应子代理修复。
