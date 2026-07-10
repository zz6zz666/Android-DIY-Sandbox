/// 内嵌 Lua 前奏脚本: 在用户脚本之前执行, 提供友好 API。
/// 不落磁盘, 保证 API 始终正确、用户不可破坏。
const String kLuaPrelude = r'''
-- ==================== host: 宿主能力 ====================
host = {}
function host.toast(msg) return __host_call("toast", tostring(msg)) end
function host.log(msg) return __host_call("log", tostring(msg)) end
function host.confirm(msg, cb) return __host_call("confirm", tostring(msg), cb) end
function host.input(opts, cb) return __host_call("input", opts or {}, cb) end
function host.exit_app() return __host_call("exit_app") end
function host.get(key) return __host_call("get_setting", key) end
function host.set(key, val) return __host_call("set_setting", key, val) end
function host.ubuntu_path() return __host_call("ubuntu_path") end
function host.home_path() return __host_call("home_path") end
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
function host.dialog(spec) return __host_call("dialog", spec) end
function host.close_dialog() return __host_call("close_dialog") end
-- 通用底部动作列表 (可绑定到任意按钮/再次点击等):
-- host.sheet({ title="", items={ {label=,icon=,onTap=fn,enabled=true,danger=false}, ... } })
function host.sheet(spec) return __host_call("sheet", spec) end

-- ==================== 网络 (通用, 供任意 Lua 玩具/AI 交互使用) ====================
-- host.http{ url=, method="GET", headers={}, body=, stream=false, timeout=,
--   on_response=function(status, headers) end,
--   on_chunk=function(text) end,          -- 仅 stream=true 时逐块回调
--   on_done=function(res) end,            -- res={status,ok,headers,body}
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

-- ==================== 反应式状态 ====================
-- local s = state("key", default); s.get(); s.set(v)  -- set 会触发本页重建
function state(key, default)
  local t = {}
  t.get = function() return __host_call("state_get", key, default) end
  t.set = function(v) __host_call("state_set", key, v) end
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
function spacer(n)           return comp("spacer", { size=n }) end
function box(o)              return comp("box", o) end
function scroll(children, o) o=o or {}; o.children=children; return comp("scroll", o) end

-- 内容
function text(s, o)   o=o or {}; o.text=s; return comp("text", o) end
function icon(name, o) o=o or {}; o.icon=name; return comp("icon", o) end
function image(path, o) o=o or {}; o.path=path; return comp("image", o) end
function spinner(o)  return comp("spinner", o) end
function progress(v, o) o=o or {}; o.value=v; return comp("progress", o) end
function chip(label, o) o=o or {}; o.label=label; return comp("chip", o) end
function badge(child, o) o=o or {}; o.child=child; return comp("badge", o) end
function divider(o)  return comp("divider", o) end

-- 交互
function button(label, onTap, o) o=o or {}; o.label=label; o.onTap=onTap; return comp("button", o) end
function iconbutton(name, onTap, o) o=o or {}; o.icon=name; o.onTap=onTap; return comp("iconbutton", o) end
function tile(title, o) o=o or {}; o.title=title; return comp("tile", o) end
function menu(iconName, items, o) o=o or {}; o.icon=iconName; o.items=items; return comp("menu", o) end
function toggle(o)   return comp("switch", o) end
function slider(o)   return comp("slider", o) end
function select(o)   return comp("select", o) end
function textfield(o) return comp("textfield", o) end
function checkbox(o) return comp("checkbox", o) end

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
-- love{ height=200, game="/path/to/game.love 或目录", autopause=true }
-- game 省略时使用内置示例(弹跳球)。
-- autopause: 切到其它导航页时自动挂起(停渲染、留内存、不丢状态), 默认 true;
--            设为 false 则一直渲染。(注: SDL 无法进程内销毁重启, 故只有挂起/恢复)
function love(o) return comp("love", o or {}) end

-- ==================== 导航目标构造 ====================
function webview(url) return { type = "webview", url = url } end
function terminal()   return { type = "terminal" } end

-- ==================== 应用注册 ====================
app = {}
function app.page(name, fn) __host_call("register_page", name, fn) end
-- 主页顶栏自定义按钮 (渲染在设置按钮左侧, 可多个):
-- app.actions({ { icon="rocket_launch", tooltip="启动", onTap=function() end }, ... })
function app.actions(list) __host_call("register_actions", list or {}) end
nav = {}
function nav.tabs(list) __host_call("nav_tabs", list) end

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
