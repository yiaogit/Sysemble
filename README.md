# Sysemble

**Assemble your own Linux.**

Sysemble is a local-first desktop application for composing a complete Linux system — base, desktop, applications, a Windows VM layer, and development environments — from a declarative spec, then building and verifying it on your own machine.

> **Status: P0-d2 (v0.0.1).** `validate`, `plan`, a real Debian build, GPT/GRUB UEFI boot, an XFCE desktop image, and a 278 MB live ISO (UEFI El Torito + live-boot) all run end to end in CI. Next: the Calamares installer. See [docs/roadmap.md](docs/roadmap.md) and the acceptance reports for [P0-a](docs/acceptance/P0.md), [P0-b](docs/acceptance/P0-b.md), [P0-c1](docs/acceptance/P0-c.md), [P0-d1](docs/acceptance/P0-d1.md), and [P0-d2](docs/acceptance/P0-d2.md).

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
- **Local build.** Builds run inside a disposable Linux sandbox (podman), never on your host.
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
│ Build sandbox (podman, rootless)                            │
│  rootfs → configure → image (ISO / qcow2 / raw / UKI)       │
│  → QEMU boot → assertions → evidence → export               │
└─────────────────────────────────────────────────────────────┘
```

The engine always runs on Linux. On Windows it lives in WSL2; on macOS it lives in an Apple Virtualization.framework VM. The UI stays native.

## Cross-platform hosts

| Host | Engine | Native target | x86_64 target |
|---|---|---|---|
| Windows x86_64 | WSL2 | x86_64 | native |
| Windows arm64 | WSL2 (arm64) | arm64 | qemu-user (slow) |
| macOS arm64 | Virtualization.framework | arm64 | Rosetta for Linux / qemu (experimental) |
| Linux x86_64 | KVM | x86_64 | native |
| Linux arm64 | KVM | arm64 | qemu-user (slow) |

Host support means the app runs everywhere; build targets are always Linux.

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
docs/          design, ADRs, roadmap
spec/          JSON Schemas for buildspec and module
examples/      runnable example specs
crates/        Rust workspace (core, cli) — skeleton
tools/         schema validation helper
```

## Roadmap

| Phase | Scope |
|---|---|
| P0 | CLI + Debian base + 10 modules + qcow2 + QEMU boot + 3 assertions |
| P1 | Tauri UI: canvas, diff, console, preview; ISO + installer |
| P2 | Windows app modes, dev profiles, local MCP server |
| P3 | Arch/Nix backends, team bundles, signing, multi-device provisioning |

## Contributing

The design is in [docs/design/0001-sysemble-design.md](docs/design/0001-sysemble-design.md) (Chinese). ADRs record the decisions that shape the engine. Issues and design discussion are welcome; code contributions start after P0's spec is frozen.

## License

MIT. See [LICENSE](LICENSE).

---

**中文简介**：Sysemble 是一个本地优先的 Linux 系统组装台：对话生成 spec、可视化分层拼装、本地沙箱构建、QEMU 启动验证，支持 Windows 应用层与团队可复现产物。跨 Windows/macOS/Linux 三端，技术栈 Rust + Tauri。当前处于设计阶段。
