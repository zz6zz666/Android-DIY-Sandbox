# Lua 沙盒脚本开发指南 (AGENTS.md)

> 你正在编辑一个 **Lua 声明式沙盒 App** 的脚本目录。本 App 是一个**空壳运行时**:
> 导航栏、每个页面的内容、主页顶栏按钮、对话框、乃至内嵌的小游戏,**全部由本目录下的 Lua
> 脚本声明式定义**,App 本身不含任何写死的业务界面。改脚本即改 App,无需重新编译。

## 目录结构

```
scripts/
  main.lua          用户主脚本 (入口, 自由定制: 导航/页面/组件)
  agent/main.lua    Agent 入口 (用户可见可改, 但一般不必动; 独立且受保护地加载)
  agent/sandbox     命令行工具集: reload / ping / run / log (改完脚本触发重载、隔离试跑、看日志)
  AGENTS.md         本文档
  ...               其余 .lua 模块 / 资源 / love 工程目录, 由你自由组织
```

> love 游戏↔UI 的通信桥(`love_host.lua`)由 App 在运行时自动、隐蔽地提供(不落在本工作区),
> 游戏里直接 `require("love_host")` 即可用,无需你创建或维护它。

- **`main.lua` 是你主要编辑的文件。** 即使把它改崩,`agent/main.lua`(独立、受保护地先行加载)
  注册的两个 Agent 入口按钮(主页顶栏右侧、设置齿轮左边的两枚)仍在,不受影响。
- 全局变量 `SCRIPTS` = 本目录绝对路径(用于拼 game 路径等)。
 - **应用脚本更改**:主页顶栏刷新图标重载(损坏会自动回退快照,15s 倒计时可保留/回退);
   Agent 也可在命令行 `bash agent/sandbox reload` 主动触发同样的重载(见「十二」)。
 - **引擎**:LuaJIT 2.1,完整标准库(`string/table/math/os/io/bit/ffi/coroutine`)全部可用。

---

## 一、应用框架与核心概念

### 声明式 UI

界面 = 组件树。每个组件是一个构造函数(`card`、`row`、`button`…),返回一个普通 Lua 表,
可自由拼接、按条件生成、存进变量。交互回调都是普通 Lua 函数。

```lua
app.page("home", function(ctx)
  return {
    card("你好", {
      text("这是一张卡片"),
      button("点我", function() host.toast("clicked") end),
    }),
  }
end)
```

### 状态: state 与 reactive

两种响应式状态,分工不同:

```lua
-- state(key, default): 页面级。set 触发【整页重建】(重跑页面函数), 适合布局/结构变化。
local n = state("counter", 0)
n.get()                           -- 读
n.set(n.get() + 1)                -- 写 → 触发当前页重建 (页面重建时按 key 保留)

-- reactive(key, initial): 细粒度。set 只重绘【绑定该 key 的组件】, 不重跑整页。
-- 适合高频更新 (AI 逐字输出、进度、计时), 避免整页重建卡顿。
local reply = reactive("chat.reply", "")
text("", { bind = "chat.reply" })     -- 该文本跟随 reply 实时刷新
reply.set(reply.get() .. token)       -- 每次只重绘这一个 Text
```

> **持久化**(重启仍在)用 `host.set/get`(简单键值)或 `store`(SQLite,见第十一节);
> **落盘**用 `host.write_file`。

### 导航栏与页面

导航栏由 `nav.tabs` 定义。每个 tab 的 `page` 有四种取值:

| page 取值        | 页面类型                                                                |
| ---------------- | ----------------------------------------------------------------------- |
| `"home"`       | 内置主页(唯一包括顶栏以及置入口)                                        |
| `terminal()`   | 内置终端页                                                              |
| `webview()`    | 内嵌网页标签(默认空白;用`host.webview_open(url, title)` 打开具体网页) |
| `"任意页面名"` | 用`app.page` 注册的自定义页面(设置页、游戏页、AI 应用页…)            |

```lua
nav.tabs({
  { title = "主页",  icon = "home_outlined", page = "home" },
  { title = "WebUI", icon = "language",      page = webview() },
  { title = "终端",  icon = "terminal",      page = terminal() },
})
```

> `main.lua` 缺失或加载崩溃时,App 自动回退到内置三页(主页 / 网页 / 终端)自救,
> 保证还能进终端与设置。此时 `agent/main.lua` 若正常,Agent 入口按钮依然在主页顶栏。

### 添加一个自定义导航页

两步:注册页面 + 挂到导航栏。

```lua
app.page("mypage", function(ctx)
  return { card("我的页面", { text("Hello") }) }
end)

nav.tabs({
  { title = "主页", icon = "home", page = "home" },
  { title = "我的", icon = "star", page = "mypage" },   -- 挂上去
})
```

页面 `build(ctx)` 返回单个组件或组件数组(数组默认纵向堆叠;顶层区块**惰性构建**,
首屏外的区块滚到才建)。`ctx.running` 是 `{ [spawnKey]=bool }` 表,反映后台任务运行态(见 `host.spawn`)。

> **铺满整页**:返回数组或单个普通组件时,页面会套一层滚动容器,内部 `expanded` 会因高度无界
> 失效(空白/报错)。要铺满(整屏游戏、上中下布局),给**根组件**加 `fill = true`:
>
> ```lua
> return column({
>   row({ iconbutton("arrow_back", back), text("标题") }),
>   divider(),
>   expanded(body),                       -- 撑满剩余空间
> }, { fill = true })
> ```
>
> `tabs` / `lifecycle` 作根组件时自动铺满。

### 页内多标签

用 `tabs` 组件在**一个页面内**做多标签切换。标签状态由脚本用 `state` 管理(`active` 从 1 起):

```lua
app.page("tools", function()
  local t = state("tools.tab", 1)
  return tabs({
    active = t.get(),
    onSelect = function(i) t.set(i) end,
    items = {
      { title = "常规", icon = "tune",     content = card("常规", { text("...") }) },
      { title = "高级", icon = "settings", content = card("高级", { text("...") }) },
    },
  })
end)
```

`tabs` 还支持 `onClose(i)`、`onReorder(from,to)`、`trailing`(标签栏右侧)、`empty`(无标签文案)。
默认全部标签常驻(切换只挂起、保留状态);`tabs({ keepalive=false })` 则只挂载当前标签、切走即卸载
——配合 `love{keepalive=false}` 可实现"切标签销毁另一个游戏进程"。

> **标签内容自动滚动**:每个标签的 `content` 默认套一层可滚动容器(超出视口不会溢出),行为等同一个页面。
> 若某标签要**铺满**(整块 `love` 画布、`list` 虚拟长列表、或需要内部 `expanded`),把该 `content` 设为
> 填充型即可(`love{}` / `list(...)` / 嵌套 `tabs` / 根组件加 `fill=true`),框架会跳过滚动容器让它占满。

### 主页顶栏自定义按钮

主页右上角(设置齿轮左侧)可放自定义图标按钮:

```lua
app.actions({
  { icon = "rocket_launch", tooltip = "启动", onTap = function() end },
  { icon = "smart_toy",     tooltip = "AI",   onTap = function() end },
})
```

> 主页顶栏按钮均在右侧,从左到右顺序为:Agent 入口按钮(来自受保护的 `agent/main.lua`)→ 你的 `app.actions` 按钮 → 设置齿轮(最右)。
> **不要**把 Agent 启动入口写进 `main.lua`——它已在 `agent/main.lua`,那里用 `app.agent_actions({...})` 注册,
> 与用户脚本解耦,不会被 `main.lua` 覆盖或弄丢。

---

## 二、UI 组件

所有组件都接受可选 `style`(见[样式](#三样式-style))。下表列出主要属性。

### 布局

| 构造                                                                | 说明                                                                               |
| ------------------------------------------------------------------- | ---------------------------------------------------------------------------------- |
| `column(children, {main,cross,gap,expand})`                       | 纵向。main/cross:`start/end/center/stretch/spaceBetween/spaceAround/spaceEvenly` |
| `row(children, {main,cross,gap,expand})`                          | 横向                                                                               |
| `stack(children)`                                                 | 层叠(配合`positioned`)                                                           |
| `wrap(children, {spacing,runSpacing})`                            | 自动换行流式                                                                       |
| `grid(children, {columns,gap,ratio,padding,scroll})`              | 网格。`scroll=true` 时虚拟化(仅建可视项)                                         |
| `list(children, {axis,separator,padding,scroll})`                 | 列表。`scroll=true` 时虚拟化;每项可带 `key` 字段助复用                         |
| `datatable({headers, rows})`                                      | 数据表                                                                             |
| `padding(child, pad)` · `align(child, a)` · `center(child)` | 内边距 / 对齐 / 居中                                                               |
| `expanded(child, flex)` · `flexible(child, {flex,tight})`      | 在 row/column 中占据/弹性空间                                                      |
| `spacer(size?)`                                                   | 间隔(省略则弹性)                                                                   |
| `box({width,height,child})`                                       | 定尺寸盒子                                                                         |
| `scroll(children, {axis})`                                        | 滚动容器                                                                           |
| `positioned(child, {left,top,right,bottom,width,height})`         | 在 stack 中定位                                                                    |
| `aspect(child, ratio)` · `fitted(child, fit)`                  | 宽高比 / 缩放适配                                                                  |
| `clip(child, {shape,radius})` · `safearea(child)`              | 裁剪 / 安全区                                                                      |
| `gesture(child, {onTap,onLongPress,onDoubleTap})`                 | 手势区域                                                                           |
| `inkwell(child, {onTap,radius})`                                  | 水波纹点击区                                                                       |
| `tooltip(child, msg)`                                             | 长按提示                                                                           |

> **长列表虚拟化**:聊天/信息流等超长列表用 `list(items, {scroll=true})`,只建可视项,千万项也流畅;
> 通常放进有界高度容器(如 `box({height=300, child=list(...)})`)。普通 `column`/`row` 会全量构建。

> **`row` 里放会变长的文本要 `expanded`**:`row` 给子组件的是无限宽度,直接放一段可能变长的 `text`
> (状态、错误信息、用户输入回显)会**右侧溢出**。用 `expanded(text(...))` 包住让它在行内换行/省略。

### 内容

| 构造                                                                      | 说明                                                                                  |
| ------------------------------------------------------------------------- | ------------------------------------------------------------------------------------- |
| `text(s, {size,weight,color,align,maxLines,ellipsis,bind})`             | 文本。`bind="reactiveKey"` 时内容跟随 `reactive(key)` 实时刷新(流式,只重绘本组件) |
| `markdown(s, {selectable})`                                             | 渲染 Markdown(标题/列表/代码块/加粗/链接等);链接点击自动外部打开                      |
| `richtext({ {text,color,weight,size,italic,underline}, ... }, {align})` | 富文本(多段)                                                                          |
| `icon(name, {size,color})`                                              | 图标(见[图标](#四图标))                                                                |
| `avatar({image,icon,text,radius,color})`                                | 头像                                                                                  |
| `image(path, {width,height})`                                           | 本地路径或`http(s)` 图片                                                            |
| `spinner({size,value,color})`                                           | 环形加载                                                                              |
| `progress(value, {color,track})`                                        | 线形进度(0..1,nil 为不确定)                                                           |
| `chip(label, {color})` · `badge(child, {label,color})`               | 标签 / 角标                                                                           |
| `divider(...)` · `vdivider(...)`                                     | 横 / 竖分隔线                                                                         |

### 交互

| 构造                                                                 | 说明                                           |
| -------------------------------------------------------------------- | ---------------------------------------------- |
| `button(label, onTap, {variant,icon,color,danger})`                | variant:`filled/tonal/outlined/text`         |
| `iconbutton(name, onTap, {tooltip,color})`                         | 图标按钮                                       |
| `fab(icon, onTap, {label,color,mini})`                             | 浮动按钮                                       |
| `tile(title, {subtitle,icon,trailing,onTap})`                      | 列表项                                         |
| `menu(iconName, items)`                                            | 弹出菜单;items:`{{label,onTap,enabled},...}` |
| `toggle({title,value,onChanged})`                                  | 开关                                           |
| `checkbox({title,value,onChanged})`                                | 复选                                           |
| `radio({title,value,options,axis,onChanged})`                      | 单选组;`onChanged(v)`                        |
| `slider({value,min,max,onChanged})`                                | 滑块                                           |
| `rangeslider({min,max,low,high,onChanged})`                        | 区间滑块;`onChanged(lo,hi)`                  |
| `select({title,value,options,onChanged})`                          | 下拉;options:`{{label,value},...}`           |
| `segmented({value,options,onChanged})`                             | 分段单选                                       |
| `togglebuttons({options,selected,multi,onChanged})`                | 切换按钮组                                     |
| `textfield({label,hint,value,onChanged})`                          | 输入框                                         |
| `datefield({label,onChanged})` · `timefield({label,onChanged})` | 日期 / 时间选择                                |
| `stepper({active,steps,onStep,onContinue,onCancel})`               | 步进器                                         |

### 容器

| 构造                                              | 说明                                                     |
| ------------------------------------------------- | -------------------------------------------------------- |
| `card(title, children)` / `card(children)`    | 毛玻璃卡片                                               |
| `section(title, children)`                      | 带标题分组                                               |
| `expansion(title, children, {icon})`            | 可展开面板                                               |
| `tabs({...})`                                   | 页内多标签(见[第一部分](#页内多标签))                     |
| `lifecycle({child, onShow, onHide, onDispose})` | 可见性生命周期包裹(见[动态加载](#十一动态加载与生命周期)) |

---

## 三、样式 style

任意组件传 `style = { ... }`:

| 属性                                                                       | 取值                                                   |
| -------------------------------------------------------------------------- | ------------------------------------------------------ |
| `width`/`height`/`minWidth`/`maxWidth`/`minHeight`/`maxHeight` | 尺寸与约束                                             |
| `padding`/`margin`                                                     | edge 格式                                              |
| `bg`/`border`/`color`/`borderWidth`/`radius`/`opacity`         | 背景/边框/圆角/透明度                                  |
| `align`                                                                  | `topLeft … center … bottomRight`                   |
| `aspectRatio`/`rotate`/`scale`                                       | 宽高比 / 旋转弧度 / 缩放                               |
| `shadow`                                                                 | `true` 或 `{color,blur,dx,dy,spread}`              |
| `gradient`                                                               | `{type="linear"/"radial", colors={...}, begin, end}` |

**颜色**:`"#RRGGBB"`/`"#AARRGGBB"` · 主题色 `primary/secondary/error/surface/...` ·
Material 色板 `red/blue/teal/...`(带明度 `"blue.700"`,强调色 `blueAccent`)· `white/black/transparent/...` ·
RGB 表 `{r=255,g=128,b=0,a=1}`。

**edge 格式**:`8`(四边)/ `{h,v}` / `{l,t,r,b}` / `{left=,top=,right=,bottom=}`。

---

## 四、图标

图标名 = Flutter `Icons.<name>` 标识符,**全量 8000+ Material 图标可用**(填规范名,无历史别名):

```lua
icon("home")            -- 填充版
icon("home_outlined")   -- 描边版(常见变体: _outlined / _rounded / _sharp)
icon("rocket_launch")
icon(0xe88a)            -- 也可直接用 codepoint
```

> 图标显示成方框/不显示,多为名字拼错。

---

## 五、love2d 画布(游戏 / 动画作为 UI 组件)

`love{}` 生成一块 **love2d 画布**。它在底层就是**页面里的一个普通 Flutter UI 组件**——
不是覆盖层,而是原生地参与排版:可随页面一起滚动、拉伸,与任何其它组件同层摆放。

```lua
love{ id = 0, game = SCRIPTS.."/games/mygame" }
```

| 属性                 | 说明                                                                                                                  |
| -------------------- | --------------------------------------------------------------------------------------------------------------------- |
| `id`               | 画布标识**0..3,必须唯一**。每个 id 是一块独立实例(独立进程),同屏多块须各用不同 id                               |
| `game`             | love2d 工程目录绝对路径(内含`main.lua`)                                                                             |
| `width`/`height` | 尺寸;作为普通元素时 height 默认 200                                                                                   |
| `autopause`        | 默认`true`:切走导航页自动挂起(停渲染、留内存、不丢状态)                                                             |
| `keepalive`        | 默认`true`:移除时只挂起保留;`false` 则销毁进程,下次挂载全新启动                                                   |
| `freeze`           | 默认`false`:挂起时按真实时间推进(回来追补流逝);`true` 冻结游戏时钟、回来从快照续(游戏需 `require("love_host")`) |
| `onEvent`          | `function(msg)`:收到游戏发来的消息(表)时回调(见下「双向通信」)                                                      |

`game` 指向一个标准 love2d 工程,`main.lua` 里实现 love 回调(触摸已从 Flutter 转发):

```lua
-- SCRIPTS/games/mygame/main.lua
function love.update(dt) ... end
function love.draw() love.graphics.print("hi", 8, 8) end
function love.touchpressed(id, x, y) ... end
```

> **生命周期(运行/冻结/销毁)**:love 与纯 Lua 共用同一套模型,详见
> [动态加载与生命周期](#十一动态加载与生命周期)。渲染只在可见时进行。

### 双向通信(UI ↔ 游戏)

游戏在**独立进程、独立 Lua 状态**运行,与 UI 通过消息通信:消息是任意可 JSON 化的 Lua 表,
自动序列化(底层本机加密通道):

```lua
-- UI 侧
love{ id = 0, game = ..., onEvent = function(msg)
  if msg.type == "score" then score.set(msg.data.value) end   -- 收游戏事件
end }
love.send(0, "reset")                 -- UI → 游戏发命令 (第 1 个参数是画布 id)
love.send(0, "hit", { dmg = 10 })     -- 带数据; 等价于 love.send(0, {type="hit", data={dmg=10}})
love.on(0, function(msg) end)          -- 也可在组件外单独登记事件回调

-- 游戏侧 (游戏 main.lua 顶部一行接入)
local host = require("love_host")      -- 通信桥, App 运行时自动隐蔽提供, 无需创建/维护
host.on("reset", function(data) resetGame() end)   -- 收 UI 命令
host.on(function(msg) end)                          -- 兜底: 收全部消息
host.emit("score", { value = 1200 })                -- 回传事件给 UI
host.emit({ type = "over", score = 1200 })          -- 或直接给整表
host.connected()                                     -- 是否已连上 UI
```

> `love_host` 是通信桥的**游戏侧**一半(宿主侧在 Dart 层),必须跑在 love 进程内,故随游戏加载。
> App 自动注入到运行时目录,你在工作区看不到、也无需维护。

### 两种典型用法

**① 小游戏 → 全画布**。把 love 作为整页(或某标签页)里**唯一**的元素,自然最大化;配多标签做游戏合集:

```lua
app.page("games", function()
  local t = state("games.tab", 1)
  return tabs({
    active = t.get(), onSelect = function(i) t.set(i) end,
    items = {
      { title="旋转三角", icon="change_history", content = love{ id=2, game=SCRIPTS.."/games/mygame" } },
      { title="跑酷",     icon="directions_run", content = love{ id=3, game=SCRIPTS.."/games/mygame2" } },
    },
  })
end)
```

**② 动画 / 贴图 → 与其它 UI 同层排版**。当成普通组件放进卡片、行列里,做一小块动效:

```lua
card("今日", {
  row({
    love{ id=0, width=120, height=120, game=SCRIPTS.."/games/mygame" },
    spacer(12),
    expanded(text("一段说明文字……")),
  }),
})
```

---

## 六、网络:HTTP / WebSocket

```lua
local id = host.http{
  url = "https://api.example.com/v1/chat",
  method = "POST",                       -- 默认 GET
  headers = { ["Content-Type"]="application/json", Authorization="Bearer sk-..." },
  body = json.encode({ ... }),
  stream = true,                         -- true 时逐块回调 on_chunk(SSE)
  timeout = 60,
  response_type = "text",                -- "bytes" 时 res.body 为 base64(下载图片/音频)
  on_response = function(status, headers) end,
  on_chunk    = function(text) end,      -- 仅 stream=true
  on_done     = function(res) end,       -- res = {status, ok, headers, body}
  on_error    = function(err) end,
}
host.http_cancel(id)                     -- 取消在途请求
```

**二进制上传 / multipart 表单**:

```lua
host.http{
  url = "https://api.example.com/v1/audio/transcriptions",
  method = "POST",
  headers = { Authorization = "Bearer sk-..." },
  form = {
    fields = { model = "whisper-1" },
    files  = { { name="file", path="/sdcard/a.mp3", filename="a.mp3" } },
    -- 文件也可用 base64=host.read_bytes(p) 或 text="纯文本字段"
  },
  on_done = function(res) host.log(res.body) end,
}
-- 或纯二进制体: body_base64 = host.base64_encode(...)
```

**WebSocket**:

```lua
local ws = host.websocket{
  url = "wss://example.com/socket",
  headers = {},
  on_open    = function() end,
  on_message = function(data, is_binary) end,   -- 文本=string; 二进制=字节数组
  on_close   = function(code, reason) end,
  on_error   = function(err) end,
}
ws:send('{"type":"ping"}')
ws:close()
```

> SSE 的 `data:` 行拆分在 Lua 侧对 `on_chunk` 文本自行解析。

---

## 七、DIY 工具箱(编码 / 加密 / 定时 / 二进制 / 设备)

面向 AI、云端 API 的原生能力。`data` 可为字符串(UTF-8)或字节数组。

| API                                                                 | 说明                                                                                            |
| ------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------- |
| `host.base64_encode(data)` / `host.base64_decode(s, as_bytes?)` | Base64                                                                                          |
| `host.hex_encode(data)` / `host.hex_decode(s, as_bytes?)`       | Hex                                                                                             |
| `host.url_encode(s, component?)` / `host.url_decode(s)`         | URL 编码                                                                                        |
| `host.hash(algo, data, b64?)`                                     | `md5/sha1/sha256/sha512`,默认 hex 输出                                                        |
| `host.hmac(algo, key, data, b64?)`                                | HMAC(云 API 签名刚需)                                                                           |
| `host.md5/sha1/sha256/sha512(data, b64?)`                         | 便捷别名                                                                                        |
| `host.hmac_sha256(key, data, b64?)` / `host.hmac_sha1(...)`     | 便捷别名                                                                                        |
| `host.random_bytes(n, fmt?)`                                      | 随机字节;fmt:`hex`(默认)/`b64`/`raw`                                                      |
| `host.uuid()`                                                     | UUID v4                                                                                         |
| `host.now_ms()`                                                   | 单调毫秒时间戳(测速/计时用,`结束-开始` 得毫秒耗时)                                            |
| `host.interval(ms, cb)` → id / `host.clear_interval(id)`       | 重复定时器                                                                                      |
| `host.device_info()`                                              | `{platform,osVersion,locale,screenW,screenH,dpr,darkMode, appVersion,model,brand,sdkInt,...}` |

> 时间/随机也可直接用 Lua 标准库:`os.time()`、`os.date("%Y-%m-%d")`、`math.random()`。
>
> **重载自动清理**:刷新键 / `sandbox reload` 会自动取消上一轮的 `host.interval` 及在途 `http`/`websocket`,
> 不泄漏;同一轮内不用的定时器仍需自己 `host.clear_interval`。

---

## 八、系统通知(后台提醒 / 事件推送)

状态栏推送,点击可拉起 App。App 已内置前台保活服务,退到后台后 `host.interval` / 网络回调
仍会继续运行,因此可做"后台监听 → 通知提醒"类应用。

```lua
local id = host.notify{
  title = "提醒", body = "该喝水了",
  id = nil,          -- 省略则自动分配(高位, 安全); 用同一 id 再次调用可更新同一条通知
  ongoing = false,   -- true 为常驻(不可滑除)
  channel = nil,     -- 可选自定义通知渠道名
}
host.cancel_notify(id)

-- 后台每分钟提醒:
host.interval(60000, function() host.notify{ title = "每分钟提醒" } end)
```

> 自定义 `id` 时避开固定 id(前台保活服务用 1001);不填则自动分配,最安全。

---

## 九、对话框 / 底部菜单

对话框共用统一模板(间距一致),脚本只管内容与按钮。

```lua
host.confirm("确定删除?", function(yes) end,
  { title="请确认", ok_text="删除", cancel_text="取消" })   -- opts 可省略

host.input({ title="重命名", hint="新名称", default="旧名" }, function(text) end)

host.dialog({
  title = "选择操作",
  build = function() return column({ text("自定义内容"), toggle({title="开关"}) }) end,
  actions = {
    { label="取消", variant="text" },                       -- 默认点击后关闭
    { label="删除", variant="filled", danger=true, onTap=function() end },
  },
})
host.close_dialog()

host.sheet({ title="更多", items = {
  { label="编辑", icon="edit", onTap=function() end },
  { label="删除", icon="delete", danger=true, onTap=function() end },
}})
```

---

## 十、文件 / 存储 / 进程

| API                                                                                                               | 说明                                                                      |
| ----------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------- |
| `host.get(key)` / `host.set(key, val)`                                                                        | 持久化设置键值(set 触发重建)                                              |
| `host.read_file(p)` / `host.write_file(p, s)`                                                                 | 读写文本                                                                  |
| `host.read_bytes(p)`→base64 / `host.write_bytes(p, base64)`                                                  | 读写二进制(存 AI 图片/音频)                                               |
| `host.exists(p)` / `host.delete_file(p)` / `host.delete_dir(p)`                                             | 文件操作                                                                  |
| `host.list_dir(p)` → `{{name,path,isDir},...}` / `host.mkdirs(p)`                                          | 目录                                                                      |
| `host.home_path()` / `host.ubuntu_path()` / `host.bin_path()` / `host.tmp_path()` / `host.backup_dir()` | 常用路径                                                                  |
| `host.storage_path()`                                                                                           | 原生共享存储根 (通常`/storage/emulated/0`)                              |
| `host.clipboard.copy(s)` / `host.clipboard.paste()`                                                           | 剪贴板                                                                    |
| `host.open_url(url)` / `host.exit_app()`                                                                      | 外链 / 退出                                                               |
| `host.webview_open(url, title?)`                                                                                | 在内嵌 WebUI 标签打开一个网页                                             |
| `host.exec(cmd, cb)`                                                                                            | 容器内执行并取回`cb({code,output})`                                     |
| `host.container(cmd, cb)`                                                                                       | 容器内执行(不取输出)                                                      |
| `host.spawn(cmd, title, key, cb)`                                                                               | 容器内跑长命令,流式输出到终端 tab;`key` 跟踪运行态                      |
| `host.stop(key)`                                                                                                | 停止某 spawn                                                              |
| `host.run(program, args, cb)`                                                                                   | 宿主层进程`cb({code,stdout,stderr})`                                    |
| `host.free_port(start, stop, exclude, cb)`                                                                      | 找空闲端口`cb(port\|nil)`                                                |
| `host.delay(ms, cb)`                                                                                            | 单次延时回调                                                              |
| `host.log/warn/error(msg)`                                                                                      | 写入 App 内日志控制台(设置页顶栏「Lua 日志」);`print(...)` 亦重定向到此 |

> **把容器命令绑到按钮**:`button("启动服务", function() host.spawn("cd /root/app && python run.py", "服务", "svc") end)`,
> 再用 `ctx.running["svc"]` 显示运行态、`host.stop("svc")` 停止。

> **访问原生安卓存储**:所有文件 API 都直接接受**绝对路径**,除了应用私有目录/容器目录外,也能读写
> 原生共享存储(`/storage/emulated/0/...`,用 `host.storage_path()` 取根)。首次命中外部路径且未授权时,
> App 会**自动在系统层弹窗申请权限**(Lua 无需做任何权限处理);用户授权后重试该调用即可成功。
> 例:`host.write_file(host.storage_path().."/Download/note.txt", "hi")`。

---

## 十一、动态加载与生命周期

### 用途:静态加载 vs 动态加载

加载其它 `.lua` 有两种方式,区别只在**加载时机**:

- **静态加载**(启动即加载、常驻)——**一般 UI 用它**。写在 `main.lua`,或拆成独立文件用
  `require("tools")` 引入(加载脚本目录的 `tools.lua`)。建议:主页写在 `main.lua`,其它页简单的可
  一并留下,复杂的各自拆文件 `require` 进来。
- **动态加载**(`loadlua`)——**资源较重的元素用它**。作为独立模块按需加载、用完卸载,不常驻、
  不污染主 Lua 空间。适合偶尔用的整屏应用、重计算、游戏:触发才加载,离开即卸载。

### 模块约定

被加载的 `.lua` 放脚本目录任意位置(不注册、默认不加载),末尾 `return` 一个模块表;
`build` 返回 UI,`dispose`/`pause`/`resume` 供加载方控制其生命周期(见下节):

```lua
-- mymodule.lua (无需注册)
return {
  title = "Hello",
  build = function(ctx)
    return card({ padding(text("动态加载进来的独立模块"), 16) })
  end,
  dispose = function() end,   -- 卸载时清理自己的定时器/网络等 (可选)
}
```

`loadlua(path, ...)` 运行时读入并执行,返回该模块表(失败返回 `nil` 并把错误写日志控制台)。

### 加载与卸载

用一个"槽位"承载当前模块:某操作加载,另一操作卸载。卸载 = 调 `dispose` 释放资源 + 丢弃引用
(可被 GC),从此不占内存、不留在主脚本:

```lua
local current = nil                              -- 当前加载的独立模块 (nil = 未加载)

local function load_mod(path)
  if current and current.dispose then pcall(current.dispose) end   -- 先卸载旧的
  current = loadlua(path)                        -- 全新加载 (状态从头)
end
local function unload_mod()
  if current and current.dispose then pcall(current.dispose) end
  current = nil                                  -- 丢引用 → 释放, 不再常驻
end

app.page("host", function(ctx)
  return {
    row({
      button("加载", function() load_mod(SCRIPTS .. "/mymodule.lua") end),
      button("卸载", unload_mod, { variant = "tonal" }),
    }, { gap = 8 }),
    divider(),
    (current and current.build) and current.build(ctx) or text("(未加载)", { color = "grey" }),
  }
end)
```

> 触发方式随意:按钮、菜单、或"浏览目录选一个"(`host.list_dir` 列 `.lua` + `state` 记选中项)都行。

### 生命周期:运行 / 冻结 / 销毁

内容"不可见时(切走导航页 / 切走标签 / 退后台)怎么办"分三态。**渲染永远只在可见时进行**,
下表只决定**内核/逻辑**的去留。love 画布用属性,纯 Lua 内容用 `lifecycle{}` 包裹,两者一一对应:

| 不可见时                         | love 画布                      | 纯 Lua 内容                           |
| -------------------------------- | ------------------------------ | ------------------------------------- |
| **运行** 后台继续跑        | `love{ freeze=false }`(默认) | 不包`lifecycle`                     |
| **冻结** 暂停,回来接着     | `love{ freeze=true }`        | `lifecycle{ onHide=停, onShow=启 }` |
| **销毁** 停掉释放,回来从头 | `love{ keepalive=false }`    | `lifecycle{ onHide=停并归零 }`      |

**纯 Lua 应用没有独立进程**,跑在共享主 VM 里——移出界面只是停渲染,它的 `host.interval`/网络/`spawn`
**会继续占资源**,必须靠回调主动停。把模块写成带 `pause`/`resume`/`dispose` 的应用,定时器 id 放模块级 upvalue:

```lua
-- 一个"切走即停、回来从头"的应用模块
local timer, n = nil, 0
local function tick() n = n + 1; reactive("compute").set("已算 " .. n .. " 轮") end
local function start() if not timer then timer = host.interval(200, tick) end end
local function stop()  if timer then host.clear_interval(timer); timer = nil end end
return {
  title = "算力",
  build = function()
    reactive("compute", "…"); start()
    return center(text("", { bind = "compute", size = 22 }))
  end,
  pause   = stop,                          -- 切走 → 停 (不在后台白算)
  resume  = function() n = 0; start() end, -- 回来 → 归零重来 (要"接着跑"就写 start())
  dispose = stop,                          -- 返回/切换应用 → 彻底停
}
```

加载页用 `lifecycle{}` 把可见性接到应用的 pause/resume:

```lua
lifecycle{
  fill   = true,                           -- 作页面根且要铺满时加
  onHide = function() app.pause()  end,    -- 切走 nav/tab 或退后台
  onShow = function() app.resume() end,    -- 回来
  child  = your_component,
}
```

- 可见性 = 导航页激活 **且** 本标签激活 **且** App 在前台;任一不满足即 `onHide`(移出组件树也算),恢复即 `onShow`。
- **用确定性的 pause/resume**,不要在 `onShow` 里 `sel.set` 触发重建(会与 onHide 竞态,出现"有时从 0 有时从 9")。
- 每个应用**每次进入都全新 `loadlua`**(状态从头),定时器只在模块 upvalue 里管理。

> **脚本重载自动清理**:刷新键 / `sandbox reload` 时,上一轮的 `host.interval`、在途 `http`、`websocket`
> 由框架自动取消,不会泄漏;但同一轮内不用的定时器仍要自己 `host.clear_interval`。

---

## 十二、Agent 命令行工具集(agent/sandbox)

Agent 在容器里改完 `.lua` 后,脚本**不会自动生效**(App 不做监视/轮询)。统一工具 `agent/sandbox`
通过本机回环控制通道与宿主 App 通信,涵盖开发调试常用操作:

```sh
bash agent/sandbox reload          # 重载全部脚本 (等同主页刷新键, 带快照保护; 失败自动回退上一版)
bash agent/sandbox ping            # 探活 (确认 App 在运行)
bash agent/sandbox run <file.lua>  # 在隔离引擎里试跑一个脚本 (语法/逻辑快速自测, 不影响在跑的 UI)
bash agent/sandbox log [N]         # 查看最近 N 行 Lua 运行日志 (默认 100)
bash agent/sandbox log -f [N]      # 持续跟随 Lua 运行日志
```

- **run**:独立 `lua_State` 执行目标文件,只挂少量安全**只读**(路径/`read_file`/`list_dir`/`get`…)
  + 工具箱(编码/哈希/`uuid`/`now_ms`/`device_info`…)接口;UI/注册/异步类调用(`app.page`/`nav.tabs`/
  `host.spawn`/`host.http`/`host.dialog`/`love`…)一律视作 no-op,**不会污染正在运行的 UI**。
  捕获 `print` / `host.log|warn|error` / `host.toast` 输出与加载/运行错误后回传;若脚本 `return` 的
  模块表含 `build`,还会试运行一次 `build()` 以暴露运行期错误。适合"改完先 run 一下看能不能正常加载"。
- **log**:读取 `agent/lua.log`——它是 App 内「Lua 日志」控制台的文件镜像(`host.log/warn/error`、
  `print`、脚本加载/回调运行错误都汇聚于此),每次 App 启动/重载会重置。容器内即可 `tail` 查看。
- 原理:App 在本机回环起控制通道,把 `端口/令牌` 写入 `agent/.control`;工具读取后用 bash 内建
  `/dev/tcp` 连上发命令(不依赖 `nc`)。

> 典型调试循环:`edit foo.lua` → `bash agent/sandbox run foo.lua`(看有无报错/输出)→
> `bash agent/sandbox reload`(应用到 UI)→ `bash agent/sandbox log -f`(观察运行日志)。

---

## 十三、持久化存储(原生 SQLite)

结构与查询完全用标准 SQL 表达,不设封装天花板。每个 `name` 一个独立 `.db` 文件(隔离/备份/删除方便)。

```lua
local db = store.open("notes")
db.exec[[CREATE TABLE IF NOT EXISTS todo(
  id INTEGER PRIMARY KEY AUTOINCREMENT, text TEXT, done INT DEFAULT 0, ts INT)]]

local r = db.run("INSERT INTO todo(text,ts) VALUES(?,?)", { "买菜", os.time() })
print(r.lastId, r.changes)                       -- run 返回 { lastId, changes }

for _, row in ipairs(db.query("SELECT * FROM todo WHERE done=?", {0})) do
  print(row.id, row.text)                        -- query 返回行数组, 每行是「列名→值」的表
end

db.run("UPDATE todo SET done=1 WHERE id=?", { r.lastId })
db.close()                                       -- 可选, 生命周期随 App
```

- `params` 数组按 SQL 中的 `?` 顺序绑定(防注入);bool 存为 0/1,table 自动转 JSON 字符串;blob 读回为 Lua 字符串。
- 默认启用 WAL + 外键约束;SQL 错误写入日志控制台。
- 想要什么表结构、索引、JOIN、聚合,直接写 SQL 即可,无限制。

---

## 十四、JSON

纯 Lua 实现:

```lua
local t = json.decode(host.read_file(path))   -- 失败返回 nil, err
t.model = "gpt-4o"
host.write_file(path, json.encode(t))
```

---

## 附:接入 AI 聊天 API(流式,用 reactive 逐字刷新)

流式逐字输出用 `reactive` + `text{bind=}`,只重绘回复文本,不重跑整页(高频更新更流畅):

```lua
app.page("chat", function()
  local input = state("chat.in", "")
  local answer = reactive("chat.out", "")          -- 用 reactive 承载流式回复
  local function send()
    answer.set("")
    host.http{
      url = "https://api.openai.com/v1/chat/completions",
      method = "POST",
      headers = { ["Content-Type"]="application/json",
                  Authorization="Bearer "..host.get("openai_key") },
      body = json.encode({ model="gpt-4o-mini", stream=true,
        messages = { { role="user", content=input.get() } } }),
      stream = true,
      on_chunk = function(chunk)
        for line in chunk:gmatch("[^\n]+") do
          local data = line:match("^data: (.+)")
          if data and data ~= "[DONE]" then
            local o = json.decode(data)
            local d = o and o.choices and o.choices[1]
                      and o.choices[1].delta and o.choices[1].delta.content
            if d then answer.set(answer.get()..d) end   -- 只刷新绑定的文本
          end
        end
      end,
      on_error = function(err) host.toast("出错: "..tostring(err)) end,
    }
  end
  return { card("AI 聊天", {
    textfield({ label="问点什么", value=input.get(), onChanged=function(v) input.set(v) end }),
    spacer(8), button("发送", send, { icon="send" }), spacer(12),
    text("", { bind = "chat.out", color = "grey" }),   -- 绑定流式回复
  }) }
end)
```
