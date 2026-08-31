<div align="center">

# Zflow

**Android / Web 上的 ZCode 远程控制客户端** — 独立复刻官方 Web 远程控制协议(protocol reimplementation)

[![Flutter](https://img.shields.io/badge/Flutter-3.47-blue.svg?logo=flutter)](https://flutter.dev)
[![Dart](https://img.shields.io/badge/Dart-3.13-0175C2.svg?logo=dart)](https://dart.dev)
[![CI](https://github.com/g0spel/zflow/actions/workflows/ci.yml/badge.svg)](https://github.com/g0spel/zflow/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/g0spel/zflow)](https://github.com/g0spel/zflow/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-Android%20%7C%20Web-lightgrey.svg)](#平台)

<img src="docs/screenshots/chat-main.png" alt="Zflow 对话页(Ember 设计)" width="400">

</div>

---

Zflow 在手机上管理你的桌面 ZCode:扫码添加设备 → 连接 → 任务对话、自动化定时任务、会话洞察、模型供应商与用量管理。整个应用围绕自研的 **Ember 设计语言**构建——暖炭色板、更纱黑体、"内容区安静、控制区紧凑"的分区原则;协议层为纯 Dart 复刻,350+ 测试覆盖,全部关键改动经逐任务代码审查落地。

## 目录

- [界面总览](#界面总览)
- [功能特性](#功能特性)
- [设计语言(Ember)](#设计语言ember)
- [平台](#平台)
- [快速开始](#快速开始)
- [架构](#架构)
- [测试与质量](#测试与质量)
- [技术栈](#技术栈)
- [项目结构](#项目结构)
- [贡献](#贡献)
- [来源与迭代](#来源与迭代)

## 界面总览

| 对话页(运行中) | 会话抽屉 | 洞察 sheet(目标) | 自动化 |
|---|---|---|---|
| <img src="docs/screenshots/chat-main.png" width="270"> | <img src="docs/screenshots/chat-drawer.png" width="270"> | <img src="docs/screenshots/insights.png" width="270"> | <img src="docs/screenshots/automation.png" width="270"> |

单行顶栏:会话标题 + 工作状态胶囊(运行中显示本轮用时计时)+ 会话列表;输入区是桌面式卡片:附件 / 模式(盾标随模式变化)/ 排队计数徽 / 用量 / 模型 / 思考 / 发送-停止;底部为 44px 图标化导航栏。深色为设计基准主题,浅色(暖纸白)同步推导;设计定稿见[设计规范](docs/superpowers/specs/2026-08-28-ui-redesign-design.md)。

## 功能特性

### 多设备管理

- **扫码即连**:扫描桌面 ZCode「远程控制」生成的二维码,或粘贴 URL 添加设备;URL 解析校验后保存,无效地址直接拒绝。
- **非官方主机确认**:添加非 `zcode.z.ai` 中继主机的设备前弹窗确认,防止被调换的二维码把会话静默送往第三方。
- **启动即达**:自动连接最近设备、直达对话;顶栏设备切换胶囊一键切换多台桌面,切换竞态由双层代际防护兜底。
- **设备管理页**:卡片式列表(在线态 / 当前工作区)、扫码与粘贴双入口添加、重命名、删除(先断开后移除,带确认)、JSON 导入导出(含凭据安全警示)。
- **可读的失败原因**:连接失败按根因给出可行动的中文解释(凭据失效 / 桌面离线 / 网络错误 / 配对超时 / 被其他终端挤下线等)。

### 对话(Conversation V4)

- **流式回复**:逐 token 渲染;思考与工具调用按真实顺序穿插(思考 → 文本 → 工具 → 文本),默认展开可收起,左侧状态 rail 标示运行态(蓝运行 / 绿成功 / 红失败);工具块标题直接显示执行状态(执行中 / 执行完毕),名称按工具族着色、输出块同色底(todo·计划=主色 / bash=琥珀 / 写文件=绿 / 读·检索=蓝);bash 保留原始输入输出,todo·计划工具输出解析为步骤清单,其余工具直接展示结果。
- **消息状态机**:点发送气泡立即上屏,角标演进「发送中 → 已发送 → 处理中」;回合完成角标退场;发送失败消息常驻,点击重发(自动重建会话 / 重传未上传附件 / held 队列重新确认)。
- **单行顶栏 + 会话设置卡**:顶栏 = 标题 + 工作状态胶囊(运行中「工作中 + 本轮用时」每秒自跳,空闲「空闲」)+ 会话列表;模型与思考强度设置在输入区卡片(○用量 / ◈模型 / 🧠思考 三键),思考档位按所选模型实际支持的档位动态过滤;四种模式(构建 / 计划 / 编辑 / YOLO)盾形图标随模式变化,计划 / YOLO 模式在消息流顶部常驻状态条,风险可见性分级。
- **会话抽屉**:左缘滑出——工作区条(点击底部升起切换层)、本地搜索、＋新会话与辅助对话并列入口、活跃 / 更早分组(listPinnedTasks 实时驱动)、运行蓝点 / 等待输入黄点、多选批量管理(置顶 / 归档 / 删除);列表带离线缓存,弱网秒开。
- **完整输入能力**:桌面式输入卡片——附件、斜杠命令 + 桌面端 Skills(`$` 前缀带选择弹层)、目标指令(Goal)、图片与文件附件(384KB 分片上传带进度)、排队消息(held queue,自动 / 手动放行,排队时输入框显示占位与 √N 计数徽,发送键变停止键)。
- **交互应答**:AI 权限请求与多问题表单按官方契约渲染与一次性提交(`action:accept` + `answers`),支持部分作答;权限三选项、自由输入、单选多选表单全覆盖。
- **辅助能力**:侧对话(side chat)并行提问、回复点赞点踩、回合级文件变更卡(N 个文件已更改 +A -D,点开逐文件明细)与回滚(rewind 带预览)。
- **切会话秒开**:订阅驻留池(LRU 容量 8)——离开的会话订阅驻留传输层继续收帧,切回时身份校验后直接复用,免完整握手。

### 会话洞察

对话页输入区上方把手上滑呼出(62% 起,可拉全屏;后台有任务时把手浮出计数徽),三面板:

- **目标**:会话目标(Goal)卡——目标文本 + 进行中 / 已暂停 / 已验证状态徽,可直接开始 / 暂停;计划模式进度清单(快照 plan.items),无计划时镜像桌面宿主的 TodoWrite 待办;
- **编辑**:按回合折叠的文件变更清单——每回合一行「回合 N · N 个文件已更改 +A -D」,点开逐文件明细;最近完成的回合自动装载展开,协议层内置 stale 自愈重试;
- **后台**:后台任务与子代理分组展示——运行中转圈、待取结果、成功 / 失败 / 取消终态,已结束项可点开展开完整信息(类型 / 状态 / 起止时间)。

### 自动化

定时任务全循环管理:统计总览(全部 / 活跃 / 失败)、任务卡(生命周期徽标 + 可读调度文案,如「每 5 分钟」「每天 09:00」「周三 11:17」)、详情页立即运行 / 重启排程 / 编辑 / 删除、执行历史(触发方式与结果,成功记录可跳转对应会话)、新建编辑器带官方模板(每周回顾 / 晨会动态 / 风险扫描)、闲时任务队列只读展示。

### 模型供应商与用量

- 供应商卡片:状态徽三色(已启用 / 未配置 / 已停用,附中文原因)+ 可展开模型明细(上下文窗口 / 推理档位);
- 会话内用量 sheet(输入区 ○ 键):上下文容量进度条、累计输入 / 输出(万 / 百万 / 亿 三档单位自动切换)、平均缓存命中率(与桌面端同源——优先宿主下发的按请求加权值,缺省按桌面回退公式计算)、剩余额度内联(五小时窗口 / 每周配额 / MCP 工具调用,官方 web 样式)、任务级用量查询(getTaskTokenUsage)。

### 可靠性

- **三级断线自愈**:relay 出站队列(未配对暂存)→ 桥降级标记 + 命令排队等待恢复(`waitHealthy`,15 次换栈重试页面无感)→ V4 订阅自动重握手;
- **订阅驻留池**:离开的会话订阅 LRU 驻留(容量 8)继续收帧,切回零握手秒开,身份校验后复用;
- **心跳先探测后断开**:30s 无应答先补发查询,下个周期仍无应答才重连,吸收切后台 / 系统休眠的假性超时;waiting 状态降频至 20s;
- **锁屏恢复无感化**:跟踪最后入站帧,回前台发现超 25s 零入站(链路必死)立即重连——解锁后 1~3 秒恢复收发;短暂重连横幅延迟 5s 显示,全程零打扰,真错误立即提示;
- **历史翻页保证**:分页游标协议级正确,能翻到会话最早一条;重同步保留已加载历史,视口不跳;
- **崩溃留痕**:未捕获异常写本地(单槽),下次启动诊断页可查完整堆栈。

### 安全

- 仅接受 `https` / `wss`,relay 永远走 `wss://`,杜绝明文降级;
- 设备凭据经 Android Keystore 加密存储,`allowBackup=false` 阻止进入云备份;
- 更新包下载后 **SHA-256 校验通过才交系统安装器**,缺校验值或校验不过一律拒绝;断点续传;
- CI 三方 action 全部钉 commit SHA;通知跳转经未导出 Activity 内存交接,第三方 App 无法伪造 deep-link;
- 远程控制 URL 含设备凭据,泄露后在桌面端重新生成二维码即可作废。

### 通知与后台稳定

- **后台保活(可关)**:任务运行中 / 连接保活两种前台服务形态(空闲自动回落保活通知),息屏自动持有 wake lock,电池优化白名单引导一键加白;
- **三类任务提醒**:审批交互(高优先级横幅+声音)/ 完成 / 失败,默认全开、可分别关闭;
- **三重门控**:应用在前台且正在查看该会话时不推送,跨会话 / 后台 / 锁屏才打扰;
- **未读徽标**:设备卡显示未读提醒计数,点进对应会话自动清零;点击通知直达对应对话。

### 诊断与调试

- **诊断日志页**:`[诊断]` 条目独立成页(协议失配 / 快照解析失败 / stale 自愈等,人类可读中文说明);
- **协议日志页**:完整 relay / IPC / V4 帧记录(详细帧可开关),复制 / 导出;
- **RPC 调试器**(原始 relay payload)与**信道浏览器**(任意 IPC 信道方法调用)——协议排查利器;
- **实机探针**:`live_probe_test.dart` 等只读探针经环境变量注入凭据,无凭据自动跳过,协议变更时直接观测真实返回结构。

## 设计语言(Ember)

| 维度 | 定义 |
|---|---|
| 分区原则 | 内容区安静(AI 产品风:大留白 / 底色差分区 / 大圆角)、控制区紧凑(工具风:紧凑行高 / 细分隔 / 高信息密度) |
| 色板 | 暖炭暗色基准:bg `#1B1917` / card `#262320` / raise `#35302B`,主色陶土橙 `#D97757`;浅色暖纸白推导(主色 `#BA5A37`),文字四阶与语义色两主题各自达标(WCAG AA 守卫测试锁定) |
| 字体 | 更纱黑体(Sarasa UI SC 界面 / Sarasa Term SC 代码,GB2312 子集约 6.7MB,SIL OFL 1.1) |
| 间距圆角 | 4px 网格;内容区圆角 16(气泡尾角 4 / sheet 顶 20),控制区 10 |
| 字阶 | 22 / 17 / 15 / 13 / 12 / 11 六档,行高 1.5 |
| 动效 | 按压缩放 0.98、展开升起 200ms ease-out,仅此两类 |

## 平台

| 平台 | 状态 |
|------|------|
| Android(arm64) | ✅ 主要目标平台,Release 发布(`Zflow-v<版本>-arm64.apk`) |
| Web | ✅ 可用(调试 / 快速预览;凭据保护弱于移动端) |

## 快速开始

1. 从 [Releases](https://github.com/g0spel/zflow/releases) 下载 APK 安装;
2. 桌面 ZCode → 远程控制 → 生成二维码;
3. 应用内 **添加设备** → 扫码 → 连接。

应用内自动检查更新:下载(断点续传)→ SHA-256 校验 → 系统安装器升级。

### 从源码构建

```bash
flutter pub get

# Android release(arm64,与发布产物一致)
flutter build apk --release --target-platform android-arm64 --dart-define=APP_VERSION=$(awk -F'[ +]' '/^version:/ {print $2}' pubspec.yaml)

# Web
flutter build web --release

# 本地调试
flutter run            # Android
flutter run -d chrome  # Web
```

## 架构

```
┌────────────────────────────────────────────────────────────┐
│ UI (lib/ui)     对话(内嵌会话+抽屉+洞察sheet) / 自动化 /     │
│                 设置 / 设备管理 / 调试器                      │
├────────────────────────────────────────────────────────────┤
│ State (lib/state)  AccountStore · AppSession(连接竞态防护) │
│                   · LogStore · CrashReport · SessionListCache │
├────────────────────────────────────────────────────────────┤
│ Facade (lib/protocol/zflow_client.dart)                     │
│   relay → 配对 → bootstrap → workspace-bridge → channel RPC │
├────────────────────────────────────────────────────────────┤
│ Protocol (纯 Dart,可单测)                                   │
│   RelayClient · RpcFrameTransport · ChannelClient           │
│   IpcCodec · Conversation(V4) · Proof(HMAC-SHA256)          │
└────────────────────────────────────────────────────────────┘
```

| 层 | 职责 |
|---|---|
| `connection_params.dart` | 远程控制 URL 解析(仅 https/wss)+ relay 地址派生 |
| `proof.dart` | 配对证明(HMAC-SHA256 / base64url) |
| `relay_client.dart` | relay WebSocket + 心跳(先探测后断开)+ 指数退避重连 + 协议诊断 |
| `rpc_transport.dart` | rpc-frame 分片 / 重组 / CRC32 校验 / ack |
| `ipc_codec.dart` | 值编解码 + IPC 帧解析 |
| `channel_client.dart` | channel RPC 调用 / 事件订阅 |
| `conversation.dart` | Conversation V4 / sessions-index 快照+增量状态机、CAS 命令与 stale 自愈、历史分页游标 |
| `zflow_client.dart` | 高层门面:bootstrap / bridge / 三级断线恢复 |

## 测试与质量

```bash
flutter test    # 350+ 单元 / 组件测试
```

- **测试策略**:协议层状态机单测、UI 纯逻辑抽取测试(turn 分组 / 回显去重 / 待办推导 / 配额阈值)、wire 级组件测试(真实协议帧驱动,断言发出的 method 与参数)、真机集成套件(30+ 项端到端,环境变量门控);
- **探针方法论**:对桌面端协议的结论以宿主源码核对与实机探针为证,不靠猜——协议漂移时 `[诊断]` 日志给出证据与线索;
- **CI**:push / PR 全量 analyze + test + web 编译冒烟;tag 自动构建签名 APK 上传 Release(附 SHA-256);Dependabot 月度依赖更新;UI 大改各阶段经逐任务代码审查流程落地。

## 技术栈

- [Flutter](https://flutter.dev) / Dart(零状态管理库,`ChangeNotifier` + InheritedWidget)
- [web_socket_channel](https://pub.dev/packages/web_socket_channel) — relay 长连接
- [crypto](https://pub.dev/packages/crypto) — HMAC-SHA256 配对 / 更新校验
- [flutter_secure_storage](https://pub.dev/packages/flutter_secure_storage) — 凭据加密存储
- [mobile_scanner](https://pub.dev/packages/mobile_scanner) / [zxing2](https://pub.dev/packages/zxing2) — 扫码
- [flutter_markdown_plus](https://pub.dev/packages/flutter_markdown_plus) — Markdown 渲染
- [Sarasa Gothic](https://github.com/be5invis/Sarasa-Gothic)(SIL OFL 1.1)— 界面与等宽字体

## 项目结构

```
lib/
├── main.dart                 # 入口 + 崩溃捕获 + 启动更新检测
├── protocol/                 # ZCode 协议复刻(纯 Dart,可单测)
├── state/                    # 账号 / 连接 / 日志 / 崩溃留痕 / 会话缓存
├── notifications/            # 前台服务(运行/保活双形态) + 三类提醒 + 未读徽标
├── ui/                       # 壳 / 对话 / 自动化 / 设置 / 设备 / 调试器
└── update/                   # 更新检测 + 校验 + 断点续传下载
test/                         # 单元 / 组件 / wire 级测试 + 只读协议探针
integration_test/             # 真机端到端套件(环境变量门控)
android/                      # Android 平台(包名 dev.g0spel.zflow)
web/                          # Web 平台
docs/                         # 设计规范 / 设计图
```

## 贡献

欢迎 Issue 与 PR:`flutter analyze` 无告警、`flutter test` 全绿;涉及真实桌面的改动请注明探针验证方式。

## Changelog

版本变更记录见 [CHANGELOG.md](CHANGELOG.md)。

## License

[MIT](LICENSE)

## 免责声明

本项目为个人学习与互操作目的,对 ZCode 远程控制协议的独立复刻,非官方出品。使用者须自行承担风险与合规责任。

## 来源与迭代

本项目 fork 自 [HumanAILoop/zemote](https://github.com/HumanAILoop/zemote)(fork 点 v0.3.5),此后**独立改进与迭代**:安全加固(强制 TLS / 凭据加密 / 更新校验)、自动化管理、会话洞察面板、连接可靠性打磨(三级自愈 / 锁屏无感恢复 / 订阅驻留池)、消息状态机;v0.10.0 起全面落地的 Ember 设计语言、v0.11.0 的 Zflow 更名、v1.0.0 的真机全量稳定化;v1.1.x 吸收 zremote 项目思路完成原生重皮——后台保活(前台服务双形态 + 息屏 wake lock + 电池白名单)、通知管理(三类提醒 + 三重门控 + 未读徽标)、桌面式输入卡片、洞察三面板(目标 / 编辑 / 后台)重构与全新 Ember 图标。协议层与原项目同源(均为对 zcode.z.ai 远程控制协议的独立复刻,可与同一桌面端互换使用),但本项目不自动跟随原项目——协议变更时经宿主源码核对与实机探针验证后合并。fork 点之前的历史记录见原项目仓库,衷心感谢原项目提供的起点。
