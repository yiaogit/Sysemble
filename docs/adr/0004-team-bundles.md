# ADR-0004: 团队产物是签名 bundle，不是单张 ISO

- 状态：Accepted
- 日期：2026-11-23

## 背景

团队要"可分享的合规版本 Linux、可复现、可多设备使用"。单张 ISO 无法证明来源、无法复现、无法审计。

## 决策

产物是一个 bundle：

```
bundle/
  buildspec.yaml      # 团队配置，签名，可 review
  plan.json           # resolved：包、体积、digest
  sbom.cdx.json       # CycloneDX
  evidence.json       # 构建 + 启动断言
  signature.sig       # cosign / minisign
```

- spec 放 Git，artifact 放任意 OCI registry。
- `sysemble verify` 在安装前校验签名、SBOM、证据。
- 安装器在写入前拒绝未通过 verify 的 bundle。

**可复现**：base 钉快照、模块钉版本+摘要、`SOURCE_DATE_EPOCH` 固定、记录包清单与 digest。

**合规**：profile 只描述"检查了什么、结果如何、缺什么"，不宣称认证。per-control 结果 + 缺失项 + 人工处置。

**多设备**：一份 artifact 装多台；设备身份（hostname、SSH key、机器密钥）在首次启动注入，不重新构建。

## 后果

正面：
- 可审计、可复现、可跨设备。
- 签名让"谁构建的"可验证。

负面：
- 比"发一张 ISO"重。
- 需要团队理解签名与 SBOM。
- OCI registry 对非技术团队仍有门槛。

## 备选方案

1. **只发 ISO**：无法验证来源。否决。
2. **自建 registry**：运维成本高。否决（用现有 OCI）。
3. **只发 spec，让每人自己构建**：无法保证一致。否决。

## 约束

- P3 才实现签名与 bundle；P0 只要求 spec + plan + 日志。
- verify 失败必须阻断安装，不能只警告。
