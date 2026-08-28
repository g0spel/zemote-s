# Ember Phase 2b:对话页重构 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 对话页全面 Ember 化:消息流样式、对话 Tab 内嵌化 + Ember 顶栏(设备/会话/模型 pill)、会话列表抽屉化、模型四模式切换面板、洞察面板升格为底部 sheet。

**Architecture:** ① 对话 Tab 从"列表页 push ChatPage"改为"Tab 内嵌当前会话":RootShell 持 `_activeSessionId` 状态,`ChatPage` 增加 `embedded` 模式(去 Scaffold/AppBar 输出内容体;独立 push 用法保留);② 每个 Tab 自带头部(RootShell 无全局 AppBar):对话 Tab 头部 = 设备切换胶囊 + 会话名 + 模型 pill;③ 会话列表复用 Task 1 的数据逻辑,从页面降维为左缘抽屉;④ 洞察三面板从消息流内 chip 行改为输入区上方把手上滑呼出的底部 sheet。

**Tech Stack:** Flutter/Dart,Ember token,零状态管理库。

**Spec:** `docs/superpowers/specs/2026-08-28-ui-redesign-design.md`(§7.1 对话页定稿)

## Global Constraints

- 气泡:用户陶土橙 `EmberColors.primary` 填充白字、圆角 16/尾角 4;AI card 底、16/尾角 4;思考/工具卡 `#211E1B` 等暗一档底 + 左侧 3px 状态 rail(思考中/运行蓝、成功绿、错误红);交互卡橙描边暖底;回合标签独立小字行(faint 11)。
- 模型 pill:`模型名 | 强度档名`;非默认模式追加徽段——计划(橙)/编辑(蓝 `run`)/YOLO(红),build 隐藏;plan/yolo 追加流内状态条;点开面板分区 模式→思考强度→模型;切换即时生效(setConfig)。
- 抽屉:76% 宽、左缘滑出;工作区条(图标+项目名+等宽路径+⌄);搜索;＋新会话;分组 置顶/今天/更早;运行蓝点/等待黄点;右上"管理"→多选模式(计数条+置顶/归档/删除);底部设备状态条(只读)。
- 洞察 sheet:把手常驻输入区上方(后台有任务时右端计数徽);上滑 62% 高可拉全屏;三 Tab 待办/文件/后台(复用现有面板逻辑,数据获取与 fire-once 行为零回归)。
- 零回归红线:发送状态机(回显/角标/重试)、stale 自愈文件加载、回合完成预加载、交互卡提交契约、pendingInteractions 通知——这些逻辑本阶段只换皮不改行为;每任务收尾 analyze + 全量测试全绿。
- task_home_page.dart 的去留在本阶段裁决:其双源合并逻辑若被抽屉复用则迁移,否则删除(连带 helper 挪至中立位置)。

## 结构决策(先读)

- **ChatPage embedded 模式**:`ChatPage({embedded: false})`;embedded=true 时 build 不包 Scaffold/AppBar,直接输出消息流+横幅组+输入区(现有 build 的 L833 起内容);Scaffold 模式保留给自动化历史等 push 入口。Tab 内嵌用 `ValueKey(activeSessionId)` 重建。
- **会话选择状态**:`RootShell` 持 `ValueNotifier<String?> activeSessionId` + `ValueNotifier<String> activeSessionTitle`;对话 Tab 头部监听。会话列表条目点击 → set activeSessionId(不再 push);抽屉的"新会话" → activeSessionId = null(draft 模式,首条消息走 createSession,现有 ChatPage 逻辑已支持)。
- **顶栏**:对话 Tab 头部 Row = 设备胶囊(复用 2a 的切换 sheet)+ 会话名(solid 13,单行)+ 模型 pill;自动化/设置 Tab 头部 = 页标题(22)。
- **洞察 sheet**:`_InsightsRow` 的三个 panel 方法(_todoPanel/_filesPanel/_bgPanel)整体迁移进新 `_InsightsSheet`(StatefulWidget,`DraggableScrollableSheet` 或自定义 62% 高度);原 chip 行位置换成把手组件;自动预加载/stale 重试逻辑随方法平移。

---

### Task 1: 消息流 Ember 化(纯样式)

**Files:**
- Modify: `lib/ui/chat_page.dart`(_UserBubble/_AssistantBubble/_ReasoningTile/_ToolCallTile/_TurnGroupWidget 的标签行/_PendingInteractions 卡;约 6 个组件的 BoxDecoration/TextStyle)
- Test: 现有测试回归(纯样式无新逻辑;`chat_grouping_test` 等必须全绿)

**Interfaces:** 无接口变化——只换视觉实现。

- [ ] **Step 1: token 映射改造**(逐组件):

| 组件 | 现 | 改 |
|---|---|---|
| `_UserBubble` | primary 22% 透明底 | `EmberColors.of(context).primary` 实填充、白字、圆角 16/右下 4 |
| `_AssistantBubble` | ZInk.tile 底 | card 底(`.card`)、圆角 16/左下 4、文字 textSolid 13 |
| `_ReasoningTile` | tile 底+border | tile(暗一档:`EmberColors.of(context).bg` 与 card 之间取 `#211E1B`——用 `Color.lerp(bg, card, .5)` 或直书,两主题各自算)+左 rail 3px(streaming?run:faint)+圆角 10 |
| `_ToolCallTile` | tile 底 | 同上暗一档底+左 rail(status→色:success/ok、error/err、running/run)+等宽族 `EmberFonts.term` |
| 回合标签行(思考过程/工具名) | 无独立行 | `_TurnGroupWidget` 中抽成独立小字行(faint 11,▸/▾ 前缀),替代折叠头文字 |
| `_InteractionCard`(等待输入) | warning 黄系 | 橙描边(primary 55%)+暖底(primary 8%)+选项胶囊(primary 描边文字) |
| `_MsgBadge` | 通用 faint | failed 态 err 色,processing 态 run 色,其余 faint(现状保持) |

- [ ] **Step 2: 回归** — `flutter analyze && flutter test`(chat_grouping/echo/subagent 等 218 全绿);真机核验留 Task 6。
- [ ] **Step 3: Commit** `feat(ui): ember message stream styling (2b)`

---

### Task 2: 对话 Tab 内嵌化 + Ember 顶栏

**Files:**
- Modify: `lib/ui/chat_page.dart`(embedded 参数)、`lib/ui/root_shell.dart`(会话状态/头部/Tab 内容)
- Test: `test/root_shell_test.dart` 扩展(对话 Tab 内嵌/会话切换/新会话 draft)

**Interfaces:**
- Produces: `ChatPage({..., bool embedded = false})`;RootShell 内 `ValueNotifier<String?> _activeSessionId`(null = draft 新会话)。
- Consumes: Task 1 的样式、现有 ChatPage 全部逻辑。

- [ ] **Step 1: 失败测试** — 有 bridge 时对话 Tab 默认渲染会话列表(未选会话);选中会话后(直接调 notifier)渲染 ChatPage 消息流;activeSessionId=null 时 draft 模式(输入框可发)。
- [ ] **Step 2: ChatPage embedded** — build 按 embedded 分支:去掉 Scaffold/AppBar,直接返回消息流 Column(现有 L833 起结构);`_sessionId` 逻辑不动(draft 模式已有)。
- [ ] **Step 3: RootShell 接线** — 对话 Tab:`_activeSessionId == null` → 会话列表(暂以简洁列表呈现,Task 3 抽屉化)+ 浮动"新会话"按钮;非空 → `ChatPage(embedded: true, key: ValueKey(id), sessionId: id, ...)`。头部 Row:设备胶囊 + 会话名(ValueNotifier 驱动,ChatPage 订阅后回写或经回调) + 占位(模型 pill Task 4)。自动化历史 push ChatPage 保持非 embedded。
- [ ] **Step 4: 回归 + Commit** `feat(ui): chat tab embeds conversation (2b)`

---

### Task 3: 会话抽屉

**Files:**
- Modify: `lib/ui/root_shell.dart`(抽屉宿主)、`lib/ui/conversation_list_page.dart`(列表体抽出为可复用 `_SessionListView` 或等价重构;页面壳删除——2a 的 Tab 0 已被内嵌会话替代)
- Delete: 会话列表页壳(若内容已全部上移)
- Test: `test/conversation_list_test.dart` 保持(sortSessions/statusDotColor 不变);抽屉交互 widget 测试

**Interfaces:**
- Produces: `SessionDrawer({required BridgeSession bridge, required Map<String,dynamic> scope, required ValueChanged<String?> onPick, ...})`——onPick(null) = 新会话。

- [ ] **Step 1: 失败测试** — 左缘滑出呼出抽屉(拖拽或点击 ☎);点会话条目 → onPick(id) 且抽屉关闭;点"新会话" → onPick(null);工作区条渲染当前工作区名。
- [ ] **Step 2: 实现** — 抽屉体复用 Task 1 列表逻辑(订阅/排序/状态点);工作区条 = 橙图标+项目名(`workspaceTitle`)+等宽路径+⌄(点击弹工作区切换——2a 已有 bridge 打开逻辑,此处仅展示 + 简单切换 sheet);分组(置顶数据源 2a 未接,先按 今天/更早 两分组,置顶组留 TODO 注释挂到 channel 数据接入);"管理"入口 → 多选模式(计数条+置顶/归档/删除操作条;置顶/归档走 `zcode-task` 现有 RPC,复用 task_home_page 的调用代码后删除该文件——本任务完成 spec 的 task_home 裁决:双源合并逻辑不迁移,列表以 sessions-index 为准);底部设备状态条。
- [ ] **Step 3: 回归 + Commit** `feat(ui): session drawer (2b); retire task_home_page`

---

### Task 4: 模型 pill 与四模式面板

**Files:**
- Modify: `lib/ui/root_shell.dart`(pill 渲染)、`lib/ui/chat_page.dart`(`_ModelModeSheet` 改造为面板;模式分区)
- Test: 面板状态映射纯函数测试(模式徽色/隐藏逻辑)

**Interfaces:**
- Produces: 顶层纯函数 `String? modeBadge(String mode)`(build→null,plan→'计划',edit→'编辑',yolo→'YOLO',其余→原值)与 `Color modeBadgeColor(String mode, EmberColors c)`。

- [ ] **Step 1: 失败测试**(modeBadge/modeBadgeColor 映射表)
- [ ] **Step 2: pill 渲染**(对话 Tab 头部:`模型名 | 强度档名` + 模式徽;数据从 activeSessionId 对应的 ConversationState 取——RootShell 需订阅当前会话 config,经 ChatPage 回调或共享订阅,取最简:头部 pill 点击时才建订阅拉一次 + 监听)
- [ ] **Step 3: 面板改造** — `_ModelModeSheet` → 通用面板:模式(四档 chip,值与 label 随 prepareWorkspace configOptions 动态)/思考强度(thoughtLevels)/模型列表;`setConfig` 即时生效逻辑平移。plan/yolo 时消息流顶部状态条(橙/红,语义文案按 spec)。
- [ ] **Step 4: 回归 + Commit** `feat(ui): model pill with four modes (2b)`

---

### Task 5: 洞察 sheet

**Files:**
- Modify: `lib/ui/chat_page.dart`(`_InsightsRow` → 把手 + `_InsightsSheet`;三 panel 方法整体平移)
- Test: 现有 todo/file 相关测试回归;把手计数徽纯函数(后台任务数)

- [ ] **Step 1: 失败测试** — 把手可见性(面板数据为空也常驻);后台运行任务数>0 时计数徽文本('后台 N')。
- [ ] **Step 2: 实现** — 把手 Row(40×4 圆角条居中,右端计数徽)放输入区上方;上滑/点击 → `showModalBottomSheet` 62% 高(isScrollControlled,可全屏拖拽);sheet 内三 chip + 对应 panel(从 `_InsightsRowState` 平移 `_loadFiles`/自动预加载/stale 重试/`deriveTodoSteps` 全部逻辑);原消息流内的 `_InsightsRow` 行删除,token 条保留。
- [ ] **Step 3: 回归 + Commit** `feat(ui): insights bottom sheet (2b)`

---

### Task 6: 真机冒烟 + 收尾(用户参与)

- 全流程:对话 Tab 内嵌会话/抽屉切换会话/新会话 draft/模型四模式切换/洞察 sheet 三面板/发送状态机/文件自动预加载。
- 回归:通知路由(自动化历史 push)、断线重连、交互卡提交。
- 全绿后合并 ember-2b → main。

## 后续(不在本文档)

- Plan 2c:自动化页/设置页/二级页 Ember 化 + 全局主题 primary 接线(ZColors → EmberColors)+ 浅色全量校验。
