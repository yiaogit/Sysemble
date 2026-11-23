# P0-b 独立验收报告（真实 Debian 构建 + QEMU 启动）

- 验收角色：**SA-verify2**（独立验收子代理；只读源码/CI/证据，只在 `docs/acceptance/**` 写入）
- 日期：**2026-11-23**（本机 Europe/Madrid 13:35–13:45；CI 日志为 UTC）
- 仓库：`sysemble/`，分支 `main`，HEAD **`f8ee0561499734cb07226e3d9b256af232d70551`**（与 CI checkout 的 headSha 一致）
- 权威 CI run：**[45175496442](https://github.com/yiaogit/Sysemble/actions/runs/45175496442)**（push，`success`）
- 权威 job：**[Boot smoke (Debian) #137695543475](https://github.com/yiaogit/Sysemble/actions/runs/45175496442/job/137695543475)**（`success`，12:33:55–12:35:27 UTC）
- 证据 artifact：`boot-evidence`（artifact ID **14819850405**，zip 17624 bytes）
- 验收范围：`docs/plan/P0-b-workplan.md` 的 **B1–B8**，以及任务书要求额外核实的 8 个点
- 判定原则：CI job 绿 + 证据一致 + 断言实现真实 → PASS；任何一项不一致 → 需修复

**判定摘要：B1–B8 全部 PASS，无 FAIL。结论：`P0-b 通过`。**
未验证/待 P0-c 处理的项集中在“证据资产未上传、镜像摘要未复核、rw 启动会改写镜像、base.pin/arch 未生效、Docker 路径未验证”等，见 §6；它们不构成本轮假通过，但必须在 P0-c 前收敛。

---

## 1. 环境与执行方式

### 1.1 本地环境（只做静态检查与离线回归）

| 项 | 实际值 |
|---|---|
| OS / 架构 | macOS **26.6.2**（Build 25G83），Darwin 25.6.0，**arm64** |
| Rust / Cargo | rustc **1.100.0** (0ef1bc386 2026-11-09) / cargo **1.100.0** (3acc79c0c 2026-11-05) |
| 工具链位置 | `CARGO_HOME=<repo>/../.tools/cargo`；`RUSTUP_HOME=<repo>/../.tools/rustup` |
| git / jq / Python | git 2.52.0；jq 1.7.1-apple；Python 3.14.3（`/opt/homebrew/bin/python3`） |
| Python 依赖 | 通过 `PYTHONPATH=/tmp/pylibs314` 使用 jsonschema 4.26.0 + PyYAML 6.0.4 |
| mmdebstrap / qemu | **均不在 PATH**（macOS 上预期）；本机不能做真实构建/启动 |
| 网络 | 除 `gh` 读取 CI 证据外，回归不依赖网络；Cargo 使用本地工具链 |

本地能力边界（与工作单一致）：真实构建与 QEMU 启动的**唯一权威环境是 GitHub Actions**，本地只复跑 dry-run、静态检查、artifact/boot-check 离线测试、schema 与 P0-a 验收。

### 1.2 CI 环境

| 项 | 实际值（来自 job log） |
|---|---|
| Runner | `ubuntu-26.04`（Ubuntu 26.04.1 LTS），Azure `eastus3`，Hosted Compute Agent 20261111.635 |
| Checkout | `f8ee0561499734cb07226e3d9b256af232d70551`（depth 1） |
| 安装 | `sudo apt-get install -y --no-install-recommends mmdebstrap debian-archive-keyring qemu-system-x86 qemu-utils e2fsprogs jq` |
| 构建命令 | `sudo env PATH="$PATH" bash builders/debian/build.sh --plan plan.json --out out --execute` |
| 启动断言命令 | `bash tools/boot-check.sh --artifact out/artifact.json --timeout 300 --json` |
| 上传 | `actions/upload-artifact@v4`，`if: always()`，只上传 `plan.json`、`out/artifact.json`、`out/build.log`、`out/boot.log`、`out/boot-evidence.json`（5 个文件） |
| 时间线 | job 12:33:55 → 12:35:27；build 12:34:20.02 → 12:35:02.28；boot 12:35:02.385 → 12:35:24.609 |

复现证据获取命令：

```bash
cd "/Users/yiao/Documents/linux软件设计框架/sysemble"
gh run view 45175496442 -R yiaogit/Sysemble
rm -rf /tmp/p0b-evidence
gh run download 45175496442 -R yiaogit/Sysemble -n boot-evidence -D /tmp/p0b-evidence
# 额外取原始 zip 校验上传摘要（见 §3.5）
XDG_CACHE_HOME=/tmp/p0b-cache gh api \
  /repos/yiaogit/Sysemble/actions/artifacts/14819850405/zip > /tmp/boot-evidence.zip
```

---

## 2. B1–B8 结果总表

| # | 检查 | 命令 / 证据 | 期望 | 实际 | 判定 |
|---|---|---|---|---|---|
| B1 | `build.sh --dry-run` 回归 | `cargo run -q -p sysemble-cli -- plan examples/minimal-debian.yaml > /tmp/p0b-plan-local.json`；`bash builders/debian/build.sh --plan /tmp/p0b-plan-local.json --out /tmp/p0b-dryrun/out --dry-run` | exit 0，P0-a 行为不变，打印阶段 | exit 0；输出 6 个阶段、14 个包、`Dry run complete`；`out/` 仅有 `plan.copy.json` | **PASS** |
| B2 | builder 静态检查 | 对全部 tracked `*.sh` 跑 `bash -n`；macOS 上 `build.sh --execute`；`boot-check` 无 qemu | 语法全过；缺工具时明确报错 | 全部 `bash -n` 通过；native 拒绝 **exit 3**，逐条报 Linux/root/mmdebstrap/mkfs.ext4/qemu-img 缺失；boot-check 无 qemu **exit 3** 且信息可读 | **PASS** |
| B3 | artifact 形状 | `jq -e` 校验 `apiVersion/spec/base/arch/packages/rootfs/images/boot`、2 个 image、sha256 正则、大小/时间；与 boot.log 比对 kernel 版本 | 字段齐全且自洽 | `jq` 表达式返回 `true`；raw+qcow2，sha256 均 64 位小写 hex；kernel/initrd 为 `6.12.118+deb13-amd64`，与 boot.log 的 `Linux version` 一致 | **PASS** |
| B4 | boot-check 离线断言 | `bash tools/tests/boot-check-test.sh`；对真实 CI `boot.log` 跑 `--log-from`；构造缺 `login:` 日志做负例 | 3 条断言可内容匹配；缺 login 必失败 | 测试 **16/16 PASS**（canned good、no-login、empty、timeout、argv、exit code）；真实日志重放 3 条 pass，exit 0；缺 login 负例 `boot.login=fail`，exit 1 | **PASS** |
| B5 | boot-check 无 qemu | `bash tools/boot-check.sh --artifact <fixture>`；`--qemu /nonexistent` | exit 3，信息可读 | 前者 exit 3：`qemu-system-x86_64 not found on PATH`；后者 exit 3：`QEMU binary is not executable` | **PASS** |
| B6 | **CI boot-smoke** | run `45175496442` / job `137695543475`；job log + 下载的 boot.log | job 绿，真实 build + boot，日志含 `Linux version` 与 `login:` | run/job 均 `success`；job log 显示 mmdebstrap→mkfs.ext4→qemu-img→qemu→3 条断言 pass；boot.log 含内核/systemd/login | **PASS** |
| B7 | 回归 | 见 §5 | 全部绿 | cargo **61**；builder **13 + 33**；boot-check **16**；schema 6 个文件全 ok；P0-a acceptance **17/17** | **PASS** |
| B8 | 工作区边界 | `git status --porcelain -uall`；`git diff`；路径检查 | 变更只在允许目录 | 验收前工作区干净；写入本报告后仅新增 `docs/acceptance/P0-b.md`；`target/` 为 ignored 构建缓存；无源码/CI/plan 改动 | **PASS** |

> B3 的“kernel/initrd 路径存在”不是只靠 JSON：`boot-check` 在启动前用 `resolve_artifact_file` 要求 `boot.kernel`/`boot.initrd`/raw image 都是**可读常规文件**，否则 exit 2；本次 QEMU 实际加载了内核并挂载了 rootfs，反向证明这些路径在 CI 构建机上存在。artifact 的生成函数也在写清单前用 `find_boot_image` 检查（`builders/debian/lib.sh`）。

---

## 3. 关键证据

### 3.1 `boot.log`（48,421 bytes，sha256 `f942f934e932e5e9a410149529a4f365faf7d248db766dfe6719725ca074dfd4`）

```text
[    0.000000] Linux version 6.12.118+deb13-amd64 (debian-kernel@lists.debian.org) ... #1 SMP PREEMPT_DYNAMIC Debian 6.12.118-1 (2026-11-20)
[    0.000000] Command line: console=ttyS0 root=/dev/vda rw rootfstype=ext4 systemd.unit=multi-user.target
...
[    6.452492] EXT4-fs (vda): mounted filesystem a5f05395-0999-43c3-a66a-77593db3aadd r/w with ordered data mode. Quota mode: none.
[    7.214432] systemd[1]: systemd 257.13-1~deb13u1 running in system mode (+PAM +AUDIT +SELINUX ...)
[    7.215211] systemd[1]: Detected virtualization qemu.
[    7.228664] systemd[1]: Hostname set to <minimal-debian>.
...
[   18.092874] kvm_amd: Nested Virtualization enabled
...
[  OK  ] Started serial-getty@ttyS0.service - Serial Getty on ttyS0.
[  OK  ] Reached target getty.target - Login Prompts.
[  OK  ] Reached target multi-user.target - Multi-User System.
...
Debian GNU/Linux 13 minimal-debian ttyS0

minimal-debian login: qemu-system-x86_64: terminating on signal 15 from pid 13412 (bash)
```

逐项核对：

| 检查 | 结果 | 证据 |
|---|---|---|
| 含 `Linux version` | 是 | 第 9 行；版本 `6.12.118+deb13-amd64` |
| 含 `systemd[1]` | 是 | 第 423 行起大量 `systemd[1]:`；systemd 257.13-1~deb13u1 |
| 含 `login:` | 是 | 第 636 行 `minimal-debian login:` |
| 无 `Kernel panic` | 是 | 大小写不敏感扫描 `panic/oops/bug:/segfault` 无命中；唯一的 “Failed” 是良性 `Failed to open libbpf, cgroup BPF features disabled` |
| 时间戳合理 | 是 | 内核单调时间 0.000000 → 18.437910s；job wall clock 12:35:02.406 → 12:35:24.609 = 22.2s；evidence `elapsed_seconds=22` |
| kernel 版本与 artifact 一致 | 是 | artifact `boot.kernel=rootfs/boot/vmlinuz-6.12.118+deb13-amd64` |
| 启动的是本次构建的磁盘 | 是 | boot.log 的 ext4 UUID `a5f05395-0999-43c3-a66a-77593db3aadd` 与 build.log `mkfs.ext4` 输出 **完全相同**；hostname `minimal-debian` 与 plan.spec 一致；cmdline 与 artifact 逐字一致 |
| 是真实 QEMU 串口日志 | 是 | 开头 SeaBIOS/iPXE、DMI `QEMU Standard PC (Q35 + ICH9...)`、结尾 `qemu-system-x86_64: terminating on signal 15 from pid 13412 (bash)` |

关于加速器：`tools/boot-check.sh` 的 QEMU 参数没有 `-accel`/`-enable-kvm`；guest 打印 `Booting paravirtualized kernel on bare hardware`，systemd 识别为 `Detected virtualization qemu`。这与 **TCG** 路径一致（`kvm_amd` 是 guest 自己看到 qemu64 模型中的 AMD-V 后加载的模块，不代表宿主机用了 KVM）。该判断未从 QEMU 侧直接读取 `-accel`，已列入风险 §6-R3。

### 3.2 `boot-evidence.json`（sha256 `49085a36...3db11f`）

```json
{
  "apiVersion": "sysemble/boot-evidence/v1",
  "artifact": "/home/runner/work/Sysemble/Sysemble/out/artifact.json",
  "qemu": "qemu-system-x86_64",
  "timeout_seconds": 300,
  "elapsed_seconds": 22,
  "result": "pass",
  "assertions": [
    {"id": "boot.kernel",  "result": "pass", "detail": "matched `Linux version`"},
    {"id": "boot.systemd", "result": "pass", "detail": "matched `systemd[1]` and `Reached target`"},
    {"id": "boot.login",   "result": "pass", "detail": "matched `login:`"}
  ],
  "log": "boot.log",
  "log_sha256": "f942f934e932e5e9a410149529a4f365faf7d248db766dfe6719725ca074dfd4"
}
```

一致性核对：

- `log_sha256` 与下载的 `boot.log` 实际 `shasum -a 256` **逐字相同**（`f942f934...74dfd4`）。
- 3 条断言均 `result=pass`，与 boot.log 内容匹配方式（见 §4.1）一致。
- `elapsed_seconds=22` 与 job log 的 22.2s、boot.log 的 18.4s 内核时间、timeout 300s 相符。
- `result=pass` 与 job 退出码 0 一致；evidence 由 `write_evidence` 在断言之后生成，`log_sha256` 由 `sha256_file` 现场计算（`tools/boot-check.sh:1102-1207`）。

### 3.3 `artifact.json`（sha256 `9e8f25be...d62b5e`）

| 字段 | 实际值 | 核对 |
|---|---|---|
| `apiVersion` | `sysemble/artifact/v1` | 符合契约 |
| `spec` | `minimal-debian` | 与 plan/`examples/minimal-debian.yaml` 一致 |
| `base` | `{"kind":"debian","release":"trixie","pin":"2026-11-01"}` | 形状正确；**pin 未应用到 mirror**（风险 R5） |
| `arch` | `x86_64` | 与 plan 一致；**未校验宿主 arch**（风险 R5） |
| `packages` | 14 个，含 `linux-image-amd64`、`initramfs-tools`、`systemd-sysv`、`udev` 等 | 与 plan 的 14 个包及顺序一致 |
| `rootfs` | `{"path":"rootfs","size_mb":389}` | build.log 报 `rootfs 389 MB` |
| `images[0]` | `disk.img`，`raw`，2048 MB，sha256 64 hex | mke2fs 524288×4k = 2 GiB；build.log 一致 |
| `images[1]` | `disk.qcow2`，`qcow2`，394 MB，sha256 64 hex | qemu-img convert 产物；大小合理 |
| `boot.kernel` | `rootfs/boot/vmlinuz-6.12.118+deb13-amd64` | 与 boot.log 内核版本一致 |
| `boot.initrd` | `rootfs/boot/initrd.img-6.12.118+deb13-amd64` | 与内核同版本；qemu 实际加载 |
| `boot.cmdline` | `console=ttyS0 root=/dev/vda rw rootfstype=ext4 systemd.unit=multi-user.target` | 与 boot.log `Command line` 逐字一致 |
| `builder` | `{"name":"build.sh","version":"0.1.0"}` | 符合契约 |
| `createdAt` | `2026-11-23T12:34:59Z` | 落在 build step 12:34:20–12:35:02 内；artifact 文件 mtime 12:35 |

`jq` 形状断言（本次实际运行，返回 `true`）：

```bash
jq -e '
  .apiVersion == "sysemble/artifact/v1" and
  (.spec|type=="string" and length>0) and
  (.base.kind=="debian") and (.arch|type=="string") and
  (.packages|type=="array" and length>0) and
  (.rootfs.path=="rootfs") and (.rootfs.size_mb|type=="number" and .>0) and
  (.images|type=="array" and length==2) and
  ([.images[].format]|sort==["qcow2","raw"]) and
  (all(.images[]; (.sha256|test("^[0-9a-f]{64}$")))) and
  (all(.images[]; (.size_mb|type=="number" and .>0))) and
  (.boot.kernel|type=="string") and (.boot.initrd|type=="string") and
  (.boot.cmdline|type=="string") and
  (.createdAt|test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
' /tmp/p0b-evidence/out/artifact.json
# true
```

### 3.4 `build.log`（sha256 `126b2a01...8334741`）

关键行（连续、非拼接）：

```text
[build] stage 1/6: validate - plan is valid
[build] stage 2/6: fetch base - debian/trixie
[build] stage 3/6: bootstrap rootfs - /home/runner/work/Sysemble/Sysemble/out/rootfs
[build] stage 4/6: install packages - 14 packages via --include
[build] customize: hostname=minimal-debian, enable serial-getty@ttyS0.service (failure is non-fatal)
  $ mmdebstrap --variant=minbase --include=apt,ca-certificates,... trixie /home/runner/.../out/rootfs
I: automatically chosen mode: root
I: chroot architecture amd64 is equal to the host's architecture
I: running apt-get update...
I: downloading packages with apt...
I: extracting archives...
I: installing essential packages...
I: installing remaining packages inside the chroot...
I: running --customize-hook in shell: sh -c '... systemctl enable serial-getty@ttyS0.service ...'
I: cleaning package lists and apt cache...
I: success in 36.2915 seconds
[build] boot: kernel=vmlinuz-6.12.118+deb13-amd64, initrd=initrd.img-6.12.118+deb13-amd64
[build] stage 5/6: create ext4 disk image - rootfs 389 MB, disk 2048 MB
  $ truncate -s 2048M /home/runner/work/Sysemble/Sysemble/out/disk.img
  $ mkfs.ext4 -d /home/runner/work/Sysemble/Sysemble/out/rootfs -L SYMBLE -F /home/runner/work/Sysemble/Sysemble/out/disk.img
mke2fs 1.47.2 (1-Jan-2025)
Creating filesystem with 524288 4k blocks and 131072 inodes
Filesystem UUID: a5f05395-0999-43c3-a66a-77593db3aadd
...
Copying files into the device: done
Writing superblocks and filesystem accounting information:  0/16 ... done
  $ qemu-img convert -O qcow2 /home/runner/work/Sysemble/Sysemble/out/disk.img /home/runner/work/Sysemble/Sysemble/out/disk.qcow2
[build] stage 6/6: write artifact manifest
[build] complete
  raw:      .../disk.img (2048 MB)
  qcow2:    .../disk.qcow2
```

核对：

- `mmdebstrap` 有真实的 apt/解包/安装/清理输出，并以 `I: success in 36.2915 seconds` 结束。
- `mkfs.ext4` 为真实 `mke2fs 1.47.2` 输出，524288 个 4k 块 = 2 GiB；rootfs `du` 389 MB，disk 2048 MB，符合 `compute_disk_size_mb` 的 2048 MB floor。
- `qemu-img convert` 成功时本身静默，build.log 记录的是**命令回显**；其确实执行由两步证明：(a) 命令后立即进入 stage 6 且构建 exit 0；(b) `artifact_json` 随后对 `disk.qcow2` 做了 `sha256_file`，清单里出现 394 MB / 64-hex 的 qcow2（文件不存在会直接失败）。这是轻微证据缺口，见 R8。
- job log 的同一段输出与 build.log 逐行一致，时间戳连续（12:34:20 → 12:35:02）。

### 3.5 证据链完整性（防“调包”）

| 检查 | 结果 |
|---|---|
| 下载的 artifact zip 大小 | **17624 bytes**，与 job log “Final size is 17624 bytes” 一致 |
| zip sha256 | **`506608ce03acfdd6e20ebe4b941b1ee189c8e5f91dbbbfe28d2961c07c608ec9`**，与 job log “SHA256 digest of uploaded artifact zip” 逐字一致 |
| zip 内容 | 5 个文件：`plan.json`、`out/artifact.json`、`out/build.log`、`out/boot.log`、`out/boot-evidence.json`；zip 内 mtime 均为 2026-11-23 12:34/12:35 |
| zip 内 vs 解压后 | 5 个文件 sha256 **全部 MATCH**（含 `boot.log=f942f934...`） |
| headSha | `f8ee0561499734cb07226e3d9b256af232d70551` = 本地 HEAD |
| run 结论 | `success`；3 个 job 全 `success`（Validate specs 14s、Rust workspace 18s、Boot smoke 92s） |

这排除了“拿另一份旧证据充数”的可能：**我们核对的 boot.log/boot-evidence.json 就是该次 run 上传的原始字节**。

---

## 4. “不是假通过”的判断依据

### 4.1 断言实现是内容匹配，不是硬编码

`tools/boot-check.sh`：

- `log_has()`（763-767 行）是 `grep -Fq "$1" "$LOG_PATH"`，直接扫描 QEMU 写出的串口日志；
- `all_assertions_pass()`（769-775 行）要求：
  1. `Linux version`
  2. `systemd[1]` **或** `Reached target`
  3. `login:`
- `evaluate_assertions()`（780-842 行）逐条填充 `KERNEL_RESULT`/`SYSTEMD_RESULT`/`LOGIN_RESULT`，`determine_result()`（844-856 行）只有三条都 pass 才 `result=pass`；
- `write_evidence()`（1102-1207 行）用 `sha256_file` 现场计算日志哈希；
- 退出码：0 pass / 1 断言失败 / 2 用法或文件错误 / 3 qemu 不可用 / 4 超时；`main` 按 `RESULT` 映射退出码（1268-1276 行）。

没有 `PASS=1` 之类的短路；没有“看到 artifact 就通过”；`--log-from` 只在显式离线模式使用，CI 命令**没有**传它。

### 4.2 CI 真的执行了 build + boot，失败会让 job 红

`.github/workflows/ci.yml`（29-67 行）：

- `boot-smoke` job 在 `ubuntu-latest` 上执行，先装 mmdebstrap/qemu/e2fsprogs；
- `Build disk image` 是 `sudo env PATH=... bash builders/debian/build.sh --plan plan.json --out out --execute`；
- `Boot and assert` 是 `bash tools/boot-check.sh --artifact out/artifact.json --timeout 300 --json`；
- 这两个都是普通 `run` step，**没有 `continue-on-error`、没有 `|| true`**。boot-check 非 0 → step 失败 → job 失败；
- 只有上传步骤是 `if: always()`，用于保留失败现场，不影响 job 结论；
- job log 明确显示 `launching qemu-system-x86_64`、22 秒后三条断言 pass，且 boot.log 有真实的 SeaBIOS/内核/systemd/登录提示与 QEMU SIGTERM 结束行。

### 4.3 构建/启动是真实执行，不是 stub

- `build.sh --execute` 走到 `build_native`，实际调用 `mmdebstrap`、`truncate`、`mkfs.ext4 -d`、`qemu-img convert`（`builders/debian/build.sh:453-576`）；
- `artifact_json` 用 `sha256_file` 对真实 `disk.img`/`disk.qcow2` 求哈希，用 `find_boot_image` 找真实 kernel/initrd（`lib.sh:912-1013`）；
- `boot-check` 用真实 `qemu-system-x86_64 -machine q35 -m 1024 -smp 2 -nographic -kernel ... -initrd ... -append ... -drive file=disk.img,...` 启动（`tools/boot-check.sh:974-990`）；
- 交叉证据：boot.log 的 ext4 UUID 与 build.log 的 mkfs UUID 相同；boot.log 的 cmdline 与 artifact 相同；boot.log 的内核版本与 artifact 路径相同；磁盘 2 GiB 与 mke2fs 块数相同。

### 4.4 本次验收没有做的事（避免过度声称）

- 没有在本机重跑真实 build/QEMU（macOS 无 Linux/root/mmdebstrap/qemu）；真实构建只由 CI 提供。
- 没有独立重算 `disk.img`/`disk.qcow2` 的 sha256（镜像未上传，见 R1）。
- 没有验证分区表/GRUB/UEFI（P0-b 明确不做，P0-c 范围）。
- 没有验证 Docker 构建路径（见 R7）。

---

## 5. 回归结果（本机实际执行）

| 检查 | 命令 | 结果 |
|---|---|---|
| Rust workspace | `cargo test --workspace` | **61 passed / 0 failed**（9+12+8+10+8+14；另 doc-tests 0） |
| builder artifact 单测 | `bash builders/debian/tests/artifact_test.sh` | **13/13 passed** |
| builder execute 单测（fake toolchain） | `bash builders/debian/tests/build_exec_test.sh` | **33/33 passed** |
| boot-check 离线/假 QEMU 测试 | `bash tools/tests/boot-check-test.sh` | **16/16 passed** |
| schema | `PYTHONPATH=/tmp/pylibs314 python3 tools/validate.py` | 2 个 schema + 4 个示例全 `ok`，`all specs valid`，exit 0 |
| P0-a 验收 | `PYTHONPATH=/tmp/pylibs314 bash tests/acceptance/run.sh` | **17 passed / 0 failed / 0 blocked**，`RESULT: PASS`，exit 0 |
| shell 语法 | 对全部 tracked `*.sh` 跑 `bash -n` | 全部通过 |
| 工作区边界 | `git status --porcelain -uall` / `git diff` | 验收前干净；报告写入后仅新增 `docs/acceptance/P0-b.md` |

说明：`build_exec_test.sh` 使用 fake `mmdebstrap`/`mkfs.ext4`/`qemu-img` 验证命令顺序、日志、失败清理，不能替代真实构建；真实构建以 CI 为准。`boot-check-test.sh` 的 fake QEMU 同样只验证脚本行为，CI 用的是真实 QEMU。

---

## 6. 风险与 P0-c 输入

以下均为**未验证项/设计风险**，不是本轮 B1–B8 的失败项；按任务要求列出，供 P0-c 排期。

### R1 — 证据未包含镜像/rootfs，摘要无法独立复核（中）

上传的 artifact 只有 5 个文本文件，没有 `disk.img`/`disk.qcow2`/`rootfs/`。因此：

- 无法在本机重算 artifact 里两个 64-hex sha256 是否仍对应当前镜像；
- 无法检查磁盘内文件（`/etc/hostname`、`/etc/machine-id`、`serial-getty` enable 状态、包列表）是否与 plan 一致；
- 只能依赖 build.sh 的“先存在再哈希”逻辑与 boot.log 的间接证据（EXT4 UUID、hostname、内核版本）。

**P0-c 输入：** 上传镜像摘要清单（或小体积的 rootfs `find | sha256sum` 清单）；在 boot-check 启动前增加 `images[].sha256` 校验；必要时上传 `qemu-img info` 输出。

### R2 — `rw` 启动会改写 `disk.img`，artifact 摘要在启动后即过期（中）

frozen cmdline 是 `root=/dev/vda rw`；boot.log 显示 systemd 初始化了 machine-id，rw 挂载下 journal、随机种子等写入也会改变镜像。`artifact.json` 的 `disk.img.sha256` 是 **12:34:59 构建时**的摘要，12:35:02 之后镜像被 QEMU 以 rw 挂载并写入。之后若有人拿 `out/disk.img` 去对 artifact 的 sha256，会不匹配。

**P0-c 输入：** 冒烟启动改用 `-snapshot`（或只读盘 + overlay），或在 boot 前校验摘要、boot 后明确“镜像已被测试写脏”；不要用 boot 后的 raw 镜像作为发布物。

### R3 — 只验证了 TCG 路径，未记录 accelerator（中/低）

QEMU 参数无 `-accel`/`-enable-kvm`；guest 打印 `Booting paravirtualized kernel on bare hardware`，systemd 识别为 qemu，符合 TCG。22s 启动是 TCG 下的结果，不代表 KVM/真实硬件性能；CI runner 是否暴露 KVM 未验证。evidence 也没有记录 QEMU 版本与 accelerator。

**P0-c 输入：** 在 evidence 中记录 `qemu --version`、实际 `-accel`/`-cpu`；分别跑 TCG 与 KVM（若可用）两条路径；关注慢 runner 上的超时余量（当前 22s vs 300s）。

### R4 — 仍是“直接内核启动”，没有分区/GRUB/UEFI（设计范围，P0-c）

P0-b 用 `qemu -kernel/-initrd` 直接启动内核，`root=/dev/vda` 指向整块 raw ext4，没有分区表、bootloader、UEFI/安全启动。这证明“镜像里的系统能起来”，但不证明“可安装/可引导的发行镜像”。

**P0-c 输入：** 分区表 + GRUB/UEFI + 安装器；届时 boot-check 需要从 `-kernel` 改为从磁盘引导，并补充相应断言。

### R5 — `base.pin` 未应用、`arch` 未强制（中）

- `artifact.base.pin="2026-11-01"` 只是抄进清单；`build.sh` 调用 `mmdebstrap ... trixie ...`，没有 snapshot URL/日期，实际拉取的是运行当天的 trixie（本次内核 `6.12.118-1`，构建日期 2026-11-20）。
- `arch` 来自 plan，`native_preflight` 只检查 Linux/root/工具，不检查 `uname -m` 与 `target.arch` 一致；在 arm64 Linux 上构建 x86_64 plan 会产出宿主架构 rootfs 却写 `arch: x86_64`（boot-check 随后会找 `qemu-system-x86_64`）。
- README 已声明 pin “Not applied”；这不是隐藏行为，但与“可复现构建”目标冲突。

**P0-c 输入：** 实现 snapshot pin（或明确失败）；增加 `uname -m`/`dpkg --print-architecture` 与 plan.arch 的强校验；在 artifact 记录实际 Debian snapshot/包版本。

### R6 — serial getty 使能是 best-effort（低）

customize hook 的 `systemctl enable serial-getty@ttyS0.service` 失败只打 warning，不失败构建。本次 build.log **没有**该 warning，boot.log 也显示 `serial-getty@ttyS0.service` 启动，说明本次 enable 成功；但若未来 hook 失败，`console=ttyS0` 的 systemd 生成器通常仍会拉起 getty，断言可能仍过，掩盖 hook 失效。

**P0-c 输入：** 把 serial getty 变成显式、可断言的配置（检查 unit enable 状态或 `/etc/systemd/system/getty.target.wants/`），而不是非致命 hook。

### R7 — Docker 构建路径未验证（中）

`--engine docker` 只做 rootfs，P0-b 的 disk/artifact 装配是 native-only；`--engine docker --execute` 被显式拒绝（exit 2）。本机也没有 docker daemon，未做真实容器构建。P0-b 不要求 Docker 出镜像，但“macOS 可用”的承诺仍不完整。

**P0-c 输入：** 若 Docker 是支持路径，需要容器内完成 mkfs/qemu-img/artifact，或在文档中明确 Docker 仅用于 rootfs 预览。

### R8 — `qemu-img` 成功时无输出，build.log 只有命令回显（低）

`qemu-img convert` 成功不打印内容，build.log 仅记录 `$ qemu-img convert ...`；其成功由后续 stage 6 与 artifact 中 qcow2 的 size/sha 间接证明。若要让日志本身“自证”，可加 `qemu-img info` 或 `ls -l`。

### R9 — evidence 缺少 QEMU 版本/argv，boot.log 含 ANSI 控制字符（低）

- evidence 只记 `qemu: qemu-system-x86_64`，不记版本、`-accel`、`-cpu`、argv；
- boot.log 含 ANSI 转义序列（终端光标查询），人类阅读需过滤；断言用 `grep -Fq` 不受影响。

**P0-c 输入：** evidence 增加 `qemu_version`、`accelerator`、`argv`（脱敏路径）；另存一份去控制字符的 `boot.clean.log` 供审计。

### R10 — boot-check 结束时会留下一个 `sleep` 子进程（低）

job log 末尾有 `Terminate orphan process: pid (13537) (sleep)`，很可能是 boot-check watchdog 的 `sleep` 子进程残留；不影响结果，由 runner 清理。可在 P0-c 优化 wait/cleanup。

---

## 7. 最终结论

- **B1–B8：全部 PASS，无 FAIL。**
- **CI：** run `45175496442` 全绿；`Boot smoke (Debian)` 真实执行了 `mmdebstrap` → `mkfs.ext4 -d` → `qemu-img convert` → QEMU 启动，并在 22 秒内命中三条串口断言；job 绿不是“跳过/容忍失败”得来的。
- **证据：** boot.log、boot-evidence.json、artifact.json、build.log 四者互相一致；`log_sha256` 匹配；artifact 的 kernel/cmdline/磁盘 UUID 与 boot.log 交叉匹配；上传 zip 的 sha256 与 CI 日志记录一致，排除了旧证据调包。
- **真实性：** 断言实现是 `grep -Fq` 内容匹配 + 现场计算 sha256，没有硬编码 pass；CI step 失败会直接让 job 失败。
- **非阻断风险：** 证据资产未上传导致镜像摘要不可独立复核（R1）、rw 启动使摘要过期（R2）、TCG 性能与 accelerator 未记录（R3）、无分区/GRUB/UEFI（R4）、pin/arch 未生效（R5）、Docker 路径未验证（R7）等，均应在 P0-c 收敛。

**P0-b 通过。**

---

## 附录 A：本次实际执行的命令（关键）

```bash
cd "/Users/yiao/Documents/linux软件设计框架/sysemble"

# 证据
gh run view 45175496442 -R yiaogit/Sysemble
rm -rf /tmp/p0b-evidence
gh run download 45175496442 -R yiaogit/Sysemble -n boot-evidence -D /tmp/p0b-evidence
XDG_CACHE_HOME=/tmp/p0b-cache gh api \
  /repos/yiaogit/Sysemble/actions/artifacts/14819850405/zip > /tmp/boot-evidence.zip
shasum -a 256 /tmp/p0b-evidence/out/{boot.log,artifact.json,build.log,boot-evidence.json}

# 证据一致性
jq -e '<artifact shape 断言>' /tmp/p0b-evidence/out/artifact.json
grep -F 'Linux version' /tmp/p0b-evidence/out/boot.log
grep -F 'systemd[1]'   /tmp/p0b-evidence/out/boot.log
grep -F 'login:'       /tmp/p0b-evidence/out/boot.log
grep -iE 'kernel panic|panic|oops|bug:|segfault' /tmp/p0b-evidence/out/boot.log   # 无命中

# 离线断言（在证据副本上，kernel/initrd/raw 用占位文件）
cp -R /tmp/p0b-evidence/out /tmp/p0b-offline/out
mkdir -p /tmp/p0b-offline/out/rootfs/boot
# …创建占位 kernel/initrd/disk.img（仅满足路径存在检查，不代表真实文件）…
bash tools/boot-check.sh --artifact /tmp/p0b-offline/out/artifact.json \
  --log-from /tmp/p0b-offline/out/boot.log --json        # exit 0
bash tools/boot-check.sh --artifact /tmp/p0b-offline/out/artifact.json \
  --log-from /tmp/p0b-offline/no-login.log --json        # exit 1, boot.login=fail

# 本机回归
export CARGO_HOME=/Users/yiao/Documents/linux软件设计框架/.tools/cargo
export RUSTUP_HOME=/Users/yiao/Documents/linux软件设计框架/.tools/rustup
$CARGO_HOME/bin/cargo test --workspace
bash builders/debian/tests/artifact_test.sh
bash builders/debian/tests/build_exec_test.sh
bash tools/tests/boot-check-test.sh
PYTHONPATH=/tmp/pylibs314 /opt/homebrew/bin/python3 tools/validate.py
PYTHONPATH=/tmp/pylibs314 bash tests/acceptance/run.sh

# 静态/边界
for f in $(git ls-files '*.sh'); do bash -n "$f" || echo "SYNTAX FAIL: $f"; done
bash builders/debian/build.sh --plan /tmp/p0b-plan-local.json --out /tmp/p0b-refuse/out --execute  # exit 3
bash builders/debian/build.sh --plan /tmp/p0b-plan-local.json --out /tmp/p0b-dryrun/out --dry-run  # exit 0
git status --porcelain -uall
```

## 附录 B：B1–B8 判定与工作单条款对应

| 工作单条款 | 本报告章节 | 判定 |
|---|---|---|
| B1 `--dry-run` 回归 | §2、§5 | PASS |
| B2 builder 静态检查 | §2、§5 | PASS |
| B3 artifact 形状 | §2、§3.3 | PASS |
| B4 boot-check 离线断言 | §2、§3.1、§3.2 | PASS |
| B5 boot-check 无 qemu | §2 | PASS |
| B6 CI boot-smoke | §1.2、§2、§3 | PASS |
| B7 回归 | §5 | PASS |
| B8 工作区 | §2、§5 | PASS |
