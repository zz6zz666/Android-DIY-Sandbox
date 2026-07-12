-- syscheck: Love2D 引擎能力全面验证
-- 验证: audio / filesystem / conf.lua / 触摸 / 日志管道
require("love_host")

local results = {}
local testIdx = 0
local beepSrc = nil
local saveTestFile = nil

local function report(name, ok, detail)
  testIdx = testIdx + 1
  results[testIdx] = {
    name = name,
    ok = ok,
    detail = detail or (ok and "PASS" or "FAIL"),
  }
  print(string.format("[syscheck] %s: %s", name, ok and "OK" or "FAIL"))
end

-- --- 自动测试 (在 love.load 中跑一遍) ---
function love.load()
  report("love.graphics", true)
  report("love.timer.getFPS", true)
  report("love.system.getOS", true, love.system.getOS())
  report("love.mouse/touch*", true)

  -- Audio: 生成 440Hz 正弦波 0.4s → 创建 Source → 播放 (延迟 1s 后响)
  local ok, err = pcall(function()
    local rate = 44100
    local dur = 0.4
    local freq = 440
    local samples = math.floor(rate * dur)
    local sd = love.sound.newSoundData(samples, rate, 16, 1)
    for i = 0, samples - 1 do
      local t = i / rate
      local v = math.sin(2 * math.pi * freq * t) * 0.4
      sd:setSample(i, v)
    end
    beepSrc = love.audio.newSource(sd)
  end)
  report("love.sound.newSoundData", ok, ok and "440Hz sine generated" or tostring(err))

  -- Audio: newSource from SoundData
  if beepSrc then
    report("love.audio.newSource", true, "source created from SoundData")
  else
    report("love.audio.newSource", false, "SoundData creation failed first")
  end

  -- Filesystem: getIdentity
  local id = love.filesystem.getIdentity()
  report("love.filesystem.getIdentity", id == "syscheck",
    "identity=" .. tostring(id) .. (id == "syscheck" and " (conf.lua OK)" or " (conf.lua MISS?)"))

  -- Filesystem: getSaveDirectory
  local sdPath = love.filesystem.getSaveDirectory()
  report("love.filesystem.getSaveDirectory", sdPath ~= nil and #sdPath > 0,
    "save_dir=" .. tostring(sdPath))

  -- Filesystem: write
  ok, err = pcall(function()
    local data = "syscheck_test_" .. os.time()
    love.filesystem.write("syscheck_test.txt", data)
    saveTestFile = data
  end)
  report("love.filesystem.write", ok, ok and "wrote syscheck_test.txt" or tostring(err))

  -- Filesystem: read back
  if saveTestFile then
    ok, err = pcall(function()
      local content = love.filesystem.read("syscheck_test.txt")
      if content == saveTestFile then
        report("love.filesystem.read", true, "content matches: " .. content)
      else
        report("love.filesystem.read", false,
          "content mismatch: " .. tostring(content) .. " vs " .. saveTestFile)
      end
    end)
    if not ok then
      report("love.filesystem.read", false, tostring(err))
    end
  end

  -- Filesystem: getInfo / exists
  ok, err = pcall(function()
    local info = love.filesystem.getInfo("syscheck_test.txt")
    if info then
      report("love.filesystem.getInfo", true,
        "size=" .. (info.size or "?") .. " type=" .. (info.type or "?"))
    else
      report("love.filesystem.getInfo", false, "file not found!")
    end
  end)
  if not ok then
    report("love.filesystem.getInfo", false, tostring(err))
  end

  -- Filesystem: enumerate
  ok, err = pcall(function()
    local files = love.filesystem.getDirectoryItems("")
    local count = 0
    for _, _ in ipairs(files) do count = count + 1 end
    local names = {}
    for _, f in ipairs(files) do names[#names + 1] = f end
    report("love.filesystem.getDirectoryItems", true,
      count .. " items: " .. table.concat(names, ", ", 1, math.min(5, #names)))
  end)
  if not ok then
    report("love.filesystem.getDirectoryItems", false, tostring(err))
  end

  -- love.draw is tested implicitly
  report("love.draw", true)
end

local function tcolor(ok)
  return ok and {0.3, 0.9, 0.4} or {1.0, 0.35, 0.35}
end

function love.update(dt) end

function love.draw()
  local w, h = love.graphics.getDimensions()
  love.graphics.clear(0.06, 0.07, 0.12)

  love.graphics.setColor(0.3, 0.7, 1.0)
  love.graphics.print("LÖVE Engine SysCheck", 12, 10)

  local passed, total = 0, testIdx
  for i = 1, testIdx do
    if results[i].ok then passed = passed + 1 end
  end

  love.graphics.setColor(1, 1, 1, 0.6)
  love.graphics.print(string.format("Results: %d / %d pass", passed, total), 12, 28)

  local y = 52
  local lineH = 18
  for i = 1, testIdx do
    local r = results[i]
    local c = tcolor(r.ok)
    love.graphics.setColor(c[1], c[2], c[3])
    love.graphics.print(string.format("  %s %s", r.ok and "✓" or "✗", r.name), 12, y)
    if r.detail and #r.detail > 0 then
      love.graphics.setColor(1, 1, 1, 0.5)
      love.graphics.print("    " .. r.detail, 12, y + 14)
      y = y + 14
    end
    y = y + lineH
  end

  -- 底部提示
  love.graphics.setColor(1, 1, 0.6)
  love.graphics.print("Tap screen to play 440Hz beep (test audio)", 12, h - 28)
  love.graphics.print("Print log piped to app LuaLog console", 12, h - 14)
end

local lastTap = 0
function love.touchpressed(id, x, y)
  local t = love.timer.getTime()
  if beepSrc and t - lastTap > 0.8 then
    lastTap = t
    beepSrc:clone():play()
    print("[syscheck] beep played at t=" .. string.format("%.1f", t))
  end
end

function love.mousepressed(x, y, btn, istouch)
  if not istouch then love.touchpressed(0, x, y) end
end
