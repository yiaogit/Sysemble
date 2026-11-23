# ADR-0003: Windows 应用四档模式，按问询选择

- 状态：Accepted（RemoteApp 待真机验证）
- 日期：2026-11-23

## 背景

用户要的是"Windows 软件像本地软件一样打开"，而不是"一个 Windows 桌面"。但不同应用对 GPU、延迟、外设的要求差异很大，单一方案无法覆盖。

## 决策

提供四档，由问询选择：

| 模式 | 体验 | 前提 |
|---|---|---|
| `wine` | 原生窗口，无 VM | 应用兼容 |
| `remoteapp` | 单个 Windows 窗口混排在 Linux 桌面 | Windows Pro/Enterprise + RDP |
| `desktop` | 完整 Windows 桌面窗口 | 4–8 GB 内存 |
| `looking-glass` | 低延迟桌面 | 第二块 GPU + VFIO |

选择逻辑：

```
GPU 密集 + 双 GPU → looking-glass
偶尔用 + 兼容性可接受 → wine
有 Pro/Enterprise + 要单窗口 → remoteapp
其余 → desktop
```

`remoteapp` 用 FreeRDP `/app:`，为每个应用生成 `.desktop` 条目；VM 未运行时自动拉起；剪贴板/磁盘/音频/打印走 RDP 重定向。

## 后果

正面：
- 覆盖从"偶尔用一下"到"专业工作站"的全部场景。
- remoteapp 最接近"本地软件"的体验。

负面：
- RemoteApp 在客户端 Windows 上非微软官方支持场景，必须实测；失败回退 desktop。
- Home 版无 RDP 服务端，只能 wine 或 desktop。
- looking-glass 需要硬件与 IOMMU 配置，支持成本高。

## 法律与许可

- 不下载、不分发 Windows ISO。
- 不提供激活绕过。
- virtio-win 可自动下载，但钉版本 + 校验。
- 用户必须自备合法 license。

## 备选方案

1. **只做 Wine**：兼容性不足，专业软件跑不起来。否决。
2. **只做完整桌面 VM**：不符合"像本地软件"的目标。否决。
3. **只做 RemoteApp**：Home 版不可用，GPU 场景不可用。否决。
