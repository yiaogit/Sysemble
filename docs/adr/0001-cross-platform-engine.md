# ADR-0001: 跨三端宿主，引擎跑在 Linux VM 里

- 状态：Accepted
- 日期：2026-11-23

## 背景

Sysemble 需要在 Windows、macOS、Linux 上以同一个桌面软件交付。但构建 Linux 镜像依赖 loop device、mount、chroot、KVM、podman——这些在 Windows 与 macOS 上不存在。

## 决策

UI 用 Tauri 2 原生运行在三端；**引擎（daemon + 构建沙箱 + QEMU）永远运行在 Linux 里**，由 App 管理：

- Windows：WSL2 发行版（App 导入/更新引擎镜像）
- macOS：Apple Virtualization.framework 起 arm64 Linux VM
- Linux：原生，复用宿主 KVM/podman

三端使用**同一个签名的引擎镜像**，保证行为一致。UI 通过本地 IPC（unix socket / named pipe / vsock）与引擎通信。

## 后果

正面：
- 引擎只需维护一个 Linux 版本，避免三套构建实现。
- 宿主零 root，构建不污染用户系统。
- 未来可把同一引擎镜像搬到远程构建机。

负面：
- 首次启动需要初始化 VM/WSL2（下载数百 MB）。
- macOS arm64 构建 x86_64 目标需要 Rosetta/qemu，慢且实验性。
- 需要处理文件共享（virtiofs/9p）与端口转发。

## 备选方案

1. **每端原生实现构建**：Windows 用 Hyper-V API、macOS 用 Virtualization.framework 直接构建——三套逻辑，维护成本爆炸。否决。
2. **要求用户装 Docker Desktop**：体验差、依赖第三方、许可问题。否决。
3. **只支持 Linux 宿主**：与"封装在一个软件里支持三端"的目标冲突。否决。

## 约束

- P0 只保证宿主原生架构的目标构建；跨架构标为实验。
- 引擎镜像需要签名与版本钉死，随 App 发布说明。
