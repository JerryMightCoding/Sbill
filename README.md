# 同行账本 (Sbill)

离线优先、按出行账本隔离的多币种共享旅行记账客户端（Rust 密码学与财务核心 + Flutter Android 客户端）。

## 核心特性

- **按出行账本隔离与空白首用**：每次出行独立 SQLite 账本、独立群密钥与自定义分类，首次进入无演示数据。
- **本人 Ed25519 签名与角色权限**：支持主人、财务管理员、普通成员、只读成员；伙伴认领采用签名挑战与指纹核对，禁止代签。
- **精确多币种与有理汇率**：BigInt 整数最小货币单位、精确分数汇率、多付款人、四种分摊模式（均摊/指定金额/比例/权重，最大余数法）。
- **记账时间、未来账与多维筛选**：支持可选记账时间（含未来账目）、按日期（含星期几）/分类/币种分组及分组小计，支持时间范围、分类、金额区间、付款人、成本承担人组合筛选。
- **四模式结算与共同确认**：支持按币种/合并币种 × 一对一/最少转账次数（状态压缩精确 DP），冻结结算快照、只读受影响成员本人确认、收付双确认、异议与迟到还款映射。
- **多通道离线与错峰同步**：
  - `.tripdelta` 加密文件互传与 `SBILL1:` 紧凑同步码（单库整包原子事务）
  - 标准 ISO/IEC 18004 动态瀑布二维码（喷泉码 XOR 冗余恢复 + SQLite 进度持久化 + 相机扫码/帧流导入）
  - 同一 Wi-Fi / 热点下无公网局域网 HTTP 直连同步
  - 个人 HTTP/HTTPS WebDAV 密文对象异步留存
  - Argon2id (64 MiB / t3 / 32B 随机盐) 个人签名身份加密备份与恢复

## 文档与验收记录

- **项目开发进度追踪**：[PROGRESS.md](PROGRESS.md)
- **冒烟测试与验收清单**：[SMOKE_TEST_CASES.md](SMOKE_TEST_CASES.md)
- **产品需求文档 (PRD)**：
  - [同行账本 PRD V1.2 (Markdown)](deliverables/同行账本_PRD_v1.2.md) / [Word (.docx)](deliverables/同行账本_PRD_v1.2.docx)
  - [同行账本 PRD V1.1 (Markdown)](deliverables/同行账本_PRD_v1.1.md) / [Word (.docx)](deliverables/同行账本_PRD_v1.1.docx)
  - [同行账本 PRD V1.0 (Markdown)](deliverables/同行账本_PRD_v1.0.md) / [Word (.docx)](deliverables/同行账本_PRD_v1.0.docx)
