# P1-e2 工作分解：引擎镜像与容器后端

> P1-e 的终态是 macOS/Windows 上的 Linux 引擎 VM。本切片先把「引擎」做成**可 CI 端到端验证**的形态：一个版本化的 Debian 引擎 OCI 镜像 + docker/podman 运行时 + 桌面端探测与构建接管。原生 Virtualization.framework / WSL2 helper 顺延到 E2c，不在本切片承诺可交付。

- 日期：2026-11-24
- 基线提交：`b13956e`（P1-e1）
- 上游：`docs/plan/P1-e1-workplan.md`（已预留 docker/ssh 引擎）

## 0. 决策与证据

brief 建议 VZ（macOS）/ WSL2（Windows）。派工前实测：

| 事实 | 证据 |
|---|---|
| 本机 VZ 框架可用，但未签名进程被拒 | `VZVirtualMachineConfiguration.validate()` → `VZErrorDomain Code=2 ... doesn't have the com.apple.security.virtualization entitlement` |
| ad-hoc 签名可拿到 entitlement | `codesign --force --sign - --entitlements ent.plist` 后同一调用不再报 entitlement 错 |
| Docker Desktop 已安装且可启动 | `open -a Docker` → 2s 后 `docker info` 成功，Server 29.1.2 |
| arm64 宿主机可跑 `linux/amd64` | `docker run --platform linux/amd64 alpine uname -m` → `x86_64`（Rosetta），buildx platforms 含 amd64 |
| 宿主 bind mount 大小写不敏感会破坏 Debian rootfs | 引擎镜像内实测：`-v /tmp/case-test:/m` 后 `ln -s pam.7.gz /m/PAM.7.gz && echo > /m/pam.7.gz` → `Too many levels of symbolic links`；容器自身 fs 下同一操作正常 |
| 同一构建在本机失败的直接证据 | `/tmp/e2a-out/build.log`：`libpam-runtime ... PAM.7.gz.dpkg-new: Too many levels of symbolic links` → mmdebstrap 失败 |

结论：

1. **容器后端优先**。README 的架构本来就写的是 “Build sandbox (podman, rootless)”，P1-e1 workplan 也写明 docker/ssh 引擎在 P1-e2 加，因此这不是改架构，而是把既定后端提前落地。
2. **VZ/WSL2 顺延 E2c**。VZ 需要签名 + entitlement，Windows/WSL2 本机完全无法验证，macOS CI runner 又是嵌套虚拟机，真实启动无法作为 CI 证据。E2c 只做探测与文档，不阻塞本切片。
3. **引擎目标架构固定 x86_64**。P0–P1 的 GRUB/OVMF/boot-check 全是 amd64；ARM 目标在 roadmap 里是 P3 之后。引擎镜像固定 `linux/amd64`，在 Apple Silicon 上走 Rosetta / qemu binfmt。
4. **容器只接管 execute**。`--dry-run` 继续在宿主机 bash 跑（macOS 上已可用），这样引擎镜像缺失时用户仍能验证 spec/plan。
5. **不碰 builder 契约**。容器内执行同一份 `builders/debian/build.sh`，不复制、不 fork。

## 1. 架构

```
Tauri desktop (macOS / Windows / Linux)
  engine_info() ──► probe 顺序: local(Linux root+tools) → container(docker|podman) → none
  start_build(execute) ──► docker run --rm --init --privileged --platform linux/amd64
                             --name sysemble-build-<id>
                             -v <repo>:/work:ro  -v <out>:/export
                             -w /work  <image>
                             bash engine/runtime/container-entry.sh \
                               --plan /export/plan.json --out /out --export /export --mode execute
                                   │
                                   ▼
                        sysemble-engine:0.1.0 (Debian trixie)
                        mmdebstrap · qemu-system-x86 · grub-efi-amd64-bin
                        ovmf · xorriso · squashfs-tools · rsync · gdisk · jq
                                   │
                                   ▼
                        container /out (case-sensitive) → export top-level files
                        <out>/artifact.json + disk.img + qcow2/iso (+ live build.log)
```

宿主与容器只通过挂载共享：仓库只读挂到 `/work`，宿主 out 挂到 `/export`；rootfs 在容器内 `/out` 构建（大小写敏感）。日志仍由桌面进程把子进程 stdout/stderr 写到宿主 `<out>/build.log`。

## 2. 冻结接口

### 2.1 引擎镜像

| 项 | 值 |
|---|---|
| 默认引用 | `sysemble-engine:0.1.0` |
| 版本文件 | `engine/image/version`，单行 `0.1.0` |
| 平台 | `linux/amd64` |
| 基础镜像 | `debian:trixie-slim@sha256:<digest>`，digest 写死在 Dockerfile |
| 构建脚本 | `engine/image/build-image.sh --ref <ref> --out <dir> [--platform linux/amd64] [--no-cache]` |
| 校验 | `engine/image/build-image.sh --verify <dir>` 比对 manifest 的 image id 与本地镜像 |
| 清单 | `<out>/sysemble-engine.json`（不提交，CI artifact） |

清单字段（冻结）：

```json
{
  "schema": 1,
  "name": "sysemble-engine",
  "version": "0.1.0",
  "ref": "sysemble-engine:0.1.0",
  "platform": "linux/amd64",
  "base": "debian:trixie-slim@sha256:...",
  "image_id": "sha256:...",
  "source_date_epoch": 1732406400,
  "created": "2026-11-24T00:00:00Z",
  "tool_versions": {"mmdebstrap": "...", "qemu-system-x86_64": "...", "grub-mkstandalone": "...", "xorriso": "...", "rsync": "..."},
  "packages": ["name=version", "..."],
  "verified": true
}
```

`--verify` 必须：ref 存在、`image_id` 与 `docker image inspect` 一致、`base` 的 digest 与 Dockerfile 一致、`tool_versions` 非空。
镜像内必须同时具备构建与启动验证工具，使 CI 可在**同一容器内**完成 build + boot-check。

### 2.2 `engine_info` JSON（向后兼容，只增字段）

```json
{
  "kind": "local|container|none",
  "available": true,
  "platform": "macos",
  "reason": "container engine: docker 29.1.2 · image sysemble-engine:0.1.0",
  "runtime": "docker|podman|null",
  "image": "sysemble-engine:0.1.0|null",
  "image_present": true
}
```

规则：

| 场景 | kind | available | reason 要点 |
|---|---|---|---|
| Linux root + 工具齐 | `local` | true | local Linux builder |
| 容器 daemon 可达且镜像存在 | `container` | true | runtime 版本 + image |
| 容器 daemon 可达但镜像缺失 | `container` | false | 指向 `engine/image/build-image.sh` |
| daemon 不可达 | `none` | false | docker/podman 错误摘要 + “start Docker Desktop” |
| 其它宿主 | `none` | false | 缺什么写什么 |

- 探测顺序：`local`（仅 Linux）→ `container`（docker → podman）→ `none`。
- 每条探测命令 **4s 超时**；超时/失败只降级，不返回 Err（`engine_info` 契约不变）。
- 兼容 P1-e1 字段 `kind/available/platform/reason`；新增字段为 `runtime/image/image_present`，`null` 可接受。
- 环境变量覆盖（测试/高级用户）：`SYSEMBLE_ENGINE_IMAGE`（镜像引用）、`SYSEMBLE_ENGINE_RUNTIME`（运行时可执行文件路径，测试用）。既有 `SYMBLE_BUILDER` 拼写保留。

### 2.3 容器构建命令（冻结参数与顺序，v2）

> v1 把宿主 `<out>` 直接挂到容器 `/out` 并让 mmdebstrap 往里写 rootfs。E2a 本机实测失败：macOS APFS 默认大小写不敏感，Debian 包内 `PAM.7.gz → pam.7.gz` 这类同名异大小写路径在挂载目录里变成自指符号链接（ELOOP），dpkg 解包 `libpam-runtime` 失败。v2 因此改为：**构建在容器自身的大小写敏感文件系统里完成，结束后只把顶层产物导出到宿主 out**。

```
<runtime> run --rm --init --privileged --platform linux/amd64
  --name sysemble-build-<id>
  -v <repo>:/work:ro
  -v <out>:/export
  -w /work
  <image>
  bash engine/runtime/container-entry.sh --plan /export/plan.json --out /out --export /export --mode execute
```

- `engine/runtime/container-entry.sh`（容器内执行）：跑 `build.sh --plan /export/plan.json --out /out --execute`，成功后把 `/out` 的**顶层常规文件**（artifact.json、disk.img、disk.qcow2、*.iso 等）复制到 `/export`；`build.log` 不复制（桌面已把 stdout 流式写入宿主 log）。失败时保留 builder 退出码，不导出半成品。
- 容器内路径全部 ASCII：`repo→/work`（只读）、宿主 out→`/export`、构建目录→容器内 `/out`。宿主绝对路径（含中文）只出现在 `-v` 挂载源。
- 导出清单的边界：`rootfs/`、`iso/`、`esp/` 等目录不导出。因此容器构建的产物可在容器内做完整 boot-check，但**宿主上的 kernel 模式 boot-check 不可用**（artifact 的 `images[].path`/`disk.img` 会导出，`rootfs/boot/*` 不会）；P1-e2 的启动验证在容器内完成。
- 取消：先按现有进程组终止 `docker run` 客户端，再 best-effort `docker kill <name>`（`--rm` 会在停止后清理容器）。
- `--privileged` 是 mmdebstrap chroot 的硬需求，在 UI/文档中写明这是本地构建沙箱。
- 容器模式仅用于 `execute`；`dry-run` 保持 `bash <builder>` 宿主执行。

## 3. 切片与写入边界

| 切片 | 内容 | 写入边界 | 状态 |
|---|---|---|---|
| **E2a** 引擎镜像 | Dockerfile、build-image.sh、静态/在线测试、容器内 build+boot smoke、README、CI job 片段 | `engine/image/**` | 已交付（本机 K1–K5，CI `engine-check` 绿） |
| **E2b** 桌面容器后端 | `engine_info` 探测扩展、容器命令装配、execute 接管、取消、UI 文案、单测 | `apps/desktop/**` | 已交付（39 桌面测试 + 本机 E2E 通过） |
| **E2c** 原生 VM（顺延） | VZ/WSL2 helper、镜像分发、virtiofs、vsock | `engine/vm/**`（后续） | 不做 |
| **E2d** 独立验收 | 下载 CI artifact、重算 sha256、核对日志与镜像清单 | `docs/acceptance/**` | 验收中（run `45434475490`） |
| 集成 | CI job、A10 允许目录、README/roadmap、提交/推送 | 主线程 | 进行中 |

## 4. 验收矩阵

| # | 检查 | 通过条件 | 证据来源 |
|---|---|---|---|
| K1 | 镜像可构建 | `build-image.sh` 在 amd64 本机/CI 成功 | 本机 + CI 日志 |
| K2 | 工具齐全 | 容器内 `mmdebstrap/qemu-system-x86_64/grub-mkstandalone/xorriso/rsync` 版本均非空 | `image_test.sh --docker` |
| K3 | 清单一致 | `--verify` 通过；image_id 与本地 inspect 一致；base digest 与 Dockerfile 一致 | `image_test.sh --docker` |
| K4 | 容器内真实构建 | 容器内 `build.sh --execute` 产出 `artifact.json` + qcow2，退出码 0 | CI `engine-check` |
| K5 | 容器内启动验证 | 同一镜像内 `boot-check.sh` 断言通过（TCG，无 KVM） | CI `engine-check` |
| K6 | 探测正确 | macOS 有 daemon+镜像 → `container/available`；删镜像/停 daemon → `none` 或 `container/available=false`，reason 可读 | 本机 + 单测 |
| K7 | 命令装配 | 假 runtime 记录 argv，断言挂载/平台/`--privileged`/容器内路径/`--name` | 桌面单测 |
| K8 | 门控 | execute 无引擎时返回明确错误；dry-run 不受影响；UI Build 禁用/启用 | 桌面单测 + UI 逻辑 |
| K9 | 回归 | 根 workspace 61、桌面原有 17、acceptance 17/17、clippy 全绿 | 本机 |
| K10 | 独立验收 | 验收代理下载 artifact、重算 sha256、核对 manifest/日志，写 `docs/acceptance/P1-e2a.md`、`P1-e2b.md` | 验收报告 |

## 5. CI

新增 job `engine-check`（ubuntu-latest，timeout 45 min）：

1. checkout + rust toolchain；
2. `engine/image/build-image.sh --ref sysemble-engine:0.1.0 --out engine/image/build`；
3. `engine/image/tests/image_test.sh --docker`；
4. `cargo run -q -p sysemble-cli -- plan examples/minimal-debian.yaml > /tmp/plan.json`；
5. 容器内真实构建 + boot-check：`engine/image/tests/container_smoke.sh`；
6. 上传 `engine/image/build/sysemble-engine.json`、构建日志、`artifact.json`、`boot-evidence.json`。

现有 7 个 job 不动；`desktop-check` 增加 clippy `-D warnings`（P1-e2b 同步）。

## 6. 风险

1. **amd64 仿真速度**：Apple Silicon 上 apt/mmdebstrap 走 Rosetta，可能 15–40 min；CI 是原生 amd64，不受影响。若本机超时，只记录 CI 证据。
2. **Docker Desktop 依赖**：macOS/Windows 用户必须装 Docker Desktop（或 podman machine）。E2c 原生 VM 才是免依赖路径；文档必须写清。
3. **无 Windows 验证**：本机只能证明 macOS + Linux CI；Windows 路径复用同一探测/命令代码，不做真机声明。
4. **privileged 容器**：mmdebstrap 需要；沙箱边界是“本地一次性容器”，不是安全隔离，README 说明。
5. **可复现性**：固定 base digest + `SOURCE_DATE_EPOCH` + 记录 dpkg 版本，但 apt 仓库漂移使镜像不是 bit-for-bit 可复现；签名/SBOM 标准格式在 P3，不在本切片宣称。
6. **大小写不敏感宿主**：macOS APFS 默认大小写不敏感，rootfs 直接写宿主挂载目录会让 dpkg 的 `PAM.7.gz`/`pam.7.gz` 变成 ELOOP。v2 已改为容器内构建 + 顶层产物导出；CI（ext4）与 Windows（NTFS + Docker Desktop VM）同样走该路径，避免平台分叉。
7. **非 ASCII 路径**：本机仓库路径含中文，容器内映射到 `/work`/`/export` 规避；导出目录里的文件名本身是 ASCII。CI 路径为 ASCII，两边都要测。
8. **启动验证会改写 raw 盘**：boot-check 以读写方式启动 raw `disk.img`，boot 后它的 sha256 与 `artifact.json` 记录不再一致（qcow2 未被启动，保持一致）。验收/报告必须区分这一点，不能用 boot 后的 raw 反推产物损坏。
9. **macOS CI 嵌套虚拟化**：不尝试在 macOS runner 启动 VZ；E2c 的真实验证只在真机。
10. **镜像体积**：含 qemu/grub/ovmf，约 516 MB 磁盘占用；不做分发 registry，本地构建。

## 7. 非目标

- 不改 `builders/debian/**` 的接口与行为。
- 不做 arm64 目标构建（P3）。
- 不做 cosign 签名、CycloneDX SBOM、OCI registry 推送。
- 不做 VZ / WSL2 原生 helper（E2c）。
- 不做镜像增量缓存/预热。
