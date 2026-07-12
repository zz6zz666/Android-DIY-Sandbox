local M = {}

local _player = host.audio_player("audio")

M.play  = function(path, opts) _player:play(path, opts or {}) end
M.pause = function() _player:pause() end
M.resume = function() _player:resume() end
M.stop  = function() _player:stop() end
M.seek  = function(pos) _player:seek(pos) end

M.get_state = function()
  return { playing = _player.playing, position = _player.position, duration = _player.duration }
end

M.on_event = function(fn) _player:on_event(fn) end
M.off_event = function(fn) _player:off_event(fn) end

function M.last_error()
  return _player._error  -- 由 reactive key 记录
end

function M.status_text()
  return "Love Audio"
end

function M.dispose()
  _player:dispose()
end

-- 暴露 key 方法给 UI
function M.key(k)
  return _player:key(k)
end

-- 向后兼容: 暴露 player 引用
function M.player()
  return _player
end

return M
