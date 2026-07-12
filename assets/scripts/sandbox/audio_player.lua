-- Generic audio playback API. Transport + raw state + typed events.
-- No UI assumptions (no Chinese, no time formatting, no reactive keys).
--
-- Configuration:
--   local player = require("sandbox.audio_player")("bgm")
--
-- Transport:
--   player:play("/sdcard/song.mp3")
--   player:play("/sdcard/song.mp3", { volume=0.8, loop=true, start=10.5 })
--   player:pause()        -- pause playback
--   player:resume()       -- resume from paused
--   player:stop()         -- stop and release source
--   player:seek(30.0)     -- jump to position (seconds)
--   player:setVolume(0.5) -- adjust volume in-flight (0.0 ~ 1.0)
--   player:setLoop(true)  -- toggle looping
--
-- State (read-only properties, auto-updated from engine events):
--   player.playing   -- boolean
--   player.position  -- number (seconds, 0 if unknown)
--   player.duration  -- number (seconds, 0 if unknown)
--   player.error     -- string or nil
--
-- Events (typed, each returns a listener id):
--   local id = player:on("state",   function(d) end)  -- d = {playing, position, duration}
--                player:on("started", function()   end)
--                player:on("paused",  function()   end)
--                player:on("resumed", function()   end)
--                player:on("stopped", function()   end)
--                player:on("ended",   function()   end)
--                player:on("error",   function(msg)end)  -- msg is string
--   player:off(event, id)   -- remove one listener
--   player:off(event)       -- remove all listeners for that event
--
-- System media session (optional — only for full music player use cases):
--   player:enableMediaSession({ title, artist, album, duration })
--   player:updateMediaSession({ title, artist, state, position })
--   player:disableMediaSession()
--   player:onMediaButton(fn)   -- fn(action, position): "play"/"pause"/"skip_next"/"skip_prev"/"seek"
--
-- Lifecycle:
--   player:dispose()  -- stop + release media session + remove all listeners

return function(name)
  host.audio_ensure()
  name = name or "audio"

  local self = {
    name      = name,
    playing   = false,
    position  = 0,
    duration  = 0,
    error     = nil,
    _volume   = 1.0,
    _loop     = false,
  }
  local _events = {}    -- { state = { [id]=fn, ... }, started = {...}, ... }
  local _nextId = 0
  local _hostId
  local _playing = false  -- track last known state

  local function _emit(event, ...)
    local t = _events[event]
    if not t then return end
    for _, fn in pairs(t) do
      pcall(fn, ...)
    end
  end

  _hostId = host.audio_on_event(function(channel, evttype, data)
    if channel ~= name then return end
    if evttype == "state" and type(data) == "table" then
      self.playing  = data.playing == true
      self.position = tonumber(data.position) or 0
      self.duration = tonumber(data.duration) or 0
      _playing = self.playing
      _emit("state", { playing = self.playing, position = self.position, duration = self.duration })
    elseif evttype == "started" then
      self.playing = true
      _playing = true
      if type(data) == "table" and data.duration then
        self.duration = tonumber(data.duration) or 0
      end
      _emit("started")
    elseif evttype == "paused" then
      self.playing = false
      _playing = false
      _emit("paused")
    elseif evttype == "resumed" then
      self.playing = true
      _playing = true
      _emit("resumed")
    elseif evttype == "stopped" or evttype == "ended" then
      self.playing = false
      _playing = false
      if evttype == "stopped" then
        self.position = 0
      end
      _emit("stopped")
      if evttype == "ended" then _emit("ended") end
    elseif evttype == "error" then
      local msg = (type(data) == "table" and data.msg) or tostring(data)
      self.error = msg
      _emit("error", msg)
    end
  end)

  function self:on(event, fn)
    _nextId = _nextId + 1
    _events[event] = _events[event] or {}
    _events[event][_nextId] = fn
    return _nextId
  end

  function self:off(event, id)
    if not event then return end
    if id then
      local t = _events[event]
      if t then t[id] = nil end
    else
      _events[event] = nil
    end
  end

  function self:play(path, opts)
    opts = opts or {}
    self.error = nil
    self.position = 0
    self.duration = 0
    self._volume = tonumber(opts.volume) or self._volume
    self._loop   = opts.loop == true

    host.audio_play(path, {
      channel   = name,
      volume    = self._volume,
      loop      = self._loop,
      start_pos = opts.start,
    })
  end

  function self:pause()
    host.audio_pause(name)
  end

  function self:resume()
    host.audio_resume(name)
  end

  function self:stop()
    host.audio_stop(name)
  end

  function self:seek(pos)
    host.audio_seek(tonumber(pos) or 0, name)
  end

  function self:setVolume(v)
    self._volume = math.max(0, math.min(1, tonumber(v) or 1))
    host.audio_set_volume(self._volume, name)
  end

  function self:setLoop(loop)
    self._loop = loop == true
    host.audio_set_loop(self._loop, name)
  end

  -- ============================================================
  -- Optional: System Media Session (notification / lock screen controls)
  -- ============================================================

  function self:enableMediaSession(opts)
    opts = opts or {}
    host.media_session_init()
    host.media_session_update({
      title    = opts.title    or "",
      artist   = opts.artist   or "",
      album    = opts.album    or "",
      duration = opts.duration or 0,
      state    = "paused",
      position = 0,
    })
  end

  function self:updateMediaSession(opts)
    opts = opts or {}
    host.media_session_update({
      title    = opts.title,
      artist   = opts.artist,
      album    = opts.album,
      duration = opts.duration,
      state    = opts.state or (self.playing and "playing" or "paused"),
      position = math.floor(opts.position or self.position),
    })
  end

  function self:disableMediaSession()
    host.media_session_release()
  end

  function self:onMediaButton(fn)
    host.media_session_on_button(fn)
  end

  function self:dispose()
    pcall(host.media_session_release)
    if _hostId then
      host.audio_off_event(_hostId)
      _hostId = nil
    end
    pcall(host.audio_stop, name)
    _events = {}
  end

  return self
end
