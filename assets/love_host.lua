-- love_host.lua — 游戏侧(运行在 love 进程内)与 app UI 层的双向通信桥。
--
-- 用法(在游戏 main.lua 顶部):
--   local host = require("love_host")
--   host.on("reset", function(data) resetGame() end)   -- 收 UI 发来的命令
--   host.on(function(msg) end)                          -- 收全部消息(兜底)
--   host.emit("score", { value = 1200 })                -- 给 UI 发事件
--   host.emit({ type = "over", score = 1200 })          -- 或直接给整表
--
-- 说明:
--  * 通过本机回环 TCP(127.0.0.1)与 app 通信,消息为按行分隔的 JSON。
--  * 自动连接/重连、自动每帧收发(包装 love.run),无需手动 pump。
--  * host.connected() 返回当前是否已连上 app。
--  * 若游戏未连接,emit 会被缓存,连上后补发(最多缓存 256 条)。

local socket = require("socket")

--==========================================================================
-- 极简 JSON(编码 + 解码),够用即可:nil/bool/number/string/array/object。
--==========================================================================
local json = {}
do
  local function encode_string(s)
    return '"' .. s:gsub('[%z\1-\31\\"]', function(c)
      local map = { ['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n',
                    ['\r'] = '\\r', ['\t'] = '\\t', ['\b'] = '\\b', ['\f'] = '\\f' }
      return map[c] or string.format('\\u%04x', c:byte())
    end) .. '"'
  end

  local function is_array(t)
    local n = 0
    for k in pairs(t) do
      if type(k) ~= "number" or k % 1 ~= 0 or k < 1 then return false end
      if k > n then n = k end
    end
    return n, #t
  end

  local encode_value
  local function encode_table(t)
    local maxn, len = is_array(t)
    if maxn and (maxn == len) and maxn > 0 then
      local parts = {}
      for i = 1, len do parts[i] = encode_value(t[i]) end
      return "[" .. table.concat(parts, ",") .. "]"
    elseif next(t) == nil then
      return "{}"
    else
      local parts = {}
      for k, v in pairs(t) do
        if type(k) == "number" then k = tostring(k) end
        if type(k) == "string" then
          parts[#parts + 1] = encode_string(k) .. ":" .. encode_value(v)
        end
      end
      return "{" .. table.concat(parts, ",") .. "}"
    end
  end

  encode_value = function(v)
    local tv = type(v)
    if v == nil then return "null"
    elseif tv == "boolean" then return v and "true" or "false"
    elseif tv == "number" then
      if v ~= v or v == math.huge or v == -math.huge then return "null" end
      return string.format("%.14g", v)
    elseif tv == "string" then return encode_string(v)
    elseif tv == "table" then return encode_table(v)
    else return "null" end
  end
  json.encode = encode_value

  -- 解码
  local decode_value
  local function skip_ws(s, i)
    local _, j = s:find("^[ \t\r\n]*", i)
    return (j or i - 1) + 1
  end
  local esc = { ['"'] = '"', ['\\'] = '\\', ['/'] = '/', b = '\b',
                f = '\f', n = '\n', r = '\r', t = '\t' }
  local function decode_string(s, i)
    i = i + 1
    local buf = {}
    while i <= #s do
      local c = s:sub(i, i)
      if c == '"' then return table.concat(buf), i + 1
      elseif c == '\\' then
        local n = s:sub(i + 1, i + 1)
        if n == 'u' then
          local hex = s:sub(i + 2, i + 5)
          local code = tonumber(hex, 16) or 63
          if code < 128 then buf[#buf + 1] = string.char(code)
          else buf[#buf + 1] = "?" end
          i = i + 6
        else
          buf[#buf + 1] = esc[n] or n
          i = i + 2
        end
      else
        buf[#buf + 1] = c
        i = i + 1
      end
    end
    return table.concat(buf), i
  end
  decode_value = function(s, i)
    i = skip_ws(s, i)
    local c = s:sub(i, i)
    if c == '"' then return decode_string(s, i)
    elseif c == '{' then
      local obj = {}
      i = skip_ws(s, i + 1)
      if s:sub(i, i) == '}' then return obj, i + 1 end
      while true do
        local key; key, i = decode_string(s, skip_ws(s, i))
        i = skip_ws(s, i)
        if s:sub(i, i) == ':' then i = i + 1 end
        local val; val, i = decode_value(s, i)
        obj[key] = val
        i = skip_ws(s, i)
        local ch = s:sub(i, i)
        if ch == ',' then i = skip_ws(s, i + 1)
        elseif ch == '}' then return obj, i + 1
        else return obj, i + 1 end
      end
    elseif c == '[' then
      local arr = {}
      i = skip_ws(s, i + 1)
      if s:sub(i, i) == ']' then return arr, i + 1 end
      while true do
        local val; val, i = decode_value(s, i)
        arr[#arr + 1] = val
        i = skip_ws(s, i)
        local ch = s:sub(i, i)
        if ch == ',' then i = i + 1
        elseif ch == ']' then return arr, i + 1
        else return arr, i + 1 end
      end
    elseif c == 't' then return true, i + 4
    elseif c == 'f' then return false, i + 5
    elseif c == 'n' then return nil, i + 4
    else
      local num = s:match("^%-?%d+%.?%d*[eE]?[%+%-]?%d*", i)
      if num then return tonumber(num), i + #num end
      return nil, i + 1
    end
  end
  json.decode = function(s)
    local ok, v = pcall(function() return (decode_value(s, 1)) end)
    if ok then return v end
    return nil
  end
end

--==========================================================================
-- 桥本体
--==========================================================================
local M = {}

local host, port, token = "127.0.0.1", nil, ""
local freeze = false        -- 挂起时冻结游戏时钟(回来从快照继续), 由 --astrbridge 第三段决定
-- 从 love 注入的参数里取连接信息:--astrbridge=PORT:TOKEN[:FREEZE]
do
  local function scan(t)
    if type(t) ~= "table" then return end
    for _, v in pairs(t) do
      local m = tostring(v):match("^%-%-astrbridge=(.+)$")
      if m then
        local p, tk, fz = m:match("^(%d+):([^:]*):?(%d*)$")
        if p then
          port = tonumber(p); token = tk or ""
          freeze = (fz == "1")
        end
      end
    end
  end
  scan(arg)
end

local client = nil
local connected = false
local recvbuf = ""
local sendbuf = ""
local pending = {}          -- 未连接时缓存的待发消息
local nextConnectAt = 0     -- 下次尝试连接的时间(秒)
local handlers = {}         -- type -> {fn,...}
local catchall = {}         -- 全部消息处理器

local function now()
  return (love and love.timer and love.timer.getTime and love.timer.getTime()) or os.time()
end

local function dispatch(msg)
  if type(msg) ~= "table" then return end
  local t = msg.type
  if t and handlers[t] then
    for _, fn in ipairs(handlers[t]) do
      local ok, err = pcall(fn, msg.data ~= nil and msg.data or msg, msg)
      if not ok then print("[love_host] handler error: " .. tostring(err)) end
    end
  end
  for _, fn in ipairs(catchall) do
    local ok, err = pcall(fn, msg)
    if not ok then print("[love_host] handler error: " .. tostring(err)) end
  end
end

local function disconnect()
  if client then pcall(function() client:close() end) end
  client = nil
  connected = false
  recvbuf = ""
  sendbuf = ""
end

local function tryConnect()
  if connected or not port then return end
  local t = now()
  if t < nextConnectAt then return end
  nextConnectAt = t + 0.5
  local c = socket.tcp()
  if not c then return end
  c:settimeout(0.05)
  local ok = c:connect(host, port)
  if ok then
    c:settimeout(0)
    client = c
    connected = true
    recvbuf = ""
    -- 握手
    sendbuf = json.encode({ __hello = token }) .. "\n"
    -- 补发缓存
    for _, m in ipairs(pending) do
      sendbuf = sendbuf .. json.encode(m) .. "\n"
    end
    pending = {}
  else
    pcall(function() c:close() end)
  end
end

local function pumpRecv()
  if not connected then return end
  local _, err, partial = client:receive("*a")
  if partial and #partial > 0 then recvbuf = recvbuf .. partial end
  if err == "closed" then disconnect(); return end
  while true do
    local nl = recvbuf:find("\n", 1, true)
    if not nl then break end
    local line = recvbuf:sub(1, nl - 1)
    recvbuf = recvbuf:sub(nl + 1)
    if #line > 0 then
      local msg = json.decode(line)
      if msg then dispatch(msg) end
    end
  end
end

local function pumpSend()
  if not connected or #sendbuf == 0 then return end
  local sent, err, last = client:send(sendbuf)
  if err == "closed" then disconnect(); return end
  local n = sent or last or 0
  if n > 0 then sendbuf = sendbuf:sub(n + 1) end
end

function M._pump()
  if not connected then tryConnect() else
    pumpRecv()
    pumpSend()
  end
end

-- 注册处理器:host.on("type", fn) 或 host.on(fn)(兜底)
function M.on(a, b)
  if type(a) == "function" then
    catchall[#catchall + 1] = a
  elseif type(a) == "string" and type(b) == "function" then
    handlers[a] = handlers[a] or {}
    handlers[a][#handlers[a] + 1] = b
  end
  return M
end

-- 发送:host.emit(table) 或 host.emit("type", data)
function M.emit(a, b)
  local msg
  if type(a) == "table" then
    msg = a
  else
    msg = { type = a, data = b }
  end
  if connected then
    sendbuf = sendbuf .. json.encode(msg) .. "\n"
    pumpSend()
  else
    if #pending < 256 then pending[#pending + 1] = msg end
  end
  return M
end

function M.connected() return connected end

-- 自动每帧收发:包装 love.run(11.x 返回主循环函数)。
-- 若启用 freeze(挂起冻结): 在游戏定义好 love.update 后包裹它, 钳制单帧 dt 上限,
-- 这样从挂起恢复时那个"补偿真实流逝时间"的巨大 dt 会被限制, 游戏从被挂起的
-- 快照位置继续, 而不是一下跳到前面。正常帧 dt 远小于上限, 不受影响。
do
  local base = love and love.run
  if type(base) == "function" then
    love.run = function()
      if freeze and type(love.update) == "function" then
        local realupdate = love.update
        local MAXDT = 1 / 20
        love.update = function(dt)
          if dt and dt > MAXDT then dt = MAXDT end
          return realupdate(dt)
        end
      end
      local loop = base()
      if type(loop) == "function" then
        return function()
          M._pump()
          return loop()
        end
      end
      return loop
    end
  end
end

return M
