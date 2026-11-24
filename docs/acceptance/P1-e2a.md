# P1-e2a 独立验收报告（引擎镜像：构建 / 清单 / 容器内 build + boot 的镜像侧）

- 验收角色：**acceptance-e2**（独立验收子代理；只读源码/CI/产物，只写 `docs/acceptance/P1-e2a.md` 与本轮同批的 `P1-e2b.md`；未做任何 git 写操作）
- 日期：**2026-11-24**（Europe/Madrid，17:19 起；CI 时间线为 UTC）
- 仓库：`sysemble/`，分支 `main`，**HEAD `9e1823f20865375e77ffb1dec8f873db6e5475da`**
- 工作区状态（验收开始时）：**不干净**——`M docs/plan/P1-e2-workplan.md`（17:18:57 修改）。`git diff` 只有 3 行「切片状态」表格（E2a/E2b 改「已交付」、E2d 改「验收中」），**契约 §2.1/§2.2/§2.3/§4/§6 与 HEAD 逐字相同**；除该文件外，`git status --porcelain` 无其它条目，即所有被检查的源码文件均与 HEAD 一致。本报告以 HEAD 的代码 + 工作区的 plan 文本为准，见 §7.1 第 12 条。
- 权威 CI run：**[45434475490](https://github.com/yiaogit/Sysemble/actions/runs/45434475490)**（push `9e1823f`，`completed/success`，2026-11-24T16:12:52Z 创建，16:16:08Z 完成，**3m16s**，9/9 job success）
- 权威 job：**[Engine image (build + boot) #138588435469](https://github.com/yiaogit/Sysemble/actions/runs/45434475490/job/138588435469)**（`success`，16:12:55–16:15:35Z，**2m40s**）
- 权威 artifact：`engine-evidence`，id **14942030508**，**235,584,066 B**（未过期，`expires_at=2027-02-22T16:12:53Z`）
- 验收范围：`docs/plan/P1-e2-workplan.md` §2.1 镜像契约、§2.3 容器命令（镜像侧）、§4 **K1–K5**（本文件侧重 K1–K3 与镜像侧 K4/K5）、§6 风险；K6–K10 的桌面/容器后端部分见 [P1-e2b.md](P1-e2b.md)
- 判定原则：编译/测试通过 + 清单与日志自洽 + **独立重算哈希** + 本地镜像侧复跑 → PASS；任何不一致写清证据，不修饰

**判定摘要：K1–K5 PASS（镜像侧），K9/K10 见本文件与 P1-e2b；FAIL 0，BLOCKED 0。结论：`P1-e2a 通过`。**

未只信绿灯：自行下载 artifact（235 MB，含断点续传）、重算 zip/qcow2/boot.log/artifact.json/boot-evidence.json/manifest 的 sha256，与 `artifact.json`、`boot-evidence.json`、CI stdout 三方交叉；本地重跑 `image_test.sh`（96 + 117）并独立解析 qcow2 头；重算 5 条启动断言（直接读 `boot.log` 文本，不只看 JSON）；把 manifest 的 `base` 与 Dockerfile `FROM` 逐字符串比对；把 `image_id` 与产物里的 `build-image.log` 的 image_id 行比对。

---

## 1. 环境与证据获取

### 1.1 本地环境

| 项 | 实际值 |
|---|---|
| OS / 架构 | macOS **26.6.2**（Build 25G83），Darwin **25.6.0**，**arm64** |
| Rust / Cargo | rustc **1.100.0**（0ef1bc386）/ cargo **1.100.0**（3acc79c0c） |
| 工具链 | `CARGO_HOME=/Users/yiao/Documents/linux软件设计框架/.tools/cargo`，`RUSTUP_HOME=.../.tools/rustup` |
| 容器 | Docker Desktop daemon **29.1.2**；本地镜像 `sysemble-engine:0.1.0` = `sha256:568bd6adb2f254fbbfb8c5b3666e8ca11ba2e0167053db390b2dcf76d7ea4138`（amd64，516 MB 磁盘 / 119.6 MB content） |
| Python | `/opt/homebrew/bin/python3` **3.14.3** |
| gh | **2.92.0**（`api.github.com` DNS 失败，用提供的 `/tmp/ghapi.sh` DoH 绕过；脚本未改动） |

### 1.2 证据下载

```bash
mkdir -p /tmp/p1e2-accept
# 第一次 40s curl 超时截断在 222,674,944 B（--max-time 40 是 ghapi.sh 内置的）
/tmp/ghapi.sh /repos/yiaogit/Sysemble/actions/artifacts/14942030508/zip \
  -L --max-time 600 -C - -o /tmp/p1e2-accept/engine-evidence.zip
# exit 0，最终 235,584,066 B，与 artifact 元数据 size_in_bytes 完全一致
shasum -a 256 /tmp/p1e2-accept/engine-evidence.zip
# 36976b9235a97e6c5c9c781dabf887d8993e7114956b0fb0a00c7e83104863db

/tmp/ghapi.sh /repos/yiaogit/Sysemble/actions/runs/45434475490/logs -L -o /tmp/p1e2-accept/run-logs.zip
# 462,012 B；9 个 job 的分 step 日志目录 + 9 个汇总 txt
```

zip 完整性：`zipfile.testzip()` → `None`；解包 8 个文件（见 §3.2）。

---

## 2. 判定摘要

| # | 检查 | 结果 | 一句话结论 |
|---|---|---|---|
| **K1** | 镜像可构建 | **PASS** | CI `build-image.sh` 31s 成功（`#9 DONE 10.4s`、`build-image: built sysemble-engine:0.1.0`）；本机镜像 + 本地 manifest 的 `--verify` 通过 |
| **K2** | 工具齐全 | **PASS** | `image_test.sh --docker` 本机 **117 passed / 0 failed**；CI 同样 117；5 个工具版本非空且与 manifest 的 `tool_versions` 逐字一致 |
| **K3** | 清单一致 | **PASS** | `--verify` 6 条 `verify: OK`；`image_id` 与 `docker image inspect` 一致；`base` digest 与 Dockerfile `FROM` 一致；`packages=205` |
| **K4** | 容器内真实构建（镜像侧） | **PASS** | CI 同一镜像内 `build.sh --execute` 产出 `artifact.json` + `disk.qcow2`，退出码 0；本机独立复跑同样通过（见 e2b §3） |
| **K5** | 容器内启动验证（镜像侧） | **PASS** | `boot-check` UEFI 模式 5 条断言全 pass（CI 31s；本机 TCG 354s），`CONTAINER-SMOKE: pass` |
| **K6–K8** | 探测/装配/门控 | 见 [P1-e2b.md](P1-e2b.md) | 本文件不重复判定 |
| **K9** | 回归 | **PASS** | 61 + 39 + 17/17 + clippy 0 warning（明细见 e2b §5，均由本代理重跑） |
| **K10** | 独立验收 | **PASS** | 本报告 + `P1-e2b.md`，重算哈希、重跑 E2E，未只依赖 CI |

---

## 3. CI 与日志（A 节）

### 3.1 run 与 9 个 job

```bash
/tmp/ghapi.sh /repos/yiaogit/Sysemble/actions/runs/45434475490 | jq '{status,conclusion,created_at,updated_at,head_sha,run_attempt}'
# status=completed conclusion=success created_at=2026-11-24T16:12:52Z updated_at=16:16:08Z
# head_sha=9e1823f20865375e77ffb1dec8f873db6e5475da run_attempt=1
```

| job | 结论 | 起止（UTC） | 耗时 |
|---|---|---|---|
| Engine image (build + boot) | success | 16:12:55–16:15:35 | **160s** |
| Desktop app (check) | success | 16:12:55–16:15:40 | 165s |
| TUI install smoke | success | 16:12:56–16:16:08 | 192s |
| Install smoke (headless) | success | 16:12:55–16:15:59 | 184s |
| Live ISO smoke | success | 16:12:55–16:15:09 | 134s |
| Boot smoke (Debian) | success | 16:12:55–16:15:02 | 127s |
| Desktop smoke (XFCE) | success | 16:12:55–16:14:56 | 121s |
| Rust workspace | success | 16:12:55–16:13:15 | 20s |
| Validate specs | success | 16:12:55–16:13:04 | 9s |

`engine-check` 的 7 个**实质 step**（checkout → upload，step 2–8）全部 `success`，另有 `Set up job`（1）、`Post Run actions/checkout`（16）、`Complete job`（17）三个框架 step 也 success，共 10 个 step 条目。`desktop-check` **包含 clippy step**（step 7 `Clippy the desktop crate`，命令 `cargo clippy --manifest-path apps/desktop/src-tauri/Cargo.toml --all-targets -- -D warnings`），日志 `Finished dev profile ... in 2.29s`，无 warning。

engine job 各 step 耗时（由日志首末时间戳计算）：build **30.5s**、verify **1.4s**、plan **15.3s**、build+boot **88.1s**、upload **17.8s**。

### 3.2 artifact 内容（8 个文件）

| 文件 | 字节 |
|---|---|
| `sysemble-engine.json` | 7,934 |
| `build-image.log` | 62,401 |
| `smoke/container-build.log` | 4,609 |
| `smoke/container-boot-check.log` | 1,684 |
| `smoke/artifact.json` | 1,340 |
| `smoke/boot-evidence.json` | 863 |
| `smoke/disk.qcow2` | 420,937,728 |
| `smoke/boot.log` | 57,599 |

- **raw `disk.img` 未上传**（4 GiB）：workflow 的 upload `path` 列表里本来就没有它，artifact 里也确实没有；本报告不对 raw 内容做任何推断。
- **`smoke/build.log` 未出现在 artifact 里**：upload 日志自己写着 `there will be 8 files uploaded`（workflow 列了 9 条路径）。原因见 §7.1 第 8 条——`container-entry.sh` 按 §2.3 契约**故意不导出** `build.log`，workflow 里那条路径是陈旧条目，`if-no-files-found: warn` 把缺文件吞掉了。这不是 K1–K5 的失败项，但属于 CI 卫生问题。

### 3.3 CI 日志关键行（`2_Engine image (build + boot).txt` 及分 step 日志）

```text
# 4_Build the engine image.txt
#9 exporting manifest list sha256:6c8a1721c5ff948a319adacc926f873dfe3a6099677a02e15add87c6e7a85c09 done
#9 naming to docker.io/library/sysemble-engine:0.1.0 done
build-image: wrote manifest .../engine/image/build/sysemble-engine.json
build-image:   image_id=sha256:6c8a1721c5ff948a319adacc926f873dfe3a6099677a02e15add87c6e7a85c09
build-image:   base=debian:trixie-slim@sha256:8aa5a7bf5a1955bddbe7d74fcdd0b91ab30e74362a8b73af672b0481b35b44a0
build-image:   packages=205
build-image:   elapsed:  31s

# 5_Verify the engine image manifest.txt
PASS  image sysemble-engine:0.1.0 exists locally (sha256:6c8a1721...)
      verify: OK  ref=sysemble-engine:0.1.0 present locally
      verify: OK  image_id=sha256:6c8a1721... matches docker image inspect
      verify: OK  base=debian:trixie-slim@sha256:8aa5a7bf... matches the Dockerfile digest
      verify: OK  tool_versions: mmdebstrap ...; qemu-system-x86_64 ...; grub-mkstandalone ...; xorriso ...; rsync ...
      verify: OK  packages=205
      verify: OK  schema=1 name=sysemble-engine version=0.1.0 platform=linux/amd64
PASS  manifest records verified=true after --verify
PASS  image .Os is linux / PASS image .Architecture is amd64
PASS  container /bin/sh is bash (Rosetta fd > 9 workaround)
Summary: 117 passed, 0 failed

# 7_Build and boot inside the engine container.txt
container-entry: build: /work/builders/debian/build.sh --plan /export/plan.json --out /out --execute
[build] stage 5/6: assemble GPT disk image - rootfs 389 MB, disk 4096 MB
[build] complete (mode: uefi)
boot-check: boot.firmware: pass - matched `EFI v` and `UEFI`
boot-check: boot.grub: pass - matched `GRUB` and `Booting`
boot-check: boot.kernel: pass - matched `Linux version`
boot-check: boot.systemd: pass - matched `systemd[1]` and `Reached target`
boot-check: boot.login: pass - matched `login:`
boot-check: result: pass (31s)
container-smoke: elapsed: 89s
CONTAINER-SMOKE: pass
```

镜像构建只有 1 条已知 warning（`FromPlatformFlagConstDisallowed`：`FROM --platform` 用常量值，这是固定 amd64 的**有意**写法），不构成失败。

---

## 4. Artifact 完整性（B 节，关键）

### 4.1 qcow2：重算哈希 = 清单哈希 = CI stdout 哈希

```bash
cd /tmp/p1e2-accept/art && shasum -a 256 smoke/disk.qcow2
# 7a3bcd532efddf948943698f589f5ee93a0e6f22ee605903bb1f05df707bf0ed  smoke/disk.qcow2
```

| 来源 | 值 |
|---|---|
| 本次重算（420,937,728 B） | `7a3bcd532efddf948943698f589f5ee93a0e6f22ee605903bb1f05df707bf0ed` |
| `smoke/artifact.json` → `images[1].sha256`（qcow2） | `7a3bcd532efddf948943698f589f5ee93a0e6f22ee605903bb1f05df707bf0ed` |
| CI `7_Build and boot...` 的 `artifact sha256` 段 | `7a3bcd53...f822227` |

**三方一致 → qcow2 完整、且与 CI 当次产物同一文件。**

独立结构校验（不依赖 qemu）：

```bash
python3 -c "..."   # 读前 104 字节
magic b'QFI\xfb'  version 3  virtual_size 4294967296 (=4 GiB)  backing_file_offset 0  cluster_bits 16
```

qcow2 头合法、无 backing file、虚拟容量 4 GiB，与 `artifact.json` 的 `size_mb: 4096` 和 `partitions` 布局（512+3584 MiB）自洽。

### 4.2 `disk.img` 的「已记录但无法核验」与一个**真实不一致**

`smoke/artifact.json` 记录 `images[0]`（raw）`sha256=30d55ea1cf07bee39dd4a94a72aa9baf6c7478de79dc4976c0a78a3541123cb7`；CI 日志在同一文件上打印的是 `31820cbee3a26967ba33b35bd6b81f71382ac7d4f7a6aafa710e7f202a0607a4`。

**两者不同不是算错，而是启动验证写坏了 raw 镜像**：`tools/boot-check.sh` 的 UEFI 分支调用 `require_writable_disk`，并以读写在前的 `-drive file=$BOOT_DISK_ABS,format=raw,if=virtio` 挂载（`tools/boot-check.sh:1508,1554`），guest 以 `root=/dev/vda2 rw` 挂载根分区；boot 后 `disk.img` 内容改变，`artifact.json` 里的是**构建时**摘要。本机 E2E 独立复现了同一现象（见 e2b §3.4：288c267f… → 8984c48e…），而 qcow2 未被启动，摘要保持不变。

结论：raw 摘要**不能**用于校验导出的 `disk.img`；qcow2 摘要是可靠的。由于 raw 未上传，本报告不对 raw 内容做 PASS 判定，只记录该口径问题（§7.1 第 5 条）。

### 4.3 `boot.log`：重算 = `boot-evidence.log_sha256`，5 条断言独立复核

```bash
cd /tmp/p1e2-accept/art && shasum -a 256 smoke/boot.log
# b75375aaa6f305fd2af9635e13dcb2590f1aebd6240020f7dc884f7724bb8585
for pat in 'EFI v' 'UEFI' 'GRUB' 'Booting' 'Linux version' 'systemd\[1\]' 'Reached target' 'login:'; do
  grep -c "$pat" smoke/boot.log; done
```

| 断言 id | 依赖的字面量 | `boot.log` 命中（本次独立统计） | 证据行（截断） |
|---|---|---|---|
| `boot.firmware` | `EFI v` + `UEFI` | 1 / 2 | `efi: EFI v2.7 by Debian distribution of EDK II`；`BdsDxe: ... "UEFI Misc Device"` |
| `boot.grub` | `GRUB` + `Booting` | 1 / 3 | `GNU GRUB  version 2.12-9+deb13u4`；`` Booting `Sysemble' `` |
| `boot.kernel` | `Linux version` | 1 | `Linux version 6.12.118+deb13-amd64 ...` |
| `boot.systemd` | `systemd[1]` + `Reached target` | 77 / 16 | `systemd[1]: Reached target paths.target` |
| `boot.login` | `login:` | 1 | `minimal-debian login:` |

`boot-evidence.json`：`result=pass`、`elapsed_seconds=31`、`timeout_seconds=900`、5/5 断言 `pass`、`log=boot.log`、`log_sha256=b75375aa…`（= 重算值）。`artifact.json` 的 `boot.mode=uefi`、`boot.disk=disk.img`、`boot.memory_mb=1024` 与 UEFI 模式的 5 条断言集、`images[0].path=disk.img`（raw）、非桌面 `graphical=false` 自洽；`boot.kernel/initrd` 指向 `rootfs/...`（按 §2.3 不导出，符合预期）。

### 4.4 `sysemble-engine.json` 逐字段校验

```bash
python3 - <<'EOF'   # 关键断言
schema=1 name=sysemble-engine version=0.1.0 ref=sysemble-engine:0.1.0 platform=linux/amd64
base=debian:trixie-slim@sha256:8aa5a7bf...  == Dockerfile FROM（逐字符）
image_id=sha256:6c8a1721...（sha256: + 64 hex 全匹配）
source_date_epoch=1795478400 -> 2026-11-24T00:00:00Z == created
tool_versions: 5 键全部非空，packages: 205 条，verified=True
EOF
```

| 字段 | 值 | 判定 |
|---|---|---|
| `schema` / `name` / `version` / `ref` / `platform` | `1` / `sysemble-engine` / `0.1.0` / `sysemble-engine:0.1.0` / `linux/amd64` | 与 §2.1 冻结表一致 |
| `base` | `debian:trixie-slim@sha256:8aa5a7bf5a1955bddbe7d74fcdd0b91ab30e74362a8b73af672b0481b35b44a0` | 与 `engine/image/Dockerfile:16` 的 `FROM` **逐字相同** |
| `image_id` | `sha256:6c8a1721c5ff948a319adacc926f873dfe3a6099677a02e15add87c6e7a85c09` | 64 位 sha256；出现在 **`build-image.log` 的 `image_id=` 行**（且出现在 `#9 exporting manifest list` 行，两者相同） |
| `source_date_epoch` ↔ `created` | `1795478400` ↔ `2026-11-24T00:00:00Z` | 自洽；与 Dockerfile `ARG SOURCE_DATE_EPOCH=1795478400` 一致 |
| `tool_versions` | mmdebstrap 1.5.7 / QEMU 10.0.13 / GRUB 2.12-9+deb13u4 / xorriso 1.5.6 / rsync 3.5.0 | 5 键非空；与 `image_test.sh --docker` 容器内探测输出一致 |
| `packages` | 205 条 | 与 CI `verify: OK packages=205` 一致；**格式为 `name:arch=version`**（124/205 带 `:amd64`），与 §2.1 示例的 `name=version` 有出入（§7.1 第 11 条） |
| `verified` | `true` | `--verify` 后原子重写 |

补充：`image_id` 是 buildx 产出的 **manifest list（含 attestation manifest）digest**，不是单平台 image config digest；`docker image inspect {{.Id}}` 在 containerd 存储下返回同一值，因此 `--verify` 自洽。若将来有消费方按 OCI image manifest digest 解析，需要额外取 `linux/amd64` 子 manifest。

---

## 5. 本机镜像侧复跑（C 节第 7 项）

```bash
bash engine/image/tests/image_test.sh
# Summary: 96 passed, 0 failed, 1 skipped   （SKIP docker checks）

bash engine/image/tests/image_test.sh --docker
# PASS  image sysemble-engine:0.1.0 exists locally (sha256:568bd6ad...)
# PASS  manifest .../engine/image/build/sysemble-engine.json exists
#       verify: OK  ref / image_id / base / tool_versions / packages=205 / schema...
# PASS  manifest records verified=true after --verify
# PASS  image .Os is linux / PASS image .Architecture is amd64
# PASS  container /bin/sh is bash (Rosetta fd > 9 workaround)
# PASS  container: mmdebstrap/qemu-system-x86_64/grub-mkstandalone/xorriso/rsync --version 非空
# PASS  dpkg -l lists mmdebstrap qemu-system-x86 grub-efi-amd64-bin ovmf xorriso rsync
# Summary: 117 passed, 0 failed
```

- 本地 `image_id=sha256:568bd6adb2f254fbbfb8c5b3666e8ca11ba2e0167053db390b2dcf76d7ea4138`（本地 `build-image.log` 的 `#8 exporting manifest list` 行），与 CI 的 `6c8a1721…` **不同**——这正是「非 bit-for-bit 可复现」的直接证据（apt 源漂移 + 层缓存），不是缺陷，但必须如实登记。
- 本地 manifest 的 `base` 与 Dockerfile 相同、`packages=205`、`verified=true`，与 CI artifact 的 manifest 结构一致（sha256 不同：`318807e7…` vs `953174e1…`，差异来自 `image_id`）。
- 本地 apt 安装层是 `#5 CACHED`（`engine/image/build/build-image.log`），即本机镜像并非本次从零重建；因此 K1 的**本机**证据是「镜像存在 + manifest + `--verify` 通过」，**CI 的从零构建证据来自 `build-image.log`**。这一点在 §8 明确列出，不把本地缓存构建冒充为从零构建。

---

## 6. K1–K5 对照（§4 验收矩阵）

| # | 通过条件 | 结果 | 证据（文件/日志行/命令） |
|---|---|---|---|
| **K1** | `build-image.sh` 在 amd64 本机/CI 成功 | **PASS** | CI：`4_Build the engine image.txt` 的 `#9 DONE 10.4s`、`build-image: built sysemble-engine:0.1.0`、`elapsed: 31s`；产物 `build-image.log`（62,401 B，zip 内）；本机：`engine/image/build/build-image.log` + `image_test.sh --docker` 的 `ref=... present locally` |
| **K2** | 容器内 5 工具版本均非空 | **PASS** | 本机 `image_test.sh --docker` 117/117（含 5 条 `--version` 非空 + 6 条 `dpkg -l`）；CI 同脚本同结果；`sysemble-engine.json.tool_versions` 5 键非空 |
| **K3** | `--verify` 通过；image_id 与 inspect 一致；base digest 与 Dockerfile 一致 | **PASS** | CI `5_Verify...txt` 6 条 `verify: OK` + `PASS manifest records verified=true`；本机同 6 条（本地 image_id）；`engine/image/Dockerfile:16` 与 manifest `base` 逐字比对；`packages=205` |
| **K4**（镜像侧） | 同一镜像内 `build.sh --execute` 产出 artifact.json + qcow2，退出码 0 | **PASS** | CI `7_...txt`：`container-entry: build:` → `[build] complete (mode: uefi)` → `exported artifact.json/disk.img/disk.qcow2/grub.cfg/plan.copy.json` → `OK artifact.json` / `OK qcow2`；qcow2 420,937,728 B 与重算哈希一致 |
| **K5**（镜像侧） | 同一镜像内 `boot-check` 断言通过，TCG | **PASS** | CI `boot-check: result: pass (31s)` + 5/5 断言；本机 TCG 354s 同样 5/5；两份 `boot.log` 均有 `Booting paravirtualized kernel on bare hardware`（非 KVM paravirt），CPU 为 QEMU 默认 TCG 型号 `AMD QEMU Virtual CPU version 2.5+` |

> 关于「TCG，无 KVM」：CI 的 `boot.log` 里有 `kvm_amd: Nested Virtualization enabled` 等行，一度像是用了 KVM。核对后确认这是 **guest 内核在 x86_64 TCG 下加载 `kvm_amd` 模块**（QEMU `qemu64` 型号暴露 SVM）；同一份 CI `boot.log` 明确写着 `Booting paravirtualized kernel on bare hardware`，且 `boot-check.sh` 没有任何 `-enable-kvm/-accel` 参数。本机（macOS，物理上不可能有 KVM）用同一镜像跑出的 `boot.log` 是 `Booting paravirtualized kernel on bare hardware` 且**没有** `kvm_amd` 行（ARM 上的 x86 TCG 不暴露 SVM）。因此 K5 的 TCG 判定成立，CI 日志里的 `kvm_amd` 行不是 KVM 证据。

---

## 7. 风险与未验证项

### 7.1 发现（按严重度排序，均非 K1–K5 失败）

1. **Windows 无真机验证（未验证）**：CI 只有 `ubuntu-latest`（9/9 job 都 `runs-on: ubuntu-latest`，无 windows/macos job）。README 的跨平台表把 Windows x86_64/arm64 写成「Docker Desktop / WSL2 container」，但取消在 Windows 走 `taskkill /PID /T /F`（`build.rs:732-743`），且 `configure_process_group` 在非 unix 是空实现；**该路径没有在任何 Windows 上执行过**。另外宿主 `dry-run` 走 `Command::new("bash")`，Windows 需要 PATH 里有 bash（Git Bash/WSL），这一点同样未验证。**不能把 Windows 计入 PASS 证据。**
2. **VZ / WSL2 未实现（顺延）**：`engine/` 只有 `image/`、`runtime/`，全仓库无 `VZVirtualMachine`/`virtiofs`/`wsl.exe` 引用；`docs/roadmap.md`、`engine/image/README.md` 均已写明顺延 P1-e3。符合非目标，但不能作为「macOS/Windows 原生引擎可用」的证据。
3. **镜像非 bit-for-bit 可复现（已知限制，已文档化）**：同一 HEAD 下 CI 镜像 `6c8a1721…`、本机镜像 `568bd6ad…`；两份 artifact.json 的差异只有 `createdAt` 和两个镜像哈希（本机 E2E vs CI，见 e2b §3.5）。base 按 digest 固定、`SOURCE_DATE_EPOCH=1795478400` 已记录，但 `apt-get install` 解析的是实时 Debian 镜像，包版本事后才写入 manifest。`engine/image/README.md` 的 “Known limits → apt drift” 已如实说明，**不应对外宣称可复现构建**。
4. **privileged 容器不是安全边界（已知限制）**：`--privileged` 是 mmdebstrap `chroot` 的硬需求，`engine/image/README.md` 写明「local, one-shot build sandbox, **not** a security boundary」。但 **UI 未展示该提示**（`apps/desktop/ui/app.js` 只显示 `Engine: container · docker` 与 reason），§2.3「在 UI/文档中写明」目前只由文档满足。
5. **raw `disk.img` 的摘要口径（真实不一致）**：`artifact.json` 记录 `30d55ea1…`，CI `container_smoke.sh` 在 boot 后算出 `31820cbe…`。原因是 boot-check 以读写方式启动 raw 镜像（guest `root=/dev/vda2 rw`）。qcow2 不受影响。建议在 artifact 契约里注明 raw 摘要是「boot 前」摘要，或校验时排除 raw。
6. **apt 漂移**：即使 base digest 固定，`apt-get update` 后的包集合仍随镜像源变化；`packages=205` 是当次快照。重跑同一命令不保证 205 条完全相同（本次恰好相同）。
7. **本地镜像 `--docker` 复跑针对的是本机镜像**：`verify: OK image_id=568bd6ad…` 证明的是本机镜像与本机 manifest 自洽；CI 镜像 `6c8a1721…` 的自洽性由 CI 日志（同一 run、同一 job）证明。两者不能互相替代，报告中已分开陈述。
8. **CI 上传路径含一条永不存在的文件**：`.github/workflows/ci.yml` 的 upload `path` 列了 `engine/image/build/smoke/build.log`，但 `container-entry.sh` 按契约不导出 `build.log`，upload 日志显示实际只有 8 个文件。`if-no-files-found: warn` 让这个不一致静默通过。建议删掉该路径或显式生成。
9. **workplan §1 架构图仍是 v1 挂载**：`docs/plan/P1-e2-workplan.md:37` 写 `-v <repo>:/work [-v <out>:/out when outside repo]`，与同文件 §2.3 冻结的 v2（`/work:ro` + `/export` + 容器内 `/out`）矛盾。代码与 CI 实现的是 v2，**文档内部不一致**，建议修正 §1 图。
10. **`engine/image/README.md` 两处陈旧表述**：开头写「Frozen contract: … sections 2.1 and 5」，容器契约实际在 §2.3；「CI」小节写 ci-snippet「is a fragment on purpose — this slice does not edit the real workflow」，但 `.github/workflows/ci.yml` 已经包含该 job（本次 run 就是它跑的）。不影响功能，属文档保鲜问题。
11. **manifest `packages` 格式与 §2.1 示例不同**：实际是 `dpkg-query ${binary:Package}=${Version}`，多架构包带 `:amd64`（124/205）。`--verify` 只校验 `packages=205`（数量），`image_test.sh` 校验的是 Dockerfile/镜像里必需包是否存在，二者都不校验 manifest 中 `packages` 的字符串格式；暂无消费方，属低风险口径问题。
12. **验收开始时工作区不干净**：唯一修改是 `docs/plan/P1-e2-workplan.md` 的 3 行状态表（17:18:57，主线程在我启动前修改）。契约章节与 HEAD 逐字一致；本报告所有代码判定基于 HEAD `9e1823f`，CI 也跑在该 SHA 上。若要求「工作区干净」作为验收前提，此项需主线程提交或回滚后再验收。
13. **镜像体积**：本机 `docker image ls` 显示 516 MB 磁盘 / 119.6 MB content，与 README 的「约 120 MB 压缩 / 500 MB 磁盘」一致，不构成风险。

### 7.2 未验证/已知限制（不得计入 PASS 证据）

- Windows 真机（含 Docker Desktop on Windows、NTFS 大小写、`taskkill` 取消）——**未验证**。
- macOS 上 Virtualization.framework 原生引擎、Windows WSL2 helper——**未实现**（E2c）。
- 镜像 bit-for-bit 复现——**不成立**（见上）。
- 非 x86_64 目标（arm64 构建目标）——本切片非目标。
- 签名/SBOM/registry 分发——非目标。
- `--platform linux/amd64` 在 Apple Silicon 走 Rosetta 的性能——本次本机实测受并发负载影响（见 e2b），不作为性能基线。

---

## 8. 「未只信 CI」清单

1. **重算哈希（对象 → 期望值 → 结论）**：artifact zip `36976b92…`（235,584,066 B，与 GitHub 元数据一致）；`disk.qcow2` `7a3bcd53…`（= artifact.json = CI stdout）；`boot.log` `b75375aa…`（= boot-evidence.json）；`artifact.json` `c4b456bf…`（= CI stdout）；`boot-evidence.json` `679ed622…`（= CI stdout）；`sysemble-engine.json` `953174e1…`（解包前后一致）。
2. **独立重跑测试**：`image_test.sh`（96 passed / 1 skipped）、`image_test.sh --docker`（117 passed）；`cargo test --workspace`（61）、桌面 crate（39）、`clippy -D warnings`（0 warning）；`tests/acceptance/run.sh`（17/17）；`tools/validate.py`（all specs valid）。
3. **独立重跑镜像侧 E2E**：在本机用 `sysemble-engine:0.1.0` 完整跑 `container_smoke.sh`（build + UEFI boot），`CONTAINER-SMOKE: pass`（详见 P1-e2b §3）。
4. **不依赖 JSON 的断言复核**：直接从 `boot.log` 文本 grep 5 组字面量；直接解析 qcow2 头（magic/version/virtual size/backing file）。
5. **跨源交叉**：manifest `base` 与 `Dockerfile:16` 逐字符比对；manifest `image_id` 与 artifact 内 `build-image.log` 的 `image_id=` 行比对；`source_date_epoch` 与 `created` 互算；CI 日志中的 4 个 artifact sha256 与本次下载逐一对齐。
6. **未做的复现（明确声明）**：没有在本机从零 `--no-cache` 重建镜像（会改写 `engine/image/build/`，超出只写两个验收文件的边界），K1 的本机侧只用「已有镜像 + manifest + `--verify`」作证；没有对 raw `disk.img` 做任何内容判定（未上传）。

---

*本报告只写入了 `docs/acceptance/P1-e2a.md` 与本轮同批的 `docs/acceptance/P1-e2b.md`；未执行 `git add/commit/push`，未修改代码、配置、README、plan 或其它任何文件。证据目录保留在 `/tmp/p1e2-accept/`（含 zip 原包、解包产物、日志与本地 E2E 输出）。*
