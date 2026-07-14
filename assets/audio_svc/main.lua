local host = require("love_host")

-- channels[ch] = {source, volume, loop, path, was_playing, paused}
local channels = {}

-- recording[ch] = {device, rate, bits, chans, running, paused, position, chunks}
local recordings = {}
-- recorded[ch] = SoundData (final merged)
local recorded = {}

local _STATE_INTERVAL = 0.1
local _state_timer = 0

-- External directory mounts: { [dir] = mount_name }
local ext_mounts = {}
local _mount_seq = 0

--- Resolve a path: if absolute (e.g. /storage/...), mount parent dir into PhysFS.
--- Returns a PhysFS-relative path or nil on failure.
local function _resolve_path(path)
  if not path or path:sub(1, 1) ~= "/" then return path end
  local file = path:match("([^/]+)$")
  if not file then return path end
  local dir = path:sub(1, #path - #file - 1)
  if ext_mounts[dir] then return ext_mounts[dir] .. "/" .. file end
  _mount_seq = _mount_seq + 1
  local mp = "ext" .. _mount_seq
  local ok = love.filesystem.mount(dir, mp)
  if not ok then
    print("[audio_svc] mount failed: " .. dir)
    return nil
  end
  ext_mounts[dir] = mp
  print("[audio_svc] mounted " .. dir .. " -> " .. mp)
  return mp .. "/" .. file
end

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

local function _get_mic()
  if love.audio.getRecordingDevices == nil then
    return nil, "getRecordingDevices not available"
  end
  local ok, devices = pcall(love.audio.getRecordingDevices)
  if not ok or type(devices) ~= "table" or next(devices) == nil then
    return nil, "no recording device"
  end
  return devices[1]
end

host.on("play", function(data)
  if type(data) ~= "table" then data = {} end
  local ch = data.channel or "default"
  local path = _resolve_path(data.path)
  if not path then
    emit({ type = "error", channel = ch, msg = "path not accessible: " .. (data.path or "nil") })
    return
  end
  stop_channel(ch)
  local ok, src = pcall(love.audio.newSource, path, "stream")
  if not ok then
    emit({ type = "error", channel = ch, msg = "newSource failed: " .. tostring(src), path = path })
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

-- ============================================================
-- 录音 — LOVE 12 RecordingDevice API
-- ============================================================

host.on("record_start", function(data)
  if type(data) ~= "table" then data = {} end
  local ch = data.channel or "default"
  if recordings[ch] then
    emit({ type = "error", channel = ch, msg = "already recording" })
    return
  end
  local rate = tonumber(data.rate) or 44100
  local bits = tonumber(data.bits) or 16
  local chans = tonumber(data.chans) or 1
  local device, err = _get_mic()
  if not device then
    emit({ type = "error", channel = ch, msg = "mic: " .. err })
    return
  end
  local ok, startErr = pcall(device.start, device, 4096, rate, bits, chans)
  if not ok then
    emit({ type = "error", channel = ch, msg = "start: " .. tostring(startErr) })
    return
  end
  recordings[ch] = { device = device, rate = rate, bits = bits, chans = chans, running = true, position = 0, chunks = {} }
  recorded[ch] = nil
  print("[audio_svc] recording started ch=" .. ch .. " rate=" .. rate .. " bits=" .. bits .. " chans=" .. chans)
  emit({ type = "recording_started", channel = ch, rate = rate, bits = bits, chans = chans })
end)

host.on("record_stop", function(data)
  local ch = (type(data) == "table" and data.channel) or "default"
  local r = recordings[ch]
  if not r then return end
  r.running = false
end)

host.on("record_pause", function(data)
  local ch = (type(data) == "table" and data.channel) or "default"
  local r = recordings[ch]
  if not r or not r.running then return end
  r.running = false
  r.paused = true
  if r.device then pcall(r.device.stop, r.device) end
  emit({ type = "recording_paused", channel = ch, position = r.position })
end)

host.on("record_resume", function(data)
  local ch = (type(data) == "table" and data.channel) or "default"
  local r = recordings[ch]
  if not r or not r.paused then return end
  local device, err = _get_mic()
  if not device then
    emit({ type = "error", channel = ch, msg = "resume mic: " .. err })
    return
  end
  pcall(device.start, device, 4096, r.rate, r.bits, r.chans)
  r.device = device
  r.running = true
  r.paused = false
  emit({ type = "recording_resumed", channel = ch })
end)

host.on("record_discard", function(data)
  local ch = (type(data) == "table" and data.channel) or "default"
  local r = recordings[ch]
  if r then
    if r.device then pcall(r.device.stop, r.device) end
    recordings[ch] = nil
  end
  recorded[ch] = nil
  emit({ type = "recording_discarded", channel = ch })
end)

-- 回放被录数据: newSource(sd) 直接接受 SoundData (LOVE 12)
-- 然后放大音量补偿麦克风低增益
host.on("record_play", function(data)
  if type(data) ~= "table" then data = {} end
  local ch = data.channel or "default"
  local sd = recorded[ch]
  if not sd then
    emit({ type = "error", channel = ch, msg = "no recording for channel " .. ch })
    return
  end
  stop_channel(ch)
  -- 在 copy 上放大 (默认 16x)
  local totalSc = sd:getSampleCount()
  local amp = tonumber(data.amp) or 16.0
  local sdCopy = love.sound.newSoundData(totalSc, sd:getSampleRate(), sd:getBitDepth(), sd:getChannelCount())
  sdCopy:copyFrom(sd, 0, totalSc, 0)
  if amp ~= 1.0 then
    for i = 0, totalSc - 1 do
      sdCopy:setSample(i, sdCopy:getSample(i) * amp)
    end
  end
  local ok, src = pcall(love.audio.newSource, sdCopy)
  if not ok then
    emit({ type = "error", channel = ch, msg = "play recording: " .. tostring(src) })
    return
  end
  local vol = tonumber(data.volume) or 1.0
  src:setVolume(vol)
  src:setLooping(false)
  src:play()
  channels[ch] = { source = src, volume = vol, loop = false, path = "(recording)", was_playing = true, paused = false }
  emit({ type = "started", channel = ch, path = "(recording)" })
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
  -- 录音: drain getData 增量块, 停止时合并所有块
  for ch, r in pairs(recordings) do
    if r.device and r.running then
      local ok, result = pcall(r.device.getData, r.device)
      if ok and result ~= nil and type(result) == "userdata" then
        local ok2, spc = pcall(result.getSampleCount, result)
        if ok2 and type(spc) == "number" and spc > 0 then
          r.chunks[#r.chunks + 1] = result
          r.position = r.position + spc / r.rate
          -- 限频: 每 0.2s 最多发一次 recording_state 防止刷爆 UI
          r._lastEmit = r._lastEmit or 0
          r._emitTimer = (r._emitTimer or 0) + (dt or 0.02)
          if r._emitTimer >= 0.2 or r.position - (r._lastEmit or 0) > 1.0 then
            r._emitTimer = 0
            r._lastEmit = r.position
            emit({ type = "recording_state", channel = ch, position = r.position })
          end
        end
      end
    elseif r.device and not r.running and not r.paused then
      -- 最后 drain 一次, 然后 stop
      pcall(function()
        local ok, sd = r.device.getData(r.device)
        if ok and type(sd) == "userdata" then
          local ok2, cnt = pcall(sd.getSampleCount, sd)
          if ok2 and type(cnt) == "number" and cnt > 0 then
            r.chunks[#r.chunks + 1] = sd
          end
        end
      end)
      pcall(r.device.stop, r.device)
      -- 合并所有块 (SoundData:copyFrom 批量拷贝)
      local totalSamples = 0
      for _, sd in ipairs(r.chunks) do
        totalSamples = totalSamples + sd:getSampleCount()
      end
      if totalSamples > 0 then
        local merged = love.sound.newSoundData(totalSamples, r.rate, r.bits, r.chans)
        local readPos = 0
        for _, sd in ipairs(r.chunks) do
          local n = sd:getSampleCount()
          merged:copyFrom(sd, 0, n, readPos)
          readPos = readPos + n
        end
        recorded[ch] = merged
      end
      recordings[ch] = nil
      local dur = totalSamples > 0 and (totalSamples / r.rate) or 0
      print("[audio_svc] recording stopped ch=" .. ch .. " samples=" .. totalSamples .. " dur=" .. string.format("%.1f", dur) .. "s")
      emit({ type = "recording_stopped", channel = ch, samples = totalSamples, duration = dur })
    end
  end
  love.timer.sleep(0.01)
end

function love.draw()
  love.graphics.clear(0, 0, 0, 0)
end
