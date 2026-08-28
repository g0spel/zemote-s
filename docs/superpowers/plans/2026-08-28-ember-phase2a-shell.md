# Ember Phase 2a:导航壳重组 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把应用骨架重组为 Ember 信息架构:三 Tab(对话/自动化/设置)、启动直达对话、设备切换顶栏化、设备管理页成为设备列表的新家。

**Architecture:** 现有两级导航(AccountsPage 首页 → 连接 → push MainShell)重组为单壳 `RootShell`(main.dart 唯一入口):壳内持连接状态,无设备/未连接时对话 Tab 显示空态引导,连接成功后三 Tab 可用;设备列表功能从 AccountsPage 迁移为 `DeviceManagementPage`(顶栏"管理设备"进入);对话 Tab 内容为新 `ConversationListPage`(sessions-index 单源会话列表,点条目仍 push ChatPage——内嵌化留给 Phase 2b)。

**Tech Stack:** Flutter/Dart,零状态管理库(ChangeNotifier 惯例),Ember token(theme.dart 已就绪)。

**Spec:** `docs/superpowers/specs/2026-08-28-ui-redesign-design.md`(§1 信息架构、§7.3 设置/设备管理)

## Global Constraints

- 三 Tab 顺序与命名:对话 / 自动化 / 设置,选中态 `EmberColors.primary`。
- 启动路径:已保存设备 → 自动连接最近设备 → 直达对话 Tab;无设备 → 对话 Tab 空态引导(添加设备按钮 → 扫码/粘贴流程);连接失败在对话 Tab 顶部横幅提示并保留重试,不弹回设备页。
- 对话列表 sessions-index 单源:按 `lastActivityAt` 降序;运行中蓝点、等待输入黄点(沿用 notify_state 的 phase 集合语义)。
- 设备管理页功能不缩水:列表(在线态/当前工作区)、扫码添加、粘贴添加、重命名、删除(确认)、导入导出全部保留。
- 通知/心跳/桥恢复等既有行为零回归:TaskNotifier 启动点、pokeRelay 生命周期、workspaceListUpdated 监听必须原样保留(位置可移)。
- 视觉:控制区规范——card 底、hairline 分隔、圆角 `EmberRadius.control`;页标题 `EmberType.title` 22。
- 每任务收尾:`flutter analyze` 无告警 + 全量测试全绿(207+)。

## 结构决策(先读)

- 新文件 `lib/ui/root_shell.dart`:`RootShell`(StatefulWidget)替代 main.dart 的 `home: AccountsPage`;内部三态:无设备 → 空态;有设备 → 自动连接 → 连接中/失败横幅 + 三 Tab(对话 Tab 可用前置条件 = bridge 打开,自动化/设置 Tab 始终可见,未开桥时内容为提示页)。
- 现有 `MainShell` 的价值逻辑**平移**而非重写:bootstrap/load、openBridge、TaskNotifier、pokeRelay、workspaceListUpdated、设备切换 sheet 全部迁入 RootShell(方法级 copy,调用点适配)。
- `AccountsPage` 改造为 `DeviceManagementPage`(push 页,保留 Scaffold+返回);原"点击设备→连接→push MainShell"流程删除(连接自动化)。
- `ConversationListPage`(新文件):`sessions-index` 订阅 + 列表;数据经 `_ConversationListController` 薄封装便于测试。

---

### Task 1: ConversationListPage(会话列表页)

**Files:**
- Create: `lib/ui/conversation_list_page.dart`
- Test: `test/conversation_list_test.dart`(纯函数部分)

**Interfaces:**
- Consumes: `ConversationTransport.subscribeSessionsIndex()`(已有)、`SessionEntry`(protocol/conversation.dart)、`ChatPage`(push 打开单会话,现有构造)。
- Produces: `ConversationListPage({required BridgeSession bridge, required Map<String,dynamic> scope, required String workspaceKey})`;纯函数 `List<SessionEntry> sortSessions(List<SessionEntry>)`(lastActivityAt 降序)与 `Color? statusDotColor(String phase)`(running/prewarming→run 蓝,waiting→warn 黄,其余 null)供测试。

- [ ] **Step 1: 写排序与状态点纯函数的失败测试**

```dart
// test/conversation_list_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zemote/protocol/conversation.dart';
import 'package:zemote/ui/conversation_list_page.dart';
import 'package:zemote/ui/theme.dart';

SessionEntry _e(String id, String phase, int at) => SessionEntry({
      'sessionId': id, 'title': 'T-$id', 'phase': phase,
      'lastActivityAt': at, 'createdAt': 0,
    });

void main() {
  group('sortSessions', () {
    test('descending by lastActivityAt', () {
      final r = sortSessions([_e('a', 'idle', 1), _e('b', 'running', 9), _e('c', 'idle', 5)]);
      expect(r.map((e) => e.sessionId).toList(), ['b', 'c', 'a']);
    });
  });
  group('statusDotColor', () {
    test('running→run blue, waiting→warn, else null', () {
      expect(statusDotColor('running'), EmberColors.dark().run);
      expect(statusDotColor('prewarming'), EmberColors.dark().run);
      expect(statusDotColor('waiting'), EmberColors.dark().warn);
      expect(statusDotColor('completedSuccess'), isNull);
    });
  });
}
```

- [ ] **Step 2: 跑测试确认失败**(`flutter test test/conversation_list_test.dart` → sortSessions 未定义)

- [ ] **Step 3: 实现 ConversationListPage**

页面结构(控制区规范):
- 无 Scaffold/AppBar——由 RootShell 的壳提供标题区;本页是 Tab 内容(Column)。
- 订阅:`bridge.conversation(scope).subscribeSessionsIndex()`,listener 里 setState;dispose 释放订阅。
- 列表项:标题(solid 13)+ 最近预览(muted 11,单行省略)+ 相对时间(今天 HH:mm/昨天/周X,faint 10)+ 状态点(8px 圆,`statusDotColor`);行高紧凑(padding 12×10),无卡片包裹——列表即背景,分隔用底色差(奇偶不交替,项间距 2)。
- 空态(订阅 ready 且空):居中 faint 文案"暂无会话,下拉输入框开始新的对话"。
- 点击:`Navigator.push(ChatPage(session:…, workspaceKey:…, scope:…, sessionId: entry.sessionId))`(参数对齐现有 TaskHomePage 的 push 调用)。
- 错误态:订阅失败显示 muted 错误行 + 重试按钮(ghost 型,primary 文字)。

纯函数放在文件顶层(非类内),签名如上。

- [ ] **Step 4: 跑测试与 analyze** → 全绿

- [ ] **Step 5: Commit**

```bash
git add lib/ui/conversation_list_page.dart test/conversation_list_test.dart
git commit -m "feat(ui): sessions-index conversation list page (Ember 2a)"
```

---

### Task 2: RootShell 三 Tab 壳(平移 MainShell 价值逻辑)

**Files:**
- Create: `lib/ui/root_shell.dart`
- Modify: `lib/ui/main_shell.dart`(整文件废弃删除,在 Task 3 完成切换前先保留——本 Task 只新建不改旧)
- Test: `test/root_shell_test.dart`(widget test:三 Tab 渲染/切换)

**Interfaces:**
- Consumes: `ConversationListPage`(Task 1)、`AutomationPage`、`SettingsPage`、`workspaceKeyOf/workspaceTitle`(main_shell.dart 顶层函数,迁移而来)、`AppSession/AccountStore`。
- Produces: `RootShell({required AccountStore store, required AppSession session})`;内部 `openBridge/TaskNotifier/pokeRelay/workspaceListUpdated/设备切换 sheet` 全套平移。

- [ ] **Step 1: widget 失败测试**

```dart
// test/root_shell_test.dart — 用 fake/内存 AccountStore(参考 test/id_account_test.dart 的
// fake_credential_storage 注入方式),验证:
// 1) 无设备时渲染空态引导文本('添加设备');
// 2) 注入一个已保存设备但不自动连(构造参数 autoConnect:false 测试模式)时,
//    底部出现 对话/自动化/设置 三个 Tab 且默认选中对话;
// 3) 点自动化 Tab 无 bridge 时显示提示文案(包含 '连接');
// 4) 点设置 Tab 渲染 SettingsPage 标题。
```

测试采用 `autoConnect` 可注入参数(默认 true)以隔离自动连接;生产路径恒 true。

- [ ] **Step 2: 跑测试确认失败**(RootShell 未定义)

- [ ] **Step 3: 实现 RootShell**

- 状态:`_tab`(0/1/2,默认 0)、`_client/_bridge/_activeWorkspace/_workspaces`(自 `_MainShellContentState` 平移)、`_connectState`(idle/connecting/failed/error 文案)。
- `initState`:挂 session listener;若 `autoConnect` 且 store.accounts 非空 → `_connect(store.accounts.first)`(AppSession.connect + bootstrap + openBridge 链,自 `_open`/`_load`/`_openWorkspace` 平移合并)。
- 顶栏:标题区 = 设备切换胶囊(头像圆 + 设备名 + ▾;点击弹 `_DeviceSwitchSheet`,平移)+ 当前工作区名;右侧自动化/设置 Tab 内页自带操作,顶栏不放全局动作。
- Tab 内容:
  - 0 对话:bridge==null → 连接中转圈/失败横幅(`_connectState`)+ 重试;否则 `ConversationListPage`。
  - 1 自动化:bridge==null → muted 提示"连接设备后可用";否则 `AutomationPage`。
  - 2 设置:`SettingsPage`(经 `ThemeControllerProvider.of` 取控制器,平移传参)。
- `NavigationBar` 三项常驻,选中 primary;`PopScope` 退出确认平移;`_ConnectionBanner` 平移;TaskNotifier 启动点平移到 bridge 打开后。
- 全部视觉走 Ember token(bg/card/primary/字阶);连接横幅用 spec 语义(重连 5s 延迟逻辑保留)。

- [ ] **Step 4: 测试+analyze 全绿** → Commit

```bash
git add lib/ui/root_shell.dart test/root_shell_test.dart
git commit -m "feat(ui): RootShell — three-tab shell with auto-connect (Ember 2a)"
```

---

### Task 3: DeviceManagementPage + 启动路径切换

**Files:**
- Create: `lib/ui/device_management_page.dart`
- Modify: `lib/main.dart`(home 换 RootShell)、`lib/ui/accounts_page.dart`(删除——功能已迁移;若残留引用一并清理)、`lib/ui/settings_page.dart`(诊断与日志入口行组改造为 spec §7.3 的分组;设备管理入口行指向 DeviceManagementPage)
- Delete: `lib/ui/main_shell.dart`(RootShell 已接管)、`test/widget_test.dart` 中针对旧首页的断言(如有)
- Test: 扩展 `test/root_shell_test.dart`(空态→添加设备→到达扫码页的跳转断言)

**Interfaces:**
- Consumes: RootShell(Task 2)、现有扫码页 `QrScanPage`、添加 sheet 逻辑(AccountsPage 内平移)。
- Produces: `DeviceManagementPage({required AccountStore store, required AppSession session})`;RootShell 顶栏"管理设备"入口 push 本页。

- [ ] **Step 1: 测试先行** — RootShell 测试追加:空态点"添加设备"→ push 到 DeviceManagementPage(标题断言"设备管理")。

- [ ] **Step 2: 实现 DeviceManagementPage**

- 从 AccountsPage 平移:设备卡片列表(头像/名称/在线态 `session.isConnected(account)`/重命名/删除确认)、`_showAddSheet`(扫码/粘贴两入口)、导入导出;删除"点击连接"手势(连接已自动化)。
- 视觉:卡片 `EmberRadius.control` + card 底;添加按钮虚线描边 primary(primary.withValues(alpha:.55));危险操作(删除)红色文字独立区。
- AppBar:back + 标题"设备管理"(`EmberType` 15/17 档)。

- [ ] **Step 3: main.dart 切换** — `home: RootShell(store: _store, session: _session)`;删除 AccountsPage import。

- [ ] **Step 4: settings_page 分组对齐 spec §7.3** — 行组顺序:外观/设备与连接(设备管理行→DeviceManagementPage、协议帧日志开关)/模型(供应商/用量/服务管理)/关于(检查更新/诊断与日志/关于);诊断入口收拢为单行指向现有诊断列表页(0.9.4 已有二级结构,保持)。

- [ ] **Step 5: 删除旧文件** — main_shell.dart、accounts_page.dart 及仅被它们引用的私有组件;全仓 grep `MainShell|AccountsPage` 确认无残留引用。

- [ ] **Step 6: 全量验证** — `flutter analyze && flutter test && flutter build web --release`;Commit:

```bash
git add -A
git commit -m "feat(ui): device management page + root launch path (Ember 2a)"
```

---

### Task 4: 真机冒烟 + 收尾

**Files:** 无新改动(验证任务)

- [ ] `flutter run` 真机/模拟器:无设备空态 → 添加 → 自动连接 → 对话列表 → 进入会话收发;自动化/设置 Tab;顶栏切换设备;管理页增删改导入导出。
- [ ] 回归清单:断线重连横幅、锁屏恢复、通知点击路由、自动化历史跳转 ChatPage。
- [ ] 问题即修(走正常 fix 流程),全部通过后:

```bash
git add -A && git commit -m "chore: ember 2a smoke fixes" || echo "no fixes needed"
```

## 后续(不在本文档)

- Plan 2b:对话页 Ember 化(顶栏/模型 pill 四模式/消息流样式/会话列表抽屉化/洞察 sheet)。
- Plan 2c:自动化页 + 设置页 + 二级页 Ember 化。
