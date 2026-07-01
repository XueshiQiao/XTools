# PopBar 全局网页预览 + Action 呈现抽象 — 设计文档

- 日期:2026-07-01
- 状态:待用户 review → 转 writing-plans
- 涉及工具:`XTools/Sources/Tools/PopBar`

## 1. 目标(v1)

在**任意 app**(聊天窗、浏览器、邮件、文档…)选中一段文字后,PopBar 圆盘上出现一个"网页预览"动作;点它就在一个 **Mini-browser 悬浮窗**里打开该选区**关联的链接**——不只是"选中的就是一段 URL",还包括"**选中的可见文字不是 URL,但它背后挂着一个超链接**"的情况。

同时,把 action 从"copy / ai 两种硬编码"升级成一层**执行 ↔ 呈现分离**的抽象:action 跑完产出一个开放式 `PopBarPresentation`,由 `PresentationRouter` 决定渲染到哪个 surface(结果页 / 网页预览 / 未来的 Markdown 预览、图片预览…)。

## 2. 非目标(留后续)

- T5:Safari/Chrome 专用 AppleScript/JS 取 `<a>`(需自动化授权、逐浏览器适配)——v2。
- 多个预览窗并存、预览窗内多标签、阅读模式、下载——后续。
- 真正的新呈现类型(Markdown 预览、图片预览)——本次只把**抽象**铺好,不实现它们。

## 3. 现状(已读代码确认)

- 选区管线产出**纯文本** `SelectionResult { text, via, bounds }`,无任何链接信息。
- 三条策略,`SelectionResolver` 按序取第一个非空:
  - `AccessibilityStrategy` — 读 `kAXSelectedTextAttribute`,再读 WebKit `AXSelectedTextMarkerRange`;持有 `focused` 元素。
  - `CopyOnSelectStrategy` — 终端 copy-on-select,直接读剪贴板。
  - `ClipboardCopyStrategy` — 合成 ⌘C,**备份/恢复整个 pasteboard**,但只读 `.string`(HTML/RTF 被备份却没被读)。
- 动作 `PopBarActionConfig.Kind = .copy | .ai`;`ActionRegistry.run/runStreaming` switch on kind → 返回 `PopBarActionOutcome = .dismiss | .showResult(String)`;`PopBarSession.applyOutcome` 把 outcome 映射成 `PopBarPanel` 的 phase。
- 触发流程 `PopBarController.handleTrigger`:后台 `Task` 里 `resolver.resolve(context)` → hop 回 main → `windows.showTransient(text, anchor, actions)`。

## 4. 关键取舍:链接"触发时解析、点击时打开"

技术约束:T2/T3/T4 的原料**只有触发那一瞬间拿得到**——
- T2/T3 需要**触发时**原 app 的 focused AX 元素(圆盘一弹,系统焦点转到 PopBar 面板,原引用失效);
- T4 需要那次合成 ⌘C 落盘的 HTML/RTF(`ClipboardCopyStrategy` 读完就 restore 掉了)。

因此架构定为:**触发时把 URL 解析好、连同链接原料挂到 session;点击动作时只负责打开窗口 / 决定回退搜索**。用户选的"点了才解析"落实为"**点了才打开预览窗、才决定回退**"。

**性能门控(One Source of Truth):** `SelectionContext` 增加 `resolvesLinks: Bool`,由 `PopBarController` 依据「当前 `actionStore` 是否含 `.webPreview` 动作」计算。为 false 时:策略**不附带任何链接原料**、`LinkResolver` **完全不执行**、不打链接日志 → 功能没上圆盘就零成本(符合"关掉的功能不该有开销")。

## 5. 模块设计

每个模块都是可独立理解/测试的小单元。

### 5.1 `LinkResolver`(新文件 `Selection/LinkResolver.swift`)— 链接逻辑唯一去处

四层为互不耦合的静态方法,输入是触发时捕获的 `LinkProbe`:

```
struct LinkProbe {
    let text: String
    let mouseLocation: CGPoint        // Cocoa 左下原点(与 SelectionContext 一致)
    let focusedElement: AXUIElement?  // AX/CopyOnSelect 路径附带
    let html: Data?                   // 富文本剪贴板路径附带(public.html)
    let rtf: Data?                    // 富文本剪贴板路径附带(public.rtf)
}
```

- **T1 `fromText`** — `NSDataDetector(.link)` 扫 `text`,取第一个 http/https。全平台兜底。
- **T2 `urlUnderPoint`** — `AXUIElementCopyElementAtPosition(systemWide, x, y)`(**坐标翻转**:AX 左上原点 vs Cocoa 左下,主屏高度做 flip),向上遍历祖先找 role `AXLink`,读 `kAXURLAttribute`(`AXURL`,`NSURL`)。
- **T3 `urlInSelection`** — 对 `focusedElement` 读 `AXAttributedStringForTextMarkerRange`(WebKit)/ `kAXAttributedStringForRangeParameterizedAttribute`(AppKit),枚举属性,取第一个 `AXLink`(读其 `AXURL`)或 `NSLinkAttributeName` run。
- **T4 `fromRichText`** — 解析 `html` 的 `<a href>`(`NSAttributedString(html:)` 枚举 `.link`,或轻量正则)或 `rtf` 的 hyperlink field。

对外只暴露一个入口:

```
enum ResolvedTier { case t1, t2, t3, t4, none }
struct LinkResolution { let url: URL?; let tier: ResolvedTier }

func resolve(_ probe: LinkProbe) -> LinkResolution   // 内部四层全跑 + 全打日志;胜出按下方"优先级"
```

**优先级 / 胜出规则:** 语义上"关联链接"最强信号是 **T2/T3(AX 明确的 anchor→URL)**,其次 T4(富文本 href),T1(裸 URL 文本)最弱但最稳。选择顺序:**T2 → T3 → T4 → T1**(第一个非 nil 胜出)。四层**都会执行并记录**(便于分析),只是"胜出"按此优先级挑。缺原料的层记为 skipped(附原因)。

> 诚实标注(HARD RULE 1):T1~T4 的 URL 提取目前**全部"未验证"**——读代码 + PopClip 系工具通行做法推断,尚未在本 repo 真跑。落地后做原型 + 截图实测才会说"可用"。已预见风险:T2 坐标翻转、拖选终点是否恰在链接上、T4 依赖目标 app 是否往剪贴板放 HTML/RTF、自绘/未开 AX 的 Electron 可能四层全空。

### 5.2 分层诊断日志(用户明确要求:每层内容 + 耗时)

新日志频道 `FileLog("PopBar.Link")`。`LinkResolver.resolve` 里每层用**单调时钟**(`DispatchTime.now()` 差值,非 `Date`)计时,统一格式:

```
[PopBar.Link] resolve start — text="click here"(10 chars) mouse=(842.0,231.5) front=com.apple.Safari hasElem=true html=false rtf=false
[PopBar.Link] T1 fromText        ran     → nil                         (0.28ms)
[PopBar.Link] T2 urlUnderPoint   ran     → https://example.com/foo     (2.10ms)
[PopBar.Link] T3 urlInSelection  ran     → https://example.com/foo     (3.42ms)
[PopBar.Link] T4 fromRichText    skipped (no rich pasteboard on AX path)  (0.00ms)
[PopBar.Link] resolved via T2 → https://example.com/foo   total=5.9ms
```

- URL 内容**完整打印**(便于分析);skipped 必须带原因。
- 该日志只在 `resolvesLinks == true` 时产生(门控),所以不刷屏。
- 属于**长期分析日志**,非临时 DBG 脚手架;级别 `.info`(可后续降级)。

### 5.3 Action 抽象:执行 ↔ 呈现分离

**配置层不变的部分**:`PopBarActionConfig.Kind` 仍是 `Codable` 持久化枚举,新增 `case webPreview`(本地动作,无 prompt/model)。持久化/编辑器围绕 `Kind`。

**产出层泛化**:把 `PopBarActionOutcome` 升级为开放式呈现类型:

```
enum PopBarPresentation {
    case none                 // 关闭/无 UI(原 .dismiss;copy 用它)
    case result(String)       // 结果页(可流式;AI 用它。原 .showResult)
    case webPreview(URL)      // Mini-browser 网页预览
    // 预留:case markdownPreview(String) / case image(URL) …
}
```

- 向后兼容:`.dismiss → .none`、`.showResult → .result`。流式仍只服务 `.result`(webPreview 无流)。
- **执行**:`ActionRegistry.run/runStreaming` 产出 `PopBarPresentation`。`.webPreview` 分支:读 `session` 上已解析的 `url`;非空 → `.webPreview(url)`;空 → 走回退(见 5.5)。
- **呈现路由**:新增 `PresentationRouter`(注入到 `PopBarSession`,不让 session 直接摸全局)。`session.applyOutcome` 改为 `router.present(_:in:)`:
  - `.none` → 关窗(原 dismiss 路径);
  - `.result` → `PopBarPanel` 结果 phase(现有);
  - `.webPreview(url)` → `WebPreviewController.open(url)`(见 5.4)。
- 加新呈现类型 = 加一个 enum case + 一个 router 分支(+ 可能一个新窗),**不碰现有动作执行逻辑**。

### 5.4 `WebPreviewWindow` / `WebPreviewController`(新文件,`PopBar/WebPreview/`)

- 独立 `NSWindow`(标准 traffic-lights + 可缩放/拖动/**记忆 frame** 到 prefs),内容 = 迷你工具条(后退 / 前进 / 刷新 / 复制链接 / 在默认浏览器打开)+ `WKWebView` 填满。
- **v1 单窗复用**:`WebPreviewController` 持有单例窗;再次预览 = 在同一窗导航新 URL(makeKeyAndOrderFront 再 activate,遵循 [[macos-window-activation-order]])。
- **安全/隐私默认**:`WKNavigationDelegate` 只放行 `http/https`(拒 `javascript:`/`file:` 等);`WKWebsiteDataStore.nonPersistent()`(不落 cookie/历史,privacy-first)。
- 首现位置:复用现有面板定位工具,靠近光标。

### 5.5 无链接回退

- `PopBarPreferences` 加 `previewSearchEngine`(默认 **Bing**,国内外都通;设置可改)+ `previewFallbackToSearch: Bool`(默认 on)。
- 点"网页预览"时 `url == nil`:
  - `previewFallbackToSearch == true` → 用选中文字拼搜索 URL,丢进同一个预览窗;
  - 否则 → `.result("未找到链接")`(面板轻提示)。

### 5.6 数据模型 / 迁移变更

- `SelectionResult` 加 `var url: URL?`(最终解析结果)+ 触发时链接原料 `var focusedElement: AXUIElement?`、`var html: Data?`、`var rtf: Data?`(仅 `resolvesLinks` 时附带)。
- `SelectionContext` 加 `let resolvesLinks: Bool`。
- 策略只**附带原料**(不含链接解析):`AccessibilityStrategy`/`CopyOnSelectStrategy` 附 `focusedElement`;`ClipboardCopyStrategy` 在 restore 前把 `.html/.rtf` data 附上。解析集中在 `LinkResolver`。
- `PopBarSession` 存 `url`;`show(text:url:anchor:actions:)`。
- `PopBarActionConfig.Kind` 加 `.webPreview`;`PopBarActionEditorView` 加分支(仅 标题+图标,像 copy)。
- `DefaultActions.seed()` 追加一个 `webPreview` 动作(图标 `safari`,标题"网页预览 / Web Preview")。
- **老用户数据安全**:已有持久化 action 列表做一次**非破坏性追加**——`ActionStore` 加载后,若不含 `.webPreview` 动作**且**未打过本迁移标志,则**追加**(只增不删,不动排序),并记标志。永不删用户数据。

## 6. 本地化 / 权限

- 新字符串进 `Localizable.strings`(en + zh):动作标题、"未找到链接"、工具条 tooltip、设置项。
- 无新系统权限(AX 已有);WKWebView 联网是浏览器本分,app 本就非沙箱。

## 7. 性能 & 安全小结

- 链接解析 + 日志全程 `resolvesLinks` 门控;全在后台 `resolve` Task 里(不阻塞主线程)。
- T4 复用 `ClipboardCopyStrategy` 既有 ⌘C,不额外合成复制 → 不引入 issue #15 的 beep。
- 预览窗按需创建、单例复用、非持久化数据存储。

## 8. 文件改动清单

新增:
- `PopBar/Selection/LinkResolver.swift`
- `PopBar/WebPreview/WebPreviewController.swift`
- `PopBar/WebPreview/WebPreviewWindow.swift`(或 SwiftUI + NSHostingController)
- `PopBar/Actions/PresentationRouter.swift`

改动:
- `Selection/SelectionStrategy.swift`(`SelectionContext.resolvesLinks`;`SelectionResult` 加 url/原料字段)
- `Selection/AccessibilityStrategy.swift`、`CopyOnSelectStrategy.swift`、`ClipboardCopyStrategy.swift`(附带原料)
- `Controller/PopBarController.swift`(算 `resolvesLinks`;resolve 后调 `LinkResolver`;`showTransient` 带 url)
- `Controller/PopBarWindowManager.swift` / `Window/PopBarSession.swift`(存/传 url;`PresentationRouter` 注入)
- `Actions/PopBarActionConfig.swift`(`.webPreview` kind;`PopBarPresentation`)
- `Actions/ActionRegistry.swift`(产出 `PopBarPresentation`;`.webPreview` 分支)
- `Actions/ActionStore.swift`(非破坏性迁移追加)
- `PopBarActionEditorView.swift`(webPreview 编辑分支)
- `PopBarPreferences.swift`(`previewSearchEngine`、`previewFallbackToSearch`、预览窗 frame)
- `Localizable.strings`(en + zh)

## 9. 验证计划(HARD RULE 2)

不声称"可用"直到实测:kill 旧实例 → 重编 → 重签 → 重启,然后:
1. 选一段**裸 URL** → 预览窗打开它(验 T1)。
2. 在 Safari 选一段**锚文字**(可见文字≠URL)→ 预览窗打开其 href(验 T2/T3),看 `PopBar.Link` 日志确认哪层胜出 + 各层耗时。
3. 在**邮件/富文本** app 选锚文字 → 验 T4。
4. 选一段**普通文字**(无链接)→ 验回退搜索 / 提示。
5. 看日志:每层内容 + 耗时都在。
截图 + 贴日志给用户,再判定各层"可用/未验证/做不到"。

## 10. 已定取舍

- 预览界面 = Mini-browser 悬浮窗(单窗复用 v1)。
- 链接覆盖 = T1~T4 全上。
- 无链接 = 动作常驻,点了才打开;可回退搜索(默认 Bing)。
- 链接"触发解析、点击打开",门控在「圆盘是否含 webPreview 动作」。
- 四层全跑全打日志(分析优先),胜出按 T2→T3→T4→T1。
- Action 抽象 = Kind(持久化)不变 + `PopBarPresentation`(开放产出)+ `PresentationRouter`(呈现路由)。
