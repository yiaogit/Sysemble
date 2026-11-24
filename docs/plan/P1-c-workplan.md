# P1-c 工作分解：层级画布 + declared→resolved 视图

> P1-b 已有构建控制。本切片把 spec/plan 变成可视的层级卡片与差异列表。

- 日期：2026-11-24
- 基线提交：`08584c2`
- 范围：**结构可视化**，不做拖拽、不做图形画布、不做对话。

## 1. 命令契约

```rust
inspect(spec_path: String) -> Result<Inspect, String>
```

```json
{
  "layers": [
    {"id":"target","title":"Target","items":["debian trixie","x86_64","qcow2, iso"],"estimated_mb":null},
    {"id":"system","title":"System","items":["kernel lts","2 services","3 packages"],"estimated_mb":null},
    {"id":"desktop","title":"Desktop","items":["xfce","lightdm","0 apps"],"estimated_mb":null},
    {"id":"virtualization","title":"Virtualization","items":["no Windows VM"],"estimated_mb":null},
    {"id":"dev","title":"Development","items":["no profiles"],"estimated_mb":null},
    {"id":"security","title":"Security","items":["no encryption","nftables","standard hardening"],"estimated_mb":null}
  ],
  "plan": {"packages": 18, "image_mb": 1280, "build_minutes": 13, "modules": ["desktop-xfce", "..."]},
  "diff": [
    {"kind":"resolved","text":"desktop.session=xfce -> module desktop-xfce"},
    {"kind":"warning","text":"..."}
  ]
}
```

- 层从 BuildSpec 推导；`plan` 来自 `resolve_plan`；`diff` 由实现生成（resolved 模块 + plan warnings + 未映射字段提示）。
- 不新增 core 依赖，不修改 core。

## 2. UI

- 左栏改为**垂直层叠卡片**（target → system → desktop → virtualization → dev → security），每张卡显示 items。
- 右栏保留诊断/plan 摘要，新增 diff 列表（kind 着色：resolved 蓝、warning 黄）。
- 底部保留构建日志面板（P1-b）。
- 不引入前端框架；继续原生 JS。

## 3. 验收

| # | 检查 | 通过条件 |
|---|---|---|
| J1 | 命令 | `inspect` 对两个示例返回 6 层、plan 数值 |
| J2 | 层内容 | target 含 `trixie`，desktop 含 `xfce` |
| J3 | diff | 非空，含 resolved 模块条目 |
| J4 | 回归 | 桌面 11 + 根 61 测试全过 |
| J5 | CI | desktop-check 绿 |

## 4. 风险

1. 层推导是“展示用”，不等于 normalized spec；UI 必须标明“declared 视图”。
2. 无 GUI 自动化，仅单测 + 静态检查。
3. 大 spec 的 items 需要截断（最多 8 项 + “+N more”）。
