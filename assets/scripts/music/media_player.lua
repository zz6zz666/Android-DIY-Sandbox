local M = {}

local _player = host.audio_player("audio")

M.play   = function(path, opts) _player:play(path, opts or {}) end
M.pause  = function() _player:pause() end
M.resume = function() _player:resume() end
M.stop   = function() _player:stop() end
M.seek   = function(pos) _player:seek(pos) end
M.setVolume = function(v) _player:setVolume(v) end
M.setLoop  = function(loop) _player:setLoop(loop) end

M.get_state = function()
  return { playing = _player.playing, position = _player.position, duration = _player.duration }
end

M.on_event = function(fn)
  -- Generic listener: fn(event_type, data) as before
  local ids = {}
  ids[1] = _player:on("started", function()   fn("started") end)
  ids[2] = _player:on("paused",  function()     fn("paused") end)
  ids[3] = _player:on("resumed", function()     fn("resumed") end)
  ids[4] = _player:on("stopped", function()     fn("stopped") end)
  ids[5] = _player:on("ended",   function()      fn("ended") end)
  ids[6] = _player:on("error",   function(m)    fn("error", {msg=m}) end)
  ids[7] = _player:on("state",   function(d)     fn("state", d) end)
  return ids  -- caller can store to unregister later
end

M.off_event = function(ids)
  if not ids then return end
  for i, id in ipairs(ids) do
    local events = {"started","paused","resumed","stopped","ended","error","state"}
    _player:off(events[i], id)
  end
end

M.last_error  = function() return _player.error end
M.status_text = function() return "Love Audio" end

M.key = function(k)
  return "audio." .. k
end

M.player = function() return _player end

M.dispose = function()
  _player:dispose()
end

return M
