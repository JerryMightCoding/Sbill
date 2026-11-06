# 同行账本（Sbill）冒烟测试与验收清单

> 最近验证：2026-11-06，v0.3.1+5 / core 0.2.0 / 事件 V3；记账时间、排序分组与筛选见第八节，旧版本产物保留历史。
> 自动化通过不等于完整 PRD 或双机真机验收。历史 LAN/WebDAV/光学测试是进程内模拟或容器/编解码测试，不能证明真实传输已经实现。

## 一、自动化命令与结果

```bash
/Users/Jerry/.cargo/bin/cargo test --manifest-path /Users/Jerry/Documents/Sbill/rust_core/Cargo.toml
cd /Users/Jerry/Documents/Sbill/app
/Users/Jerry/flutter/bin/flutter test
/Users/Jerry/flutter/bin/flutter test --dart-define=SBILL_TEST_TOOLS=true
/Users/Jerry/flutter/bin/flutter analyze
```

- Rust：41/41。新增 `expense_details_suite.rs` 4 个，其余 37 个既有测试全部通过。
- Flutter 普通构建：18/18；启用 `SBILL_TEST_TOOLS=true` 的测试构建：21/21。包含记账时间/未来账/日期分组/五类筛选、财务精度、冻结方案、结算阻断、分类单选取消及既有工作区/控制台回归，真实加载最新 Rust release FFI。
- 静态分析：0 errors，7 条既有 warning/info，退出码 1，未宣称无告警通过。

## 二、新增自动化验收矩阵

| 编号 | 入口 | 实际断言 |
|---|---|---|
| WS-01 | `workspace_suite.rs::empty_start_multi_ledger_isolation_and_restart` | 初次启动没有账本/账目；创建只绑定自己；两账本具有不同 ID/成员 ID；账目、自定义分类、FX、结算不串账；旧页面提交被拒绝；跨账本同步码不能导入；重启恢复目录/选择/账目/身份 |
| WS-02 | `workspace_suite.rs::two_installations_claim_sync_permissions_and_history` | 两个独立安装身份认领稳定伙伴 ID，保留认领前分摊；申请验签及篡改拒绝；错误密钥/第三方加入拒绝；普通成员不能管成员或切成主人；认领后本人可签名记账和同步分类；重复导入不新增；另一身份冒领拒绝；成员无发布权；降权/移出保留历史，旧权限待核对记录不会因再次更新检查点而复活 |
| WS-03 | `workspace_suite.rs::legacy_upgrade_preserves_records_and_categories_without_new_demo` | 原 SQLite 被登记为旧账本；原账目和本机分类保留；另建账本无示例；切回旧账本数据仍在 |
| WS-04 | `workspace_suite.rs::ffi_namespace_preserves_settlement_approval_dispatch` | 新 `App*` 工作区命令不错误截获旧 `ApproveSettlement` 命令，批准仍路由到结算核心 |
| WS-05 | `workspace_suite.rs::viewer_cannot_sign_mutations_even_without_the_app_command_guard` | 新增未参与原样例欠款的只读 V，直接 Rust 审批不属于本人的方案被 PermissionDenied；不代表禁止只读本人财务确认，合法例外见 FS-02 |
| UI-01 | `app/test/workspace_onboarding_test.dart` | 390×844 逻辑像素下欢迎页没有示例；实际填写账本、本人、同行伙伴；点击创建只产生空账本；点击记第一笔填写 36 元早餐并保存；进入伙伴页；切回账本目录并重新选择后账目保留；没有 Flutter 布局/运行异常 |

## 三、既有回归边界

既有 Rust/Flutter 测试继续执行，没有删除或放宽断言。范围包括：

- Ed25519 签名、规范 JSON、认证加密、压缩包大小限制。
- 整数金额、最大余数、混合币种换算、四模式结算、最少转账反例。
- 多付款人、多承担人、并发财务修订、权限、撤权检查点。
- 共同确认结算、债务重组、还款双确认、超额与迟到映射。
- `.tripdelta` 封装、导入去重、进程内增量交换、WebDAV 内存 Store、缺序补齐。
- 光学帧/XOR 恢复、PNG `sbIl` 载体、加密附件、密钥恢复诊断。
- SQLite 关闭/重新打开后的账目与自定义分类持久化。
- 三个进程内节点并发新增分类的指定并集收敛与删除场景。

测试名称中的 AC 范围不是逐条验收完成证明。分类 observed-remove 和 Argon2id 基础已纳入指定测试；结构化分类/旧迁移/完整真机矩阵、标准 QR/相机、真实 LAN/HTTP WebDAV、Keystore 和完整安全备份换机仍未完成或未验收。

## 四、Android 真机验收步骤（当前未执行）

当前 `adb devices -l` 没有连接设备。建议用两台手机验证以下步骤；已有数据的手机不要卸载或清除数据，应覆盖安装同签名升级包。

### A. 升级与首次启动

1. 有旧数据的设备 A 覆盖安装同签名 v0.3.0：旧账本/账目/本机分类仍在，旧演示账本标注旧版身份且不允许据此邀请认领；正常新版账本继续保留本人身份。所有伙伴一起升级以使用 V2 分类删除，不能保证旧客户端完整双向处理 V2。
2. 使用未安装过本 App 的独立测试设备 B 验证首次启动：只显示“创建出行账本 / 加入同行账本”，没有阿杰/白露等示例成员，也没有酒店和晚餐示例账。
3. A 新建“周末杭州游”，填写本人昵称，同行伙伴可留空；验证点击“记第一笔”能保存第一条真实账目。
4. 新建第二次出行，验证伙伴、账目、自定义分类、汇率和结算均为空且独立；切回第一个账本并杀进程重启，数据和选择保留。

### B. 伙伴本人认领

1. A 在新账本“同步与伙伴”添加“小白”，状态是待认领，不能替小白签名。
2. A 从小白菜单打开认领，复制账本编号与伙伴编号，通过可信渠道给 B。
3. B 点击“加入同行账本”，填写这两个编号和昵称，生成本人签名申请；把申请给 A。
4. A 粘贴申请，点击验签，并当面或通过可信渠道核对申请指纹与 B App 显示的一致。
5. A 点击批准，分别交付加密加入包和访问密钥。勿把两者一起公开；它们合用可读取该账本。
6. B 粘贴加入包及密钥：以小白身份加入，认领前已有账目分摊仍指向同一个稳定 ID。
7. 第三台设备不得导入 B 的加入包，也不能再用不同公钥认领小白。错误密钥或改动后的申请必须报错。

### C. 双机真实手动同步

1. B 断网新增账目与自定义分类，点击分享同步文件；系统分享应附带可保存的 `.tripdelta` 文件，不只是文本。
2. A 选中相同账本，通过“选择同步文件”打开 B 的文件，或粘贴 B 的 `SBILL1:` 同步码；新账目/分类出现。
3. 重复导入同一包，不新增重复账目。
4. 在 A 的另一个账本导入该包必须拒绝，不能混入其他出行。
5. A 导出自己的更新给 B，确认双向状态收敛，并各自杀进程重启验证保存。

### D. 权限、移出与结算

1. 普通成员可新建/修订本人创建的账目，不能修改他人账目或发布结算，不能管理/认领其他成员。
2. 主人把 B 改为财务管理员并同步：B 可修订其他人账目、处理冲突和发布结算，但不能管理成员。
3. 改为只读并同步：B 不能记账、改账或发布方案，但可签本人受影响方案、声明本人还款和确认本人收款；不能签别人的收付或无关方案；普通版界面不提供身份切换。
4. 移出 B 后，其历史账目、分摊和欠款仍保留；新账目不能加入 B。未同步的旧权限账目应暂缓核对，不能自动入账。
5. 只有付款人声明本人还款、收款人本人确认到账。优化/合并结算须先共同确认正式义务，不把预览直接记作原始关系还款。
6. 未认领伙伴不能被代签正式结算；缺少汇率时显示暂不能计算，不显示全部结清。

## 五、历史产物与当时未完成项（v0.2.0；最新见第七节）

- APK：`/Users/Jerry/Documents/Sbill/同行账本_Sbill_v0.2.0_release.apk`。
- package `com.sbill.app`，versionName `0.2.0`，versionCode `2`，minSdk `24`，arm64-v8a。
- 内含 `libsbill_core.so`、`libapp.so`、`libflutter.so`，22,365,660 字节。沿用项目当前调试签名，供试用。
- Android FileProvider、系统文件选择器、加密加入逻辑已编译/自动化验证；双机系统操作尚未实测。
- 正式界面已隐藏附近/HTTP WebDAV/相机 QR 演示入口；这些真实传输能力仍待开发。
- 本机密钥仍存应用私有 SQLite，Keystore、群密钥轮换、可靠换机恢复与安全 KDF/正式签名仍需完善。

## 六、开发者测试版控制台（v0.2.1）

### 自动化验证

```bash
cd /Users/Jerry/Documents/Sbill/app
/Users/Jerry/flutter/bin/flutter test
/Users/Jerry/flutter/bin/flutter test --dart-define=SBILL_TEST_TOOLS=true
```

`test/test_console_test.dart` 分别验证以下构建行为（不使用跳过或放宽断言）：

- 默认构建没有浮层/面板，调用测试身份 API 会拒绝，且不收集测试日志。
- 仅 Dart 开启、原生未开启时不允许打开测试身份目录。
- 测试身份数据库损坏时切换失败，恢复原签名身份、账本和持久化选择，解除批量操作锁并显示失败。
- 一键创建空联调账本，A/B/C/D 的公钥身份各不相同，通过真实签名认领加入同一本账本；A 主人、B 财务、C 普通、D 只读。B 写账后 C 的独立目录不自动出现，交换加密包后四者收敛；只读操作/财务管成员仍被拒绝。
- 重启恢复选中的测试身份；调用记录最多 100 条，仅包含操作名、结果和耗时，可清空。
- 390×844 下实际点击浮层、确认准备联调场景、从未保存的编辑页切到 B、等待旧页销毁、收起、拖动到边界，无遮挡弹窗或布局异常。
- 两个 APK 均通过 ZIP 校验并包含 arm64 Rust 库。普通包 `com.sbill.app` 不含 AOT 控制台入口标记；测试包 `com.sbill.app.testing` 含该标记，应用名为“同行账本·测试”。

### 手机手动检查（尚未实测）

1. 安装 `同行账本_Sbill_v0.2.1_testing.apk`，应与普通版并排存在，启动后出现“调试 · A”小浮层，默认仍是空白引导。
2. 点击浮层展开控制台，选择“准备四身份联调账本”，确认后看到 A 主人/B 财务/C 成员/D 只读。没有示例账目。
3. 切 B 新建账目，切 C 验证未同步时不可见；点击“同步四个测试身份”，四个身份应看见同一账目。此按钮是同机包交换，不是网络模拟。
4. 切 D 尝试写账或修改权限，应拒绝；切 B 不得管理成员。切换前未保存编辑会退出，不能把旧编辑内容写到另一身份。
5. 杀进程重启应恢复当前身份；浮层可拖动、收起，不离开屏幕。
6. 打开普通 APK，不能出现浮层，也不能通过普通原生入口打开测试身份；普通版原有数据不受影响。

产物：

- 测试版：`/Users/Jerry/Documents/Sbill/同行账本_Sbill_v0.2.1_testing.apk`（22,497,076 字节）。
- 普通版：`/Users/Jerry/Documents/Sbill/同行账本_Sbill_v0.2.1_release.apk`（22,365,660 字节）。
- 两者均为 v0.2.1+3、arm64-v8a、沿用试用签名。测试版独立包名，不是覆盖普通版的升级安装；不要卸载普通版来测试。

## 七、v0.3.0 财务、安全、事务与兼容专项

### 新增自动化证据

| 编号 | 入口 | 实际断言及边界 |
|---|---|---|
| FS-01 | `financial_precision_test.dart`、`expense_precision_widget_test.dart` | BigInt 金额/有理汇率和尺度舍入、非法精度/溢出及大权重；390×844 实际编辑 JPY 1000 / 汇率 21/400 / CNY 52.50，保存后原币与分母不丢；分类切换/取消保留自写描述，本地目标币种变为 JPY |
| FS-02 | `financial_safety_suite.rs::viewer_can_only_sign_own_financial_consent` | Viewer 可批准本人受影响方案、声明本人还款和确认本人收款；改账/发布/代签/无关确认拒绝，不赋予治理或映射权限 |
| FS-03 | `financial_safety_suite.rs`、`settlement_guard_widget_test.dart` | malformed FX 不 panic，缺/部分原币元数据拒绝；待收款确认阻断 propose/approve/commit；UI Rust blocker 可见，正式发布按钮禁用，不误报已结清 |
| FS-04 | `snapshot_frozen_widget_test.dart`、`settlement_staleness_suite.rs` | CNY 正式快照在本地改 JPY 后仍显示冻结 CNY 金额和覆盖数量；重复/过期批准和提交拒绝，事件数不增且提交链无冲突 |
| FS-05 | `amount_display_precision_test.dart` | signed minimum 格式化、千位分组校验、9007199254740993 等大整数动画完成后显示精确最后一分；动画中间仍浮点插值 |
| SYNC-A01 | `import_category_suite.rs` | 有效分类与签名有效但财务错误事件同包导入，整包拒绝、不部分新增；完整集合验证不依赖包内到达顺序 |
| SYNC-A02 | `storage.rs::atomic_import_tests` | 测试私有临时 SQL trigger 注入中途失败，事件与 outbox 一起回滚；撤除测试 trigger 后重试全部新增，再导入新增 0。不是 Android 强杀/断电或跨库/catalog 验收 |
| CAT-A01 | `import_category_suite.rs` | 低序号删除已观察高序号新增有效；未观察并发同名新 tag 保留，逆序收敛；缺引用 pending，不提前删除；不等于旧分类迁移/全部历史标签矩阵 |
| SEC-A01 | `backup_security_suite.rs` | V2 随机 32 字节盐、固定 Argon2id 64 MiB/t3/p1、正确恢复与认证 metadata；弱口令、异常 KDF 参数、篡改身份和旧弱 V1 默认拒绝；不是完整 App 备份/换机 |
| SEC-A02 | `signature_strict_suite.rs`、`event_boundary_suite.rs` | small-order Ed25519 签名拒绝；未来 schema、零/超 i64 序号、超补齐窗口缺序、同 device 混用成员/公钥拒绝；缺序处理有界 |
| LEG-A01 | `event_boundary_suite.rs`、`legacy_schema_upgrade_suite.rs` | V1 分类不补空新字段，旧签名 roundtrip 不变；测试自建真实 schema1 SQLite 升级，原账目和 SignedEvent 集合完全不变、不添样例。不是用户手机升级验收 |

### 最新 APK 核验

| 构建 | 包名 | 大小 | 核验 |
|---|---|---|---|
| [普通版](/Users/Jerry/Documents/Sbill/同行账本_Sbill_v0.3.0_release.apk) | com.sbill.app | 22,465,988 字节 | ZIP CRC、versionName 0.3.0 / code 4、min 24 / target 36、仅 arm64、签名通过；AOT 无 TestConsoleOverlay/源路径/联调文案 |
| [测试版](/Users/Jerry/Documents/Sbill/同行账本_Sbill_v0.3.0_testing.apk) | com.sbill.app.testing | 22,531,868 字节 | 相同版本/SDK/ABI；应用名“同行账本·测试”，AOT 含控制台入口；独立私有目录 |

- 普通 APK SHA-256：`9f4f21e224700b2cc01a7574dbbe615ca0b2cf711165b74a52edcd7aeca5527f`。
- 测试 APK SHA-256：`9f5b6ee0e6b0c38d7e7623efcb6e32c6d4a431091fb1a8154e1cfb60b96b96d2`。
- 签名证书为 Android Debug，证书 SHA-256：`ccbce1ae779ea70cae6835beffe5be82604dfc1017780a692d5ff3029aff010e`，仍为试用包而非正式生产发布。
- Gradle merged native 库与本轮重建核心相同，APK 库与 Gradle strip 后的输出相同。去调试符号后的库不能与未 strip 输入直接做字节等同。
- 新事件 schema V2；V1 历史可读，伙伴应一起升级，旧软件不保证完整处理 V2 observed-remove。备份 V2 不默认恢复旧弱 V1；完整备份/换机入口尚未提供。

### v0.3.0 新增真机步骤（尚未执行）

1. 同签名覆盖升级并保留原数据；测试包与普通包并排，不卸载/清除原普通版。
2. 两设备相互认领并手动交换真实系统文件；JPY/KWD/CNY 等不同精度与有理汇率再编辑、重启后原币/分母/折合值不丢。
3. 待确认收付时正式按钮禁用且说明原因；Viewer 本人确认合法，改账/发布/代签不合法。
4. 发布冻结方案后改本地试算币种与模式，待确认卡片金额/汇率/指纹不变；本地过期提交拒绝。
5. 离线并发分类新增、删除已观察分类和未观察新 tag，双向同步后收敛；缺依赖显示待补齐，不提前生效。
6. 错误或中断包不部分改变账本，失败后重试不重复；真正强杀/断电、跨库/catalog 一致性需要专门故障验收，不由 SQL trigger 测试替代。

Keystore、完整备份/换机、群密钥轮换、真实 LAN/HTTP WebDAV、标准 QR/相机/持久分片和附件传输仍未接通；完整治理/筛选/原币债务/多设备/报表/历史管理及真机、性能、能耗和正式签名门槛继续保留。iOS 不在本轮开发范围，不删除长期需求。

## 八、v0.3.1 可选记账时间、未来账、排序分组与筛选专项

| 编号 | 入口 | 实际断言及边界 |
|---|---|---|
| EXP-T01 | `expense_details_suite.rs` | V3 账目携带未来记账时间与结构化分类，签名、`.tripdelta` 导入与 SQLite 重开保持一致；V1/V2 旧账目不补 `details` 字段；编辑/作废/冲突合并保留或显式清除；非法日历或分类拒绝写入 |
| EXP-T02 | `expense_schedule_filter_test.dart` | 默认时间从新到旧并按 `YYYY-MM-DD 星期X` 分组，列头展示分币种有效小计，无日期旧账归入“未记录日期”；支持 5 种排序、4 种分组，以及时间范围、分类、同币种金额区间、付款人包含、成本承担人包含交集筛选；390×844 真实 FFI UI 验证通过 |

最新安装包：

- [普通版 v0.3.1](/Users/Jerry/Documents/Sbill/同行账本_Sbill_v0.3.1_release.apk)（22,892,596 字节，`com.sbill.app`，versionCode 5）。
- [测试版 v0.3.1](/Users/Jerry/Documents/Sbill/同行账本_Sbill_v0.3.1_testing.apk)（23,024,016 字节，`com.sbill.app.testing`，versionCode 5）。

## 九、v0.3.2 真实瀑布二维码、HTTP WebDAV、局域网直连与治理备份专项

| 编号 | 入口 | 实际断言及边界 |
|---|---|---|
| CH-01 | `real_channels_and_governance_test.dart` | `QrCodeMatrix` 生成标准 ISO/IEC 18004 二维码矩阵（含 7×7 定位图形、分隔区、BCH 格式与 Reed-Solomon 纠错码）；正式版 `OpticalQrSyncScreen` 渲染真实二维码并支持丢前 2 帧的喷泉码流恢复 |
| CH-02 | `real_channels_and_governance_test.dart` | 正式版配置真实本地 HTTP WebDAV 服务端，完整执行 `MKCOL`、`PUT` 密文上传、`PROPFIND` 列举、`GET` 拉取与 `ApplyWebDavHttpSync` 解密验签入账；局域网 HTTP 节点启动与客户端直连同步收敛；Argon2id V2 身份备份导出与恢复通过 |

最新安装包（v0.3.2+6）：

- [普通版 v0.3.2](/Users/Jerry/Documents/Sbill/同行账本_Sbill_v0.3.2_release.apk)（23,509,780 字节，`com.sbill.app`，versionCode 6）。
- [测试版 v0.3.2](/Users/Jerry/Documents/Sbill/同行账本_Sbill_v0.3.2_testing.apk)（23,575,656 字节，`com.sbill.app.testing`，versionCode 6）。

