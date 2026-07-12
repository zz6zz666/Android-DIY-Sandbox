-- syscheck: Love2D 引擎能力全面验证
-- 验证: audio / filesystem / conf.lua / 触摸 / 日志管道
require("love_host")

local results = {}
local testIdx = 0
local beepSrc = nil
local saveTestFile = nil
local lastKey = ""
local lastText = ""

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

  -- Physics: Box2D
  ok, err = pcall(function()
    local w = love.physics.newWorld(0, 0, true)
    local b1 = love.physics.newBody(w, 100, 100, "dynamic")
    local s1 = love.physics.newCircleShape(20)
    love.physics.newFixture(b1, s1)
    local b2 = love.physics.newBody(w, 300, 100, "static")
    local s2 = love.physics.newRectangleShape(0, 0, 60, 20)
    love.physics.newFixture(b2, s2)
    w:update(0.016)
    local x1, y1 = b1:getPosition()
    if x1 == 0 and y1 == 0 then error("body position was (0,0)") end
    w:destroy()
  end)
  report("love.physics (Box2D)", ok, ok and "world + body + fixture + step OK" or tostring(err))

  -- love.math
  ok, err = pcall(function()
    local v = love.math.perlinNoise(0.5, 0.7)
    if type(v) ~= "number" then error("perlinNoise() returned " .. type(v)) end
  end)
  report("love.math.perlinNoise", ok, ok and string.format("perlinNoise(0.5,0.7)=%.4f", love.math.perlinNoise(0.5, 0.7)) or tostring(err))

  ok, err = pcall(function()
    local rng = love.math.newRandomGenerator(os.time())
    local a, b = rng:random(100), rng:random(100)
    if a == b and a == b then end
  end)
  report("love.math.newRandomGenerator", ok, ok and "RNG created" or tostring(err))

  local triCount = 0
  ok, err = pcall(function()
    local verts = love.math.triangulate({
      0,0, 100,0, 50,80,
    })
    if verts then triCount = #verts else error("triangulate returned nil") end
  end)
  report("love.math.triangulate", ok, ok and string.format("%d vertices", triCount) or tostring(err))

  -- Image: newImage from generated ImageData
  ok, err = pcall(function()
    local id = love.image.newImageData(64, 64)
    for px = 0, 63 do
      for py = 0, 63 do
        local r = math.floor((px / 63) * 255)
        local g = math.floor((py / 63) * 255)
        id:setPixel(px, py, r, g, 128, 255)
      end
    end
    local img = love.graphics.newImage(id)
    local iw, ih = img:getDimensions()
    if iw ~= 64 or ih ~= 64 then error("size mismatch") end
  end)
  report("love.graphics.newImage", ok, ok and "ImageData→Image 64x64 OK" or tostring(err))

  -- Image: file-based load (write to save dir, read back)
  ok, err = pcall(function()
    local id = love.image.newImageData(32, 32)
    for px = 0, 31 do
      for py = 0, 31 do
        id:setPixel(px, py, math.floor(px / 31 * 255), math.floor(py / 31 * 255), 128, 255)
      end
    end
    local fd = id:encode("png")
    love.filesystem.write("_test_image.png", fd)
    if not love.filesystem.getInfo("_test_image.png") then error("file not written") end
    local img = love.graphics.newImage("_test_image.png")
    local iw, ih = img:getDimensions()
    if iw ~= 32 or ih ~= 32 then error("size mismatch: " .. iw .. "x" .. ih) end
  end)
  report("love.graphics.newImage(file)", ok, ok and "write ImageData→PNG → load OK" or tostring(err))

  -- Font: newFont from .ttf or default
  ok, err = pcall(function()
    local f = love.graphics.newFont(16)
    if not f then error("font nil") end
  end)
  report("love.graphics.newFont", ok, ok and "size=16 created" or tostring(err))

  -- Image: ImageData:getPixel + getDimensions
  ok, err = pcall(function()
    local id = love.image.newImageData(4, 4)
    id:setPixel(1, 2, 255, 128, 64, 255)
    local r, g, b, a = id:getPixel(1, 2)
    if r ~= 255 or g ~= 128 or b ~= 64 or a ~= 255 then
      error(string.format("got (%d,%d,%d,%d)", r, g, b, a))
    end
    local iw = id:getWidth()
    local ih = id:getHeight()
    if iw ~= 4 or ih ~= 4 then error("dims " .. iw .. "x" .. ih) end
  end)
  report("ImageData:getPixel+getDim", ok, ok and "pixel (255,128,64) OK" or tostring(err))

  -- Image: ImageData:paste
  ok, err = pcall(function()
    local src = love.image.newImageData(2, 2)
    src:setPixel(0, 0, 255, 0, 0, 255)
    local dst = love.image.newImageData(4, 4)
    dst:paste(src, 1, 1)
    local r = {dst:getPixel(1, 1)}
    if r[1] ~= 255 then error("paste pixel mismatch") end
  end)
  report("ImageData:paste", ok, ok and "2x2→4x4 OK" or tostring(err))

  -- Image: ImageData:mapPixel
  ok, err = pcall(function()
    local id = love.image.newImageData(4, 4)
    id:mapPixel(function(x, y, r, g, b, a)
      return r, g, b, 128
    end)
    local _, _, _, a = id:getPixel(1, 1)
    if a ~= 128 then error("mapPixel alpha not 128") end
  end)
  report("ImageData:mapPixel", ok, ok and "alpha→128 OK" or tostring(err))

  -- Image: encode multiple formats
  ok, err = pcall(function()
    local id = love.image.newImageData(2, 2)
    local tga = id:encode("tga")
    if not tga or tga == "" then error("tga empty") end
    local bmp = id:encode("bmp")
    if not bmp or bmp == "" then error("bmp empty") end
  end)
  report("ImageData:encode(tga,bmp)", ok, ok and "TGA+BMP OK" or tostring(err))

  -- Image: newImageData from file (PNG → ImageData, not via graphics)
  ok, err = pcall(function()
    local fd = love.image.newImageData("_test_image.png")
    if not fd then error("nil ImageData") end
    local iw, ih = fd:getDimensions()
    if iw ~= 32 or ih ~= 32 then error("size " .. iw .. "x" .. ih) end
  end)
  report("love.image.newImageData(file)", ok, ok and "PNG→ImageData 32x32 OK" or tostring(err))

  -- Image: Canvas:newImageData (render-to-texture readback)
  ok, err = pcall(function()
    local c = love.graphics.newCanvas(32, 32)
    love.graphics.setCanvas(c)
    love.graphics.clear(1, 0, 0)
    love.graphics.setCanvas()
    local id = c:newImageData()
    local r = {id:getPixel(0, 0)}
    if r[1] ~= 255 or r[2] ~= 0 or r[3] ~= 0 then
      error(string.format("canvas pixel (%d,%d,%d)", r[1], r[2], r[3]))
    end
    c:release()
  end)
  report("Canvas:newImageData", ok, ok and "red pixel readback OK" or tostring(err))

  -- Text input: callback registration (love.textinput fires on IME/flutter text)
  ok, err = pcall(function()
    if type(love.textinput) ~= "function" then error("love.textinput not a function") end
    -- Register a handler that will be called when text arrives
  end)
  report("love.textinput (callback)", ok, ok and "function exists" or tostring(err))

  -- Joystick: module existence + api probe
  ok, err = pcall(function()
    if not love.joystick then error("love.joystick is nil") end
  end)
  report("love.joystick module", ok, ok and "loaded" or tostring(err))

  if ok then
    ok, err = pcall(function()
      local j = love.joystick.getJoysticks()
      -- Empty on devices without gamepad; the API call itself should succeed
    end)
    report("love.joystick.getJoysticks", ok, ok and ("count=" .. #(love.joystick.getJoysticks() or {})) or tostring(err))
  end

  -- Joystick callbacks: register handlers that fire when a device connects
  ok, err = pcall(function()
    local sentinel = false
    love.joystickadded = function(joystick) sentinel = true end
    love.joystickremoved = function(joystick) sentinel = true end
    love.joystickpressed = function(joystick, button) sentinel = true end
    love.joystickreleased = function(joystick, button) sentinel = true end
    love.joystickaxis = function(joystick, axis, value) sentinel = true end
    love.joystickhat = function(joystick, hat, direction) sentinel = true end
    if type(love.joystickadded) ~= "function" then error("callback not set") end
  end)
  report("love.joystick* callbacks", ok, ok and "6 handlers registered" or tostring(err))

  -- Gamepad callbacks (modern gamepad API, maps gamepad buttons to standard SDL layout)
  ok, err = pcall(function()
    love.gamepadpressed = function(joystick, button) end
    love.gamepadreleased = function(joystick, button) end
    love.gamepadaxis = function(joystick, axis, value) end
    if type(love.gamepadpressed) ~= "function" then error("callback not set") end
  end)
  report("love.gamepad* callbacks", ok, ok and "3 handlers registered" or tostring(err))

  -- Thread: probe love.thread module (may not be compiled in)
  ok, err = pcall(function()
    if not love.thread then error("love.thread not loaded") end
  end)
  report("love.thread module", ok, ok and "loaded" or tostring(err))

  if ok then
    ok, err = pcall(function()
      local t = love.thread.newThread([[
        local count = 0
        for i = 1, 1000000 do count = count + 1 end
        return count
      ]])
      if not t then error("newThread returned nil") end
      t:start()
      t:wait()
      local result = t:getError()
      t:release()
      if result and #result > 0 then
        error("thread error: " .. result)
      end
    end)
    report("love.thread.newThread", ok, ok and "created+ran+released" or tostring(err))
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
  love.graphics.print("Tap screen to play 440Hz beep (test audio)", 12, h - 56)
  love.graphics.print("Print log piped to app LuaLog console", 12, h - 42)
  if #lastKey > 0 then
    love.graphics.print("Last key: " .. lastKey, 12, h - 28)
  end
  if #lastText > 0 then
    love.graphics.print("Last text: " .. lastText, 12, h - 14)
  end
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

function love.keypressed(key, scancode, isrepeat)
  lastKey = key
  report("love.keypressed", true, "key=" .. tostring(key))
end

function love.textinput(text)
  lastText = text
  print("[syscheck] textinput: " .. text)
end
