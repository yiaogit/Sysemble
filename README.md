# Sysemble

**Assemble your own Linux.**

Sysemble is a local-first desktop application for composing a complete Linux system — base, desktop, applications, a Windows VM layer, and development environments — from a declarative spec, then building and verifying it on your own machine.

> **Status: P1-e3 prototype (v0.0.1).** The engine builds, boots, installs, and runs a live ISO in CI. The Tauri shell validates/plans, runs and tails builds, renders a six-layer view, and reports whether real builds are possible. The engine ships as a versioned Debian OCI image (`engine/image`) that the shell runs through Docker Desktop or podman on macOS/Windows and through the local builder on Linux. `engine/vm` adds a Virtualization.framework prototype that boots an arm64 Debian engine VM on Apple Silicon, shares repo/out via virtiofs, and runs a real build inside the guest; it is a CLI prototype not yet wired into the shell. WSL2 and desktop integration remain future work. See [docs/roadmap.md](docs/roadmap.md).

---

## Why

Building a personal or team Linux system today means choosing between:

- a stock distro that almost fits,
- a pile of post-install scripts that nobody can reproduce,
- or a cloud builder that ships your recipes and artifacts to someone else's servers.

Sysemble takes a fourth path: **a local workbench**. It runs on Windows, macOS, and Linux, keeps every spec and artifact on your machine, and treats the system as a stack of composable layers instead of a shell script.

The design borrows the useful parts of hosted builders — spec-as-truth, state separation, evidence, agent tooling — and drops the parts that don't fit a desktop: accounts, queues, quotas, and the cloud.

## What it does

- **Conversation → spec.** An assistant interviews you in structured questions and writes a reviewable `buildspec.yaml`. It never free-hands shell commands.
- **Visual assembly.** A layer canvas shows base → kernel → desktop → apps → Windows VM → dev environment, with size and time estimates per layer.
- **Local build.** Builds run inside the disposable, versioned Linux engine image (docker/podman), never directly on your host.
- **Boot verification.** Every artifact is booted in QEMU and checked against assertions before it is called usable.
- **Windows apps that feel native.** Pick per-application integration: Wine, RDP RemoteApp, full desktop VM, or GPU passthrough + Looking Glass.
- **Team artifacts.** Share a signed spec plus SBOM and build evidence; reproduce the same image on every device.
- **Agent-ready.** A local MCP server exposes ~20 tools so Claude Code, Codex, or any MCP client can drive builds — with read/write/destructive permissions.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│ Tauri 2 UI (native webview, Windows / macOS / Linux)        │
│  conversation · layer canvas · diff · build console · preview│
└───────────────────────────┬─────────────────────────────────┘
                            │ local IPC
┌───────────────────────────▼─────────────────────────────────┐
│ Sysemble engine (same Linux daemon on every host)           │
│  spec store · resolver · state machine · job runner         │
│  evidence store (SQLite + CAS) · MCP server (stdio/HTTP)    │
└───────────────────────────┬─────────────────────────────────┘
                            │
┌───────────────────────────▼─────────────────────────────────┐
│ Engine image (engine/image, docker/podman)                  │
│  rootfs → configure → image (ISO / qcow2 / raw / UKI)       │
│  → QEMU boot → assertions → evidence → export               │
└─────────────────────────────────────────────────────────────┘
```

The engine always runs on Linux. On macOS it currently runs in the Linux VM
provided by Docker Desktop or podman; `engine/vm` is a native
Virtualization.framework prototype (arm64 guest, CLI only, not yet in the shell).
On Windows it runs in Docker Desktop/WSL2. The UI stays native.

## Cross-platform hosts

| Host | Engine | Native target | x86_64 target |
|---|---|---|---|
| Windows x86_64 | Docker Desktop / WSL2 container | x86_64 | native |
| Windows arm64 | Docker Desktop / WSL2 container | arm64 | qemu (amd64 engine, slow) |
| macOS arm64 | Docker Desktop / podman (amd64 engine image) | arm64 | Rosetta for Linux / qemu |
| Linux x86_64 | native (root) or docker/podman | x86_64 | native |
| Linux arm64 | native (root) or docker/podman | arm64 | qemu-user (slow) |

Host support means the app runs everywhere; build targets are always Linux.
The container engine is verified on macOS arm64 (local E2E) and Linux CI; the
Windows path and native Virtualization.framework/WSL2 helpers (P1-e3) are
implemented/planned but not yet verified on real hardware.

## Base spectrum

| Level | Base | Typical size | Build time | For |
|---|---|---|---|---|
| L0 | Alpine / Buildroot | < 300 MB | 5–15 min | appliances, servers, learning |
| L1 | Debian/Ubuntu minbase | 300–600 MB | 10–25 min | minimal desktops, custom stacks |
| L2 | Base + desktop | 2–4 GB | 20–45 min | daily-driver workstations |
| L3 | Official ISO remaster | 3–6 GB | 15–30 min | hardware compatibility first |
| L4 | Linux From Scratch | 3–8 GB | 8–20 h | expert lab, teaching |

The assistant recommends a level from your answers (purpose, apps, hardware, maintenance appetite, disk/time budget) and requires explicit acknowledgement before L4.

## Windows apps, native-feeling

| Mode | How it feels | Requires |
|---|---|---|
| `wine` | native window, no VM | app compatibility |
| `remoteapp` | individual Windows windows on the Linux desktop | Windows Pro/Enterprise, RDP |
| `desktop` | full Windows desktop in a window | 4–8 GB RAM |
| `looking-glass` | low-latency Windows desktop | second GPU, VFIO |

`remoteapp` is the default recommendation for line-of-business apps; the interview asks which apps, whether they need a GPU, and which Windows edition you own.

> Sysemble never downloads or distributes Windows media or activation. You supply the ISO and licence.

## Team artifacts

A team publishes a **bundle**, not a snowflake machine:

```
bundle/
  buildspec.yaml        # signed, reviewable
  plan.json             # resolved: packages, sizes, digests
  sbom.cdx.json         # CycloneDX
  evidence.json         # build + boot assertions
  signature.sig         # cosign / minisign
```

Specs live in Git, artifacts in any OCI registry. `sysemble verify` checks signature, SBOM, and evidence before a device is allowed to install.

## Repository layout

```
docs/          design, ADRs, roadmap, plans, acceptance reports
spec/          JSON Schemas for buildspec and module
examples/      runnable example specs
crates/        Rust workspace (plan resolver, CLI)
builders/      Debian rootfs/disk/ISO builder and installer assets
engine/        engine image (Dockerfile, manifest), container entry point, VM prototype
apps/desktop/  Tauri 2 shell (separate cargo workspace)
tools/         boot/install checks, schema validation
tests/         black-box acceptance suite
```

## Roadmap

| Phase | Scope |
|---|---|
| P0 | CLI + Debian base + 10 modules + qcow2 + QEMU boot + 3 assertions |
| P1 | Tauri UI: canvas, diff, console, preview; ISO + installer; container engine |
| P2 | Windows app modes, dev profiles, local MCP server |
| P3 | Arch/Nix backends, team bundles, signing, multi-device provisioning |

## Contributing

The design is in [docs/design/0001-sysemble-design.md](docs/design/0001-sysemble-design.md) (Chinese). ADRs record the decisions that shape the engine. Issues and design discussion are welcome; code contributions start after P0's spec is frozen.

## License

MIT. See [LICENSE](LICENSE).

---

**中文简介**：Sysemble 是一个本地优先的 Linux 系统组装台：对话生成 spec、可视化分层拼装、本地引擎镜像构建、QEMU 启动验证，支持 Windows 应用层与团队可复现产物。跨 Windows/macOS/Linux 三端，技术栈 Rust + Tauri。当前处于 P1：macOS/Windows 通过 Docker Desktop/podman 运行版本化 Debian 引擎镜像（原生 VZ/WSL2 helper 在 P1-e3）。
