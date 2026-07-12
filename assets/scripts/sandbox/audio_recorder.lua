-- Audio recording API. Transport + raw state + typed events.
-- No UI assumptions (no Chinese, no time formatting, no reactive keys).
--
-- Configuration:
--   local rec = require("sandbox.audio_recorder")("voice")
--
-- Transport:
--   rec:start()           -- start recording (defaults: rate=44100, bits=16, channels=1)
--   rec:start({ rate=8000, bits=8, channels=2 })
--   rec:stop()            -- stop and keep recorded data
--   rec:pause()           -- pause recording
--   rec:resume()          -- resume from pause
--   rec:discard()         -- discard recorded data
--
-- State (read-only properties, auto-updated from engine events):
--   rec.recording     -- boolean (true while microphone input active)
--   rec.paused        -- boolean (true when recording is paused)
--   rec.position      -- number (seconds elapsed in current session)
--   rec.duration      -- number (total recorded seconds, 0 until stop)
--   rec.hasRecording  -- boolean (true after successful stop)
--   rec.error         -- string or nil
--   rec.channel       -- string (the channel name, for interop)
--
-- Events (typed, each returns a listener id):
--   local id = rec:on("state",     function(d) end)  -- d = {recording, paused, position}
--                rec:on("started",  function()   end)
--                rec:on("paused",   function()   end)
--                rec:on("resumed",  function()   end)
--                rec:on("stopped",  function(d) end)  -- d = {duration}
--                rec:on("discarded",function()   end)
--                rec:on("error",    function(msg)end)  -- msg is string
--   rec:off(event, id)   -- remove one listener
--   rec:off(event)       -- remove all listeners for that event
--
-- Playback handle (to play recorded data back on the same channel):
--   local pb = rec:playback()           -- optional { volume=1.0, amp=16.0 }
--   pb:play()    -- start playing from beginning
--   pb:pause()   -- pause playback
--   pb:resume()  -- resume playback
--   pb:stop()    -- stop playback
--   pb:seek(pos) -- jump to position (seconds)
--
--   -- Playback state (read-only, auto-updated):
--   pb.playing   -- boolean
--   pb.position  -- number (seconds)
--   pb.duration  -- number (seconds)
--   pb.error     -- string or nil
--
--   -- Playback events (same pattern):
--   pb:on("state", fn) / :on("started",fn) / :on("paused",fn) / :on("resumed",fn)
--     / :on("stopped",fn) / :on("ended",fn) / :on("error",fn)
--   pb:off(event, id)
--   pb:dispose()  -- stop + remove listeners
--
-- Lifecycle:
--   rec:dispose()  -- discard + remove listeners

return function(name)
  host.audio_ensure()
  name = name or "recorder"

  local self = {
    name         = name,
    channel      = name,
    recording    = false,
    paused       = false,
    position     = 0,
    duration     = 0,
    hasRecording = false,
    error        = nil,
  }
  local _events  = {}
  local _nextId  = 0
  local _hostId
  local _defaultRate  = 44100
  local _defaultBits  = 16
  local _defaultChans = 1

  local function _emit(event, ...)
    local t = _events[event]
    if not t then return end
    for _, fn in pairs(t) do
      pcall(fn, ...)
    end
  end

  _hostId = host.audio_on_event(function(channel, evttype, data)
    if channel ~= name then return end
    if evttype == "recording_started" then
      self.recording = true; self.paused = false; self.position = 0; self.duration = 0
      _emit("started")
    elseif evttype == "recording_state" then
      local pos = tonumber((type(data) == "table" and data.position)) or 0
      self.position = pos
      _emit("state", { recording = self.recording, paused = self.paused, position = pos })
    elseif evttype == "recording_paused" then
      self.paused = true
      _emit("paused")
    elseif evttype == "recording_resumed" then
      self.recording = true; self.paused = false
      _emit("resumed")
    elseif evttype == "recording_stopped" then
      self.recording = false; self.paused = false
      local dur = tonumber((type(data) == "table" and data.duration)) or 0
      self.duration = dur
      self.hasRecording = (dur > 0)
      _emit("stopped", { duration = dur })
    elseif evttype == "recording_discarded" then
      self.recording = false; self.paused = false; self.position = 0; self.duration = 0; self.hasRecording = false
      _emit("discarded")
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

  -- ================================================================
  -- Recording transport
  -- ================================================================

  function self:start(opts)
    opts = opts or {}
    self.error = nil
    self.recording = false; self.paused = false; self.position = 0; self.duration = 0
    _defaultRate  = opts.rate  or _defaultRate
    _defaultBits  = opts.bits  or _defaultBits
    _defaultChans = opts.chans or _defaultChans
    host.audio_record_start(name, {
      rate  = _defaultRate,
      bits  = _defaultBits,
      chans = _defaultChans,
    })
  end

  function self:stop()
    host.audio_record_stop(name)
  end

  function self:pause()
    host.audio_record_pause(name)
  end

  function self:resume()
    host.audio_record_resume(name)
  end

  function self:discard()
    host.audio_record_discard(name)
  end

  -- ================================================================
  -- Playback handle
  -- ================================================================

  function self:playback(opts)
    opts = opts or {}
    local vol = tonumber(opts.volume) or 1.0
    local amp = tonumber(opts.amp) or 16.0

    local pb = {
      recordingChannel = name,
      playing   = false,
      position  = 0,
      duration  = self.duration,
      error     = nil,
    }
    local _pevents = {}
    local _pnextId = 0
    local _phostId

    local function _pemit(event, ...)
      local t = _pevents[event]
      if not t then return end
      for _, fn in pairs(t) do
        pcall(fn, ...)
      end
    end

    _phostId = host.audio_on_event(function(channel, evttype, data)
      if channel ~= name then return end
      if evttype == "started" then
        pb.playing = true
        _pemit("started")
      elseif evttype == "state" and type(data) == "table" then
        pb.playing  = data.playing == true
        pb.position = tonumber(data.position) or 0
        local dur = tonumber(data.duration) or 0
        if dur > 0 then pb.duration = dur end
        _pemit("state", { playing = pb.playing, position = pb.position, duration = pb.duration })
      elseif evttype == "paused" then
        pb.playing = false
        _pemit("paused")
      elseif evttype == "resumed" then
        pb.playing = true
        _pemit("resumed")
      elseif evttype == "stopped" or evttype == "ended" then
        pb.playing = false
        if evttype == "stopped" then pb.position = 0 end
        _pemit("stopped")
        if evttype == "ended" then _pemit("ended") end
      elseif evttype == "error" then
        local msg = (type(data) == "table" and data.msg) or tostring(data)
        pb.error = msg
        _pemit("error", msg)
      end
    end)

    function pb:on(event, fn)
      _pnextId = _pnextId + 1
      _pevents[event] = _pevents[event] or {}
      _pevents[event][_pnextId] = fn
      return _pnextId
    end

    function pb:off(event, id)
      if not event then return end
      if id then
        local t = _pevents[event]
        if t then t[id] = nil end
      else
        _pevents[event] = nil
      end
    end

    function pb:play()
      pb.error = nil
      pb.position = 0
      host.audio_record_play(name, { volume = vol, amp = amp })
    end

    function pb:pause()
      host.audio_pause(name)
    end

    function pb:resume()
      host.audio_resume(name)
    end

    function pb:stop()
      host.audio_stop(name)
    end

    function pb:seek(pos)
      host.audio_seek(tonumber(pos) or 0, name)
    end

    function pb:dispose()
      if _phostId then
        host.audio_off_event(_phostId)
        _phostId = nil
      end
      pcall(host.audio_stop, name)
      _pevents = {}
    end

    return pb
  end

  -- ================================================================
  -- Lifecycle
  -- ================================================================

  function self:dispose()
    if _hostId then
      host.audio_off_event(_hostId)
      _hostId = nil
    end
    pcall(host.audio_record_discard, name)
    _events = {}
  end

  return self
end
