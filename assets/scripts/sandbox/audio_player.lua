local function fmt_time(sec)
  sec = tonumber(sec) or 0
  local m = math.floor(sec / 60)
  local s = math.floor(sec % 60)
  return string.format("%02d:%02d", m, s)
end

return function(name)
  name = name or "audio"
  host.audio_ensure()

  local ch = name
  local self = {
    _name = name,
    playing = false,
    position = 0,
    duration = 0,
  }
  local _custom = {}
  local _listener_id

  -- 直接写 Dart notifier, 不创建 Lua reactive 对象 (避免泄漏到组件树)
  local function _set(key, val)
    __host_call("reactive_set", name .. "." .. key, val)
  end

  _set("playing", false)
  _set("position", "00:00")
  _set("duration", "00:00")
  _set("status", "就绪")
  _set("error", "")

  _listener_id = host.audio_on_event(function(channel, evttype, data)
    if channel ~= ch then return end
    if evttype == "state" and type(data) == "table" then
      local p = data.playing == true
      local pos = tonumber(data.position) or 0
      local dur = tonumber(data.duration) or 0
      self.playing = p
      self.position = pos
      self.duration = dur
      _set("playing", p)
      _set("position", fmt_time(pos))
      _set("duration", fmt_time(dur))
    elseif evttype == "started" then
      self.playing = true
      _set("playing", true)
      _set("status", "正在播放")
      if type(data) == "table" and data.duration then
        local dur = tonumber(data.duration) or 0
        self.duration = dur
        _set("duration", fmt_time(dur))
      end
    elseif evttype == "paused" then
      self.playing = false
      _set("playing", false)
      _set("status", "已暂停")
    elseif evttype == "resumed" then
      self.playing = true
      _set("playing", true)
      _set("status", "正在播放")
    elseif evttype == "stopped" or evttype == "ended" then
      self.playing = false
      self.position = 0
      _set("playing", false)
      _set("position", fmt_time(0))
      _set("status", "已停止")
    elseif evttype == "error" then
      local msg = (type(data) == "table" and data.msg) or "unknown"
      _set("error", msg)
      _set("status", "错误: " .. msg)
    end
    for _, fn in ipairs(_custom) do
      pcall(fn, evttype, data)
    end
  end)

  function self:play(path, opts)
    opts = opts or {}
    _set("error", "")
    _set("status", "加载中…")
    _set("position", fmt_time(0))
    _set("duration", fmt_time(0))
    self.position = 0
    self.duration = 0
    host.audio_play(path, {
      channel   = ch,
      volume    = opts.volume or 1.0,
      loop      = opts.loop or false,
      start_pos = opts.start_pos,
    })
  end

  function self:pause()   host.audio_pause(ch) end
  function self:resume()  host.audio_resume(ch) end
  function self:stop()    host.audio_stop(ch) end

  function self:seek(pos)
    host.audio_seek(tonumber(pos) or 0, ch)
  end

  function self:set_volume(v)
    host.audio_set_volume(tonumber(v) or 1.0, ch)
  end

  function self:set_loop(loop)
    host.audio_set_loop(loop == true, ch)
  end

  function self:key(k)
    return name .. "." .. k
  end

  function self:on_event(fn)
    table.insert(_custom, fn)
  end

  function self:off_event(fn)
    for i, f in ipairs(_custom) do
      if f == fn then table.remove(_custom, i); return end
    end
  end

  function self:dispose()
    if _listener_id then
      host.audio_off_event(_listener_id)
    end
    self:stop()
    _custom = {}
  end

  return self
end
