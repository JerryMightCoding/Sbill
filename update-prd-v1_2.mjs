import fs from 'node:fs';
import {
  createDocument, saveDocument, addTitle, addHeading, addParagraph,
  addBullets, addNumbered, addQuote, addTable, addPageBreak, addToc,
} from '/Users/Jerry/.chengxiaobang/builtin/plugins/office-suite/skills/word/scripts/docx-author.mjs';

const root = '/Users/Jerry/Documents/Sbill';
const source = fs.readFileSync(`${root}/deliverables/同行账本_PRD_v1.1.md`, 'utf8');
const output = `${root}/deliverables/同行账本_PRD_v1.2`;
if ((fs.existsSync(`${output}.md`) || fs.existsSync(`${output}.docx`)) && !process.argv.includes('--regenerate-own-output')) {
  throw new Error('V1.2 已存在，请先查看文件后决定是否重新生成');
}
let md = source;
function replaceOnce(oldText, newText) {
  if (md.split(oldText).length !== 2) throw new Error(`替换目标不唯一：${oldText}`);
  md = md.replace(oldText, newText);
}
function replaceSection(prefix, body) {
  const start = md.indexOf(prefix);
  if (start < 0) throw new Error(`缺少章节：${prefix}`);
  const tail = md.slice(start + prefix.length);
  const next = tail.search(/^#{1,3} /m);
  const end = next < 0 ? md.length : start + prefix.length + next;
  md = md.slice(0, start) + body.trim() + '\n\n' + md.slice(end);
}
function cells(line) { return line.trim().slice(1, -1).split('|').map(x => x.trim()); }
function changeRow(id, changes) {
  let found = 0;
  md = md.split('\n').map(line => {
    if (!line.startsWith(`| ${id} |`)) return line;
    found++;
    const c = cells(line);
    for (const [index, value] of Object.entries(changes)) c[Number(index)] = value;
    return `| ${c.join(' | ')} |`;
  }).join('\n');
  if (found !== 1) throw new Error(`行不唯一：${id}`);
}
replaceOnce('**版本：V1.1｜日期：2026-11-03｜对应应用：v0.2.1+3｜状态：实现基线与未完成需求清单**',
  '**版本：V1.2｜日期：2026-11-03｜对应应用：v0.3.0+4 / core 0.2.0｜状态：首批非 iOS 改进与未完成需求清单**');
replaceOnce('> 对照源码、现有构建和测试记录；本次只更新文档，不修改业务代码。',
  '> 本版对应已落地的财务、安全与导入基础改进。iOS 明确不在本轮开发范围，但长期需求、全部 FR/AC 和原优先级继续保留；其余非 iOS 剩余项仍须开发与验收。');
replaceOnce('目标描述不表示 v0.2.1 已提供对应适配', '目标描述不表示 v0.3.0 已提供对应适配');
changeRow('FR-EXP-02', {4:'Flutter 按原币小数位编辑，BigInt 精确小数/分数汇率及尺度换算，保留分母并拒绝部分原币元数据；JPY 再编辑有真实 FFI Widget 证据。汇率来源/适用范围/确认元数据及完整币种矩阵仍未完成。'});
changeRow('FR-PAY-01', {4:'本人声明/收款确认及部分、超额、迟到映射核心已有；待确认/争议/待映射等状态由 Rust 统一阻断正式结算。争议/纠正/迟到映射正式 UI、超额用途和同额实际付款专项仍未闭环。'});
changeRow('FR-SET-01', {3:'已实现',4:'四模式核心与界面已接通；合并模式可选择目录中的目标币种，本地设置按账本保存；缺汇率明确不可计算。Rust 模式回归与 Flutter 目标币种切换通过；iOS/真实多手机同结果验收不在已通过范围。'});
changeRow('FR-SET-03', {4:'统一结算阻断、只读成员本人批准/收付确认、冻结金额/汇率/覆盖数量/指纹展示及本地过期/重复提交保护已补。政策/提交分叉、重授权、还款异常及完整范围展示和远端并发治理仍未闭环。'});
changeRow('FR-SYNC-03', {4:'Android 文件/系统分享与同步码入口已有；事件和加密 outbox 整包单 SQLite 事务，拒绝包不部分写入，有故障注入回滚/重试证据；摘要显示待依赖/重授权。工作区跨库/catalog 原子性、完整同步范围/接收确认及 Android 双机系统互传仍未验收；iOS 本轮排除。'});
changeRow('FR-BKP-01', {4:'个人备份核心改为 V2 随机 32 字节盐、固定 Argon2id-v19-m65536-t3-p1，认证身份元数据并清理部分敏感内存；弱口令、异常参数、旧弱 V1 默认拒绝。没有完整备份/换机入口；SQLite 种子/群密钥仍未 Keystore 保护，设备治理/群密钥轮换未完成。'});
changeRow('FR-CAT-01', {4:'已有单选/取消和 Emoji 自定义；新增真实 Widget 单选/取消回归，分类签名事件采用 observed-remove，低序号删除、并发新 tag、缺依赖及 V1 tombstone 有测试。分类仍在标题中，旧本机分类未全迁成事件，真机及完整历史分类矩阵未验收。'});
replaceOnce('| 新增/改本人账目、本人声明还款 | 是 | 是 | 是 | 否 |',
  '| 新增/改本人账目 | 是 | 是 | 是 | 否 |\n| 本人声明还款 | 本人且有效时 | 本人且有效时 | 本人且有效时 | 本人且有效时 |');
replaceOnce('| 本人签名批准/本人收款确认 | 有权且受影响时 | 有权且受影响时 | 有权且受影响时 | 当前禁止，导致受影响只读参与人的结算阻塞，尚需治理规则 |',
  '| 本人签名批准/本人收款确认 | 本人且受影响时 | 本人且受影响时 | 本人且受影响时 | 本人且受影响时；不可代签、改账或发布 |');
replaceSection('### 9.7 ', `### 9.7 当前外币精度与剩余验证

Flutter 已使用 BigInt 精确解析金额与有理汇率，按原币/目标币小数位换算；已有 JPY 金额不再统一 /100，汇率 0.0525 保留为 21/400。390×844 真实 Rust FFI 测试验证 JPY 1000 → CNY 52.50、再次编辑和保存不丢原币/分母；金额边界、完整权重和超 double 精度动画最终值也有测试。汇率来源、适用范围、确认元数据和全部币种/尾差/累计财务边界仍须补齐，不能把这些指定用例当 AC-E07/E08 全量验收。`);
replaceSection('### 11.4 ', `### 11.4 当前还款闭环的不足

本人声明和本人收款确认已接通，只读成员也可执行本人确认，但不能改账或发布。Rust 统一检查待确认、争议、待映射/待依赖、陈旧授权及财务/政策/提交冲突；相关正式发布、批准、提交有阻断与原因展示。争议/纠正/迟到映射仍缺正式用户操作闭环，部分/超额/同额实际付款与跨设备完整状态矩阵仍未验收。当前采用保守账本级阻断，不代表已实现精细的相关范围隔离。`);
replaceSection('### 13.6 ', `### 13.6 当前结算限制与已补保护

合并币种现在可选择目录币种；这是按账本保存的本地试算，不改变已有正式快照。正式卡片展示冻结转账、币种、汇率、覆盖数量和完整指纹，确认针对冻结方案而非后来预览。只读且受影响成员可以本人签名批准、声明本人还款和确认本人收款；不能改账、发布或代签。

统一阻断和本地过期/重复提交保护已补，测试确认不会污染正常提交链。待重授权/政策分叉/远端提交分叉、完整范围展示、争议/纠正/迟到映射和多设备并发治理仍未形成完整产品闭环。基础快照/重组通过不等于本节全部异常规则已通过。`);
replaceOnce('当前差距：正式文件导出取当前账本全部事件，没有给用户的对端摘要请求/增量选择；导入是逐事件事务和摘要，而非整包/整个工作区原子提交。只显示新增/重复/拒绝等摘要，待依赖/待授权/待升级范围不完整。下述真正增量、确认、独立重试与整包原子要求继续保留为待完成。',
  '当前导入先验证完整集合，再以一个 SQLite 事务写全部新增事件和加密 outbox；财务错误或 SQL 写入失败整包不落盘，摘要显示新增/重复/待依赖/待重授权。未来协议版本及超限缺序会拒绝并提示升级/补齐。仍无对端摘要请求/用户增量选择；整个工作区多库/catalog 原子性、完整范围/业务接收确认/分包重试尚未完成。SQL 故障注入不是 Android 强杀或断电验收。');
replaceOnce('当前只有整块加密附件/缺失报告和个人口令备份原型，正式账目 FFI 写空附件列表，没有附件或备份/换机用户入口。备份原型的单次 BLAKE3 口令派生和确定性盐不满足安全 KDF 要求；普通私有 SQLite 存种子/群密钥不等于 Keystore/Keychain 安全存储。以下需求不能标为已经完成。',
  '当前有整块加密附件/缺失报告和个人备份核心，正式账目 FFI 仍写空附件列表，未接附件或完整备份/换机入口。备份 V2 已用随机 32 字节盐、固定 Argon2id（64 MiB、3 次、并行 1）、认证元数据和部分 zeroize 清理；旧弱 V1 默认拒绝，须从旧设备重导。普通 SQLite 中的签名种子和群密钥仍未迁移或加密，不等于 Keystore/Keychain 安全存储；可靠恢复、设备授权和密钥轮换仍未完成。');
changeRow('AC-E07', {4:'部分覆盖',5:'JPY→CNY 混合付款再编辑真实 FFI Widget、分母与尺度/非法元数据核心测试通过；原币债务、来源/确认元数据和全部币种矩阵仍未全验收。E-FX'});
changeRow('AC-S12', {4:'部分覆盖',5:'Rust 统一阻断及待收款确认禁止发布/批准/提交、UI 禁用与原因显示有新增断言；完整争议/映射/治理与跨设备矩阵未完成。E-SET/E-PAY'});
changeRow('AC-CAT01', {4:'部分覆盖',5:'390×844 Widget 实际切换分类、再次取消且保留自写描述通过；Emoji 自定义已有，任意图标输入专项和真机仍未验收。E-CAT'});
changeRow('AC-CAT03', {4:'部分覆盖',5:'observed-remove 的低序号删除、未观察并发同名新增保留、逆序收敛和缺依赖有核心断言；V1 tombstone/签名兼容通过，历史分类结构迁移及真机矩阵仍未完成。E-CAT'});

const originalFr = source.split('\n').filter(x => /^\| FR-/.test(x)).map(cells);
const originalAc = source.split('\n').filter(x => /^\| AC-/.test(x)).map(cells);
const fr = md.split('\n').filter(x => /^\| FR-/.test(x)).map(cells);
const ac = md.split('\n').filter(x => /^\| AC-/.test(x)).map(cells);
if (fr.length !== 23 || ac.length !== 72) throw new Error('FR/AC 数量变化');
if (JSON.stringify(fr.map(x => x.slice(0,3))) !== JSON.stringify(originalFr.map(x => x.slice(0,3)))) throw new Error('FR 原需求/优先级变化');
if (JSON.stringify(ac.map(x => x.slice(0,4))) !== JSON.stringify(originalAc.map(x => x.slice(0,4)))) throw new Error('AC 场景/预期/优先级变化');
const counts = Object.fromEntries(['已实现','部分实现','未实现'].map(k => [k,fr.filter(x => x[3]===k).length]));
const countText = `${counts.已实现} 已实现、${counts.部分实现} 部分、${counts.未实现} 未实现`;
replaceOnce('| 实现状态 | v0.2.1 普通/测试 APK 已构建；23 FR 中 7 已实现、12 部分、4 未实现；双机/iOS/性能/安全尚未全量验收 |',
  `| 实现状态 | v0.3.0 普通/测试 APK 已构建；23 FR 中 ${countText}；真实设备/性能/完整安全尚未全量验收；iOS 本轮不开发 |`);
const start = md.indexOf('## 26. ');
if (start < 0) throw new Error('缺少基线章节');
const releaseSize = fs.statSync(`${root}/同行账本_Sbill_v0.3.0_release.apk`).size;
const testingSize = fs.statSync(`${root}/同行账本_Sbill_v0.3.0_testing.apk`).size;
md = md.slice(0, start) + `## 26. v0.3.0 实现基线、验证与交付

### 26.1 本轮范围

- Android arm64、core 0.2.0、事件 schema V2。保留空白首用、多账本、独立本人身份、伙伴认领、四模式结算、文件/同步码、分类和测试控制台。
- 本轮补齐外币/金额精度基础、目标币种、本人与只读确认、正式结算阻断/冻结信息/过期保护、单库整包原子导入、分类因果删除和基础密码学加固。
- 普通版不开放演示身份切换/模拟网络/仿 QR；测试控制台四目录包交换不是真实网络。
- iOS 不在本轮开发范围，但长期目标保留。其他剩余需求见第 27 节，不因排除 iOS 而视为完成。

### 26.2 已取得的分层证据

- Rust 37/37：unit 1、backup 2、core 11、event boundary 2、financial safety 3、import/category 3、legacy schema 1、settlement staleness 1、strict signature 1、smoke 7、workspace 5。
- Flutter 普通 16/16、测试 19/19；加载最新本机 Rust release FFI，指定 390×844 Widget 回归。测试专用平台目录适配不等于 Android 系统分享通过。
- 静态分析 0 errors、7 条既有 warning/info，退出码 1；不宣称无告警通过。
- Android arm64 核心和两个 APK 构建成功；ZIP/库/版本/包名/控制台裁剪检查单独记录在 SMOKE_TEST_CASES.md。尚未真机安装、双机系统互传、最低系统、断电/强杀、性能或能耗验收。
- SQL trigger 故障注入证明事件/outbox 单库回滚、重试和幂等，不证明整个工作区/Android 断电恢复。真实 V1 SQLite 升级测试证明旧事件、签名和账目不变，不是用户手机升级验收。

### 26.3 产物与兼容边界

| 构建 | 包名 | 产物 | 边界 |
|---|---|---|---|
| 普通 v0.3.0+4 | com.sbill.app | 同行账本_Sbill_v0.3.0_release.apk（${releaseSize.toLocaleString('en-US')} 字节） | arm64-v8a；minSdk 24；targetSdk 36；试用 debug 签名 |
| 测试 v0.3.0+4 | com.sbill.app.testing | 同行账本_Sbill_v0.3.0_testing.apk（${testingSize.toLocaleString('en-US')} 字节） | SBILL_TEST_TOOLS=true；独立数据目录、与普通版并排 |

V1 历史可读，新增事件使用 V2；同行应一起升级，不能保证旧客户端完整处理 V2 observed-remove。V1 无新增空字段的规范序列化保持旧签名不变。身份备份 V2 使用新 KDF，旧弱备份默认拒绝，完整 App 恢复入口仍不存在。minSdk 24 是元数据而非 Android 7 真机验收。沿用试用签名，不能宣称正式生产发布；升级已有普通版时不要卸载或清数据。V1.0/V1.1 和旧 APK 保留归档。

### 26.4 复验命令

\`\`\`bash
/Users/Jerry/.cargo/bin/cargo test --manifest-path /Users/Jerry/Documents/Sbill/rust_core/Cargo.toml
cd /Users/Jerry/Documents/Sbill/app
/Users/Jerry/flutter/bin/flutter test
/Users/Jerry/flutter/bin/flutter test --dart-define=SBILL_TEST_TOOLS=true
/Users/Jerry/flutter/bin/flutter analyze
/Users/Jerry/flutter/bin/flutter build apk --release --target-platform android-arm64
/Users/Jerry/flutter/bin/flutter build apk --release --target-platform android-arm64 --dart-define=SBILL_TEST_TOOLS=true
\`\`\`

## 27. 完整性结论、未完成门槛与证据索引

### 27.1 是否完成全部需求

**否。**本版只是首批非 iOS 改进，尚未完成全部非 iOS 需求或全部 P0。23 项 FR 中 ${countText}；原 20 FR/61 AC 与新增 3 FR/11 AC 的场景、预期和优先级均保留，总计 23 FR/72 AC。实现主干计数不是验收完成率。iOS 仅排除本轮开发，没有从长期 PRD 删除。

### 27.2 剩余差距和发布门槛

| 编号/优先级 | 已补与仍未完成 | 剩余验收 |
|---|---|---|
| GAP-01 / P0 | 外币尺度/分母/金额边界已修；元数据及完整财务矩阵未完 | 汇率来源/适用/确认、0/2/3 位全部币种、尾差与累计边界。E-FX |
| GAP-02 / P0 | 统一正式结算阻断已补；争议/纠正/迟到映射正式闭环未完 | 授权 UI、部分/超额用途、同额实际付款和状态矩阵。E-PAY |
| GAP-03 / P0 | Viewer 本人确认、冻结展示及本地过期保护已补；异常治理未完 | 政策/提交分叉、待重授权、远端并发和完整范围，禁止代签。E-AUTH/E-SET |
| GAP-04 / P0 | Argon2id/随机盐/严格验签/部分内存清理已补；安全存储和可靠恢复未完 | Android Keystore、数据/密钥/附件备份、换机授权、成员设备治理、群密钥轮换。E-BKP |
| GAP-05 / P0 | 真实 LAN/HTTP WebDAV 未接通；iOS 本轮排除 | 真实发现/连接/断网补传，HTTP 认证/证书/错峰/失败恢复；iOS 留长期计划。E-LAN/E-DAV/E-IOS |
| GAP-06 / P0 | 事件/outbox 单库整包事务已补；工作区一致性和同步状态未完 | 多库/catalog 原子性、完整范围/待升级/业务接收确认、持久重试与故障恢复。E-FILE/E-WSP |
| GAP-07 / P0/P1 | 分类 observed-remove 已补；结构化分类/旧数据迁移/筛选未完 | 历史分类、旧本机分类迁事件、成员/时间/币种过滤及真机并发矩阵。E-CAT |
| GAP-08 / P1 | 标准二维码/相机/附件正式产品未接通 | 双向请求确认、持久分片缓存、反光低端机、附件选择显示与分块补传。E-OPT/E-ATT |
| GAP-09 / 全版本 | 真实设备、性能、能耗、故障恢复和正式签名未验收 | 第 21 节机型/数据集，启动/1000事件/求解/吞吐、强杀/断电/切网/能耗、正式签名 |

原币债务、同成员多设备、报表、历史管理和链锚等 FR-ADV 仍按原优先级保留。首批交付不代表全部开发结束，不给未实现能力贴“已完成”标签。

### 27.3 当前实现和测试证据索引

路径相对项目根；以函数/测试名查找，避免旧行号误导。证据是指定用例而非全面审计。

| 编号 | 实现定位 | 验证与边界 |
|---|---|---|
| E-WSP | rust_core/src/workspace.rs；WorkspaceSession | workspace_suite.rs、legacy_schema_upgrade_suite.rs、workspace_onboarding_test.dart：空白、多账本、认领、重开、V1 历史不变；跨库故障未验收 |
| E-MONEY | engine.rs；ledger_models.dart MoneyFormatter、FxRateSpecModel；animated_amount_text.dart | core_m1_m3_suite.rs、financial_precision_test.dart、amount_display_precision_test.dart；指定精度/权重/显示边界，非所有累计财务边界 |
| E-FX | expense_editor_sheet.dart _collectPayers/_recalcForeignPayer；ffi.rs；domain.rs | financial_safety_suite.rs、financial_precision_test.dart、expense_precision_widget_test.dart：JPY、21/400、再次编辑、非法元数据 |
| E-REV | storage.rs 财务投影；conflict_resolution_screen.dart、expense_detail_screen.dart | core/联合冒烟/M4 既有修订冲突测试；非任意并发全集 |
| E-AUTH | storage.rs is_personal_confirmation/身份与陈旧授权；workspace.rs | financial_safety_suite.rs、workspace_suite.rs：Viewer 本人确认/越权拒绝、撤权检查点；完整治理未完成 |
| E-PAY | ffi.rs 还款；storage.rs ensure_formal_settlement_ready；settlement_center_screen.dart | financial_safety_suite.rs、settlement_guard_widget_test.dart、M4/M5；争议/纠正/映射 UI 未完成 |
| E-SET | storage.rs ensure_snapshot_current/ensure_formal_settlement_ready；api.rs、ffi.rs；settlement_center_screen.dart | settlement_staleness_suite.rs、snapshot_frozen_widget_test.dart、四模式/M5：冻结展示、过期/重复保护；远端治理未完成 |
| E-LAN | api.rs sync_lan_with_peer；sync.rs select_events_missing_on_peer | M3/M7 进程内测试，不是真网络 |
| E-DAV | sync.rs WebDavRemoteStore/InMemoryWebDavStore/sync_with_webdav | M3/M6 内存 Store，不是 HTTP |
| E-FILE | MainActivity.kt 分享/选择器；ffi.rs import_tripdelta_payload；storage.rs import_event_batch | import_category_suite.rs、atomic_import_tests：错误整包拒绝、SQL 回滚/幂等；Android 双机未测 |
| E-OPT | sync.rs 光学帧；optical_qr_sync_screen.dart 仿 QR | M3/M7/smoke_09 编解码；标准 QR/camera 未接通 |
| E-PNG | sync.rs embed_tripdelta_into_png/extract_tripdelta_from_png | smoke_09 容器验证，非图像平台矩阵 |
| E-ATT | storage.rs 加密整块附件；ffi.rs attachment_refs | smoke_10 缺失诊断；正式附件/分块产品未接通 |
| E-BKP | sync.rs MemberIdentityBackup/derive_passphrase_key；crypto.rs verify_strict/GroupCipher Drop | backup_security_suite.rs、signature_strict_suite.rs：Argon2id/随机盐/元数据/异常参数；SQLite 密钥未保护、完整恢复未完成 |
| E-IOS | app/ios 不存在；bridge 预留分支 | 不在本轮开发范围，无 iOS 工程/产物/验收 |
| E-ADV | domain.rs 原币信息；workspace.rs 安装 device_id；sync.rs zlib | 不等于原币债务、同成员多设备、报表、历史回收或链锚产品 |
| E-CAT | domain.rs observed_add_event_ids；storage.rs observed_category_tags/分类投影；expense_editor_sheet.dart | import_category_suite.rs、event_boundary_suite.rs、legacy_schema_upgrade_suite.rs、expense_precision_widget_test.dart；旧分类结构迁移/真机未完 |
| E-DEV | build_config.dart、test_console_controller.dart、test_console_overlay.dart；Android BuildConfig | test_console_test.dart：普通裁剪/四私钥/合法认领/包交换/失败恢复；并非真实多手机同步 |

### 27.4 协议升级与输入边界证据

事件 V2 拒绝未来版本、sequence=0/超 i64、有界缺序窗口和同 device_id 混用身份；Ed25519 严格验证拒绝 small-order 公钥签名。event_boundary_suite.rs、signature_strict_suite.rs、import_category_suite.rs 和真实 V1 SQLite 升级测试提供指定证据。没有因此宣称所有解析深度、累计财务上限或安全攻击面已审计完成。
`;
fs.writeFileSync(`${output}.md`, md);

const doc = createDocument({
  title:'同行账本：离线优先共享旅行记账 PRD', template:'report',
  page:{size:'A4',margins:{top:20,bottom:20,left:20,right:20}},
  theme:{fontFace:'PingFang SC',headingFontFace:'PingFang SC',baseSize:10.5},
  header:'同行账本 · PRD V1.2', footer:{pageNumber:true},
});
addTitle(doc, undefined, {subtitle:'V1.2 · v0.3.0+4 / core 0.2.0 · 首批非 iOS 改进与剩余需求'});
addParagraph(doc, '保留 23 项 FR / 72 条 AC 与原优先级；尚未完成全部非 iOS 需求或全部 P0。iOS 不在本轮开发范围。');
addPageBreak(doc);
addToc(doc,{levels:2});
addPageBreak(doc);
function plain(text) {
  return text.replace(/\[([^\]]+)\]\(([^)]+)\)/g,'$1（$2）').replace(/\*\*/g,'').replace(/`/g,'');
}
const lines = md.split('\n');
let code = false;
for (let i=0;i<lines.length;i++) {
  const line=lines[i];
  if (line.startsWith('```')) {code=!code;continue;}
  if (code) {addParagraph(doc,line||' ',{spacingAfter:30});continue;}
  if (!line.trim() || /^---+$/.test(line)) continue;
  const heading = line.match(/^(#{1,4}) (.*)$/);
  if (heading) {
    if(heading[1].length===1) continue;
    addHeading(doc,plain(heading[2]),{level:heading[1].length-1});continue;
  }
  if(line.startsWith('|')) {
    const block=[];
    while(i<lines.length && lines[i].startsWith('|')) block.push(lines[i++]);
    i--;
    const parsed=block.filter(x=> !/^\|[\s:|-]+\|$/.test(x)).map(x=>cells(x).map(plain));
    const headers=parsed.shift();
    const n=headers.length;
    const widths=n===6?(headers.some(x=>x.includes('预期'))?[13,20,24,8,12,23]:[13,21,8,12,36,10]):n===4?[17,24,31,28]:n===3?[18,37,45]:undefined;
    addTable(doc,{headers,rows:parsed,columnWidths:widths,fontSize:n>=6?8.5:9,zebra:true,keepTogether:false});continue;
  }
  if(/^[-*] /.test(line)) {
    const items=[];
    while(i<lines.length && /^[-*] /.test(lines[i])) items.push(plain(lines[i++].slice(2)));
    i--;addBullets(doc,items);continue;
  }
  if(/^\d+[.)] /.test(line)) {
    const items=[];
    while(i<lines.length && /^\d+[.)] /.test(lines[i])) items.push(plain(lines[i++].replace(/^\d+[.)] /,'')));
    i--;addNumbered(doc,items);continue;
  }
  if(line.startsWith('>')) {addQuote(doc,plain(line.replace(/^>\s?/,'')));continue;}
  addParagraph(doc,plain(line));
}
await saveDocument(doc,`${output}.docx`);
console.log(JSON.stringify({markdown:`${output}.md`,word:`${output}.docx`,requirements:fr.length,acceptanceCriteria:ac.length,counts,originalRequirementsAndPrioritiesPreserved:true},null,2));
