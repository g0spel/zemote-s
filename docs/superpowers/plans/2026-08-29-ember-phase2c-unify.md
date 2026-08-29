# Ember Phase 2c:页面统一与主题收尾 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 全部剩余页面(自动化/设置/二级页)Ember 化,全局主题 primary 接线(ZColors → EmberColors,移除 2a 的局部覆盖),浅色全量校验,清偿历阶段 deferred 项。

**Architecture:** buildDarkTheme/buildLightTheme 的 ColorScheme/组件主题改由 EmberColors 驱动(seed/primary/surface 等),Tab 选中色的局部覆盖随之删除;各页面按 spec §7.2/§7.3/§7.4 的定稿布局做样式统一(结构已在位,主要为 token 替换与组件形态对齐);markdown 正文与死代码清理一并收口。

**Tech Stack:** Flutter/Dart,Ember token。

**Spec:** `docs/superpowers/specs/2026-08-28-ui-redesign-design.md`(§2/§3/§7.2/§7.3/§7.4)

## Global Constraints

- 全局主题接线后:**零视觉兜底例外**——Tab 选中色局部覆盖(root_shell NavigationBarThemeData)删除;appBar/组件主题全部走 Ember。
- ColorScheme.fromSeed 移除或以 EmberColors 直构:primary/surface/surfaceContainerHighest/outline 按 spec §2 映射(card→surfaceContainerHighest 等),浅色同步。
- 页面样式统一到控制区规范:card 底 + hairline 分隔 + `EmberRadius.control` + 字阶;消灭各页面残留的 ZColors/ZInk 硬编码(**markdown_view 正文改 EmberColors textSolid 属本阶段**)。
- Deferred 清偿清单:theme.dart 死代码(statusColor/relativeTime)、ui_settings home.* 死键、session_list_cache 裁决(给抽屉接回离线缓存 或 正式移除)、conversation_list_page.dart 改名 session_drawer 相关文件。
- 每任务收尾:analyze 无告警 + 全量测试全绿(248+)。
- 浅色:Task 4 专项校验(每个页面截图级自查可延后,但 token 映射必须两主题各自成立)。

---

### Task 1: 全局主题接线 + 死代码清理

**Files:**
- Modify: `lib/ui/theme.dart`(buildDarkTheme/buildLightTheme 的 ColorScheme/组件主题 → EmberColors;删 ZInk 中已被 Ember 取代且无引用的方法——先 grep 逐个确认;删 statusColor/relativeTime)
- Modify: `lib/ui/root_shell.dart`(删 NavigationBarThemeData 局部覆盖)、`lib/ui/markdown_view.dart`(正文 ZInk.solid → EmberColors.of(context).textSolid)、`lib/ui/ui_settings.dart`(删 home.* 死键)
- Test: `test/ember_theme_test.dart` 扩展(主题 primary == EmberColors primary;markdown 正文色)

**Interfaces:**
- Produces: 全局 ThemeData 的 primary/surface 与 Ember 色板一致——后续页面不再需要局部覆盖。

- [ ] **Step 1: 失败测试** — buildDarkTheme().colorScheme.primary == EmberColors.dark().primary(浅色同理);ZemoteMarkdown 正文 textStyle.color == textSolid。
- [ ] **Step 2: 实现** — ColorScheme 直构(`ColorScheme.dark(primary:…, surface:…, …)` 或 fromSeed 后 copyWith 全量覆盖);root_shell 局部覆盖删除;markdown 正文接线;死代码删除(逐个 grep 确认零引用后再删)。
- [ ] **Step 3: 全量回归 + Commit** `feat(ui): global theme wired to Ember palette (2c)`

---

### Task 2: 自动化页 + 设置页样式统一

**Files:**
- Modify: `lib/ui/automation_page.dart`、`lib/ui/settings_page.dart`(+关联小部件)
- Test: 现有 automation_schedule_test 回归

**Interfaces:** 无接口变化,纯样式 + 组件形态。

- [ ] **Step 1: 自动化页** — 对照 spec §7.2:统计卡(card 底/数值 17/标签 11)/任务卡(control 圆角、生命周期徽色 ok/err/muted、可读调度 11)/详情 sheet(顶 20 圆角、KV 格 tile 底、操作按钮三型)/编辑器(raise 底输入框、primary 主按钮);残留 ZColors/ZInk 替换为 Ember。
- [ ] **Step 2: 设置页** — §7.3 已在 2a 完成分组;本步查漏:图标/徽标/字体档位/诊断二级页统一 token。
- [ ] **Step 3: 回归 + Commit** `feat(ui): automation + settings ember pass (2c)`

---

### Task 3: 二级页 + deferred 清偿

**Files:**
- Modify: `lib/ui/model_providers_page.dart`、`lib/ui/usage_page.dart`、`lib/ui/conversation_list_page.dart`(改名 session_drawer.dart,git mv)
- Modify/Delete: `lib/ui/chat_page.dart` 与 `root_shell.dart` 的 import 更新;session_list_cache 接回抽屉(read 在抽屉打开时播种、write 在订阅 ready 后)
- Test: 更名后 import/测试修正;缓存播种测试

**Interfaces:**
- Produces: `SessionDrawer` 所在文件更名(类名不变);会话列表离线缓存恢复(2b 遗失的能力)。

- [ ] **Step 1: 二级页样式** — 供应商(状态徽三色 ok/warn/muted + 模型明细展开)/用量(主额度大卡 + 双窗口格 + 阈值色)/诊断中心(状态前置)对照 spec §7.4 统一 token。
- [ ] **Step 2: conversation_list_page.dart → session_drawer.dart**(git mv,全仓 import 更新)。
- [ ] **Step 3: 缓存接回** — SessionListCache 复活(2b 删除的实现在 git 历史 dffb03a^ 可考):抽屉订阅 ready 后 write;打开抽屉先 read 播种(标记 cached,真实数据到达覆盖);裁决记录:缓存数据仅种子显示,状态点以实时为准。
- [ ] **Step 4: 回归 + Commit** `feat(ui): secondary pages ember pass + drawer cache (2c)`

---

### Task 4: 浅色全量校验 + 冒烟收尾(用户参与)

- 两主题逐页过:设备空态/对话流/抽屉/洞察 sheet/模型面板/自动化/设置/二级页;对比度抽查(文字四阶 on bg/card/raise)。
-历阶段 deferred 的真机项:MsgBadge 橙底对比度、sheet 短内容拖拽、SafeArea 手势条。
- 问题即修;全绿后合并 ember-2c → main,发版(v0.10.0——UI 大改,minor 升级)。

## 后续(不在本文档)

- Plan 3(可选):动效打磨/触感反馈/剩余打磨项(视 2c 真机反馈决定是否需要)。
