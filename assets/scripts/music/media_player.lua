local M = {}

host.audio_ensure()

local _listeners = {}
local _states = {}     -- channel -> {playing, position, duration}
local _last_error = nil
local _listener_id = nil

_listener_id = host.audio_on_event(function(channel, evttype, data)
  if type(data) ~= "table" then return end
  if evttype == "state" then
    _states[channel] = {
      playing  = data.playing == true,
      position = tonumber(data.position) or 0,
      duration = tonumber(data.duration) or 0,
    }
  elseif channel == "default" then
    if evttype == "started" then
      local st = _states["default"] or {}
      st.duration = tonumber(data.duration) or st.duration or 0
      st.playing = true
      _states["default"] = st
    elseif evttype == "paused" then
      local st = _states["default"] or {}
      st.playing = false; _states["default"] = st
    elseif evttype == "resumed" then
      local st = _states["default"] or {}
      st.playing = true; _states["default"] = st
    elseif evttype == "stopped" or evttype == "ended" then
      local st = _states["default"] or {}
      st.playing = false; st.position = 0; _states["default"] = st
    elseif evttype == "error" then
      _last_error = data.msg or "unknown"
      host.warn("audio error: " .. _last_error .. " (channel=" .. channel .. ")")
    end
  end
  for _, fn in ipairs(_listeners) do
    pcall(fn, channel, evttype, data)
  end
end)

function M.on_event(fn)
  table.insert(_listeners, fn)
  return function()
    for i, f in ipairs(_listeners) do
      if f == fn then table.remove(_listeners, i); return end
    end
  end
end

function M.play(path, opts)
  opts = opts or {}
  _last_error = nil
  host.audio_play(path, {
    channel   = opts.channel or "default",
    volume    = opts.volume or 1.0,
    loop      = opts.loop or false,
    start_pos = opts.start_pos,
  })
end

function M.pause(channel)
  host.audio_pause(channel or "default")
end

function M.resume(channel)
  host.audio_resume(channel or "default")
end

function M.stop(channel)
  host.audio_stop(channel or "default")
end

function M.seek(pos, channel)
  host.audio_seek(tonumber(pos) or 0, channel)
end

function M.get_state(channel)
  channel = channel or "default"
  return _states[channel] or { playing = false, position = 0, duration = 0 }
end

function M.last_error()
  return _last_error
end

function M.status_text()
  return "Love Audio"
end

return M
