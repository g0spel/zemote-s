# UI 改版逻辑回归 — 全量复查评审清单

- **基准版本**: `9f1c437`(v0.9.8,UI 大改前最后一个版本)
- **对比范围**: `9f1c437..HEAD`,共 87 个提交(Ember UI 重构 v0.10.0 → 改名 Zflow → 真机修复轮 r1–r33)
- **复查方法**: 逐文件 diff(协议/状态层全文比对;UI 层提取旧实现管线对照);未做任何代码改动
- **状态**: ⏳ 待用户逐项确认后执行

---

## 第一部分:已修复清单(分组验证阶段以后的修正,回退时必须保留,避免二次破坏)

这些条目全部有真机实证(要么是用户报障后修复并验证,要么有宿主侧逆向证据):

| # | 修复 | 提交 | 证据 |
|---|------|------|------|
| F1 | createSession 去掉 firstInput(宿主 .strict() schema 静默剥离,首条消息从未送达) | ce89fe7 前后 | 宿主 schema 逆向 + 真机"新会话首条收不到回复"复现→修复 |
| F2 | workspaceId 顶层字符串(嵌套 workspace 对象被宿主校验层拒绝) | eb0f45e | 真机 Invalid input 实证 |
| F3 | 首发并行订阅(unawaited,不白等订阅) | ce89fe7 | 真机时序探针 |
| F4 | 新会话误判"已归档"复位 → 三重确认 + 30s adopt 宽限 | ce89fe7/31d04c4 | 真机复现→修复 |
| F5 | provider not in registry → modelProviderId(注册表 id) | 1f7ead2 轮 | 真机报错截图 |
| F6 | 模型面板不即时刷新 → AnimatedBuilder + optimisticPatch | 220c67f 等 | 真机验证 |
| F7 | 草稿配置回填 prep 当前值(思考档/模型/模式) | 16637b8 | 真机验证 |
| F8 | 思考档落地:建会话后补发 switchModelConfig | 3a45b8e | 任务库 thoughtLevel None→max,订阅回读 thought=max |
| F9 | 归档组恢复:listArchivedTasks 条目直接构造归档组 | 220c67f | 真机验证 |
| F10 | 归档混入活跃:索引∩活跃任务过滤(已删任务孤儿隐藏,default 工作区 28 个孤儿实证) | 3a45b8e | 桌面端 SQLite deleted 标志 + 真机分组验证 |
| F11 | 桌面归档/删除同步:开抽屉重拉 + 索引新面孔重拉 + 活跃条目消失重拉 + 15s 节流 | 3a45b8e | 真机验证 |
| F12 | 抽屉闪烁:Stack children 形状恒定(常驻) | 485aad7 | 真机录屏验证 |
| F13 | 消息行尾时间戳(_zflowTs,旧机制改名,无逻辑变化) | 真机轮 | — |
| F14 | 乐观"处理中"(发送 ack 后徽章/胶囊即时反馈,桥冻结时不再干等) | 3a45b8e | 真机时序验证 |
| F15 | 状态胶囊实时翻转(补订阅监听) | f1389e2 | 回归测试(无修复失败/有修复通过) |
| F16 | 启动加载配对设备(main._store.load) | eb0f45e | 真机验证 |
| F17 | 跨工作区混入 + listSessions 校验 → _normalizeWorkspace | 7b63940 | 真机验证 |

**用户明确要求的新特性(不得裁撤,仅复核)**:默认连接上次设备、连接后进工作区选择、进工作区直达最近会话、抽屉两组(活跃/归档)、消息时间戳、状态文字+图标、两行顶栏、输入栏按钮合并、模式简称、插入菜单二级分类、草稿选择持久化、自动化页文案。

---

## 第二部分:变更评审清单(逐项 What / Why / Impact / 决策建议)

### A. 协议层(lib/protocol/conversation.dart)

**A1. subscribe/subscribeSessionsIndex 失败回收**(try→dispose→rethrow)
- What:订阅启动失败时回收实例,防僵尸订阅残留
- Why:Ember A 系列加固;旧版失败即抛、实例泄漏
- Impact:仅失败路径;成功路径行为与旧版完全一致
- 决策:**复核保留**(纯健壮性,快乐路径零差异)

**A2. createSession 载荷重写**(去 firstInput/attachments;model→{providerId,modelId} 顶层;thoughtLevel/mode 顶层)
- What:见 F1/F2/F8;签名同步删除 firstText/attachments 参数
- Why:旧实现是死 bug(宿主剥离 firstInput)
- Impact:**不能回退**——回退=复活"新会话第一条消息收不到回复"
- 决策:**保留(已修复 F1/F2/F8)**

**A3. ConfigOptionValue 新增 modelProviderId / modelThoughtLevels 解析**
- What:读宿主注册表 provider id 与模型思考档位列表
- Why:F5("provider not in registry")的修复基础
- Impact:纯新增解析字段,不改变旧字段行为
- 决策:**保留(已修复 F5)**

**A4. SessionEntry 双方言字段**(phase/status、lastActivityAt/updatedAt、archived/archivedAt + isArchived)
- What:同一字段两套 wire 命名都认;归档时间戳
- Why:归档分流(F9/F10)需要
- Impact:向后兼容(旧字段优先级不变)
- 决策:**保留(已修复 F9/F10)**

**A5. createSession req/res debugPrint 探针**
- What:两行诊断打印
- Why:真机取证(思考档问题定位依赖它)
- Impact:每次建会话 2 行 logcat,无行为影响
- 决策:**保留**(与 B4 同为诊断能力;如嫌噪可后续统一降级)

**A6. 命名清扫与诊断文案**("上游协议"→"桌面端协议"等)
- Why:用户明确要求的与上游解耦
- 决策:**保留**

### B. 状态层(app_session / account_store / main)

**B1. AppSession 在途连接守卫**(_inFlight 复用、_connectIntents 撤销、_activationEpoch 末次请求胜)
- What:同账号并发 connect 复用同一 future;连接中途断开则作废;慢连接不抢激活
- Why:Ember A1/A2 加固(非用户报障)
- Impact:快乐路径(单连接、无切换)行为与旧版一致;有配套测试
- 决策:**复核保留**(建议;若按最严口径"未经授权一律回退",此项可回退——但会带回 socket 泄漏/抢激活隐患)

**B2. account_store.accounts 按 lastUsedAt 降序**
- What:设备列表排序从插入序改为最近使用优先
- Why:"默认连接上次设备"(用户要求)取 accounts.first 的依据
- Impact:设备管理页排序变化;无其他依赖
- 决策:**保留(用户特性配套)**

**B3. main.dart 启动即 _store.load()**
- 决策:**保留(已修复 F16)**

**B4. onLog 双写(debugPrint + LogStore)**
- What:协议日志同时进 logcat
- Why:release 真机取证(桥降级诊断靠它完成)
- Impact:logcat 噪音增加([wire]/[chat]/[zflow] 行);无行为影响
- 决策:**保留**(诊断基础设施;可讨论加开关)

### C. 会话列表数据管线(task_home_page → session_drawer)★核心区

**C1. 数据源倒置**
- What:旧版=**任务列表为主体**(listTasks+listPinned+listArchived 一次拉取,sessions-index 仅做富化:补 preview/phase、引入新会话;索引缺失的任务照常显示);新版=**索引为主体**(sessions-index 订阅是列表本体,listTasks/listArchivedTasks 降级为"归属过滤器":活跃=索引∩活跃任务,归档=archList 条目直构)
- Why:UI 大改把列表页改为常驻抽屉后,围绕"实时性"逐步重写;历经 r25–r33 多轮返工才稳定
- Impact:**这是回归重灾区**(混入/归档组空/闪烁/复位误判全部源于此管线的反复重写)。另注意一个事实:旧管线对"已删任务的索引条目"同样无防御(_mergeSessions 会引入索引新面孔)——用户当时实测旧版无混入,推测是当时工作区孤儿较少;**回退旧管线不会自动解决混入,F10 的过滤必须叠加保留**
- 决策建议:**回退旧管线骨架(任务为主体、索引富化),叠加保留 F9(归档组 archList 直构)+ F10(孤儿过滤,即活跃=合并结果∩(活跃任务∪索引),归档成员剔除)+ 索引富化仍过滤 archivedIds**。这样列表行为=旧版(含"任务不在索引也显示"的容差)+ 两项已验证修复
- 备选:维持现状(新版管线已真机验证通过)。**请用户拍板**

**C2. 刷新触发器群**(开抽屉重拉/索引新面孔重拉/活跃条目消失重拉/15s 节流/管理操作后重拉)
- What:旧版只有 init、下拉刷新、操作后三种;新版五种
- Why:F11(桌面归档不同步)
- Impact:RPC 频率略增(开抽屉+2 次);行为只增不删
- 决策:**保留 F11 部分**(若 C1 回退,触发器随旧骨架简化:保留"开抽屉重拉"+"索引移除活跃条目重拉"两个已验证触发,去掉 15s 节流轮询)

**C3. 离线种子 + _lastNonEmpty 粘性 + ready 门闩**
- What:打开抽屉先显示缓存;快照重放瞬间沿用旧列表
- Why:防闪(真机录屏验证);旧版也有缓存 hydrate(仅列表页)
- Impact:纯显示层防护
- 决策:**复核保留**(F12 相关)

**C4. vanished 回调(三重确认)**
- What:内嵌当前会话从索引消失→回调壳复位 draft(旧版无此机制——旧版列表页与聊天页分离,无内嵌会话)
- Why:新 UI 结构(抽屉+内嵌聊天)必需;F4
- 决策:**保留(新 UI 配套 + 已修复 F4)**

**C5. 丢失的旧功能:重命名、查看原始快照(TaskDetailPage)、条目左滑快捷操作**
- What:旧版单条操作单有 置顶/重命名/归档/取消归档/删除/查看原始快照;新版收进"管理"多选,只剩 置顶/归档/删除
- Why:UI 重构时裁掉,未经用户确认
- Impact:功能缺失(回归)
- 决策:**待用户拍板**——建议在抽屉条目长按单条操作里恢复"重命名/取消归档/查看原始快照"(RPC 与旧版同源:renameTask/unarchiveTask/getTaskSnapshotWithEtag)

**C6. 多选批量操作(置顶/归档/删除)**
- What:新增批量;RPC 与旧版同源
- 决策:**保留(纯新增能力)**

### D. 外壳流程(main_shell/accounts_page → root_shell)

**D1. 默认连接上次设备**(autoConnect + touch(lastUsedAt))
- 决策:**保留(用户要求;配套 B2/F16)**

**D2. 连接后进工作区选择页,不直接开会话**
- 决策:**保留(用户要求)**;旧版"单工作区自动打开"逻辑已被替代(多工作区场景)

**D3. 进工作区直达最近会话**(handshake→订阅索引→等首个快照≤4s→取最近未归档)
- What:全新管线(旧版进列表页)
- Why:用户要求"进入该工作区最近一个会话"
- Impact:已真机验证;实现里 80×50ms 轮询等快照略糙但可用
- 决策:**复核保留(用户特性,已验证)**;可选项:把轮询改成快照到达回调(实现更干净,行为不变)

**D4. _normalizeWorkspace**(bootstrap {path} 归一化)
- 决策:**保留(已修复 F17)**

**D5. _sessionEpoch / _onSessionInfo / adopt 宽限**(内嵌会话的身份/回写机制)
- 决策:**保留(新 UI 结构必需,F4 一部分)**

**D6. 当前会话消失复位(提示+回 draft)**
- 决策:**保留(依赖 C4,已验证)**

**D7. 常驻抽屉(Stack 形状恒定)**
- 决策:**保留(已修复 F12)**

### E. chat_page

**E1. 首发流程**(create→switchModelConfig→并行订阅→sendText)
- 决策:**保留(已修复 F1/F3/F8;回退任一环节=复活已修 bug)**

**E2. _buildDraftConfig 回填 + 草稿持久化(SharedPreferences)**
- 决策:**保留(F7 + 用户要求的持久化)**

**E3. _turnPending 乐观处理中 + 徽章/胶囊即时反馈**
- 决策:**保留(F14/F15)**

**E4. 消息时间戳 _zflowTs**
- 决策:**保留(旧 _zemoteTs 机制改名,零逻辑变化)**

**E5. 模型/思考/模式选择面板重构**(onDraftChange 移入组件、InputBar AnimatedBuilder)
- 决策:**保留(UI 重构 + F6)**

### F. 次级页面(automation / usage / settings / 设备管理 / 日志 / 扫码 / diff / markdown / theme)

- 全部为 UI 重排 + 文案(含用户要求的自动化页文案);**无任何 wire/RPC/持久化逻辑变更**(diff 筛查确认)
- 决策:**保留,无需回退**

---

## 第三部分:执行 TODO(确认后逐项人工修改,严禁脚本批处理)

- [x] T1(C1)session_drawer 数据管线回退旧法骨架:任务为主体+索引富化;叠加 F9/F10 —— 已执行(fc12b13)
- [x] T2(C2)刷新触发器:**全保留**(含 15s 节流——实测索引不移除归档条目,节流是抽屉展开期桌面归档同步的唯一通道)
- [x] T3(C5)恢复丢失操作:重命名/取消归档/查看原始快照 —— 长按单条操作已恢复(TaskDetailPage 重建)
- [x] T4(C5)左滑快捷操作 —— 不恢复(不在批准建议内)
- [x] T5(B1)AppSession 在途守卫 —— 保留(用户未要求回退)
- [x] T6(A5/B4)诊断日志 —— 设置页开关「诊断日志(logcat)」,默认关,持久化
- [x] T7 全量测试(277 绿)+ release 构建 + 真机回归(活跃组排序/无混入、归档组直构正常)

## 复核结论(供决策参考)

87 个提交里,**未经用户要求、且改变了行为逻辑**的改动集中在两处:
1. **C1 会话列表数据源倒置**(及其衍生的触发器群)——唯一建议"回退旧实现骨架"的项(叠加保留 F9/F10 两个已验证修复);
2. **B1 AppSession 在途守卫、A1 订阅失败回收**——快乐路径行为与旧版一致的加固,建议保留。

其余逻辑变更全部属于:用户明确要求的特性、或用户报障后的已验证修复(第一部分清单),按铁律第 2 条应予保留。
