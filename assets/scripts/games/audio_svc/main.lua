local host = require("love_host")

-- channels[ch] = {source, volume, loop, path, was_playing, paused}
local channels = {}

local _STATE_INTERVAL = 0.1
local _state_timer = 0

local function emit(evt)
  local ok, err = pcall(function() host.emit(evt) end)
  if not ok then print("[audio_svc] emit failed: " .. tostring(err)) end
end

local function stop_channel(ch)
  local c = channels[ch]
  if not c then return end
  if c.source then
    pcall(function()
      c.source:stop()
      c.source:release()
    end)
  end
  channels[ch] = nil
  emit({ type = "stopped", channel = ch })
end

host.on("play", function(data)
  if type(data) ~= "table" then data = {} end
  local ch = data.channel or "default"
  local path = data.path
  print("[audio_svc] play channel=" .. ch .. " path=" .. tostring(path))
  if not path then
    emit({ type = "error", channel = ch, msg = "no path provided" })
    return
  end
  stop_channel(ch)
  local ok, src = pcall(love.audio.newSource, path, "stream")
  if not ok then
    local errmsg = tostring(src)
    print("[audio_svc] newSource failed: " .. errmsg)
    emit({ type = "error", channel = ch, msg = "newSource failed: " .. errmsg, path = path })
    return
  end
  local vol = data.volume
  if type(vol) ~= "number" then vol = 1.0 end
  src:setVolume(vol)
  src:setLooping(data.loop == true)
  local start_pos = data.start_pos or 0
  if start_pos > 0 then src:seek(start_pos) end
  src:play()
  channels[ch] = { source = src, volume = vol, loop = data.loop == true, path = path, was_playing = false, paused = false }
  emit({ type = "started", channel = ch, path = path })
end)

host.on("pause", function(data)
  local ch = (type(data) == "table" and data.channel) or "default"
  local c = channels[ch]
  if not c or not c.source then return end
  c.paused = true
  pcall(c.source.pause, c.source)
  emit({ type = "paused", channel = ch })
end)

host.on("resume", function(data)
  local ch = (type(data) == "table" and data.channel) or "default"
  local c = channels[ch]
  if not c or not c.source then return end
  c.paused = false
  c.source:play()
  c.was_playing = true
  emit({ type = "resumed", channel = ch })
end)

host.on("stop", function(data)
  local ch = (type(data) == "table" and data.channel) or "default"
  stop_channel(ch)
end)

host.on("seek", function(data)
  if type(data) ~= "table" then return end
  local ch = data.channel or "default"
  local pos = tonumber(data.position) or 0
  local c = channels[ch]
  if not c or not c.source then return end
  local ok, err = pcall(c.source.seek, c.source, pos)
  if ok then
    local p = c.source:tell("seconds") or pos
    emit({ type = "seeked", channel = ch, position = p })
  else
    emit({ type = "error", channel = ch, msg = "seek failed: " .. tostring(err) })
  end
end)

host.on("set_volume", function(data)
  if type(data) ~= "table" then return end
  local ch = data.channel or "default"
  local vol = tonumber(data.volume) or 1.0
  local c = channels[ch]
  if not c or not c.source then return end
  c.volume = vol
  c.source:setVolume(vol)
end)

host.on("set_loop", function(data)
  if type(data) ~= "table" then return end
  local ch = data.channel or "default"
  local loop = data.loop
  local c = channels[ch]
  if not c or not c.source then return end
  c.loop = loop == true
  c.source:setLooping(c.loop)
end)

function love.update(dt)
  _state_timer = _state_timer + dt
  if _state_timer >= _STATE_INTERVAL then
    _state_timer = 0
    for ch, c in pairs(channels) do
      if c.source then
        local playing = c.source:isPlaying()
        local pos = c.source:tell("seconds") or 0
        local dur = c.source:getDuration("seconds") or 0
        emit({ type = "state", channel = ch, playing = playing, position = pos, duration = dur })
        if c.was_playing and not playing and dur > 0 and not c.paused then
          stop_channel(ch)
          emit({ type = "ended", channel = ch })
        end
        c.was_playing = playing
      end
    end
  end
  love.timer.sleep(0.05)
end

function love.draw()
  love.graphics.clear(0, 0, 0, 0)
end
