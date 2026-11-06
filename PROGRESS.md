# 同行账本（Sbill）项目开发进度追踪

> **用途**：本文件作为跨会话、防上下文丢失的持久进度基准。每次模块开发或状态变更后均同步更新本文件。
> **工作目录**：`/Users/Jerry/Documents/Sbill`
> **关联文档**：
> - 最新 PRD（Markdown）：[同行账本 PRD V1.2](/Users/Jerry/Documents/Sbill/deliverables/同行账本_PRD_v1.2.md)
> - 最新 PRD（Word）：[同行账本 PRD V1.2](/Users/Jerry/Documents/Sbill/deliverables/同行账本_PRD_v1.2.docx)
> - V1.0/V1.1 保留归档，不覆盖。
> - **当前产品结论（2026-11-06，v0.3.2+6 / core 0.2.0 / schema V3）**：已接通真实标准 ISO/IEC 18004 瀑布二维码展示与喷泉码持久化接收、相机扫码/连续帧流导入、正式版 WebDAV 配置与真实 HTTP/HTTPS 对象同步、局域网 HTTP 节点直连同步、还款异议/迟到映射以及 Argon2id 加密身份备份导出恢复；真机双手机物理实测、Android Keystore 硬件密钥、分块附件 UI 与正式签名仍待验收。最新逐项状态见本文件第十三节。
> - 全项目冒烟用例清单：`/Users/Jerry/Documents/Sbill/SMOKE_TEST_CASES.md`

---

## 一、本机开发环境快照（最近核实：2026-10-31）

| 组件 | 当前状态 | 路径 / 版本备注 |
|---|---|---|
| **操作系统** | 已就绪 | macOS 26.5.1 (`arm64` Apple Silicon, 16 GB RAM) |
| **Rust 工具链** | 已就绪 | `rustc 1.99.1` / `cargo 1.99.1` (`/Users/Jerry/.cargo/bin`) |
| **Android Studio** | 已就绪 | `2026.2` (`/Applications/Android Studio.app`，自带 JBR) |
| **Android SDK** | 已就绪（含 NDK） | `/Users/Jerry/Library/Android/sdk`（`platforms/android-37.0` + 构建自动补装的 `android-36`、`build-tools/36.0.0`、`platform-tools`、`emulator`、`system-images`、`ndk/28.2.13676358`、`cmdline-tools/latest` 23.0；licenses 已全部接受） |
| **Flutter SDK** | 已就绪（arm64 原生） | `3.47.9` stable / Dart `3.13.7`，位于 `/Users/Jerry/flutter`（arm64 包，`flutter doctor` 不再报 Rosetta）；旧的 x86_64 包保留在 `/Users/Jerry/flutter-x64-rosetta` 备用。`~/.zshrc` 已配 PATH，`flutter config` 指向该 Android SDK 与 Android Studio 自带 JBR（JDK 25.0.4） |
| **Rust 动态库（macOS）** | 已构建完成 | `/Users/Jerry/Documents/Sbill/rust_core/target/release/libsbill_core.dylib` |
| **Rust 动态库（Android arm64）** | 已构建完成 | `/Users/Jerry/Documents/Sbill/rust_core/target/aarch64-linux-android/release/libsbill_core.so`，已拷入 `app/android/app/src/main/jniLibs/arm64-v8a/`（NDK 28.2 clang + API 24 交叉编译） |

---

## 二、模块总览与当前进度（算法、界面与真实传输分别验收）

> **2026-11-03 更正**：历史“全部完成”仅覆盖算法/FFI 与演示流程，不能认定真实 LAN、HTTP WebDAV、摄像头 QR、全部财务规则或安全恢复已完成。当前 v0.3.0+4 的逐项结论以 PRD V1.2 和第十一节为准；第八至十节保留版本历史。

| 模块 | 名称 | 状态 | 核心产物路径 | 验证状态 |
|---|---|---|---|---|
| **M0** | 跨语言桥接与工程脚手架 | **Android/本机 FFI 已实现，iOS 待开发** | `rust_core/src/ffi.rs`, `app/lib/bridge/sbill_rust_bridge.dart`, `app/android/` | Rust C-ABI FFI 基础闭环通过；无 iOS 工程/产物 |
| **M1** | Rust 密码学、规范编码与事件日志存储层 | **核心主干已实现，完整安全/故障验收未完成** | `rust_core/src/crypto.rs`, `rust_core/src/storage.rs` | 严格验签、版本/缺序边界、单库事件/outbox 整包 SQL 故障回滚通过；SQLite 密钥保护、工作区和真机故障仍待补 |
| **M2** | Rust 多币种账单、权限修订与四模式结算引擎 | **核心主干已实现，完整财务闭环未验收** | `rust_core/src/domain.rs`, `rust_core/src/engine.rs`, `rust_core/src/storage.rs` | 四模式、精度/输入、统一阻断与过期提交保护通过；治理/还款异常和完整矩阵仍有缺口 |
| **M3** | 同步包封装、WebDAV、PNG、附件与备份核心 | **部分核心已加固，真实通道和完整恢复待补** | `rust_core/src/sync.rs`, `rust_core/src/api.rs` | Argon2id/随机盐/元数据认证通过；内存 Store 非 HTTP，PNG 非图像矩阵，备份核心非完整换机产品 |
| **M4** | Flutter 核心账本 UI | **外币精度、可选记账时间、排序分组与筛选已实现，草稿等仍待补** | `app/lib/ui/`, `app/lib/state/`, `app/test/expense_schedule_filter_test.dart` | 未来账、星期分组、五类筛选和 JPY 再编辑通过；完整币种/元数据和真机未验收 |
| **M5** | Flutter 结算与收付中心 | **目标币种、本人确认、阻断/冻结展示已补，异常闭环待补** | `app/lib/ui/screens/settlement_center_screen.dart`, `app/test/m5_settlement_center_test.dart` | 待确认 UI 禁用、冻结方案不随预览变化、Viewer 本人确认通过；争议/纠正/迟到映射与治理入口未完 |
| **M6** | Android 文件互传与 WebDAV | **单库整包事务已补，真实 WebDAV 待开发** | `app/lib/ui/screens/companion_center_screen.dart`, `app/android/app/src/main/kotlin/com/sbill/app/MainActivity.kt` | 单库整包错误回滚/重试/幂等通过；跨库/catalog 与完整同步范围未完，双机系统互传未实测 |
| **M7** | 局域网与动态 QR | **真实传输待开发** | `app/lib/ui/screens/optical_qr_sync_screen.dart`, `app/test/m7_lan_and_optical_qr_test.dart` | 仅进程内模拟/分片编解码；无真实发现/socket/标准 QR/camera scanner |
| **WORKSPACE** | 多账本、空白引导、成员认领 | **主干已实现** | `rust_core/src/workspace.rs`, `app/lib/ui/screens/workspace_home_screen.dart` | 独立安装身份、正常重开和手机尺寸 UI 回归通过；双机/故障待验收 |
| **DEVTOOLS** | 仅测试版四身份浮层 | **已实现，真机待验收** | `app/lib/state/test_console_controller.dart`, `app/lib/ui/widgets/test_console_overlay.dart` | 普通/测试裁剪、独立私钥与目录、合法认领/包交换/错误恢复回归通过 |
| **SMOKE** | 核心、FFI 与界面回归 | **自动化通过，非完整 PRD 验收** | `rust_core/tests/`, `app/test/`, `SMOKE_TEST_CASES.md` | Rust 41/41，Flutter 普通 18/18、测试 21/21；真机/性能/完整安全未全量验收，iOS 本轮排除 |

---

## 三、常用回归与真机启动命令

```bash
# 1. 运行 37 个 Rust 核心、安全、原子导入、兼容、FFI 与工作区回归测试
/Users/Jerry/.cargo/bin/cargo test --manifest-path /Users/Jerry/Documents/Sbill/rust_core/Cargo.toml

# 2. Flutter 单元测试与真机联调
cd /Users/Jerry/Documents/Sbill/app
flutter pub get
flutter test
flutter run

# 3. 重新交叉编译 Android 端 Rust 动态库并放入 jniLibs
export NDK=/Users/Jerry/Library/Android/sdk/ndk/28.2.13676358
export TOOLCHAIN=$NDK/toolchains/llvm/prebuilt/darwin-x86_64
export CC_aarch64_linux_android=$TOOLCHAIN/bin/aarch64-linux-android24-clang
export AR_aarch64_linux_android=$TOOLCHAIN/bin/llvm-ar
export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER=$TOOLCHAIN/bin/aarch64-linux-android24-clang
/Users/Jerry/.cargo/bin/cargo build --release --target aarch64-linux-android --manifest-path /Users/Jerry/Documents/Sbill/rust_core/Cargo.toml
cp /Users/Jerry/Documents/Sbill/rust_core/target/aarch64-linux-android/release/libsbill_core.so \
   /Users/Jerry/Documents/Sbill/app/android/app/src/main/jniLibs/arm64-v8a/
```

---

## 四、Flutter 环境就绪后的首次真实验证（2026-10-31）

- `flutter pub get` 通过（27 个依赖解析成功；工具自动升级了 `analysis_options.yaml` 的 exclude 配置）。
- `flutter test`：4 个用例，2 通过、2 失败：
  - `test/m7_lan_and_optical_qr_test.dart`：`ServicesBinding` 未初始化——测试 `main()` 里直接经 `LedgerController.configureLanDiscovery` 调用 `MethodChannel`，需先 `TestWidgetsFlutterBinding.ensureInitialized()`。
  - `test/m6_sync_center_test.dart:47`：断言 `expect(..., greaterThanOrEqualTo(1))` 实际为 `0`。
- 结论：M6/M7 之前标注的"FFI 全流程测试已通过"只在 Rust/FFI 层成立，Flutter 侧此前从未真实执行；上述两处修复后 Flutter 测试才算真正通过。
- 另需注意：`app/android/` 下只有 `app/` 子目录，缺 `android/app/build.gradle(.kts)`、`gradle.properties`、`settings.gradle` 等脚手架文件，`flutter run` 前需要补齐。

---

## 五、缺口补齐与 M6/M7 修复（2026-10-31 二次验证，全部通过）

**根因**
1. 首装的 Flutter SDK 是 x86_64 包（`flutter doctor` 显示 Rosetta），Dart VM 与 arm64 `libsbill_core.dylib` 架构不匹配，FFI 加载抛 `ArgumentError` 后**静默退化**到 `_FallbackDeterministicEngine`，于是 M6 的篡改拦截计数走了兜底引擎的错误实现。已换成官方 arm64 包（`flutter_macos_arm64_3.47.9-stable.zip`），`flutter doctor` 现为 `darwin-arm64`，测试已确认 `isNativeRustLoaded == true`（走 Rust FFI）。
2. M7 失败是测试缺 Flutter Binding：`configureLanDiscovery` 会经 `MethodChannel` 调用 Android 侧 `setMulticastLock`。已在测试 `main()` 加 `TestWidgetsFlutterBinding.ensureInitialized()`。
3. M6 失败是 WebDAV 报告的语义缺陷：`SimulateRemoteWebDavIncoming` 记录的篡改计数会被随后的 `SyncWebDavNow` 覆盖成 0。Rust 侧本来就正确（拉取时累计），兜底引擎已补上"待消费的拉取/篡改计数"并在同步时结算，两条引擎语义一致。

**补齐的工程缺口**
- `app/android/` 用 `flutter create --platforms=android --project-name app --org com.sbill` 生成，合并时保留自定义的 `MainActivity.kt`、`AndroidManifest.xml`、`local.properties`；包名统一为 `com.sbill.app`，生成 `gradlew`/`settings.gradle.kts`/`build.gradle.kts`/`gradle.properties`/`res/`。
- `app/lib/ui/theme/app_theme.dart` 补 `package:flutter/cupertino.dart` 导入：Flutter 3.47 起 `CupertinoPageTransitionsBuilder` 不再由 `material.dart` 导出，原代码无法编译。
- 新增 Android 端 Rust 产物：`rustup target add aarch64-linux-android`，用 NDK 28.2 的 `aarch64-linux-android24-clang` 交叉编译，产物放入 `app/android/app/src/main/jniLibs/arm64-v8a/libsbill_core.so`。

- **验证结果**
- `flutter test`：4/4 全通过（M4–M7），且确认跑在 Rust FFI 上而非兜底引擎。
- `flutter analyze`：0 error，6 条 warning/info（未使用的 import、`RadioListTile.value` 已废弃等）。
- `flutter build apk --debug` 成功，`app-debug.apk` 内已含 `lib/arm64-v8a/libsbill_core.so`。
- 仅 arm64-v8a 带 Rust 库，armeabi-v7a / x86_64 仍会走兜底引擎；需要覆盖这些 ABI 时按同样方式补交叉编译。

---

## 六、SQLite 全状态落盘持久化升级（2026-11-02 已完成并验证）

**解决的问题**
- 此前 `WorkspaceSession` 默认使用 `LedgerRepository::open_in_memory()`，导致在手机上杀掉进程重启 App 后，新增账单、新增成员密钥、修改过的汇率与当前视角丢失并退回 2 条演示数据。

**落地改造**
1. **SQLite 持久化表扩展（`rust_core/src/storage.rs`）**：
   - 除原有的 `events`、`webdav_outbox`、`attachments` 表外，新增 `workspace_meta`（保存 `group_id`、`active_actor_id`、`cipher_b64`、`default_fx_rates`、`webdav` 配置等）、`local_member_keys`（持久化初始及后续动态新增成员的 Ed25519 私钥种子）与 `webdav_remote_mirror`。
2. **持久化会话加载与自动落盘（`rust_core/src/ffi.rs`）**：
   - 新增 `WorkspaceSession::open_or_init_persistent(db_path)` 与 `FfiCommand::OpenPersistentWorkspace { db_path }`：仅当磁盘 SQLite 文件首次创建（`total_event_count() == 0`）时写入创世政策和 2 条初始示例账单；后续重启打开已有数据库时直接恢复所有历史事件、成员密钥、当前视角及汇率配置，不再重置。
   - 每次执行写操作后自动调用 `persist_session_metadata()` 同步落盘。
3. **Android 私有目录路径接入（`MainActivity.kt` & `ledger_controller.dart`）**：
   - `MainActivity.kt` 的 `com.sbill.app/fileshare` 通道新增 `getDatabasePath`，返回 Android 私有持久化路径 `File(filesDir, "sbill_ledger_v1.sqlite3").absolutePath`。
   - `LedgerController.initialize()` 启动时自动获取该路径并发送 `OpenPersistentWorkspace` 指令。

**验证结果**
- `cargo test`：17 组测试（含新增的跨进程重启测试 `smoke_11_sqlite_disk_persistence_across_app_restart`）全部通过。
- `flutter test`：5/5 全部通过（含新增的 `SQLite disk persistence across controller restart` 测试）。
- 已重新编译 `libsbill_core.dylib`（macOS）与 `libsbill_core.so`（Android `arm64-v8a`），并重新打包生成：
  - Release 版 APK（AOT 编译、丝滑动画、适合小米真机独立安装）：`/Users/Jerry/Documents/Sbill/同行账本_Sbill_v0.1.0_release.apk`（同 `/Users/Jerry/Documents/Sbill/app/build/app/outputs/flutter-apk/app-release.apk`，约 21 MB，内含 `lib/arm64-v8a/libsbill_core.so`）
  - Debug 版 APK：`/Users/Jerry/Documents/Sbill/app/build/app/outputs/flutter-apk/app-debug.apk`

---

## 七、记账分类单选/取消修复与自定义分类（Emoji 图标库 + SQLite 持久化，2026-11-02）

1. **修复分类变多选且无法取消的问题**（`app/lib/ui/screens/expense_editor_sheet.dart`）：
   - 将分类选中状态改为独立的 `_selectedCategoryId` 单选变量，并实现 `_stripKnownCategoryPrefix` 与 `_toggleCategorySelection`：
     - 点击未选中的分类：严格单选，自动替换标题中的旧分类前缀，不再将多个分类名拼接到一起；
     - 再次点击已选中的分类（或点击芯片右侧 `×`）：立即取消选中，并干净移除标题中的分类前缀，保留用户手写的描述文字。
2. **新增自定义分类（36 枚精选旅行 Emoji 图标网格 + 支持键盘输入任意 Emoji + 长按删除 + 跨设备签名事件流并集同步）**：
   - 分类栏末尾新增 `+ 自定义分类` 按钮，弹出图标与名称选择面板；
   - `rust_core/src/domain.rs` 与 `src/storage.rs` 新增 `EventBody::CategoryUpsert(CustomCategoryUpsertPayload)` 签名事件：
     - 有记账权限的成员新增或删除自定义分类会生成 Ed25519 签名事件，随通用事件包同步。当前正式界面使用 `.tripdelta` 文件/同步码；LAN、WebDAV 和光学通道仅有模拟或编解码验证，尚未完成真实接入；
     - 投影层 `build_projection` 对所有成员的自定义分类取**确定性并集（Set Union）**，同名分类按全局确定性事件序去重收敛（已由 `smoke_12_multi_peer_custom_category_sync_union` 验证通过）。
   - 当日重新编译 `libsbill_core.so` 并导出 Release APK：`/Users/Jerry/Documents/Sbill/同行账本_Sbill_v0.1.0_release.apk`。

---

## 八、多账本、空白引导与伙伴本人认领（2026-11-03，v0.2.0）

### 已实现

- **账本目录与隔离**：`rust_core/src/workspace.rs` 提供安装级目录和本机身份。目录位于 Android 私有目录的 `sbill_ledger_v1.catalog.sqlite3`；每个新账本使用独立的 `ledger_<group_id的BLAKE3十六进制>.sqlite3`，不直接拼接外来 ID 到路径。事件、伙伴政策、自定义分类、汇率、结算、群密钥与同步队列隔离；恢复当前账本选择。
- **无示例真实启动**：`main.dart` 使用 `initializeApp` / `WorkspaceHomeScreen`，首次进入显示“创建出行账本 / 加入同行账本”。创建只需要出行名称和本人昵称，同行伙伴每行一位、可跳过。仅写创世政策，不预填示例账目，也不填写假设汇率。空账本提示“记第一笔”。
- **本机身份**：安装生成随机 Ed25519 身份与 device_id，新账本生成随机 group_id、participant_id 和群密钥。每个账本只以本机绑定身份操作；正式路径拒绝 `SwitchActor`、模拟操作、重置示例及代造其他人私钥。Rust 不可加载时启动显示错误，不静默回退到内存演示引擎。
- **伙伴管理**：主人可添加待认领伙伴，调整普通成员/财务管理员/只读成员权限，移出或重新启用伙伴。移出仅设置 inactive，保留历史引用和欠款；新账目不再分摊给 inactive 伙伴。主人不能删除或降权自己，财务管理员不能管理成员。
- **离线本人认领**：主人把账本与伙伴编号给对方；对方 App 生成含公钥、目标账本/伙伴和随机 nonce 的签名申请。主人验签并核对申请人与身份指纹后审批，政策绑定其公钥。返回随机高熵访问密钥加密的加入包，对方分别接收加入包和密钥、解密并核验所有事件和本机公钥后加入。任何其他安装身份不能导入该加入包；另一公钥不能再次认领已绑定伙伴。主人从不取得对方私钥。
- **真实手动同步**：已认领伙伴可交换当前账本的 `.tripdelta` 文件或 `SBILL1:` 同步码。Android 分享改用 FileProvider / EXTRA_STREAM，新增系统文件选择器；文件读取限制 20 MiB。系统打开文件时恢复后校验当前账本，不自动混入其他出行。
- **权限收紧**：结算发布验证 SettlementPublish；还款声明必须由付款人本人签名，到账确认由收款人本人完成。优化/合并预览不再直接“记已还”到原始债权；应先共同确认正式义务。没有折算汇率时显示“暂不能计算”，不误报已结清。
- **撤权检查点**：除了账目修订，分类及其他业务事件也检查陈旧权限。再次降权/移出时检查点不会越过待依赖/待重授权事件，避免待核对记录被自动追认为已确认。
- **旧数据保留**：检测原 `sbill_ledger_v1.sqlite3` 已有事件后登记为旧账本，保留原账目和本机分类，不清表、不追加示例。因旧版保存了多人的演示签名身份，旧账本只能继续使用已选本机身份，不开放新伙伴认领；新出行使用新账本。示例引擎只保留给旧测试夹具，不用于正式启动。

### 验证与产物

- `cargo test`：23/23（原核心 11 + 冒烟 7 + 新 workspace 5，含绕过 App 窗体后只读身份仍不能签名修改的核心校验），无 Rust warnings。
- `flutter test`：6/6，新增 390×844 手机尺寸 Widget 测试真实点击创建、添加待认领伙伴、记录首笔账目、进入伙伴页与账本选择。
- 新 Rust 测试覆盖空安装、两个账本隔离、错误账本包拒绝、旧账本保留、独立安装身份认领/重启、篡改申请、错误密钥、第三方导入、冒领、越权、重复同步、撤权待核对记录不复活，以及 `App*` 命名空间与 `ApproveSettlement` 路由回归。
- `flutter analyze`：0 errors，仍有 7 条既有 warning/info（unused import、旧 value API 等），退出码为 1，不记作完全无告警通过。
- macOS Rust 动态库与 Android arm64 Rust 动态库均重建成功，Release APK 成功生成。
- APK：`/Users/Jerry/Documents/Sbill/同行账本_Sbill_v0.2.0_release.apk`，22,365,660 字节；package `com.sbill.app`，versionName `0.2.0`，versionCode `2`，minSdk `24`，含 `lib/arm64-v8a/libsbill_core.so`。仍用项目现有 debug signingConfig，只供试用，不是商店正式签名。
- 当前 `adb devices -l` 没有连接设备：未执行双物理手机安装、系统分享和认领实测。更新优先覆盖安装，**不要为验证卸载或清除原 App 数据**。

### 仍未完成的产品能力

- 真正的附近网络发现与 socket/QUIC 传输、HTTP WebDAV 客户端、标准 QR 编码与相机扫描；已从正式日常入口隐藏，不再把模拟称作真实同步。
- Android Keystore/硬件保护签名密钥、可靠换机/备份恢复、安全 KDF 与正式发布签名。本机密钥目前保存在应用私有 SQLite；不能称作已经完成安全加固的生产版本。
- 已持有群密钥的离开成员无法被远程收回旧副本，群密钥轮换尚未实现；当前撤权限制新的授权业务事件，不承诺撤销其解密旧数据的能力。
- 全套角色认领/文件分享的双机真机验收，以及自定义分类并发删除的完整 CRDT 语义。现有分类测试只验证指定事件集合的并集收敛，不代表所有删除竞争已覆盖。

---

## 九、仅测试版的开发者浮层（2026-11-03，v0.2.1+3）

### 功能与隔离

- `app/lib/build_config.dart` 的编译期开关 `SBILL_TEST_TOOLS` 默认 false。普通构建不显示浮层，测试身份 API 直接拒绝调用；Android 根据同一 dart-define 生成 `BuildConfig.SBILL_TEST_TOOLS`，原生也拒绝普通构建的测试目录/身份持久化操作。
- 普通版 package 为 `com.sbill.app`、名称“同行账本”；测试版为 `com.sbill.app.testing`、名称“同行账本·测试”。可并排安装，不共享 Android 私有数据，不读取或覆盖普通版账本。
- 测试版浮层入口可拖动且限制在屏幕内，点击展开开发者控制台，点击关闭收起。显示当前成员/权限、账目/分类/事件/冲突/待重授权计数、公开身份指纹和最近操作错误。
- A 为测试版默认目录；B/C/D 使用测试版私有 `test_profiles/<profile>/sbill_ledger_v1.sqlite3` 及各自安装级目录/私钥。身份选择通过原生 SharedPreferences 持久化；重启恢复当前身份。没有复制他人的私钥，没有重新开放生产 `SwitchActor`。
- “准备四身份联调账本”经确认后，新增一本空测试账本，通过现有签名申请、主人批准、加密加入和政策同步流程让 A/B/C/D 加入同一本账本。角色分别为主人/财务管理员/普通成员/只读成员。不会填充示例账目，也不会清空已有测试账本；准备失败会显示错误，已产生的有效测试事件不自动回滚或清除。
- “同步四个测试身份”在同机四个独立目录间交换真实加密事件包，明确标注不是网络直连；刷新状态从 Rust 读取。切换身份前关闭并等待旧编辑页/弹窗销毁；未保存输入会丢弃。控制台批量操作期间阻止普通页面交互及恢复回调误消费外来文件。
- 调用记录最多 100 条，只记录操作名、成功/失败和耗时；可清空和复制，不记录参数、私钥、加入包或访问密钥。切换打开失败会恢复原签名身份和账本，错误不会伪装成功。

### 构建与验证

```bash
cd /Users/Jerry/Documents/Sbill/app
# 普通版：默认不含调试工具
/Users/Jerry/flutter/bin/flutter build apk --release --target-platform android-arm64
# 测试版：Dart 与原生共同开启；自动使用独立包名
/Users/Jerry/flutter/bin/flutter build apk --release --target-platform android-arm64 --dart-define=SBILL_TEST_TOOLS=true
# 两种构建分别回归
/Users/Jerry/flutter/bin/flutter test
/Users/Jerry/flutter/bin/flutter test --dart-define=SBILL_TEST_TOOLS=true
```

- Rust：23/23 通过，原财务/签名/权限规则未改。
- Flutter 普通构建：7/7；测试构建：10/10。新增 `test/test_console_test.dart` 覆盖默认无入口且拒绝测试 API、Dart 开启但原生未开启时拒绝、打开坏 SQLite 恢复原身份、四个独立私钥的认领/同步/角色权限/重启/100 条记录上限，以及 390×844 手机尺寸下浮层展开、确认场景、从旧编辑页切换、收起与拖动边界。
- 静态分析：0 errors，仍为 7 条既有 warning/info，退出码 1；本次控制台代码无新增诊断。
- 普通 APK：`/Users/Jerry/Documents/Sbill/同行账本_Sbill_v0.2.1_release.apk`，22,365,660 字节；测试 APK：`/Users/Jerry/Documents/Sbill/同行账本_Sbill_v0.2.1_testing.apk`，22,497,076 字节。两者 versionName `0.2.1`、versionCode `3`、arm64-v8a，均包含 Rust 核心库。
- 已核对 APK 包名/应用名/ZIP 完整性，并验证 AOT `libapp.so` 中控制台入口标记普通版不存在、测试版存在，证明不是仅把入口藏起来。沿用现有试用签名，尚未执行真机安装和点击验证。

---

## 十、PRD V1.1 历史核对（2026-11-03，v0.2.1+3；最新状态见第十一节）

### 文档与结论

- 新版：[PRD V1.1 Markdown](/Users/Jerry/Documents/Sbill/deliverables/同行账本_PRD_v1.1.md)、[PRD V1.1 Word](/Users/Jerry/Documents/Sbill/deliverables/同行账本_PRD_v1.1.docx)。原 V1.0 保留，不覆盖。
- 保留原 20 项 FR 和 61 条 AC 的 ID、目标、预期与优先级；新增多账本、分类与测试工具 3 项 FR、11 条 AC，共 23 FR / 72 AC。
- 状态：7 项功能主干已实现、12 项部分、4 项未实现。已实现不等于该项所有 AC/NFR/物理设备已经通过；不据此给出完成百分比。
- **未完成全部 PRD，P0 也未全部完成。**当前是 Android 本地/手动协作试用版本，不能称为完整跨平台、LAN 优先、异步留存和安全恢复产品。

### 核对发现的关键剩余项

- P0 财务：外币编辑固定 /100、汇率分母和币种尺度未正确处理；争议/纠正/迟到映射无完整入口；待确认/争议付款的结算阻断不完整；受影响只读伙伴无法签名批准义务。
- P0 安全与可靠性：普通 SQLite 存签名种子/群密钥；口令备份 KDF 为单次 BLAKE3；缺平台安全存储、可靠备份换机、群密钥轮换、整包原子和工作区故障恢复/完整状态展示。
- P0 真实适配：无真实 LAN/socket/握手、HTTP WebDAV 或 iOS 工程；Android 原文件分享虽已编译，双手机未实测。
- 分类：指定新增并集有回归，但即时删除没有因果 tombstone，跨设备序号排序可能导致分类复活；旧分类迁移、结构化分类和完整删除竞争未完成。
- P1/P2 与验收：标准 QR/相机、双向光学与持久缓存、附件分块补传及产品入口、原币债务/多设备/报表/历史优化/链锚未完成；真机/跨平台/性能/能耗/强杀或断电仍待验收。

### 本次复验与文档 QA

- 重新执行 Rust 回归：23/23 通过（11 核心 + 7 冒烟 + 5 工作区）。
- 重新执行 Flutter 普通/测试两种回归：7/7、10/10 通过。
- 重新执行静态分析：0 errors、7 条既有 warning/info，退出码 1，不计为无告警通过；本次不修改业务代码。
- Markdown 生成断言和 Word XML 独立核对：原 81 行 FR/AC 全部保留，新增后 ID 唯一且 23/72 计数一致。
- Word 结构校验通过；全文占位符 0、静态格式问题 0。渲染 50 页，抽查目录、FR/AC 跨页宽表、差距表及证据索引，未见溢出；不是逐页视觉验收。目录页码需在 Word/WPS 更新域后显示。
- 产品物理设备、安全和性能验收未在此次文档更新中执行；不得把模拟测试、测试名称或 APK 构建当作这些条件通过。

## 十一、首批非 iOS 改进与交付（2026-11-03，v0.3.0+4 / core 0.2.0 / schema V2）

### 已落地

- 金额和汇率使用 BigInt 精确解析/尺度换算，保留有理数分母；修复 JPY 再编辑、无效外币付款人被丢弃后误保存、大权重截断、signed minimum 格式化和超 double 精度动画最终金额。汇率来源/适用/确认元数据、完整币种及累计财务边界仍须补齐。
- 本地试算结算币种按账本保存；正式卡片显示冻结转账、汇率、覆盖数量和指纹，不随之后的试算开关改变。零净额不冒称已结清，可共同确认零转账抵销方案。
- Rust 统一正式结算阻断并向 UI 返回原因；只读成员可签本人受影响方案、声明本人还款/确认本人收款，不可改账/发布/代签；本地过期或重复批准/提交不新增事件或污染提交链。
- 整包先验证完整集合，再以一个 SQLite 事务写事件和加密 outbox；财务错误包全拒，SQL 故障全部回滚，重试和重复导入幂等。不能据此声称工作区跨库/catalog 或 Android 强杀/断电一致性已完成。
- 分类采用 observed-remove：删除只移除已观察新增 tag；低设备序号删除仍有效，未观察并发同名新 tag 保留，缺引用进 pending；V1 稳定 ID tombstone 和不添加空字段的签名序列化兼容。分类结构化与旧本机分类迁事件未完成。
- schema V2/未来版本/设备序号/缺序窗口与同设备身份混用边界；Ed25519 verify_strict；个人备份 V2 随机 32 字节盐、固定 Argon2id-v19-m65536-t3-p1 和认证元数据，部分 zeroize 清理。旧弱备份默认拒绝；SQLite 签名种子和群密钥尚未 Keystore 保护，完整备份换机/设备治理/轮换未接通。

### 验证和产物

- Rust 37/37：unit 1、backup 2、core 11、event boundary 2、financial safety 3、import/category 3、legacy schema 1、settlement staleness 1、strict signature 1、smoke 7、workspace 5；主机和 Android release 核心已重建。
- 最后 Flutter 全量复验：普通 16/16、测试 19/19，均使用真实最新 Rust FFI；静态分析 0 errors、7 条既有 warning/info（退出码 1）。
- [普通 APK v0.3.0](/Users/Jerry/Documents/Sbill/同行账本_Sbill_v0.3.0_release.apk)：22,465,988 字节，com.sbill.app。
- [测试 APK v0.3.0](/Users/Jerry/Documents/Sbill/同行账本_Sbill_v0.3.0_testing.apk)：22,531,868 字节，com.sbill.app.testing。
- 两者 versionCode 4、minSdk 24、targetSdk 36，仅 arm64-v8a；ZIP CRC/签名通过。Gradle 合并库等于本轮核心，APK 等于 Gradle 去调试符号后的库；不能直接将被 strip 的 APK 库与未 strip 源库作字节等同。普通 AOT 不含 TestConsoleOverlay/源路径/联调文案，测试 AOT 含这些入口标记。
- 沿用 Android Debug 试用签名，不是生产发布。没有安装到用户手机、卸载或清除数据；双机系统分享/最低系统/强杀/断电/性能/能耗未实测。
- [PRD V1.2 Markdown](/Users/Jerry/Documents/Sbill/deliverables/同行账本_PRD_v1.2.md) / [Word](/Users/Jerry/Documents/Sbill/deliverables/同行账本_PRD_v1.2.docx)：23 FR / 72 AC，8 主干已实现、11 部分、4 未实现；原需求、场景、预期和优先级保留。生成断言及独立 Word XML ID/计数核对通过；结构、占位符和静态格式检查通过；渲染 54 页并抽查风险页，不是逐页视觉验收，目录页码需更新域。

### 剩余任务（不得标为全部完成）

1. 还款争议/纠正/迟到映射与政策/提交分叉、重授权治理闭环。
2. 工作区多库/catalog/元数据一致性，完整同步范围、对端请求、业务接收确认和持久重试。
3. Android Keystore、完整备份换机、成员设备治理、群密钥轮换。
4. 真实 LAN/mDNS/socket 和 HTTP WebDAV，认证/证书/错峰/断网失败恢复。
5. 标准 QR、相机、双向请求确认、持久分片缓存、附件选择显示和分块补传。
6. 结构化分类/旧分类迁移、成员/时间/币种筛选、草稿、原币债务、同成员多设备、报表和历史管理等原优先级需求。
7. 真机、最低系统、性能/吞吐/能耗、强杀/断电和正式发布签名门槛。

iOS 仅排除本轮开发，没有从长期 PRD 删除。以上是首批交付，尚未完成全部非 iOS 需求或全部 P0。

## 十二、可选记账时间、未来账、排序分组与五类筛选（2026-11-06，v0.3.1+5 / schema V3）

### 已落地

- 账目修订支持可选 `details`（UTC 毫秒业务时间 + 冻结分类资料），事件协议升级为 V3。V1/V2 旧账目不补空字段，旧签名和历史不改变；旧账不伪造日期，旧标题前缀只在缺失新资料时作为只读兼容回退。
- 编辑、作废与冲突合并默认继承前驱资料；也可以显式清除时间或分类。分支时间/分类不一致时，未显式指定资料的合并会被核心拒绝。
- 新建默认填入当前本地时间，可选公元 1–9999 年任意未来或过去日期、时间，或一键清除为未设置时间；未来账正常参与余额和结算。
- 账单页默认按记账时间从新到旧排序，并按 `YYYY-MM-DD 星期X` 分组；无日期旧账排在“未记录日期”末尾。支持切换时间新到旧/旧到新、同币种金额高到低/低到高、标题排序，以及按日期、按分类、按币种、不分组。每个分组列头右侧展示有效账单小计（排除已作废账单，多币种按 `¥... + $...` 分币种汇总）。
- 支持时间范围、账单分类（含未分类与已删除历史分类）、指定原币金额区间、付款人包含（任一且实付 > 0）、成本承担人包含（任一且 `resolved_shares` > 0）五类筛选并取交集，可一键重置；切换账本时自动重置，不串账。

### 验证和产物

- Rust 41/41（新增 `expense_details_suite.rs` 4 项：未来时间与分类签名/同步/落盘、V1/V2 不补字段、修订/作废/冲突合并保留或清除、非法日历/分类拒绝）。
- Flutter 普通构建 18/18、测试构建 21/21（新增 `expense_schedule_filter_test.dart`：纯模型排序/分组/筛选交集，以及 390×844 手机尺寸真实 FFI 录入未来账、星期分组和筛选重置）；静态分析 0 errors、7 条既有 warning/info。
- [普通 APK v0.3.1](/Users/Jerry/Documents/Sbill/同行账本_Sbill_v0.3.1_release.apk)：22,892,596 字节，`com.sbill.app`，versionCode 5，SHA-256 `d1102e6959e6343aa2d71f73e3376adde31dcda828c6ccf50ff555c5a82ca440`。
- [测试 APK v0.3.1](/Users/Jerry/Documents/Sbill/同行账本_Sbill_v0.3.1_testing.apk)：23,024,016 字节，`com.sbill.app.testing`，versionCode 5，SHA-256 `32033d344beeeb55c397c63b7bb8bf116ee10152f2d1756d041ff65c4fb34c73`。
- 两个 APK 已通过 ZIP CRC、arm64 核心一致性和测试控制台裁剪校验；仍为 Android Debug 试用签名，同行使用新时间/分类同步时需一起升级 v0.3.1。

## 十三、真实瀑布二维码、相机扫码、HTTP WebDAV、局域网 HTTP 直连与治理备份闭环（2026-11-06，v0.3.2+6）

### 已落地

- **第一批：真实标准二维码瀑布流展示与相机/连续帧流接收（`qr_code_matrix.dart`、`optical_qr_sync_screen.dart`、`MainActivity.kt`）**：
  - 实现标准 ISO/IEC 18004 Byte 模式二维码矩阵编码器（Versions 1–20，ECC Level L，GF(256) Reed-Solomon 纠错、定位/校正/时序图形与 BCH 格式/版本信息），替换原先的伪随机点阵，使每一帧喷泉码（源分片帧与 XOR 冗余帧）均为真实可扫描的标准二维码。
  - 在正式版「同步与伙伴」页开放「面对面瀑布二维码」入口，进入自动生成当前账本的喷泉码帧流，并将接收端 `OpticalFountainAssembler` 解码进度持久化到 SQLite。
  - Android 原生 `MainActivity.kt` 接入 `CAMERA` 运行时权限申请与系统二维码扫描器调用，同时支持复制/粘贴单帧或多帧连续喷泉码 JSON 流（含中途起扫丢弃前 2 帧靠 XOR 冗余恢复）。
- **第二批：正式版 WebDAV 配置与真实 HTTP/HTTPS 同步 + 局域网无公网 HTTP 直连（`companion_center_screen.dart`、`ledger_controller.dart`、`ffi.rs`）**：
  - 正式版「同步与伙伴」页新增「局域网直连与 WebDAV 异步留存」卡片，提供 WebDAV 地址、专用账号、密码配置弹窗与立即同步按钮。
  - 当配置真实 HTTP/HTTPS WebDAV 地址时，客户端通过 `HttpClient` 执行 `MKCOL` 创建不透明群组目录、`PUT` 上传本地 `webdav_outbox` 待传密文对象、`PROPFIND` 列举远端 `.sbill` 对象并 `GET` 拉取新密文，交由 Rust 核心 `ApplyWebDavHttpSync` 校验 BLAKE3 哈希、XChaCha20-Poly1305 解密、Ed25519 验签后原子导入。
  - 支持一键开启本机局域网 HTTP 同步节点（自动绑定局域网 IPv4 端口并获取 MulticastLock）以及输入同伴局域网地址通过 `POST /sbill/v1/tripdelta` 一次往返双向交换加密增量包。
- **第三批：还款异议、迟到还款映射与 Argon2id 身份备份恢复正式入口（`settlement_center_screen.dart`、`companion_center_screen.dart`）**：
  - 结算页收付记录支持收款人（含只读成员）一键提出「异议」并填写原因（生成 `RepaymentDispute` 签名事件阻断结算），后续核对无误仍可确认收款；支持将「迟到还款 (`PendingMapping`)」映射到重组后的新结算单义务（生成 `RepaymentMapObligation` 签名事件）。
  - 正式版「同步与伙伴」页底部新增「安全备份与恢复 (Argon2id)」卡片，支持输入强口令导出 V2 Argon2id (64 MiB / t3 / 32B 随机盐) 加密身份备份 JSON，以及粘贴备份 JSON 与口令恢复并校验本机成员签名私钥。

### 验证与产物

- Rust：41/41 全部通过。
- Flutter：普通构建 21/21、测试构建 24/24 全部通过（新增 `real_channels_and_governance_test.dart` 验证标准 ISO QR 矩阵、正式版 HTTP WebDAV 服务端完整 `MKCOL/PUT/PROPFIND/GET` 闭环、局域网 HTTP 服务端/客户端直连同步、Argon2id 备份导出恢复及瀑布二维码中途起扫恢复）。
- 静态分析：0 errors，6 条既有 info（本批新增代码 0 warnings / 0 infos）。
- [普通 APK v0.3.2](/Users/Jerry/Documents/Sbill/同行账本_Sbill_v0.3.2_release.apk)：23,509,780 字节，`com.sbill.app`，versionCode 6，SHA-256 `bac0193cb19d6c0d4463172f92845b6e08fbeb9216733a39f3d415235a8ed081`。
- [测试 APK v0.3.2](/Users/Jerry/Documents/Sbill/同行账本_Sbill_v0.3.2_testing.apk)：23,575,656 字节，`com.sbill.app.testing`，versionCode 6，SHA-256 `fac794b9e4e1cc2f7e940a714850289aa51e835e256d3b3347db595edc4fd098`。








