# P1-e2b 独立验收报告（容器后端与桌面：探测 / 门控 / argv / 取消 / 本地 E2E）

- 验收角色：**acceptance-e2**（独立验收子代理；只读源码/CI/产物，只写 `docs/acceptance/P1-e2b.md` 与本轮同批的 `P1-e2a.md`；未做任何 git 写操作）
- 日期：**2026-11-24**（Europe/Madrid，17:19 起；CI 时间线为 UTC）
- 仓库：`sysemble/`，分支 `main`，**HEAD `9e1823f20865375e77ffb1dec8f873db6e5475da`**
- 工作区状态：**不干净**——`M docs/plan/P1-e2-workplan.md`（仅 3 行「切片状态」表，17:18:57 由主线程修改；契约章节与 HEAD 逐字一致）。代码与 HEAD 一致，CI 也跑在该 SHA 上；边界说明见 `P1-e2a.md` §7.1 第 12 条。
- 权威 CI run：**[45434475490](https://github.com/yiaogit/Sysemble/actions/runs/45434475490)**（push `9e1823f`，`completed/success`，16:12:52–16:16:08Z，9/9 job success）
- 权威 job（桌面）：**[Desktop app (check) #138588435441](https://github.com/yiaogit/Sysemble/actions/runs/45434475490/job/138588435441)**（success，16:12:55–16:15:40Z，**2m45s**，含 clippy）
- 权威 job（容器 E2E）：**[Engine image (build + boot) #138588435469](https://github.com/yiaogit/Sysemble/actions/runs/45434475490/job/138588435469)**（success，16:12:55–16:15:35Z，**2m40s**）
- 验收范围：`docs/plan/P1-e2-workplan.md` §2.2 `engine_info`、§2.3 v2 容器命令、§4 **K4、K6–K10**（K1–K3 的镜像侧细节见 [P1-e2a.md](P1-e2a.md)）、§6 风险；以及任务书的 D 节静态核对与「过度声明」检查
- 判定原则：命令/测试/日志/产物可复现 → PASS；环境确实无法执行才写 BLOCKED；任何过度声明单独列出，不计入 PASS

**判定摘要：K4、K6–K10 PASS；K1–K3/K5 镜像侧见 P1-e2a（PASS）。FAIL 0，BLOCKED 0。结论：`P1-e2b 通过`。**

未只信绿灯：本机从零跑完整容器 E2E（新目录 `/tmp/p1e2-accept/smoke`，8m24s，`CONTAINER-SMOKE: pass`），重算本次 qcow2/boot.log/artifact.json 哈希并与本次 `artifact.json` 比对；在**真实 Docker daemon** 上跑 `engine_info` 的三个分支（有镜像 / 缺镜像 / runtime 不可达）并对照 §2.2 逐字段；逐行核对 `build.rs` 的 argv 装配、门控、取消与 UI 的 `disabled` 逻辑；重跑 61 + 39 测试、clippy、17 项 acceptance、`tools/validate.py`。

---

## 1. 环境与证据获取

### 1.1 本地环境

| 项 | 实际值 |
|---|---|
| OS / 架构 | macOS **26.6.2**（Build 25G83），Darwin **25.6.0**，**arm64** |
| Rust / Cargo | rustc 1.100.0 / cargo **1.100.0**（3acc79c0c） |
| 容器 | Docker Desktop daemon **29.1.2**；本地 `sysemble-engine:0.1.0`（amd64） |
| Python | 3.14.3（`/opt/homebrew/bin/python3`，`PYTHONPATH=/tmp/pylibs314`） |
| 证据目录 | `/tmp/p1e2-accept/`（art/ = CI artifact 解包；smoke/ = 本次独立 E2E；logs/ = run logs） |

### 1.2 证据获取

```bash
/tmp/ghapi.sh /repos/yiaogit/Sysemble/actions/artifacts/14942030508/zip \
  -L --max-time 600 -C - -o /tmp/p1e2-accept/engine-evidence.zip
# 235,584,066 B（首轮 --max-time 40 截断于 222,674,944 B，续传补齐）
shasum -a 256 .../engine-evidence.zip
# 36976b9235a97e6c5c9c781dabf887d8993e7114956b0fb0a00c7e83104863db

/tmp/ghapi.sh /repos/yiaogit/Sysemble/actions/runs/45434475490/logs \
  -L -o /tmp/p1e2-accept/run-logs.zip   # 462,012 B
```

CI 侧 `engine-check` 的容器 E2E：`16:13:46–16:15:15Z`（**88.1s**），其中 `container-smoke: elapsed: 89s`，boot 31s。
本机独立 E2E：`16:20:39Z` 起，`16:29:03Z` 止，`container-smoke: elapsed: 504s`，`real 8m24.403s`，boot **354s**。

---

## 2. 判定摘要

| # | 检查 | 结果 | 一句话结论 |
|---|---|---|---|
| **K1** | 镜像可构建 | **PASS**（见 P1-e2a §6） | CI 31s 成功；本机镜像 `--verify` 通过 |
| **K2** | 工具齐全 | **PASS**（见 P1-e2a §5） | 本机 117/117；5 工具版本非空 |
| **K3** | 清单一致 | **PASS**（见 P1-e2a §4.4） | image_id/base/205/tool_versions 全部核对 |
| **K4** | 容器内真实构建 | **PASS** | CI 同一镜像内产出 artifact.json + qcow2；**本机独立 E2E 复现**，`CONTAINER-SMOKE: pass`，退出码 0 |
| **K5** | 容器内启动验证 | **PASS** | CI 31s / 本机 TCG 354s，均 `result=pass`、5/5 断言 |
| **K6** | 探测正确 | **PASS** | 真实 daemon 三分支：`container/available`、`container/available=false`（reason 含 `engine/image/build-image.sh`）、`none`（reason 含 `start Docker Desktop`） |
| **K7** | 命令装配 | **PASS** | 单测逐字断言 §2.3 v2 argv（含 `--privileged`、`/work:ro`、`/export`、`/out`、`--name`） |
| **K8** | 门控 | **PASS** | execute 无引擎返回可读错误；dry-run 不受影响；UI Build 按钮在 `locked` 或引擎不可用时置 `disabled` |
| **K9** | 回归 | **PASS** | workspace **61**、桌面 **39**、acceptance **17/17**、clippy **0 warning**、validate.py 全绿 |
| **K10** | 独立验收 | **PASS** | 本报告 + `P1-e2a.md`，未依赖 CI 结论 |

---

## 3. 本机独立重跑容器 E2E（任务书第 10 项，最重要）

### 3.1 命令与结果

```bash
mkdir -p /tmp/p1e2-accept/smoke
cargo run -q -p sysemble-cli -- plan examples/minimal-debian.yaml \
  > /tmp/p1e2-accept/smoke/plan.json          # exit 0，674 B，stderr: plan: 14 packages, 500 MB

bash engine/image/tests/container_smoke.sh \
  --image sysemble-engine:0.1.0 \
  --repo "$PWD" \
  --out /tmp/p1e2-accept/smoke \
  --boot-timeout 600
```

```text
container-smoke: image: sysemble-engine:0.1.0 (platform linux/amd64)
container-smoke: phase 1/2: build inside sysemble-engine:0.1.0
container-smoke:   repo: /Users/.../sysemble -> /work (read-only)
container-smoke:   out:  /private/tmp/p1e2-accept/smoke -> /export (build directory: /out inside the container)
container-entry: build: /work/builders/debian/build.sh --plan /export/plan.json --out /out --execute
[build] stage 5/6: assemble GPT disk image - rootfs 389 MB, disk 4096 MB
[build] complete (mode: uefi)
container-entry: exported artifact.json / disk.img / disk.qcow2 / grub.cfg / plan.copy.json
container-entry: build and export complete
container-smoke: phase 2/2: boot-check inside sysemble-engine:0.1.0 (timeout 600s)
boot-check: boot.firmware: pass - matched `EFI v` and `UEFI`
boot-check: boot.grub: pass - matched `GRUB` and `Booting`
boot-check: boot.kernel: pass - matched `Linux version`
boot-check: boot.systemd: pass - matched `systemd[1]` and `Reached target`
boot-check: boot.login: pass - matched `login:`
boot-check: result: pass (354s)
container-smoke: asserting exported artifacts
OK    artifact.json (1340 bytes)
OK    raw disk image (disk.img, UEFI boot target) (4294967296 bytes)
OK    qcow2 disk image (disk.qcow2) (420937728 bytes)
OK    boot evidence: boot-evidence.json (864 bytes)
OK    qcow2 image(s) exported: 1
container-smoke: elapsed: 504s
CONTAINER-SMOKE: pass
```

- **退出码 0**、`CONTAINER-SMOKE: pass`、耗时 **504s**（`real 8m24.403s`）。阶段拆分：phase 1 构建到导出约 **135s**（`artifact.json.createdAt=16:22:54Z`，起点 16:20:39Z），boot-check **354s**，其余为导出/校验。
- 与 CI 对比：CI 同一脚本 `elapsed: 89s`（boot 31s，x86_64 原生 TCG）；本机是 **arm64 + Rosetta + TCG**，boot 慢约 11 倍。`--boot-timeout 600` 下 boot 用了 354s（**59% 预算**），余量不算宽裕（§6 第 2 条）。
- **未出现 FAIL/BLOCKED**：本轮第一次执行即通过，无超时、无重试。

### 3.2 本次导出的文件与哈希（新目录）

| 文件 | 字节 | 备注 |
|---|---|---|
| `artifact.json` | 1,340 | `sha256=7ef82cb786cdcda9af65eeec06b5eb530aae22daebd5c81a2ecd14c1e767c9de` |
| `disk.img` | 4,294,967,296 | boot 后 `8984c48e1eabee0575ae0fb4b77271ccddfa99ea0d82ccc4b17ad8641e64cb71` |
| `disk.qcow2` | 420,937,728 | `cb0b417c7295e0626ef171b794e5c660b6ad04d454e6a0e519e5cd7dcf9731f8` |
| `boot.log` | 57,435 | `b45fdd434952e9d58a69ee4cca599e63d190075a53fd8c5c432ac9b7f353158f` |
| `boot-evidence.json` | 864 | `87050770adbc72f4adf29f454332ecfa81da91b22d89a42a18a8086363ff3ca3` |
| `grub.cfg` / `plan.copy.json` | 306 / 674 | 导出的**顶层常规文件**（契约允许） |
| `container-build.log` / `container-boot-check.log` | 4,609 / 1,686 | phase 1/2 的 docker stdout |

校验：

```bash
shasum -a 256 disk.qcow2                        # cb0b417c… == 本次 artifact.json images[1].sha256 ✓
python3 -c "json.load(open('boot-evidence.json'))"  # result=pass, 5/5 pass, log_sha256=b45fdd43… ✓
shasum -a 256 boot.log                          # b45fdd43… == boot-evidence.log_sha256 ✓
```

### 3.3 boot-evidence 5 条断言（本机重跑）

`result=pass`，`elapsed_seconds=354`，`timeout_seconds=600`，断言：`boot.firmware` / `boot.grub` / `boot.kernel` / `boot.systemd` / `boot.login` **全部 `pass`**。`boot.log` 中 `minimal-debian login:` 出现在 guest 时间 **40.4s**（CI 为 19.8s）。`Booting paravirtualized kernel on bare hardware` 与 QEMU 默认 TCG CPU 型号 `AMD QEMU Virtual CPU version 2.5+` 证明本机走 TCG（macOS 无 KVM）。

### 3.4 一个必须记录的差异：raw `disk.img` 的摘要会失效

| 来源 | raw `disk.img` sha256 |
|---|---|
| 本机 `artifact.json`（构建时） | `288c267f3c75a4b0716073f1d5a99b1d6be7acafa4a77bbec5d76fce25410dec` |
| 本机 boot 后实际文件 | `8984c48e1eabee0575ae0fb4b77271ccddfa99ea0d82ccc4b17ad8641e64cb71` |
| CI `artifact.json`（构建时） | `30d55ea1cf07bee39dd4a94a72aa9baf6c7478de79dc4976c0a78a3541123cb7` |
| CI boot 后 stdout | `31820cbee3a26967ba33b35bd6b81f71382ac7d4f7a6aafa710e7f202a0607a4` |

两次运行独立复现同一现象：`tools/boot-check.sh` 的 UEFI 分支要求磁盘**可写**并以读写方式挂载（`tools/boot-check.sh:1508,1554`），guest 以 `root=/dev/vda2 rw` 启动，因此 boot 后 raw 镜像内容必然改变，`artifact.json` 记录的是**构建时**摘要。`disk.qcow2` 未被启动，摘要始终稳定（CI `7a3bcd53…`、本机 `cb0b417c…` 各自与本地 artifact.json 一致）。

判定：**不构成 K4/K5 失败**（qcow2 与 boot 证据完整可信），但 raw 摘要不能用于校验导出的 `disk.img`，应在 artifact 契约中注明或改为 boot 后重算（§6 第 5 条）。

### 3.5 本机 vs CI 的 `artifact.json` 内容对比

逐字段展平后只有 **3 处差异**：`createdAt`（16:14:29Z vs 16:22:54Z）、`images[0].sha256`、`images[1].sha256`。包列表（14 项）、kernel 版本 `6.12.118+deb13-amd64`、分区布局（512 MiB ESP + 3584 MiB root）、`memory_mb=1024`、`boot.mode=uefi`、`graphical=false` 全部一致。即**内容级可复现，bit-for-bit 不可复现**，与 `engine/image/README.md` 的 Known limits 一致。

---

## 4. 静态交叉核对（任务书第 11–14 项）

### 4.1 `build.rs` 的容器 argv 是否严格符合 §2.3 v2 —— **PASS**

`apps/desktop/src-tauri/src/build.rs:632-684` 装配，`build.rs:958-1009` 的 `container_argv_uses_the_v2_entry_script_and_mounts` **逐元素 `assert_eq!`** 整条 argv：

```text
run --rm --init --privileged --platform linux/amd64
    --name sysemble-build-<id>
    -v <repo>:/work:ro
    -v <out>:/export
    -w /work
    sysemble-engine:0.1.0
    bash engine/runtime/container-entry.sh
      --plan /export/plan.json --out /out --export /export --mode execute
```

逐条对照 §2.3：`--rm/--init/--privileged/--platform linux/amd64/--name` 全部存在且**顺序一致**（`build.rs:641-653`）；`repo` 只读挂载到 `/work`（`656`）；宿主 out 挂到 `/export`（`661-663`），**没有** v1 的 `-v <out>:/out`（`container_argv_exports_an_in_repo_output_at_export` 断言不存在 `-v repo:/work` 可变挂载、且参数里不出现 `/work/` 前缀）；容器内构建目录固定 `/out`（`673`）；**无宿主 `/out` 挂载**；`-w /work`。

- **execute 无引擎**：`start_build` 先探测，`!probe.info.available` 立即返回 `unavailable_engine_error`（`build.rs:280-288,601-606`），错误串形如 `cannot start an execute build: <reason> (engine kind: none); use --dry-run to validate the plan on this host`；单测 `execute_without_an_engine_returns_a_readable_error`。
- **local 引擎走宿主 bash**：`execution_backend` 把 `local`/`None` 映射到 `Host`（`build.rs:142-151`），命令为 `bash <builder> --plan … --out … --mode`（`352-362`）；单测 `local_engine_keeps_the_host_backend_without_a_runtime_path`。
- **dry-run 不查引擎**：只有 `mode == Execute && !builder_override` 才探测（`280-288`）；单测 `dry_run_still_runs_when_the_engine_is_unavailable` 与 `dry_run_build_exits_zero_and_logs_the_plan`。
- **取消 kill 容器名**：`cancel_build` 先 `terminate_process_group(pid)`（unix 用 `kill(-pid, SIGKILL)`，`build.rs:718-730`），再 best-effort `kill_container`（`runtime kill <name>`，`687-704`），且不阻塞调用方（helper 线程 `wait`）；单测 `cancel_kills_the_named_container` + 集成测试 `tests/cancel_build.rs`。
- 容器入口脚本存在性在**写盘/启动之前**校验（`build.rs:296-305`），缺失时给出可读错误（单测 `execute_without_the_container_entry_script_is_a_readable_error`）。

### 4.2 `engine_info` 契约（§2.2）—— **PASS**

| 要求 | 实现证据 |
|---|---|
| 顺序 local → docker → podman → none | `engine.rs:124-133`（Linux 本地引擎可用时直接返回，否则 `probe_container_runtimes`，`CONTAINER_RUNTIMES = ["docker","podman"]`） |
| 每条探测 4s 超时、失败只降级不返回 Err | `PROBE_TIMEOUT = Duration::from_secs(4)`（`engine.rs:38`）；`engine_info()` 恒 `Ok`（`114-116`）；单测 `probe_marks_hung_runtime_commands_unreachable`（断言 elapsed < 5s）与 `engine.rs:847-849` 断言常量=4s |
| 镜像缺失 `available=false` 且 reason 含 `engine/image/build-image.sh` | `classify_engine` 第二段（`395-420`）拼 `... not found...; build it with engine/image/build-image.sh`；单测 `classification_points_at_the_image_script_when_the_image_is_missing` |
| 新字段向后兼容 | `EngineInfo` 新增 `runtime/image/image_present` 均为 `Option`（`engine.rs:64-70`），旧字段 `kind/available/platform/reason` 不动；单测 `engine_info_serializes_the_e2_fields` 断言 7 个键都在 |
| 环境变量覆盖 | `SYSEMBLE_ENGINE_IMAGE`、`SYSEMBLE_ENGINE_RUNTIME`（`engine.rs:29-35`）；集成测试 `tests/engine_probe.rs` 用假 runtime 端到端 |

**真实 daemon 三分支实测**（非 mock，`cargo test --lib engine::tests::engine_info_reports_the_host_capability -- --nocapture`）：

```json
// 1. 有 daemon + 有镜像
{"kind":"container","available":true,"platform":"macos",
 "reason":"container engine: docker 29.1.2 · image sysemble-engine:0.1.0",
 "runtime":"docker","image":"sysemble-engine:0.1.0","image_present":true}

// 2. 有 daemon + 镜像缺失（SYSEMBLE_ENGINE_IMAGE=sysemble-engine:does-not-exist）
{"kind":"container","available":false,"platform":"macos",
 "reason":"container engine: docker 29.1.2 · image sysemble-engine:does-not-exist not found (Error response from daemon: No such image: ...); build it with engine/image/build-image.sh",
 "runtime":"docker","image":"sysemble-engine:does-not-exist","image_present":false}

// 3. runtime 不可达（SYSEMBLE_ENGINE_RUNTIME=/nonexistent/docker）
{"kind":"none","available":false,"platform":"macos",
 "reason":"no usable build engine on macos: docker: cannot run `/nonexistent/docker`: No such file or directory (os error 2) — start Docker Desktop (or run `podman machine start`) and retry",
 "runtime":null,"image":null,"image_present":null}
```

说明：第 3 分支用「指向不存在的 runtime 路径」模拟 daemon 不可达，**没有真的停掉**本机 Docker Desktop（避免影响用户环境）；分类逻辑与错误文案与 §2.2 表格一致。

### 4.3 大小写不敏感修复是否真实存在 —— **PASS（有 1 处文档不精确）**

- `engine/runtime/container-entry.sh`：在容器内 `/out` 构建（`--out /out` 传给 `build.sh`），只导出 `$OUT/*` 的**顶层常规文件**（`for file in "$OUT"/*; do [ -f "$file" ] || continue`，目录被跳过），显式跳过 `build.log`（注释说明宿主进程仍持有该文件），并要求至少导出 `artifact.json`。
- 拒绝 `/work`、`/export` 作为 `--out`：`case "$OUT" in /work|/work/*) die ...; /export|/export/*) die ...; esac`；`--mode` 只接受 `execute`，其余报错「dry-run stays on the host」。
- `engine/image/Dockerfile:88-96` 有 `RUN ln -sf bash /bin/sh`，并带长注释解释 Rosetta 占用 fd 3–9 导致 mmdebstrap 的 `cat >&<fd>` 在 dash 下 `Bad fd number`；guest rootfs 不受影响。
- 运行时证据：CI 与本机日志里导出的顶层文件都是 `artifact.json/disk.img/disk.qcow2/grub.cfg/plan.copy.json`，`rootfs/`、`esp/`、`iso/` 未导出，`build.log` 不在宿主。
- `docs/plan/P1-e2-workplan.md` §2.3 与 `engine/image/README.md` 都如实描述了该机制与代价（宿主只能拿到产物、kernel 模式 boot-check 在宿主不可用）。
- **不精确处**：README 写「copies only the top-level result files (`artifact.json`, `disk.img`, `disk.qcow2`, any `*.iso`)」，实际还导出了 `grub.cfg`、`plan.copy.json`（同属「顶层常规文件」，契约允许）。建议把措辞改成「all top-level regular files (e.g. …)」。

### 4.4 过度声明检查 —— 结论：**有 4 处需要标注，均未计入 PASS 证据**

| 声明 | 实际情况 | 处置 |
|---|---|---|
| Windows 可用（README 跨平台表 + 中文简介） | 本机/CI 都没有 Windows；CI 9/9 job 全是 `ubuntu-latest`；取消走 `taskkill`（`build.rs:732-743`）从未在 Windows 执行；宿主 `dry-run` 依赖 PATH 里的 `bash` | **未验证**，不得作为 PASS 证据 |
| VZ / WSL2 | 全仓库无 `VZVirtualMachine`/`virtiofs`/`wsl.exe`/`hvf` 代码；`engine/` 只有 `image/`、`runtime/`；roadmap 写明顺延 P1-e3 | **未实现**（符合非目标） |
| 镜像「可复现」 | 同 HEAD 下 CI `6c8a1721…` vs 本机 `568bd6ad…`；artifact.json 哈希不同；README 已如实写「not bit-for-bit reproducible」 | **已知限制**，文档已披露 |
| `--privileged` 的沙箱边界 | `engine/image/README.md` 明确写「local, one-shot build sandbox, **not** a security boundary」；但 **UI 不展示**该提示（`app.js` 只显示 `Engine: container · docker`） | 文档已披露、UI 未披露；§2.3 的「UI/文档」只满足文档一半 |

另外根 README 的卖点句「Builds run inside the disposable, versioned Linux engine image …, never directly on your host」与 Linux `local` 引擎（root 直接宿主构建）矛盾；这是既有文案，不属本切片新增，但会被理解为「永不在宿主构建」。

---

## 5. 回归与门控复跑（任务书第 8–9 项）

```bash
export CARGO_HOME=.../.tools/cargo RUSTUP_HOME=.../.tools/rustup

$CARGO_HOME/bin/cargo test --workspace
# 6 个 target + 1 个空 doc-test：9 + 12 + 8 + 10 + 8 + 14 = 61 passed；0 failed

$CARGO_HOME/bin/cargo test --manifest-path apps/desktop/src-tauri/Cargo.toml
# lib 36 + tests/cancel_build 1 + tests/engine_gate 1 + tests/engine_probe 1 = 39 passed；0 failed

$CARGO_HOME/bin/cargo clippy --manifest-path apps/desktop/src-tauri/Cargo.toml --all-targets -- -D warnings
# Finished `dev` profile ... in 0.50s；exit 0；输出中 warning 行数 = 0

PYTHONPATH=/tmp/pylibs314 bash tests/acceptance/run.sh
# SUMMARY: 17 passed, 0 failed, 0 blocked / RESULT: PASS

PYTHONPATH=/tmp/pylibs314 /opt/homebrew/bin/python3 tools/validate.py
# ok spec/*.schema.json、ok examples/*.yaml；all specs valid；exit 0
```

- acceptance 的 A10 报告 `git status entries: 1 (unchanged before/after the run)`，那 1 条就是 `M docs/plan/P1-e2-workplan.md`（状态表 3 行），运行前后未变化；`Cargo.lock` sha256 未变。
- workplan K9 写「桌面原有 17」，当前桌面 crate 总数是 **39**（36 lib + 3 集成）。本报告以 39 全绿作为回归证据，未逐条区分基线 17 与新增 22；数字表述与现状不同，属文档口径问题，不影响回归结论。
- UI 门控（K8）：`apps/desktop/ui/app.js:74-75` `els.dryRun.disabled = locked; els.build.disabled = locked || !engineAvailable;`；不可用时 `Engine unavailable — <reason>`（`131-133`），reason 直接来自 `engine_info`；`refreshControls()` 在探测回调里调用（`135`）。

---

## 6. 风险与未验证项

1. **Windows 从未验证（未验证）**：无 Windows CI、无真机；`taskkill` 取消路径、NTFS 大小写不敏感（虽然 v2 已规避）、`bash` 依赖的宿主 dry-run 都只是「读代码推断」。不能把 Windows 计入任何 PASS。
2. **本机 boot 时间余量偏紧**：本次 boot **354s / 600s（59%）**，总 E2E **504s**。若宿主机更慢或并行负载更高，`container_smoke.sh` 的默认 900s 尚可，但任务书给的 600s 只剩 246s 余量；建议本机默认 900s，并在文档写清「Apple Silicon 上 boot 可能 5–6 分钟」。
3. **本机 E2E 耗时与文档不符**：`engine/image/README.md` 写「measured 191 s for the minimal plan on the M-series dev host」、workplan 写「本机 E2E 3m11s」；本次独立实测 **504s**。差异主要来自我在 E2E 期间并行跑了 `cargo test`/`clippy`/两次 `image_test.sh`，以及 boot 从 31s（CI）变成 354s（Rosetta+TCG）。**性能声明不能当作契约**，也不能用 191s 承诺用户。
4. **apt 漂移**：包集合随 Debian 实时镜像变化；`packages=205`、kernel `6.12.118+deb13-amd64` 都是当次快照，重跑不保证逐字一致（本次恰好一致）。
5. **raw `disk.img` 摘要失效**：见 §3.4；建议契约注明「raw 摘要为构建时值」或 boot 后重算。
6. **privileged 边界**：`--privileged` 容器可访问宿主内核能力，仅适合可信 spec；UI 未提示，只有 `engine/image/README.md` 说明。若产品要求「启动构建前告知」，目前不满足。
7. **Docker Desktop 强依赖**：macOS/Windows 上无 daemon 时只能 dry-run（`kind=none`，reason 可读）；原生 VZ/WSL2 顺延 E2c。这是产品级限制，不是本切片缺陷。
8. **`engine_info` 的可用性以「镜像 inspect 成功」为准**：不校验镜像架构/版本是否匹配 `linux/amd64`/`0.1.0`；若本地存在同名但错误架构的镜像，探测会报 available。当前版本 `--platform` 由 `docker run` 强制，属低风险。
9. **文档内部不一致（非阻塞）**：workplan §1 架构图仍是 v1 的 `-v <out>:/out`（与 §2.3 v2 矛盾）；`engine/image/README.md` 引用「sections 2.1 and 5」而容器契约在 §2.3；ci-snippet 仍写「this slice does not edit the real workflow」，但 `ci.yml` 已包含该 job。建议主线程统一修正。
10. **CI upload 路径含永不存在的 `smoke/build.log`**（upload 日志 `there will be 8 files uploaded`）；`if-no-files-found: warn` 静默通过，`build.log` 按契约不导出属预期，但路径条目应删。
11. **工作区不干净**：验收开始时 `docs/plan/P1-e2-workplan.md` 有 3 行未提交状态表改动；代码与 HEAD 一致，CI 跑在 HEAD 上。若要求干净工作区，需主线程先提交。

---

## 7. K1–K10 对照（§4 验收矩阵）

| # | 通过条件 | 结果 | 证据（文件/日志行/命令） |
|---|---|---|---|
| K1 | `build-image.sh` 在 amd64 本机/CI 成功 | **PASS** | CI `4_Build…txt`：`#9 DONE 10.4s`、`build-image: built …`、`elapsed: 31s`；本机 `image_test.sh --docker` 的 `verify: OK ref=… present locally`；详见 P1-e2a §6 |
| K2 | 5 工具版本非空 | **PASS** | 本机 `image_test.sh --docker` 117/117；CI 117/117；manifest `tool_versions` 5 键非空（P1-e2a §4.4） |
| K3 | `--verify` / image_id / base digest | **PASS** | CI 6 条 `verify: OK`；本机同 6 条；manifest `base` == `Dockerfile:16`（P1-e2a §4.4） |
| K4 | 容器内 `build.sh --execute` 产出 artifact.json + qcow2，退出码 0 | **PASS** | **本机**：`CONTAINER-SMOKE: pass`，`container-smoke: elapsed: 504s`，`artifact.json`(1,340B)+`disk.qcow2`(420,937,728B)，qcow2 `cb0b417c…` == 本地 artifact.json；**CI**：88.1s，qcow2 `7a3bcd53…` == artifact.json |
| K5 | 同一镜像内 boot-check 断言通过（TCG） | **PASS** | 本机 `result: pass (354s)` + 5/5；CI `result: pass (31s)` + 5/5；两份 boot.log 均 `Booting paravirtualized kernel on bare hardware`。P1-e2a §3.3/§6 |
| K6 | macOS daemon+镜像 → container/available；删镜像/停 daemon → 明确降级且 reason 可读 | **PASS** | §4.2 的真实 daemon 三段 JSON；单测 `classification_*` 5 条 + `probe_*` 4 条；集成 `tests/engine_probe.rs` |
| K7 | 假 runtime 记录 argv，断言挂载/平台/privileged/容器内路径/`--name` | **PASS** | `build.rs:958-1009` 逐元素断言 v2 argv；`build.rs:1012-1058` 断言只有 `/export`（无 v1 可变 `/work`、无 `/work/` 前缀） |
| K8 | execute 无引擎明确报错；dry-run 不受影响；UI Build 禁用/启用 | **PASS** | `execute_without_an_engine_returns_a_readable_error`、`dry_run_still_runs_when_the_engine_is_unavailable`、`dry_run_build_exits_zero_and_logs_the_plan`；`app.js:74-75,131-135` |
| K9 | 根 workspace 61、桌面、acceptance 17/17、clippy 全绿 | **PASS** | §5：61 / 39 / 17-0-0 / clippy 0 warning / validate.py 全绿 |
| K10 | 验收代理下载 artifact、重算 sha256、核对 manifest/日志，写两份报告 | **PASS** | 本报告 + `P1-e2a.md`；zip `36976b92…`、qcow2/boot.log/artifact.json/boot-evidence 全部重算并三方比对 |

---

## 8. 「未只信 CI」清单

1. **重算哈希**：artifact zip `36976b92…`（235,584,066 B）；CI qcow2 `7a3bcd53…`、boot.log `b75375aa…`、artifact.json `c4b456bf…`、boot-evidence `679ed622…`——四者分别等于 `artifact.json` / `boot-evidence.json` / CI stdout 中对应值。
2. **独立 E2E**：本机 `/tmp/p1e2-accept/smoke` 从 `plan.json` 开始完整重跑（8m24s），退出 0、`CONTAINER-SMOKE: pass`、boot 5/5；本次 qcow2 `cb0b417c…` 与本次 artifact.json 一致，boot.log `b45fdd43…` 与本次 boot-evidence 一致。
3. **真实 daemon 探测**：三个分支都跑了真实 docker（只第三个用不存在的 runtime 路径模拟不可达），不是只看单测。
4. **重跑测试**：workspace 61、桌面 39、clippy、acceptance 17/17、validate.py；未复用 CI 结论。
5. **逐行读代码**：`build.rs` argv/门控/取消、`engine.rs` 探测/超时/兼容字段、`container-entry.sh` 的 `/out` 与导出边界、`Dockerfile` 的 `/bin/sh→bash`、`app.js` 的 disabled 逻辑。
6. **未做的复现（声明）**：没有在 Windows 上执行任何东西；没有停掉本机 Docker daemon（用不可达 runtime 代替）；没有对 raw `disk.img` 内容做判定（4 GiB 未上传，且 boot 后摘要失效）。

---

*本报告只写入了 `docs/acceptance/P1-e2b.md` 与本轮同批的 `docs/acceptance/P1-e2a.md`；未执行 `git add/commit/push`，未修改代码、配置、README、plan 或其它任何文件。证据保留在 `/tmp/p1e2-accept/`（`art/`=CI artifact、`smoke/`=本机 E2E、`logs/`=run logs、`cargo-all.log`、`acceptance.log`、`image-test-docker.log`）。*
