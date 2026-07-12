-- Voice Recorder — demo application using audio_recorder API
local rec = require("sandbox.audio_recorder")("recorder")

local function fmt(sec)
  local s = tonumber(sec) or 0
  if s < 60 then return string.format("%02d:%05.2f", 0, s) end
  return string.format("%02d:%02d", math.floor(s / 60), math.floor(s % 60))
end

local function fmt_simple(sec)
  sec = tonumber(sec) or 0
  return string.format("%02d:%02d", math.floor(sec / 60), math.floor(sec % 60))
end

-- Module-level state (survives page rebuilds, shared with event callbacks)
local _rebuild = nil
local _player  = nil
local _timeKey       = "recorder.time"
local _statusKey     = "recorder.status"
local _hasRecKey     = "recorder.hasRecording"

__host_call("reactive_set", _timeKey,   "00:00.00")
__host_call("reactive_set", _statusKey, "idle")
__host_call("reactive_set", _hasRecKey, false)

-- Push live time to reactive key (called from state events, no full rebuild)
local function push_time()
  local t
  if _player and _player.playing then
    t = fmt(_player.position)
  elseif rec.recording or rec.paused then
    t = fmt(rec.position)
  elseif rec.hasRecording then
    t = fmt_simple(rec.duration)
  else
    t = "00:00.00"
  end
  __host_call("reactive_set", _timeKey, t)
end

-- Derive status label for display (Chinese — demo layer, not API)
local function status_label()
  if rec.recording and not rec.paused then return "\229\189\149\229\136\182\228\184\173\226\128\166"
  elseif rec.recording and rec.paused then return "\229\183\178\230\154\130\229\129\156"
  elseif rec.hasRecording then
    if _player and _player.playing then return "\229\155\158\230\148\190\228\184\173\226\128\166"
    else return "\229\189\149\229\136\182\229\174\140\230\136\144" end
  else return "\229\176\177\231\187\170" end
end

-- Trigger full page rebuild for structural changes (buttons, etc.)
local function do_rebuild()
  __host_call("reactive_set", _statusKey, status_label())
  __host_call("reactive_set", _hasRecKey, rec.hasRecording or false)
  push_time()
  if _rebuild then _rebuild.set(_rebuild.get() + 1) end
end

-- Sync playback handle lifecycle with recorder state
local function sync_player()
  if rec.hasRecording and not _player then
    _player = rec:playback()
    _player:on("state",   function() push_time() end)
    _player:on("started", do_rebuild)
    _player:on("paused",  do_rebuild)
    _player:on("resumed", do_rebuild)
    _player:on("stopped", do_rebuild)
    _player:on("ended",   do_rebuild)
    _player:on("error",   do_rebuild)
  elseif not rec.hasRecording and _player then
    _player:dispose()
    _player = nil
  end
end

-- Register recorder events once (module level)
rec:on("state",    function() push_time() end)
rec:on("started",  function() sync_player(); do_rebuild() end)
rec:on("paused",   do_rebuild)
rec:on("resumed",  do_rebuild)
rec:on("stopped",  function() sync_player(); do_rebuild() end)
rec:on("discarded",function() sync_player(); do_rebuild() end)
rec:on("error",    do_rebuild)

-- ================================================================
-- Page
-- ================================================================

app.page("recorder", function()
  _rebuild = state("rec.rebuild", 0)
  _rebuild.get()   -- subscribe: without this, .set() won't trigger page rebuild
  sync_player()

  local st  = status_label()
  local er  = rec.error or ""
  local has = rec.hasRecording

  -- Buttons (rebuilt on every do_rebuild → state change)
  local buttons = {}
  if rec.recording and not rec.paused then
    buttons[#buttons+1] = iconbutton("stop",      function() rec:stop()  end, { tooltip="Stop", color="error" })
    buttons[#buttons+1] = iconbutton("pause",     function() rec:pause() end, { tooltip="Pause" })
  elseif rec.recording and rec.paused then
    buttons[#buttons+1] = iconbutton("stop",           function() rec:stop()   end, { tooltip="Stop", color="error" })
    buttons[#buttons+1] = iconbutton("play_arrow",     function() rec:resume() end, { tooltip="Resume", color="primary" })
  else
    buttons[#buttons+1] = iconbutton("mic", function() rec:start() end, { tooltip="Record", color="primary" })
  end

  if has and _player then
    if _player.playing then
      buttons[#buttons+1] = iconbutton("pause",      function() _player:pause()  end, { tooltip="Pause playback", color="primary" })
    else
      buttons[#buttons+1] = iconbutton("play_arrow", function() _player:play()   end, { tooltip="Play", color="primary" })
    end
    buttons[#buttons+1] = iconbutton("delete", function() rec:discard() end, { tooltip="Discard", color="error" })
  end

  return lifecycle({
    onDispose = function()
      if _player then _player:dispose(); _player = nil end
    end,
    child = card("Recorder", {
      row({ text("", { bind = _timeKey, size = 40, weight = "bold" }) }, { main = "center" }),
      row({ text("", { bind = _statusKey, size = 13, color = "grey" }) }, { main = "center" }),
      spacer(16),
      row(buttons, { main = "center", gap = 16 }),
      #er > 0 and text(er, { size = 12, color = "red", align = "center" }) or nil,
    }, { padding = 20 }),
  })
end)
