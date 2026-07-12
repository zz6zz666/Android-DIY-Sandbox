/// 内嵌 Lua 前奏脚本: 在用户脚本之前执行, 提供友好 API。
/// 不落磁盘, 保证 API 始终正确、用户不可破坏。
const String kLuaPrelude = r'''
-- ==================== host: 宿主能力 ====================
host = {}
function host.toast(msg) return __host_call("toast", tostring(msg)) end
function host.log(msg) return __host_call("log", tostring(msg)) end
function host.warn(msg) return __host_call("warn", tostring(msg)) end
function host.error(msg) return __host_call("logerror", tostring(msg)) end
-- 重定向 print 到 app 内日志 (方便手机端调试; 多参以 tab 分隔)
function print(...)
  local t = {...}
  for i = 1, #t do t[i] = tostring(t[i]) end
  return __host_call("log", table.concat(t, "\t"))
end
-- host.confirm(msg, cb, opts?): opts={ title=, ok_text="确定", cancel_text="取消" }
function host.confirm(msg, cb, opts) return __host_call("confirm", tostring(msg), cb, opts) end
-- host.input(opts, cb): opts={ title=, hint=, default=, ok_text=, cancel_text= }
function host.input(opts, cb) return __host_call("input", opts or {}, cb) end
function host.exit_app() return __host_call("exit_app") end
function host.get(key) return __host_call("get_setting", key) end
function host.set(key, val) return __host_call("set_setting", key, val) end
function host.ubuntu_path() return __host_call("ubuntu_path") end
function host.home_path() return __host_call("home_path") end
-- 原生共享存储根目录 (通常 /storage/emulated/0)。文件 API 直接接受绝对路径,
-- 命中外部存储且未授权时会自动在系统层弹窗申请权限, 授权后重试即可。
function host.storage_path() return __host_call("storage_path") end
function host.read_file(p) return __host_call("read_file", p) end
function host.write_file(p, c) return __host_call("write_file", p, c) end
function host.exists(p) return __host_call("exists", p) end
function host.delete_dir(p) return __host_call("delete_dir", p) end
function host.delete_file(p) return __host_call("delete_file", p) end
function host.list_dir(p) return __host_call("list_dir", p) end
function host.open_webview(url) return __host_call("webview_open", url, "WebUI") end
function host.webview_open(url, title) return __host_call("webview_open", url, title) end
function host.open_url(url) return __host_call("open_url", url) end
function host.bin_path() return __host_call("bin_path") end
function host.tmp_path() return __host_call("tmp_path") end
function host.backup_dir() return __host_call("backup_dir") end
function host.mkdirs(p) return __host_call("mkdirs", p) end
function host.run(program, args, cb) return __host_call("host_run", program, args, cb) end
function host.container(cmd, cb) return __host_call("container", cmd, cb) end
function host.exec(cmd, cb) return __host_call("exec", cmd, cb) end
function host.spawn(cmd, title, key, cb) return __host_call("spawn", cmd, title, key, cb) end
function host.stop(key) return __host_call("stop", key) end
function host.free_port(start, stop, exclude, cb) return __host_call("free_port", start, stop, exclude or {}, cb) end
function host.install_rootfs(cb) return __host_call("install_rootfs", cb) end
-- 延时回调 (Lua 无 sleep): host.delay(ms, function() end)
function host.request_reload() return __host_call("request_reload") end
function host.delay(ms, cb) return __host_call("delay", ms, cb) end
host.clipboard = {
  copy  = function(s) return __host_call("clipboard_copy", tostring(s)) end,
  paste = function() return __host_call("clipboard_paste") end,
}
host.nav = { go = function(i) return __host_call("nav_go", i) end }
-- 自定义对话框 (统一模板, 间距固定, 只需关心内容与按钮):
-- host.dialog({
--   title = "标题",
--   build = function() return <组件树> end,   -- 依赖 state() 可响应式重建
--   actions = {                                -- 省略则默认单个"关闭"
--     { label="取消", variant="text" },        -- 默认点击后关闭对话框
--     { label="删除", danger=true, variant="filled", onTap=function() ... end },
--     -- close=false 可让按钮点击后不关闭对话框
--   },
-- })
function host.dialog(spec) return __host_call("dialog", spec) end
function host.close_dialog() return __host_call("close_dialog") end
-- 通用底部动作列表 (可绑定到任意按钮/再次点击等):
-- host.sheet({ title="", items={ {label=,icon=,onTap=fn,enabled=true,danger=false}, ... } })
function host.sheet(spec) return __host_call("sheet", spec) end

-- ==================== 网络 (通用, 供任意 Lua 玩具/AI 交互使用) ====================
-- host.http{ url=, method="GET", headers={}, body=, stream=false, timeout=,
--   response_type="text"|"bytes",  -- bytes: res.body 为 base64 (下载图片/音频)
--   body_base64=,                   -- 上传二进制 (base64)
--   form={ fields={k=v}, files={ {name=,path=|base64=|text=,filename=,content_type=} } }, -- multipart 上传
--   on_response=function(status, headers) end,
--   on_chunk=function(text) end,          -- 仅 stream=true 时逐块回调
--   on_done=function(res) end,            -- res={status,ok,headers,body[,is_base64]}
--   on_error=function(err) end }
-- 返回句柄 id; host.http_cancel(id) 取消在途请求。
function host.http(spec) return __host_call("http", spec or {}) end
function host.http_cancel(id) return __host_call("http_cancel", id) end

-- host.websocket{ url=, headers={},
--   on_open=function() end,
--   on_message=function(data, is_binary) end,  -- 文本为 string; 二进制为字节数组
--   on_close=function(code, reason) end,
--   on_error=function(err) end }
-- 返回连接对象: ws:send(data) / ws:close(code, reason)
function host.websocket(spec)
  local id = __host_call("ws_open", spec or {})
  if not id then return nil end
  local ws = { id = id }
  function ws:send(data) return __host_call("ws_send", self.id, data) end
  function ws:close(code, reason) return __host_call("ws_close", self.id, code, reason) end
  return ws
end

-- 本地 WebSocket 回声服务器地址 (ws://127.0.0.1:port); App 内置, 零外网依赖, 用于自测 WS。
function host.ws_echo_url() return __host_call("ws_echo_url") end

-- ==================== DIY 工具箱: 编码/加密/定时/二进制/设备 ====================
-- 编码 (data 可为字符串或字节数组[0-255]; decode 默认返回文本, 传 true 返回字节数组)
function host.base64_encode(data) return __host_call("base64_encode", data) end
function host.base64_decode(s, as_bytes) return __host_call("base64_decode", s, as_bytes) end
function host.hex_encode(data) return __host_call("hex_encode", data) end
function host.hex_decode(s, as_bytes) return __host_call("hex_decode", s, as_bytes) end
-- URL 编码: component=false 时用 encodeFull(保留 /:?&=)
function host.url_encode(s, component) return __host_call("url_encode", s, component) end
function host.url_decode(s) return __host_call("url_decode", s) end

-- 哈希 / HMAC (默认输出 hex; 传 b64=true 输出 base64)
-- algo: "md5" | "sha1" | "sha256" | "sha512"
function host.hash(algo, data, b64) return __host_call("hash", algo, data, b64) end
function host.hmac(algo, key, data, b64) return __host_call("hmac", algo, key, data, b64) end
-- 便捷别名
function host.md5(data, b64)    return __host_call("hash", "md5", data, b64) end
function host.sha1(data, b64)   return __host_call("hash", "sha1", data, b64) end
function host.sha256(data, b64) return __host_call("hash", "sha256", data, b64) end
function host.sha512(data, b64) return __host_call("hash", "sha512", data, b64) end
function host.hmac_sha256(key, data, b64) return __host_call("hmac", "sha256", key, data, b64) end
function host.hmac_sha1(key, data, b64)   return __host_call("hmac", "sha1", key, data, b64) end

-- 随机: random_bytes(n, fmt) fmt="hex"(默认)|"b64"|"raw"(字节数组); uuid() -> v4
function host.random_bytes(n, fmt) return __host_call("random_bytes", n, fmt) end
function host.uuid() return __host_call("uuid") end
function host.now_ms() return __host_call("now_ms") end

-- 二进制文件 IO (与 base64 互转; 用于存取 AI 返回的图片/音频等)
function host.write_bytes(path, b64) return __host_call("write_bytes", path, b64) end
function host.read_bytes(path) return __host_call("read_bytes", path) end

-- 重复定时器: interval(ms, fn) -> id; clear_interval(id) 停止
function host.interval(ms, cb) return __host_call("interval", ms, cb) end
function host.clear_interval(id) return __host_call("clear_interval", id) end

-- 系统通知 (状态栏推送, 点击可拉起 app)。配合前台服务, app 退到后台仍可发送。
--   local id = host.notify{ title="提醒", body="该喝水了", id=?, ongoing=false, channel=? }
--   id 省略则自动分配; 用同一 id 再次调用可更新同一条通知。
--   ongoing=true 为常驻通知(不可滑除); channel 自定义通知渠道名(可选)。
--   host.cancel_notify(id) 取消某条通知。
-- 典型用法(后台提醒): host.interval(60000, function() host.notify{title="每分钟提醒"} end)
function host.notify(spec) return __host_call("notify", spec or {}) end
function host.cancel_notify(id) return __host_call("cancel_notify", id) end

-- 设备/应用信息: { platform, osVersion, locale, screenW, screenH, dpr, darkMode,
--   appVersion, buildNumber, packageName, model, brand, sdkInt, ... }
-- (型号/版本首次调用异步补齐, 下次调用即完整)
function host.device_info() return __host_call("device_info") end

-- ==================== 反应式状态 ====================
-- local s = state("key", default); s.get(); s.set(v)  -- set 会触发本页重建
function state(key, default)
  local t = {}
  t.get = function() return __host_call("state_get", key, default) end
  t.set = function(v) __host_call("state_set", key, v) end
  return t
end

-- 细粒度响应式值 (流式/高频更新, 如 AI 逐字输出、进度百分比):
--   local r = reactive("chat.reply", "")
--   r.set(r.get() .. token)      -- 只重绘绑定该 key 的组件, 不重跑整页 Lua
-- 用 text{ bind = "chat.reply" } 把某个文本组件绑定到该 key, 之后 r.set 只刷新那一个 Text。
-- 与 state 的区别: state.set 触发整页重建 (适合布局变化); reactive.set 只更新绑定点
-- (适合每秒几十次的内容刷新, 避免整页重建卡顿)。
function reactive(key, initial)
  __host_call("reactive_init", key, initial)
  local t = {}
  t.key = key
  t.get = function() return __host_call("reactive_get", key, initial) end
  t.set = function(v) __host_call("reactive_set", key, v) end
  return t
end

-- ==================== 组件构造 (纯 Lua, 返回带 __type 的描述表) ====================
local function comp(kind, props) props = props or {}; props.__type = kind; return props end

-- 布局
function column(children, o) o=o or {}; o.children=children; return comp("column", o) end
function row(children, o)    o=o or {}; o.children=children; return comp("row", o) end
function stack(children, o)  o=o or {}; o.children=children; return comp("stack", o) end
function wrap(children, o)   o=o or {}; o.children=children; return comp("wrap", o) end
function padding(child, pad) return comp("padding", { child=child, pad=pad }) end
function align(child, a)     return comp("align", { child=child, align=a }) end
function center(child)       return comp("center", { child=child }) end
function expanded(child, flex) return comp("expanded", { child=child, flex=flex }) end
function flexible(child, o)  o=o or {}; o.child=child; return comp("flexible", o) end
function spacer(n)           return comp("spacer", { size=n }) end
function box(o)              return comp("box", o) end
function scroll(children, o) o=o or {}; o.children=children; return comp("scroll", o) end
function positioned(child, o) o=o or {}; o.child=child; return comp("positioned", o) end
function aspect(child, ratio) return comp("aspect", { child=child, ratio=ratio }) end
function fitted(child, fit)  return comp("fitted", { child=child, fit=fit }) end
function safearea(child)     return comp("safearea", { child=child }) end
function intrinsicHeight(child) return comp("intrinsic_height", { child=child }) end
function intrinsicWidth(child)  return comp("intrinsic_width", { child=child }) end
function clip(child, o)      o=o or {}; o.child=child; return comp("clip", o) end
function grid(children, o)   o=o or {}; o.children=children; return comp("grid", o) end
-- list(children, { scroll=true, axis="horizontal"?, separator=n?, padding=? })
-- scroll=true 时启用虚拟化: 仅构建可视项, 千/万项长列表 (聊天记录/信息流) 也流畅。
-- 每项可带 key 字段 (唯一标识) 以帮助插入/删除时正确复用与保留滚动位置。
function list(children, o)   o=o or {}; o.children=children; return comp("list", o) end
function datatable(o)        return comp("table", o or {}) end
-- 手势/点击区域: gesture(child, { onTap=, onLongPress=, onDoubleTap=, ink=true, radius= })
function gesture(child, o)   o=o or {}; o.child=child; return comp("gesture", o) end
function inkwell(child, o)   o=o or {}; o.child=child; return comp("inkwell", o) end
function tooltip(child, msg) return comp("tooltip", { child=child, message=msg }) end

-- 内容
-- text(s, { size=, weight=, color=, align=, maxLines=, ellipsis=, bind= })
-- bind = "reactiveKey" 时文本内容跟随 reactive(key) 实时刷新 (流式输出), 只重绘本组件。
function text(s, o)   o=o or {}; o.text=s; return comp("text", o) end
-- markdown(s, o): 渲染 Markdown 文本 (标题/列表/代码块/加粗/链接等)
function markdown(s, o) o=o or {}; o.text=s; return comp("markdown", o) end
-- richtext({ {text=, color=, weight=, size=, italic=, underline=}, ... }, o)
function richtext(spans, o) o=o or {}; o.spans=spans; return comp("richtext", o) end
function icon(name, o) o=o or {}; o.icon=name; return comp("icon", o) end
-- 头像: avatar({ image=, icon=, text=, radius=, color=, textColor= })
function avatar(o)   return comp("avatar", o or {}) end
function image(path, o) o=o or {}; o.path=path; return comp("image", o) end
function spinner(o)  return comp("spinner", o) end
function progress(v, o) o=o or {}; o.value=v; return comp("progress", o) end
function chip(label, o) o=o or {}; o.label=label; return comp("chip", o) end
function badge(child, o) o=o or {}; o.child=child; return comp("badge", o) end
function divider(o)  return comp("divider", o) end
function vdivider(o) return comp("vdivider", o) end

-- 交互
function button(label, onTap, o) o=o or {}; o.label=label; o.onTap=onTap; return comp("button", o) end
function iconbutton(name, onTap, o) o=o or {}; o.icon=name; o.onTap=onTap; return comp("iconbutton", o) end
-- fab(icon, onTap, { label=, color=, mini= })
function fab(name, onTap, o) o=o or {}; o.icon=name; o.onTap=onTap; return comp("fab", o) end
function tile(title, o) o=o or {}; o.title=title; return comp("tile", o) end
function menu(iconName, items, o) o=o or {}; o.icon=iconName; o.items=items; return comp("menu", o) end
function toggle(o)   return comp("switch", o) end
function slider(o)   return comp("slider", o) end
-- rangeslider({ min=, max=, low=, high=, divisions=, onChanged=fn(lo,hi) })
function rangeslider(o) return comp("rangeslider", o) end
function select(o)   return comp("select", o) end
function textfield(o) return comp("textfield", o) end
function checkbox(o) return comp("checkbox", o) end
-- radio({ title=, value=, options={ {label=,value=}, ... }, axis=, onChanged=fn(v) })
function radio(o)    return comp("radio", o) end
-- segmented({ value=, options={ {label=,value=,icon=}, ... }, onChanged=fn(v) })
function segmented(o) return comp("segmented", o) end
-- togglebuttons({ options={ {label=/icon=}, ... }, selected={1,..}, multi=, onChanged=fn(i,active) })
function togglebuttons(o) return comp("togglebuttons", o) end
-- datefield({ label=, value=, onChanged=fn(y,m,d) }) / timefield({ ..., onChanged=fn(h,m) })
function datefield(o) return comp("datefield", o) end
function timefield(o) return comp("timefield", o) end
-- stepper({ active=1, axis=, steps={ {title=,subtitle=,content=<组件>}, ... },
--           onStep=fn(i), onContinue=fn(i), onCancel=fn(i) })
function stepper(o)  return comp("stepper", o) end

-- 容器
function card(title, children, o)
  if children == nil and type(title) == "table" then return comp("card", { children = title }) end
  o=o or {}; o.title=title; o.children=children; return comp("card", o)
end
function section(title, children) return comp("section", { title=title, children=children }) end
function expansion(title, children, o) o=o or {}; o.title=title; o.children=children; return comp("expansion", o) end

-- 通用多标签视图 (可用于自定义导航页):
-- tabs({ active=1, items={ {title=,icon=,key=,content=<组件>}, ... },
--        onSelect=fn(i), onClose=fn(i), onReorder=fn(from,to), trailing={...}, empty="" })
function tabs(o) return comp("tabs", o or {}) end

-- LÖVE (love2d) 动态渲染画布: 一块可与其它 Lua 组件同层排版的"贴纸画布"。
-- love{ id=0, height=200, game="/path/to/game.love 或目录", autopause=true,
--       onEvent=function(msg) ... end }
-- id: 画布标识 (0..3), 不同 id 运行在各自独立进程中, 可同屏多块, 默认为 0。
-- game 省略时使用内置示例(弹跳球)。
-- autopause: 切到其它导航页时自动挂起(停渲染、留内存、不丢状态), 默认 true;
--            设为 false 则一直渲染。(注: SDL 无法进程内销毁重启, 故只有挂起/恢复)
-- keepalive: 默认 true — 画布从组件树移除(dispose)时只挂起、保留进程与状态, 再次挂载沿用旧实例;
--            设为 false — 移除时彻底销毁该画布的独立进程, 下次挂载全新启动(真正从头重载运行)。
--            用于"动态加载/切换应用"场景: 离开再进入希望游戏完全重来时用 keepalive=false。
-- onEvent(msg): 收到游戏发来的消息(表)时回调, msg 即游戏侧 host.emit 的内容。
--
-- 双向通信(UI ↔ 游戏):
--   * UI 发命令给游戏:  love.send(id, { type="reset" })  或  love.send(id, "reset", {..})
--   * UI 收游戏事件:    love{ onEvent=function(msg) score.set(msg.value) end }
--                       或  love.on(id, function(msg) ... end)
--   * 游戏侧(游戏 main.lua 顶部): local host = require("love_host")
--                       host.on("reset", function() ... end);  host.emit("score",{value=10})
--   传输为本机加密通道, 消息是任意可 JSON 化的 Lua 表, 自动序列化, 无需手动编解码。
love = setmetatable({}, {
  __call = function(_, o) return comp("love", o or {}) end,
})

-- love.send(id, msg) 或 love.send(id, type, data): 给指定画布的游戏发消息。
function love.send(id, a, b)
  local msg
  if type(a) == "table" then msg = a
  else msg = b or {}; msg.type = a end
  return __host_call("love_send", id or 0, msg)
end

-- love.on(id, fn): 登记某画布的事件回调 (与 love{onEvent=...} 等价, 便于在组件外注册)。
function love.on(id, fn)
  return __host_call("love_on", id or 0, fn)
end

  -- ==================== 音频 (headless love 进程) ====================
  -- 后台音频引擎, 支持多声道并行播放 (bgm / sfx / default 等)。
  --
  -- 事件回调: host.audio_on_event(function(channel, type, data) ... end)
  --   type: "started" / "paused" / "resumed" / "stopped" / "ended" / "seeked" / "state" / "error"
  --   data: 具体数据表 (state 时为 {playing, position, duration})
  --
  -- 示例:
  --   host.audio_ensure()
  --   host.audio_play("/sdcard/bgm.mp3", {channel="bgm", loop=true})
  --   host.audio_play("/sdcard/sfx.wav", {channel="sfx", volume=0.8})
  --   local id = host.audio_on_event(function(ch, ty, d) print(ch, ty) end)
  --   host.audio_off_event(id)
  --
  function host.audio_ensure() return __host_call("audio_ensure") end
  function host.audio_play(path, opts) return __host_call("audio_play", path, opts or {}) end
  function host.audio_pause(channel) return __host_call("audio_pause", channel) end
  function host.audio_resume(channel) return __host_call("audio_resume", channel) end
  function host.audio_stop(channel) return __host_call("audio_stop", channel) end
  function host.audio_seek(pos, channel) return __host_call("audio_seek", pos, channel) end
  function host.audio_set_volume(v, channel) return __host_call("audio_set_volume", v, channel) end
  function host.audio_set_loop(loop, channel) return __host_call("audio_set_loop", loop, channel) end
  -- 返回最近一次状态快照 { playing, position, duration, channel } (若未播放则 playing=false)。
  function host.audio_state(channel) return __host_call("audio_state", channel) end
  -- 注册事件回调; 返回 listener_id 供 audio_off_event 注销。
  function host.audio_on_event(fn) return __host_call("audio_on_event", fn) end
  function host.audio_off_event(id) return __host_call("audio_off_event", id) end

-- ==================== 持久化存储 (原生 SQLite) ====================
-- store.open(name) 打开一个数据库(每个 name 一个独立文件, app 重启后数据保留)。
-- 返回的对象提供三个原生方法, 结构与查询完全用标准 SQL 表达, 不设任何限制:
--   db.exec(sql)            执行 DDL/DML(建表等), 无返回。
--   db.run(sql, params?)    执行带 ? 占位参数的写入, 返回 { lastId=.., changes=.. }。
--   db.query(sql, params?)  查询, 返回行数组;每行是「列名→值」的表。
--   db.close()              关闭(通常无需调用, 生命周期随 app)。
-- params 是数组, 依次绑定 SQL 里的 ? (防注入);布尔存为 0/1, 表会转成 JSON 字符串。
-- 示例:
--   local db = store.open("notes")
--   db.exec[[CREATE TABLE IF NOT EXISTS todo(
--     id INTEGER PRIMARY KEY AUTOINCREMENT, text TEXT, done INT DEFAULT 0, ts INT)]]
--   local r = db.run("INSERT INTO todo(text,ts) VALUES(?,?)", { "买菜", os.time() })
--   print(r.lastId)                                   -- 新行 id
--   for _, row in ipairs(db.query("SELECT * FROM todo WHERE done=?", {0})) do
--     print(row.id, row.text)
--   end
--   db.run("UPDATE todo SET done=1 WHERE id=?", { r.lastId })
store = {}
function store.open(name)
  local h = __host_call("store_open", name or "default")
  local db = { handle = h }
  function db.exec(sql) return __host_call("store_exec", h, sql) end
  function db.run(sql, params) return __host_call("store_run", h, sql, params or {}) end
  function db.query(sql, params) return __host_call("store_query", h, sql, params or {}) or {} end
  function db.close() return __host_call("store_close", h) end
  return db
end



-- ==================== 导航目标构造 ====================
function webview(url) return { type = "webview", url = url } end
function terminal()   return { type = "terminal" } end

-- ==================== 应用注册 ====================
app = {}
function app.page(name, fn) __host_call("register_page", name, fn) end
-- 主页顶栏自定义按钮 (渲染在设置按钮左侧, 可多个):
-- app.actions({ { icon="rocket_launch", tooltip="启动", onTap=function() end }, ... })
function app.actions(list) __host_call("register_actions", list or {}) end
-- Agent 入口按钮 (供 agent/main.lua 使用, 渲染在最左侧, 独立于用户 app.actions):
function app.agent_actions(list) __host_call("register_agent_actions", list or {}) end
nav = {}
function nav.tabs(list) __host_call("nav_tabs", list) end

-- ==================== 生命周期可见性 ====================
-- 包裹任意 child, 当它随【导航页 / 页内标签 / 应用前后台】的组合可见性变化时回调,
-- 用于纯 Lua 动态内容的"按需加载/卸载"(love 画布自带此能力, 纯 Lua 用本组件)。
--   lifecycle{ child=..., onShow=fn, onHide=fn, onDispose=fn }
--   onHide:  变为不可见 (切走 nav 页 / 切走 tab / 退后台), 或被移出组件树时(只要之前可见)。
--   onShow:  从不可见变回可见。首次挂载即可见时【不触发】(内容已在首次渲染)。
--   onDispose: 组件真正从树移除时 (可选, 区分"暂时隐藏"与"彻底移除")。
-- 作页面根组件时若要铺满, 传 fill=true。
function lifecycle(o) return comp("lifecycle", o or {}) end

-- ==================== 动态加载 ====================
-- loadlua(path[, ...]): 运行时读入并执行脚本释放目录下任意 .lua 文件, 返回其返回值。
-- 该文件默认未注册到主入口/不会自动加载; 用它按需 pick 一个脚本渲染到页面。
-- 典型: 脚本文件末尾 `return { build = function(ctx) return column{...} end }` 或直接
-- `return card{...}`; 主 Lua 在某处 `local m = loadlua(path); ... 渲染 m 或 m.build(ctx)`。
-- 失败返回 nil 并把错误写入日志控制台。额外参数原样传给被加载文件的 `...`。
function loadlua(path, ...)
  local chunk, err = loadfile(path)
  if not chunk then
    host.error("loadlua 编译失败 ["..tostring(path).."]: "..tostring(err))
    return nil
  end
  local ok, res = pcall(chunk, ...)
  if not ok then
    host.error("loadlua 运行失败 ["..tostring(path).."]: "..tostring(res))
    return nil
  end
  return res
end

-- ==================== JSON (纯 Lua) ====================
json = {}
local function json_encode(v)
  local t = type(v)
  if t == "nil" then return "null"
  elseif t == "boolean" then return v and "true" or "false"
  elseif t == "number" then return tostring(v)
  elseif t == "string" then
    return '"' .. v:gsub('[%z\1-\31\\"]', function(c)
      local m = { ['"']='\\"', ['\\']='\\\\', ['\n']='\\n', ['\r']='\\r', ['\t']='\\t' }
      return m[c] or string.format('\\u%04x', string.byte(c))
    end) .. '"'
  elseif t == "table" then
    local isArr, n = true, 0
    for k, _ in pairs(v) do
      n = n + 1
      if type(k) ~= "number" then isArr = false end
    end
    local parts = {}
    if isArr and n == #v then
      for _, item in ipairs(v) do parts[#parts+1] = json_encode(item) end
      return "[" .. table.concat(parts, ",") .. "]"
    else
      for k, val in pairs(v) do
        parts[#parts+1] = json_encode(tostring(k)) .. ":" .. json_encode(val)
      end
      return "{" .. table.concat(parts, ",") .. "}"
    end
  end
  return "null"
end
json.encode = json_encode

local function json_decode(str)
  local pos = 1
  -- 跳过 UTF-8 BOM (EF BB BF)
  if str:sub(1, 3) == '\239\187\191' then pos = 4 end
  local decode_value
  local function skip() while pos <= #str and str:sub(pos,pos):match("%s") do pos = pos + 1 end end
  local function decode_str()
    pos = pos + 1
    local buf = {}
    while pos <= #str do
      local c = str:sub(pos,pos)
      if c == '"' then pos = pos + 1; return table.concat(buf)
      elseif c == '\\' then
        local n = str:sub(pos+1,pos+1)
        local m = { ['"']='"', ['\\']='\\', ['/']='/', n='\n', r='\r', t='\t', b='\b', f='\f' }
        buf[#buf+1] = m[n] or n
        pos = pos + 2
      else buf[#buf+1] = c; pos = pos + 1 end
    end
  end
  local function decode_num()
    local s = pos
    while pos <= #str and str:sub(pos,pos):match("[%d%.eE%+%-]") do pos = pos + 1 end
    return tonumber(str:sub(s, pos-1))
  end
  decode_value = function()
    skip()
    local c = str:sub(pos,pos)
    if c == '"' then return decode_str()
    elseif c == '{' then
      pos = pos + 1; local obj = {}
      skip(); if str:sub(pos,pos) == '}' then pos = pos + 1; return obj end
      while true do
        skip(); local k = decode_str(); skip(); pos = pos + 1 -- skip ':'
        obj[k] = decode_value(); skip()
        local d = str:sub(pos,pos); pos = pos + 1
        if d == '}' then break end
      end
      return obj
    elseif c == '[' then
      pos = pos + 1; local arr = {}
      skip(); if str:sub(pos,pos) == ']' then pos = pos + 1; return arr end
      while true do
        arr[#arr+1] = decode_value(); skip()
        local d = str:sub(pos,pos); pos = pos + 1
        if d == ']' then break end
      end
      return arr
    elseif c == 't' then pos = pos + 4; return true
    elseif c == 'f' then pos = pos + 5; return false
    elseif c == 'n' then pos = pos + 4; return nil
    else return decode_num() end
  end
  local ok, res = pcall(decode_value)
  if ok then return res else return nil, res end
end
json.decode = json_decode
''';
