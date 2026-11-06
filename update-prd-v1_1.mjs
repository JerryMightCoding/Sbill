import { readFile, writeFile, mkdir } from 'node:fs/promises';
import assert from 'node:assert/strict';
import { createDocument, saveDocument, addTitle, addHeading, addParagraph, addBullets, addNumbered, addTable, addToc, Paragraph, TextRun } from '/Users/Jerry/.chengxiaobang/builtin/plugins/office-suite/skills/word/scripts/docx-author.mjs';

const root = '/Users/Jerry/Documents/Sbill';
const oldPath = '/Users/Jerry/.chengxiaobang/s_s14b18pkj1fl/deliverables/同行账本_PRD_v1.0.md';
const mdPath = `${root}/deliverables/同行账本_PRD_v1.1.md`;
const docxPath = `${root}/deliverables/同行账本_PRD_v1.1.docx`;
let md = await readFile(oldPath, 'utf8');
const original = md;
const cells = line => line.trim().slice(1, -1).split('|').map(v => v.trim());
const originalFr = original.split('\n').filter(v => /^\| FR-/.test(v)).map(cells);
const originalAc = original.split('\n').filter(v => /^\| AC-/.test(v)).map(cells);
assert.equal(originalFr.length, 20);
assert.equal(originalAc.length, 61);
const I = '已实现';
const P = '部分实现';
const N = '未实现';
const fr = {
  'FR-GRP-01': [I, '随机安装身份、离线创建、待认领伙伴、签名申请、主人核对后批准与加密加入已接通。', '双机加入/可信密钥交付尚未实测；本地密钥保护另见安全与恢复要求。', 'E-WSP'],
  'FR-GRP-02': [P, '主人可添加、改名、调角色、移出/重新启用伙伴；稳定 ID 和旧债务保留。', '尚无成员自助退出、主人移交、换机授权与群密钥轮换；旧演示账本禁止新认领。', 'E-WSP'],
  'FR-EXP-01': [I, '多付款人、部分参与、均摊/金额/整数比例/权重及实时守恒校验已实现。', '实现判定限分摊主干；非法输入/极值与完整机型矩阵仍需专项验收。', 'E-MONEY'],
  'FR-EXP-02': [P, 'Rust 整数最小单位、币种小数位、冻结有理汇率与原币付款数据已实现。', 'Flutter 外币编辑固定 /100、只保存整数分子/分母 1，自动折算不处理币种尺度；来源/适用/确认元数据不完整。', 'E-FX'],
  'FR-EXP-03': [I, '不可变完整修订、作废、原因、作者/历史与已结算后的差额已有实现。', '单事件及出箱事务不等于整个工作区事务；未签名草稿跨重启和故障注入尚未完成。', 'E-REV'],
  'FR-AUTH-01': [P, '核心验身份/能力，主人/财务/成员/只读角色和旧政策因果检查点已实现。', '待重授权处理、政策分叉治理与可配置细粒度授权缺用户闭环；只读确认规则存在阻塞。', 'E-AUTH'],
  'FR-CON-01': [I, '并发分支保留；授权人引用父版本采纳或合并；冲突阻止正式结算。', '基础核心/FFI 回归通过；多人真实设备与更广泛并发排列仍待验证。', 'E-REV'],
  'FR-PAY-01': [P, '本人声明、收款人确认、部分还款、超额/迟到映射核心模型已实现。', '争议/纠正/迟到映射无正式操作入口；待确认/争议结算阻断不完整，超额用途选择与真实同额付款场景未完整验收。', 'E-PAY'],
  'FR-SET-01': [P, '四模式核心预览及 8/6/6/3 样例、缺汇率不可计算提示已实现。', '当前合并币种界面固定 CNY，非任意可选结算币种；跨平台结果未验收。', 'E-SET'],
  'FR-SET-02': [I, '不超过 12 个非零余额成员的确定性精确 DP；更大规模标识启发式，稳定并列规则。', '已证明状态仅针对支持的模型；性能预算/极值/跨平台专项尚未验证。', 'E-MONEY'],
  'FR-SET-03': [P, '快照摘要、本人批准、正式提交、新义务、还款和差额重组主干有测试。', '完整阻断状态、只读且受影响成员的确认能力、政策/提交冲突处理及信息范围展示仍有缺口。', 'E-SET'],
  'FR-SYNC-01': [N, '仅有摘要/缺序选择算法及进程内节点交换、模拟发现。', '没有真实 mDNS、socket/QUIC、手动连接/握手、切网续传；不得称真实局域网同步。', 'E-LAN'],
  'FR-SYNC-02': [N, '仅有 WebDAV 接口、内存 Store、出箱队列与模拟错误。', '没有 HTTP、真实认证/证书校验、异步重试/错峰访问和仓库切换产品适配。', 'E-DAV'],
  'FR-SYNC-03': [P, 'Android FileProvider/EXTRA_STREAM、系统文件选择/打开、加密 JSON 文件和 SBILL1 文本已接通并构建。', 'Android 双机未实测；iOS 工程/文件适配不存在；正式导出全量事件，整包原子和接收确认不完整。', 'E-FILE'],
  'FR-SYNC-04': [P, '自定义 JSON/XOR 分片及恢复算法、慢速/手动演示已编写。', '仿 QR 绘制不是标准 QR/Multipart UR；无相机、双向请求/确认、持久接收缓存或物理光学验收。', 'E-OPT'],
  'FR-SYNC-05': [P, 'SBILL1 编码文本有用户入口；PNG sbIl 容器有 Rust 基础测试。', '静态标准 QR 未实现；PNG 没有产品导入/导出入口；完整图片失真矩阵未测。', 'E-PNG'],
  'FR-ATT-01': [P, '有本地附件整块加密存取、引用及缺失诊断原型。', '账目 FFI 固定空附件引用，无拍摄/选择/查看、分块清单与补传队列。', 'E-ATT'],
  'FR-BKP-01': [P, '有独立口令加密私钥与恢复完整度报告的核心原型。', '没有可靠备份/换机恢复产品；签名种子/群密钥存普通 SQLite，KDF 为单次 BLAKE3，未 Keystore/Keychain 或密钥轮换。', 'E-BKP'],
  'FR-ADV-01': [N, '原币付款信息与 device_id 字段只是基础。', '原币归还债务分录、同一成员多设备授权/撤销和增强附近链路未实现；测试四身份不等于多设备功能。', 'E-ADV'],
  'FR-ADV-02': [N, '传输包 zlib 压缩已有。', '无报表导出、历史存储压缩/回收或链锚；传输压缩不能算历史优化。', 'E-ADV'],
  'FR-WSP-01': [I, '无示例首用；创建/选择多个账本；事件、成员、分类、FX、结算、密钥和队列按账本隔离；旧数据保留。', '基础正常关闭重开已测；真实手机升级/强制杀进程/故障恢复仍待验收。', 'E-WSP'],
  'FR-CAT-01': [P, '单选/再次取消、Emoji 自定义、签名分类事件、按精确名称去重的并集与本机持久化已实现。', '删除未使用因果 tombstone/observed-remove；跨设备低序号删除可能先于高序号新增而失效；分类仍编码于账目标题，旧本机分类未全部迁成签名事件。', 'E-CAT'],
  'FR-DEV-01': [I, '仅测试编译启用浮层；独立包名和四私钥目录；真实认领空联调账本、同机包交换、状态和无敏感参数的限额日志。', '不绕过业务权限，不是正式账号切换/网络同步；真机浮层和安装尚未实测。', 'E-DEV'],
};
const extraFr = [
  ['FR-WSP-01', '多账本选择、空白首用、按账本隔离与旧数据保留', 'P0'],
  ['FR-CAT-01', '分类单选/取消、Emoji 自定义与按账本多人同步', 'P0'],
  ['FR-DEV-01', '仅测试版开发者浮层、独立身份与联调工具', 'P1（仅测试）'],
];
const frRows = [...originalFr, ...extraFr].map(([id, title, priority]) => [id, title, priority, ...[fr[id][0], `${fr[id][1]} ${fr[id][2]}`, fr[id][3]]]);
assert.equal(Object.keys(fr).length, 23);
const counts = { [I]: 0, [P]: 0, [N]: 0 };
for (const row of frRows) counts[row[3]]++;
assert.deepEqual(Object.values(counts), [7, 12, 4]);
const A = '基础自动化';
const C = '部分覆盖';
const U = '未验收';
const D = '已知缺口';
const X = '仅模拟/原型';
const ac = {
 'AC-G01':[C,'离线创建/认领已在独立目录验证；双手机断公网与密钥交付未测。E-WSP'],
 'AC-G02':[A,'未绑定伙伴可付款分摊、缺签名不得提交有核心测试；代理确认未开放。E-WSP/E-SET'],
 'AC-G03':[C,'稳定 ID 模型不按姓名合并；完整同名认领/UI/同步金额专项未覆盖。E-WSP'],
 'AC-E01':[A,'CNY 样例余额和付款分摊断言已有。E-MONEY'],
 'AC-E02':[C,'记录人/付款人/承担人独立可表达；付款不参与消费的完整 UI 专项未覆盖。E-MONEY'],
 'AC-E03':[A,'100 分均摊 34/33/33 与固定 ID 尾差已有断言。E-MONEY'],
 'AC-E04':[C,'均摊、加权与部分参与有实现和部分用例；四种 UI/非法权重全矩阵未验收。E-MONEY'],
 'AC-E05':[A,'核心不平衡拒绝及编辑守恒主干已有验证。E-MONEY'],
 'AC-E06':[C,'币种尺度与整数计算有核心用例；非法精度和四币种编辑全链路不完整。E-FX'],
 'AC-E07':[D,'Rust 混合付款有效；Flutter /100、汇率分母丢失与尺度折算缺口。E-FX'],
 'AC-E08':[C,'核心 FxRateSpec 按尺度整数换算；外币编辑与尾差可解释展示未完整兑现。E-FX'],
 'AC-A01':[A,'管理员新修订保留旧作者/版本，FFI 冲突合并有回归。E-AUTH/E-REV'],
 'AC-A02':[A,'核心权限/签名拒绝、普通成员冒领/切他人身份拒绝已有验证。E-AUTH'],
 'AC-A03':[A,'撤权旧账目/分类及检查点不越过待核对事件的基础用例已有。E-AUTH'],
 'AC-A04':[C,'保留已接受历史的规则存在；撤权前共同确认记录专项需扩充。E-AUTH'],
 'AC-C01':[A,'离线同父版本双分支、暂停正式结算的核心/FFI 回归已有。E-REV'],
 'AC-C02':[A,'双父合并/采用分支在固定事件集下收敛已有回归。E-REV'],
 'AC-C03':[C,'完整修订和守恒验证避免字段拼接；广泛交叉分支组合专项未完成。E-REV'],
 'AC-P01':[A,'本人声明未确认，不抵扣正式余额；非收款人确认拒绝已有回归。E-PAY'],
 'AC-P02':[C,'义务 paid/remaining 支持部分金额；用户入口和部分还款完整矩阵待验收。E-PAY'],
 'AC-P03':[C,'超额和反向余额核心断言有；用途选择/双方确认产品入口不完整。E-PAY'],
 'AC-P04':[C,'事件级去重已有；三个真实物理通道投递同一还款未测。E-PAY'],
 'AC-P05':[U,'不按金额日期去重的主规则存在；两笔真实同额转账与相似提示专项未验收。E-PAY'],
 'AC-P06':[C,'核心 PendingMapping/映射单次抵扣有测试；正式 App 无映射操作入口。E-PAY'],
 'AC-S01':[A,'同一数学样例四模式 8/6/6/3 核心及 FFI 已断言。E-SET'],
 'AC-S02':[A,'B→A25、D→A150、D→C275 与未清义务有回归。E-SET'],
 'AC-S03':[C,'本地模式只改预览；多人设备正式方案隔离尚未实测。E-SET'],
 'AC-S04':[A,'精确 DP 优于贪心的反例和状态已有断言。E-MONEY'],
 'AC-S05':[U,'指定事件集重放有覆盖；Android/iOS 不同平台全结果和哈希未验收。E-SET'],
 'AC-S06':[C,'算法不依赖求解墙钟；真实时钟/速度差异专项未验收。E-MONEY'],
 'AC-S07':[A,'未全体批准提交失败、签名进度/正式义务不等于付款已有回归。E-SET'],
 'AC-S08':[A,'合并币种提交和义务履行后旧债不复活有回归。E-SET'],
 'AC-S09':[A,'优化重组履行后切回其他模式无旧债有回归。E-SET'],
 'AC-S10':[A,'已结算修订只产生差额的核心样例已断言。E-SET'],
 'AC-S11':[C,'提交前驱与分叉检测代码存在；两个快照并发消费同源全链路专项未完成。E-SET'],
 'AC-S12':[C,'已知财务冲突/待映射阻断有断言；更广待确认/争议规则见 GAP-02，未完整。E-SET/E-PAY'],
 'AC-L01':[X,'只有内存节点/模拟地址；无真实无公网发现或连接。E-LAN'],
 'AC-L02':[X,'测试手工设置 AP 隔离标志，不是实际网络检测。E-LAN'],
 'AC-L03':[N,'无手动扫码地址、直接连接与身份握手产品实现。E-LAN'],
 'AC-L04':[C,'缺序与连续游标算法已有断言；真实 seq50 网路补齐未验收。E-LAN'],
 'AC-L05':[U,'幂等/正常重开有覆盖；真实传输中断、切网与断点恢复未验收。E-LAN'],
 'AC-L06':[N,'无 iOS 工程或恢复后的 LAN 自动补齐。E-IOS'],
 'AC-D01':[X,'内存 Store 顺序模拟错峰；无真实 HTTP 客户端。E-DAV'],
 'AC-D02':[X,'出箱模拟失败保留；真实 LAN 并行正常/独立调度未实现。E-DAV'],
 'AC-D03':[X,'不可达开关不是实际关闭公网；LAN 也未接入。E-DAV'],
 'AC-D04':[X,'内存对象幂等有覆盖；真实并发/旧索引服务器矩阵未验收。E-DAV'],
 'AC-D05':[C,'假哈希对象拒绝有原型测试；已知回滚/删除完整度警告未验收。E-DAV'],
 'AC-F01':[C,'独立本地仓库交换和 Android 文件适配已实现；Android/iOS 原文件双向分享未验收。E-FILE/E-IOS'],
 'AC-F02':[C,'损坏码/跨群/加入密钥错误有部分测试；普通同步包错误密钥及失败后整库不变矩阵未完整。E-FILE'],
 'AC-F03':[C,'zlib 超限有断言；当前不支持 ZIP 解包，不能计作 ZIP 内部路径穿越专项通过。E-FILE'],
 'AC-F04':[U,'无厂商云端 QR 路径识别/用户提示专项，系统分享不控制厂商网络。E-FILE'],
 'AC-Q01':[X,'仅内存帧恢复，无关闭所有无线后的双手机扫码。E-OPT'],
 'AC-Q02':[C,'跳前两帧和冗余恢复有算法断言；重复/广泛丢帧和真实动态 QR 未验收。E-OPT'],
 'AC-Q03':[U,'换包清缓存代码存在；测试未实际喂第二包，也无失焦/重启接收矩阵。E-OPT'],
 'AC-Q04':[N,'没有真实 QR 解析器，不能宣称首次离线识别已通过。E-OPT'],
 'AC-Q05':[X,'仅 2 FPS 推荐值断言；无低端相机/反光实测。E-OPT'],
 'AC-I01':[C,'Rust PNG 容器提取摘要/事件数有断言，无 App 用户入口。E-PNG'],
 'AC-I02':[C,'伪 JPEG 头和无载荷 PNG 报错已有；真实截图/相册重存未测。E-PNG'],
 'AC-B01':[X,'仅模拟队列不可达；真实节点停服/切换没有接入。E-DAV/E-BKP'],
 'AC-B02':[C,'错口令/缺签名密钥/附件报告有核心样例；群密钥缺失、换机授权和安全 KDF 未完整。E-BKP'],
 'AC-B03':[C,'指定事件集核心财务投影有比较；全部状态、多真实通道与两平台未验收。E-FILE'],
};
for (const [id] of originalAc) assert.ok(ac[id], `Missing ${id}`);
assert.equal(Object.keys(ac).length, 61);
const extraAc = [
 ['AC-W01','全新安装无示例','只显示创建/加入，不填充示例成员、账目或假设汇率','P0',A,'首用 Widget + WSP 空目录测试。E-WSP'],
 ['AC-W02','创建与选择多个出行账本','两项必填即可创建，伙伴可跳过；目录能选择账本','P0',A,'创建/首笔账目/切回目录真实 Widget 操作。E-WSP'],
 ['AC-W03','按账本隔离与旧页面提交','成员/账目/分类/FX/结算/密钥/队列独立；错误群包和旧上下文写入拒绝','P0',C,'独立库、基础财务对象和错群测试；全对象/真机矩阵仍待测。E-WSP'],
 ['AC-W04','关闭后重新打开工作区','账目、目录、当前账本与合法签名身份保留，不退化到内存示例','P0',A,'正常会话重开有断言；真实杀进程/断电另作 NFR。E-WSP'],
 ['AC-W05','升级已有演示账本','保留旧账目与本机分类，不追加示例；旧代造身份不用于新认领','P0',C,'旧数据保留核心测试；真实手机覆盖升级未验收。E-WSP'],
 ['AC-CAT01','分类单选、取消与 Emoji 自定义','切换不堆叠标题，再点取消保留自写描述；图标/名称可新增','P0',U,'实现已有；尚无单选取消/图标输入专门 Widget 断言。E-CAT'],
 ['AC-CAT02','多人离线新增分类并同步','同账本取精确名称并集，确定性去重且重启保留','P0',C,'三进程内节点指定并集及重开有测试；真实手机未测。E-CAT'],
 ['AC-CAT03','分类跨设备删除及并发新增','删除有因果语义，不因无关设备序号而复活；历史账目分类保留','P0',D,'仅按设备 sequence/eventId 排序并即时 retain，无 tombstone。E-CAT'],
 ['AC-DEV01','普通/测试构建隔离','普通版没有控制台且拒绝测试操作；测试版独立包名/目录','P1（仅测试）',A,'普通 7 项/测试 10 项及 APK 标记/包名检查。E-DEV'],
 ['AC-DEV02','四个测试身份联调','私钥独立，合法认领同一空账本；角色限制不绕过，同机包交换标识明确','P1（仅测试）',A,'四身份、独立写入、包交换、只读/财务拒绝和重启回归。E-DEV'],
 ['AC-DEV03','控制台状态、错误与安全切换','最多100条无敏感参数日志；坏库恢复；旧编辑销毁后切换，浮层不越界','P1（仅测试）',A,'390×844 浮层/关闭编辑、坏库恢复与记录上限回归。E-DEV'],
];
const acRows = [...originalAc.map(([id, scene, expected, priority]) => [id, scene, expected, priority, ...ac[id]]), ...extraAc];
assert.equal(acRows.length, 72);
const table = (headers, rows) => [ `| ${headers.join(' | ')} |`, `|${headers.map(()=>'---').join('|')}|`, ...rows.map(row=>`| ${row.join(' | ')} |`) ].join('\n');
function change(oldText, replacement) {
  assert.equal(md.split(oldText).length - 1, 1, `Expected unique text: ${oldText.slice(0,100)}`);
  md = md.replace(oldText, replacement);
}
function section(start, end, replacement) {
  const from = md.indexOf(start), to = md.indexOf(end, from + start.length);
  assert.ok(from >= 0 && to > from, `Missing section ${start}`);
  md = md.slice(0, from) + replacement + '\n\n' + md.slice(to);
}
change('**版本：V1.0｜日期：2026-10-12｜状态：产品与架构评审稿**', '**版本：V1.1｜日期：2026-11-03｜对应应用：v0.2.1+3｜状态：实现基线与未完成需求清单**\n\n> 本版保留 V1.0 的全部 20 项 FR 和 61 条 AC，不因代码缺失删除或降低原 P0/P1/P2 要求；补入 3 项 FR、11 条 AC。原 V1.0 文件保留归档。\n> 结论：当前未完成全部 PRD，也未完成全部 P0；“自动化通过”“已实现”和“真实设备验收通过”不是同一状态。\n> 对照源码、现有构建和测试记录；本次只更新文档，不修改业务代码。');
change('| 产品名称 | 同行账本（暂定名） |', '| 产品名称 | 同行账本（Sbill） |');
change('| 产品定位 | 面向朋友出游的小型共享账本；Android/iOS 跨平台、本地优先、局域网优先同步 |', '| 产品定位 | 面向不同出行的小型共享账本；本地优先、按账本协作；长期目标 Android/iOS 与局域网优先，当前仅 Android arm64 试用 |');
change('| 同步通道 | 局域网直连为主；WebDAV 异步留存；系统文件互传及动态二维码作为手动通道 |', '| 同步通道 | 当前用户入口为加密文件/同步码；真实 LAN、HTTP WebDAV、标准 QR/相机尚未接通，仍保留为需求 |');
change('| 本文性质 | 将本次讨论整理为可评审需求；包含推荐默认值、分期建议和需要验证的技术假设 |', '| 本文性质 | 目标需求 + 当前实现边界 + 逐项 FR/AC 状态 + 发布门槛；估算不是实测 |');
change('| 实现状态 | 尚未开发应用，尚未完成 Android/iOS 真机互通、性能或安全验收 |', '| 实现状态 | v0.2.1 普通/测试 APK 已构建；23 FR 中 7 已实现、12 部分、4 未实现；双机/iOS/性能/安全尚未全量验收 |');
change('本次讨论已确定的方向：', '产品长期目标与当前规则如下。目标描述不表示 v0.2.1 已提供对应适配；本版可用范围见第 26 节：');
change('本文中的 P0/P1/P2 是推荐开发优先级，不表示用户已批准具体排期。性能数字除特别说明外都是目标或样本估算，不能当作已测量的应用表现。', 'P0/P1/P2 表示需求优先级，不是“是否已经完成”的标签。原优先级保留，不因当前缺实现而降级。性能数字除特别说明外都是目标或历史样本估算，不能当作实测。');
section('## 4. 功能范围与分期', '## 5. 产品架构与边界', `## 4. 功能范围、优先级与当前状态\n\n“已实现”表示本表所定义的功能主干有正式入口或核心实现及证据，仍需阅读 AC/NFR 的验收层级；“部分实现”表示只有子功能、原型、测试或存在已知缺口；“未实现”表示完整产品功能未接通，即使有接口/模拟代码也不算完成。\n\n${table(['需求 ID','功能（保留原范围）','优先级','实现状态','当前情况与剩余缺口','证据'],frRows)}\n\n统计：${counts[I]} 项已实现、${counts[P]} 项部分实现、${counts[N]} 项未实现，共 23 项。原 V1.0 20 项中 5 项已实现、11 项部分、4 项未实现；新增多账本与测试台已实现、分类同步仍部分。这个计数不是完成百分比，也不等于 7 项已经通过所有设备验收。\n\nP0 仍包含真实 LAN、WebDAV、安全基础恢复与尚有缺口的财务流程，因此当前不是原 PRD 的完整 MVP。不得通过只统计 M0～M7 模块或删去 P0 来宣称完成。`);
change('- 共享界面：Flutter 为推荐实现选项，最终依开发验证确定。', '- 共享界面：已采用 Flutter；当前只有 Android 工程和 arm64 APK，iOS 仍未实现。');
change('- 共享业务核心：建议 Rust 实现事件验证、金额运算、财务投影、结算和传输打包。', '- 共享业务核心：已采用 Rust + C ABI FFI，Flutter 经后台 Isolate 调用；现有测试不能替代跨平台验收。');
change('- 本地存储：SQLite 保存不可变事件、投影视图、同步队列和附件状态。', '- 本地存储：SQLite 保存事件、工作区元数据、签名身份及出箱；安装级目录登记多个独立账本文件。事件投影按需计算，不把当前全部状态原子性视为已验收。');
section('### 6.1 主要页面','### 6.2 离线记账流程',`### 6.1 主要页面与当前入口\n\n正式版本主导航为“账单 / 结算与收付 / 同步与伙伴”。\n\n${table(['页面','目标内容','v0.2.1 情况'],[
 ['首次进入/账本选择','无示例；创建或加入；选择不同出行','已实现；必填出行名和本人昵称，伙伴可跳过'],
 ['账本首页/账单列表','余额、来源范围、状态；按成员/时间/币种过滤','全部/与我相关/冲突过滤已实现；任意成员/时间/币种过滤和同步范围未完整'],
 ['账单编辑/详情','多付款/分摊/修订/原因/历史与冲突','主干已实现；外币编辑缺口；草稿跨重启尚未实现'],
 ['结算与收付','四模式、确认与正式义务、还款/争议/映射','基础已实现；合并固定CNY，争议/映射无操作入口，完整阻断待补'],
 ['同步与伙伴','真实导入/导出、成员认领、角色和退出','Android 文件/码、主人管理/认领已实现；LAN/WebDAV/QR 演示入口已隐藏，自助退出待补'],
 ['备份与恢复','数据/密钥/附件备份、换机授权、完整度','只有核心原型，没有正式用户页面'],
 ['开发者浮层','独立测试身份、合法空联调账本、状态和限额日志','仅显式测试构建有；普通版编译裁剪并原生拒绝'],
 ])}`);
change('## 7. 核心对象与标识', `### 6.4 无示例首用与多账本\n\n首次启动 → 创建出行账本或加入已有账本。创建必填“出行名称、本人昵称”，伙伴可每行一位或跳过。只建立本人 Owner 身份和创世政策，不填写酒店/晚餐等示例账或假设 FX。空账本给出“记第一笔”，后续从“同步与伙伴”管理伙伴。\n\n同一安装可拥有多个出行账本。成员稳定 ID、事件、分类、汇率、结算、群密钥和同步队列按 group_id 隔离；切换只换账本上下文，不换成其他人的签名身份。旧页面提交和错误群包必须拒绝。旧数据库升级登记为旧账本，保留原账目/本机分类，不清表；由于旧版有代造演示身份，旧账本不能据此给别人认领。\n\n### 6.5 自定义分类与开发者工具\n\n分类支持单选/再次取消、Emoji 图标与新增；由有 BillCreate 能力的成员提交 CategoryUpsert 签名事件，随当前账本事件包传递。当前按 trim 后精确名称去重，不按不同账本合并。目标是新增并集、删除具有明确因果语义、历史账目不丢；现有序号排序删除并非完整 observed-remove CRDT，见第 27 节。\n\n开发者台必须仅存在于测试构建：SBILL_TEST_TOOLS 默认关闭，Dart 和 Android 共同启用，测试包 com.sbill.app.testing 与普通包 com.sbill.app 隔离。四个测试身份持有自己的私钥，通过真实申请/批准加入同一空账本，不伪造签名、不绕过权限、不自动填账。状态/日志不记录私钥、密钥、加入包或参数；同机包交换必须说明不是网络直连。\n\n## 7. 核心对象与标识`);
change('### 8.2 默认权限矩阵', `### 8.1.1 当前离线认领实现\n\n主人添加待认领伙伴并交付账本编号/伙伴编号 → 对方自己安装的 App 生成含公钥、设备标识、目标和 nonce 的签名申请 → 主人验签并通过可信渠道核对指纹 → 主人签名政策绑定该稳定 participantId → 生成随机高熵独立访问密钥加密的加入包 → 对方分别接收包和访问密钥，解密、验事件和本机公钥后加入。这个加入密钥不是弱用户口令，也不是已经实现的公钥 ECDH 密钥交换。\n\n导出不包含对方签名私钥；另一公钥不能再认领已绑定伙伴。群密钥随加密加入包交付，包和访问密钥合用可读取账本，不能公开同发。认领后继承原 participantId 的历史付款/承担；未认领不能代签共同确认。当前主人可移出伙伴但不物理删除历史；成员自助退出、主人移交、换机多设备与未来群密钥轮换仍未完成。\n\n### 8.2 默认权限矩阵`);
section('| 操作 | 群主 | 财务编辑 | 普通成员 | 只读成员 |','具体能力如 bill.create',`${table(['操作','账本主人','财务管理员','普通成员','只读成员'],[
 ['查看/生成本地预览/导入导出当前账本','是','是','是','是'],
 ['新增/改本人账目、本人声明还款','是','是','是','否'],
 ['改任意账目/解决冲突/作废','是','当前默认是','仅自己的常规修订/作废由核心校验','否'],
 ['发布正式结算/提交重组','是','当前默认是','否（可本地预览）','否'],
 ['管理成员/批准认领/政策更新','是','否','否','否'],
 ['本人签名批准/本人收款确认','有权且受影响时','有权且受影响时','有权且受影响时','当前禁止，导致受影响只读参与人的结算阻塞，尚需治理规则'],
 ['代别人签名/虚构确认','否','否','否','否'],
 ])}\n\n本矩阵同时标注当前实现与未解决问题，不是用“排除只读签名”降低全体受影响人确认的原要求。原 V1.0 对财务作废/发布写“可授权”，当前默认角色已有该能力；可配置细粒度授权界面仍需补。\n\n`);
change('## 10. 账单修订、作废与冲突', `### 9.7 当前外币编辑的已知缺口\n\nRust FxRateSpec 使用整数分子/分母并处理币种小数位，但 Flutter 外币付款编辑仍把已有原币金额统一 /100 显示，保存分母固定为 1，自动折算为 originalMinor × 整数分子。这在 JPY/KWD 等不同尺度或分数汇率下不正确，不能因 CNY/USD 7:1 样例通过而认定 AC-E07/E08 全部通过。目标仍是第 9.5/9.6 节的有理汇率与尺度约束，需修复而不是删掉要求。\n\n## 10. 账单修订、作废与冲突`);
change('## 12. 结算模式与计算规则', `### 11.4 当前还款闭环的不足\n\n已接通本人声明和收款人确认。Rust 也有 Disputed/PendingMapping 等模型及迟到映射能力，但正式 App 命令白名单和界面未开放争议/纠正/映射流程；通用还款对话框也尚未覆盖所有状态。提出结算当前检查财务/政策/提交冲突和 PendingMapping，未完整检查等待确认或争议付款。第 11.3 节“相关范围阻断”继续作为未完成 P0 要求保留。\n\n## 12. 结算模式与计算规则`);
change('以上数学示例已在本次文档制作中复算。它不构成产品实现或真实设备验收。', '以上样例现已在核心/FFI 回归中断言余额、8/6/6/3 笔数和正式义务流程。它仅是测试夹具/数学说明，不会填充到正式新账本，也不等于真实设备验收。当前 UI 初始选择合并 CNY + 最少次数，其他本地模式可切换；原“默认按币种一对一”是早期推荐而非已兑现的配置。');
change('## 14. 通用同步协议与状态', `### 13.6 当前结算限制\n\n合并币种界面固定 CNY，任意结算目标币种选择仍需实现。受影响只读成员可以承担财务，但当前核心禁止其签名批准/确认，与“所有受影响参与人本人确认”的要求形成阻塞。不得通过代签、静默剔除其签名或以测试台切换绕过解决；需要独立确认能力或明确的合法治理规则，并补验收。\n\n待重授权/政策分叉/提交分叉的处理、完整范围展示和多设备并发提交仍未形成完整产品闭环。基础快照/重组通过不等于本节所有异常规则已通过。\n\n## 14. 通用同步协议与状态`);
change('### 14.2 真正增量', `当前差距：正式文件导出取当前账本全部事件，没有给用户的对端摘要请求/增量选择；导入是逐事件事务和摘要，而非整包/整个工作区原子提交。只显示新增/重复/拒绝等摘要，待依赖/待授权/待升级范围不完整。下述真正增量、确认、独立重试与整包原子要求继续保留为待完成。\n\n### 14.2 真正增量`);
change('## 15. 局域网主同步与弱网策略', '## 15. 局域网主同步与弱网策略\n\n**当前未接通真实 LAN。**固定 IP 发现 DTO、组播锁和进程内 sync_lan_with_peer 不是实际发现/socket/握手。以下仍是目标，不能把模拟新增事件或 AP 隔离开关断言当成真机网络验收。');
change('## 16. WebDAV 加密异步留存', '## 16. WebDAV 加密异步留存\n\n**当前未接通 HTTP WebDAV。**只有 WebDavRemoteStore 接口、InMemoryWebDavStore、出箱和模拟可达性；以下真实认证、证书校验、上传/拉取、退避和节点迁移仍是需求。');
change('## 18. 完全无无线连接的光学通道', '## 18. 完全无无线连接的光学通道\n\n**当前只是 JSON/XOR 分片恢复与演示。**画面是仿二维码，没有标准 QR/Multipart UR 编码或相机解析；也没有双向摘要请求/确认和持久接收缓存。以下光学场景均未完成真实产品/物理设备验收。');
change('## 19. 附件、备份与恢复', '## 19. 附件、备份与恢复\n\n当前只有整块加密附件/缺失报告和个人口令备份原型，正式账目 FFI 写空附件列表，没有附件或备份/换机用户入口。备份原型的单次 BLAKE3 口令派生和确定性盐不满足安全 KDF 要求；普通私有 SQLite 存种子/群密钥不等于 Keystore/Keychain 安全存储。以下需求不能标为已经完成。');
change('下表是未来产品必须执行的验收用例，不表示本次已经运行应用测试。','下表保留原 61 条验收场景和预期，新增 11 条。状态说明：基础自动化 = 主要基础断言已有，不代表全设备通过；部分覆盖 = 只有子场景/核心层；仅模拟/原型 = 不是真实传输；未验收 = 缺专项或物理平台；已知缺口 = 当前实现不符合部分目标；未实现 = 缺实际能力。具体证据编号见第 27.3 节。');
const acStart = md.indexOf('| 用例 ID | 场景 | 预期结果 | 优先级 |');
const acEnd = md.indexOf('## 23. 建议实施顺序与交付物', acStart);
assert.ok(acStart > 0 && acEnd > acStart);
md = md.slice(0, acStart) + table(['用例 ID','场景','预期结果（原标准保留）','优先级','验证状态','证据与未覆盖范围'], acRows) + '\n\n' + md.slice(acEnd);
change('以下资源用于支持架构可行性和平台条件；不是本应用的实现验收。文档条件在本次讨论中检索，未来开发时应再次核对版本和地区。', '以下是 V1.0 于 2026-10-12 调研的公开技术参考，支持架构可行性而非应用实现。V1.1 未重新检索厂商/平台网页；机型、版本、地区和后台条件在真正开发/验收前须复核，不将旧参考当作当前已测事实。');
md += `\n## 26. v0.2.1 实现基线、验证与交付\n\n### 26.1 本版实际可用范围\n\n- Android arm64 普通版：空白首用、多账本创建/选择/隔离、本人签名、伙伴待认领/主人批准/角色管理、基础多币种记账和修订/冲突、四模式核心结算/确认义务、手动加密文件或同步码交换、自定义 Emoji 分类。已知财务与异常闭环缺口见第 27 节。\n- 开发者测试版：独立包名、可拖动/收起控制台，四身份合法认领同一空账本，同机加密包交换、状态和最多 100 条不含参数/密钥的调用记录。\n- 普通启动不开放演示角色切换/模拟网络/仿 QR；旧演示代码只供旧测试夹具，不因可调用测试方法而宣称产品接通。\n- 真实 LAN、HTTP WebDAV、标准 QR/相机、iOS、完整附件和可靠安全恢复、原币债务/同成员多设备/报表/链锚仍未兑现。\n\n### 26.2 核验层级与当前证据\n\n- 现有 Rust 回归 23/23、普通 Flutter 构建 7/7、测试构建 10/10。23 个 Rust 测试包括核心 11、冒烟 7、工作区 5；这些测试数量不是 AC 完成数量，也不能把含多个 AC 的测试名称当逐条通过。\n- Flutter Widget 验证过 390×844 下的创建/首笔账目/切回目录及测试浮层操作；MethodChannel 的测试目录适配使用 mock，但签名/SQLite/认领/事件包是真实 Rust。没有把四目录测试当四台物理设备。\n- 当前静态分析 0 errors、7 条既有 warning/info（退出码 1），没有无告警通过声明。\n- APK 已生成并核对包名/版本/完整性/arm64 Rust 库及普通版 AOT 控制台入口裁剪。当前尚未做手机安装/双机文件分享/关闭公网/摄像头/最低系统/跨平台或性能能耗验收。\n\n### 26.3 构建产物和系统边界\n\n${table(['版本','包名/标识','产物','安装元数据/边界'],[
 ['普通 v0.2.1+3','com.sbill.app；同行账本','同行账本_Sbill_v0.2.1_release.apk（22,365,660 字节）','arm64-v8a；minSdk 24；targetSdk 36；沿用 debug 签名，供试用'],
 ['测试 v0.2.1+3','com.sbill.app.testing；同行账本·测试','同行账本_Sbill_v0.2.1_testing.apk（22,497,076 字节）','SBILL_TEST_TOOLS=true；独立 Android 数据目录，与普通版并排'],
 ])}\n\nminSdk 24 只是 Android 7.0 安装元数据，不代表已在 Android 7/所有机型实测；推荐先验收 Android 10+ 的原目标保留。只有 arm64 Android 核心，其他 ABI 无交付；macOS 动态库用于本机 FFI 测试，不是已发布 macOS 应用。iOS 15+ 仍为目标，没有 app/ios 工程或产物。不得为测试卸载或清除已有普通版数据。\n\n### 26.4 复验命令\n\n\ CODE\ bash\n/Users/Jerry/.cargo/bin/cargo test --manifest-path /Users/Jerry/Documents/Sbill/rust_core/Cargo.toml\ncd /Users/Jerry/Documents/Sbill/app\n/Users/Jerry/flutter/bin/flutter test\n/Users/Jerry/flutter/bin/flutter test --dart-define=SBILL_TEST_TOOLS=true\n/Users/Jerry/flutter/bin/flutter analyze\n\ CODE\ \n\n## 27. 完整性结论、未完成门槛与证据索引\n\n### 27.1 是否完成全部 PRD\n\n**否。**本版是 Android 本地/手动协作试用版本，不是原 Android/iOS、LAN 优先、异步留存和安全恢复完整产品。23 项 FR 中 7 已实现、12 部分、4 未实现；原 20 项的优先级与全部 61 条预期没有删减。新增后 72 条 AC 逐条区分证据层级，尚无全量通过结论。连 P0 也未全部完成。\n\n### 27.2 主要差距与发布门槛\n\n${table(['编号/优先级','差距','必须完成的验收'],[
 ['GAP-01 / P0','外币编辑与冻结汇率不完整','修复不同币种尺度、分母/小数汇率与原币显示；覆盖 JPY/KWD 等、再编辑不丢值、正确尾差与元数据。E-FX'],
 ['GAP-02 / P0','还款争议/纠正/迟到映射与结算状态阻断不完整','提供授权用户闭环，待确认/争议/待映射均按明确范围阻断；真实部分/超额/两笔同额款专项。E-PAY'],
 ['GAP-03 / P0','受影响只读成员无法本人批准正式义务，治理异常无完整入口','定义独立确认能力或明确合法治理；不得代签或剔除本人确认；政策/提交分叉、重授权全链路验证。E-AUTH/E-SET'],
 ['GAP-04 / P0','密钥安全与可靠恢复仍是原型','平台安全存储、安全口令 KDF、数据/密钥/附件分离备份、换机授权、未来群密钥轮换与旧副本边界。E-BKP'],
 ['GAP-05 / P0','真实 LAN、HTTP WebDAV 和 iOS 未接入','两设备无公网发现/连接/补传；真实错峰 HTTP/认证/证书；iOS 工程与同规则双向原文件验收。E-LAN/E-DAV/E-IOS'],
 ['GAP-06 / P0','导入/元数据/多库一致性与同步状态不完整','整包原子或明确独立分包事务；错误/中断前后数据库不变与重试不重复；待依赖/授权/升级、业务接收确认完整展示。E-FILE/E-WSP'],
 ['GAP-07 / P0/P1','分类删除因果/旧分类迁移及页面筛选未完整','并发删除与新增不复活、历史分类保留；明确分类结构和旧数据迁移；成员/时间/币种过滤按规划补齐。E-CAT'],
 ['GAP-08 / P1','真实光学与附件产品未实现','标准 QR/UR + camera + 双向请求/确认 + 分片缓存，真实反光/低端机矩阵；附件选择/显示/分块补传。E-OPT/E-ATT'],
 ['GAP-09 / 全版本门槛','真机、性能、能耗与故障恢复未验收','执行第 21 节目标和机型数据集：启动/1000事件/求解/包体积/实际吞吐，强杀/断电/切网和能耗；正式签名后再评估发布'],
 ])}\n\n未完成项不能因本版暂只提供手动通道而被删掉。建议先修 P0 财务/安全/事务与双机文件闭环，再接真实 LAN/WebDAV 与 iOS，随后 P1 光学/附件，最后 P2 增强；不在本次文档更新中承诺日期或执行代码修复。\n\n### 27.3 源码与测试证据索引\n\n路径均相对项目根 /Users/Jerry/Documents/Sbill，行号为本次核对位置；代码可能后续移动，以函数名和测试名检索。证据用于状态核对，不等于全面审计。\n\n${table(['编号','实现定位','测试/验证范围'],[
 ['E-WSP','rust_core/src/workspace.rs:108 AppCommand、240 save_catalog、420 update_policy、456 approve、513 join；app/lib/ui/screens/workspace_home_screen.dart:69','rust_core/tests/workspace_suite.rs；app/test/workspace_onboarding_test.dart：空白、多库、认领、正常重开与旧数据'],
 ['E-MONEY','rust_core/src/engine.rs:11 EXACT_DP_MAX_NONZERO_MEMBERS、15 apportion_by_weights、74 compute_resolved_shares；domain.rs:157 FxRateSpec','core_m1_m3_suite.rs 的 splits / four_settlement_modes / exact_bitmask_dp；smoke_suite.rs 的 smoke_02'],
 ['E-FX','app/lib/ui/screens/expense_editor_sheet.dart:161 原币 /100、324 分母1、1314 _recalcForeignPayer；rust_core/src/domain.rs:157','Rust 混合币种样例不覆盖 Flutter 外币编辑错误；本次为源码核对，未新增故障测试'],
 ['E-REV','rust_core/src/storage.rs:1064 ExpenseUpsert 投影；app/lib/ui/screens/conflict_resolution_screen.dart、expense_detail_screen.dart','core_m1_m3_suite.rs permissions/concurrent、M4 FFI；smoke_suite.rs 联合流程；非任意并发全集'],
 ['E-AUTH','rust_core/src/domain.rs:31 default_capabilities；storage.rs:1004 陈旧权限、1703 身份校验；workspace.rs:621 撤权检查点','workspace_suite.rs：冒领、越权、只读签名拒绝、待核对不复活；未验证完整治理 UI'],
 ['E-PAY','rust_core/src/ffi.rs:1268 仅 PendingMapping 阻断；workspace.rs:729 命令白名单；settlement_center_screen.dart:739 通用还款','core_m1_m3_suite.rs overpayment/late mapping；app/test/m4_closed_loop_test.dart、m5_settlement_center_test.dart'],
 ['E-SET','rust_core/src/ffi.rs:1241 propose_settlement、1312 required_approvers；app/lib/ui/screens/settlement_center_screen.dart:218/509 固定CNY','four_settlement_modes、M5 FFI/Flutter；workspace_suite.rs:360 Viewer 禁止批准，未形成只读财务确认闭环'],
 ['E-LAN','rust_core/src/api.rs:535 sync_lan_with_peer；sync.rs:206 select_events_missing_on_peer；ffi.rs:1579 固定发现地址','M3/M7 测试：仅进程内交换/游标/标志，不是网络'],
 ['E-DAV','rust_core/src/sync.rs:491 WebDavRemoteStore、510 InMemoryWebDavStore、586 sync_with_webdav；ffi.rs:694 configure_webdav','M3/M6 内存 Store/队列/假哈希拒绝；无真实HTTP'],
 ['E-FILE','MainActivity.kt:45 分享、78 选择器、173 readBounded；ffi.rs:583 全量导出、611 导入；storage.rs:567/670 事务','独立目录交换、损坏码、跨群/zlib 限额有覆盖；Android/iOS 分享和故障矩阵未测'],
 ['E-OPT','rust_core/src/sync.rs:276 编码、411 ingest_frame；optical_qr_sync_screen.dart:353 仿 QR 绘制、304 内存帧接收','smoke_09/M3/M7 算法；没有真实相机/标准QR'],
 ['E-PNG','rust_core/src/sync.rs:658 embed_tripdelta_into_png、688 extract_tripdelta_from_png','smoke_09 容器摘要/事件数、伪JPEG/空PNG；没有产品入口'],
 ['E-ATT','rust_core/src/storage.rs:398/431 整块附件存取；ffi.rs:1086 空 attachment_refs','smoke_10 加密/缺失诊断；无附件用户闭环'],
 ['E-BKP','rust_core/src/sync.rs:769/794 私钥备份、817 derive_passphrase_key、837 完整度；storage.rs:331 种子、ffi.rs:299 群密钥元数据','smoke_10 原型恢复；无安全KDF/换机/Keystore/Keychain'],
 ['E-IOS','app/ios 不存在；sbill_rust_bridge.dart 的 DynamicLibrary.process 只是预留分支','无 Xcode 工程、iOS 原生适配或产物；不是已通过跨平台'],
 ['E-ADV','domain.rs 原币付款信息、workspace.rs 安装 device_id 是基础；sync.rs zlib 是传输包压缩','未定位原币债务、多设备授权、报表/历史回收/链锚产品入口'],
 ['E-CAT','rust_core/src/storage.rs:996 序号排序、1043 retain 删除；ffi.rs:1600 旧本机分类合并；expense_editor_sheet.dart','smoke_12 指定三节点并集/删除；m4 持久化；无单选取消专项或完整删除因果矩阵'],
 ['E-DEV','app/lib/build_config.dart；main.dart 条件入口；state/test_console_controller.dart；test_console_overlay.dart；Android BuildConfig 开关','app/test/test_console_test.dart：普通拒绝、四私钥/角色/包交换、坏库/旧编辑/记录上限；APK 包名和入口标记'],
 ])}\n`;
md = md.replaceAll('\\\u0000CODE\\\u0000', '```').replaceAll('\u0000CODE\u0000', '```');
assert.ok(!md.includes('\u0000'), 'Unexpected placeholder');
// Preserve every original ID, scenario, expected result and priority in the new status tables.
for (const [id, scene, expected, priority] of originalAc) {
  assert.ok(md.includes(`| ${id} | ${scene} | ${expected} | ${priority} |`), `Changed original AC ${id}`);
}
for (const [id, title, priority] of originalFr) assert.ok(md.includes(`| ${id} | ${title} | ${priority} |`));
assert.equal(md.split('\n').filter(v => /^\| FR-/.test(v)).length, 23);
assert.equal(md.split('\n').filter(v => /^\| AC-/.test(v)).length, 72);
await mkdir(`${root}/deliverables`, { recursive: true });
await writeFile(mdPath, md);

const doc = createDocument({title: '同行账本：离线优先共享旅行记账 PRD', template: 'report',
 theme:{baseSize:10.5}, page:{size:'A4',margins:{top:20,bottom:20,left:20,right:20}},
 header:{left:'同行账本 PRD V1.1',right:'实现基线 v0.2.1+3'}, footer:{pageNumber:true}});
const plain = text => text.replace(/`([^`]+)`/g,'$1').replace(/\*\*([^*]+)\*\*/g,'$1').replace(/\[([^\]]+)\]\(([^)]+)\)/g,'$1（$2）');
const rich = text => {
 const runs = []; let index=0;
 const re = /\*\*([^*]+)\*\*|\[([^\]]+)\]\(([^)]+)\)|`([^`]+)`/g;
 for (const match of text.matchAll(re)) {
  if(match.index>index) runs.push({text:text.slice(index,match.index)});
  if(match[1]) runs.push({text:match[1],bold:true});
  else if(match[2]) runs.push({text:match[2],link:match[3]});
  else runs.push({text:match[4]});
  index=match.index+match[0].length;
 }
 if(index<text.length) runs.push({text:text.slice(index)});
 return runs;
};
const lines = md.split('\n'); let inCode=false;
for(let i=0;i<lines.length;i++) {
 const line=lines[i].trim();
 if(line.startsWith('```')) {inCode=!inCode;continue;}
 if(inCode) {doc.push(new Paragraph({children:[new TextRun({text:line,font:'Courier New',size:16})],spacing:{after:60}}));continue;}
 if(!line || /^---+$/.test(line)) continue;
 if(line.startsWith('# ')) {addTitle(doc,line.slice(2),{subtitle:'V1.1 · 当前实现、保留目标与逐项验收'}); addToc(doc,{levels:2});continue;}
 const heading=line.match(/^(#{2,4}) (.+)$/);
 if(heading){addHeading(doc,heading[2],{level:heading[1].length-1});continue;}
 if(line.startsWith('|')) {
  const block=[];
  while(i<lines.length && lines[i].trim().startsWith('|')) {block.push(cells(lines[i]));i++;}
  i--;
  const headers=block[0].map(plain), rows=block.slice(2).map(r=>r.map(plain));
  let columnWidths;
  if(headers[0]==='需求 ID') columnWidths=[15,19,7,11,38,10];
  else if(headers[0]==='用例 ID') columnWidths=[12,16,27,7,13,25];
  else if(headers[0]==='编号/优先级') columnWidths=[15,30,55];
  else if(headers[0]==='编号' && headers.length===3) columnWidths=[12,47,41];
  addTable(doc,{headers,rows,columnWidths,fontSize:headers.length>=5?8.5:9,keepTogether:false,allowRowSplit:false});continue;
 }
 if(line.startsWith('> ')){addParagraph(doc,rich(line.slice(2)));continue;}
 if(line.startsWith('- ')){const items=[plain(line.slice(2))];while(i+1<lines.length&&lines[i+1].trim().startsWith('- ')){items.push(plain(lines[++i].trim().slice(2)));} addBullets(doc,items);continue;}
 if(/^\d+\. /.test(line)){const items=[plain(line.replace(/^\d+\. /,''))];while(i+1<lines.length&&/^\d+\. /.test(lines[i+1].trim())){items.push(plain(lines[++i].trim().replace(/^\d+\. /,'')));}addNumbered(doc,items);continue;}
 addParagraph(doc,rich(line));
}
assert.equal(inCode,false,'Unclosed code block');
await saveDocument(doc,docxPath);
console.log(JSON.stringify({markdown:mdPath,word:docxPath,frCount:23,originalFr:20,acCount:72,originalAc:61,statusCounts:counts},null,2));
