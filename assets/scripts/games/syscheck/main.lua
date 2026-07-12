-- 引擎诊断: LOVE 模块完整性 + 核心能力覆盖率
require("love_host")

local results = {}
local testIdx = 0
local beepSrc = nil
local testImg = nil      -- 运行时生成的测试图片, 在底部绘制
local lastKey = ""
local lastText = ""

local function report(name, ok, detail)
  testIdx = testIdx + 1
  results[testIdx] = { name = name, ok = ok, detail = detail or (ok and "PASS" or "FAIL") }
  print(string.format("[syscheck] %s: %s", name, ok and "OK" or "FAIL"))
end

function love.load()
  report("love.graphics", true)
  report("love.system.getOS", true, love.system.getOS())

  -- Audio: SoundData → Source (tap to beep)
  local ok, err = pcall(function()
    local rate, dur, freq = 44100, 0.4, 440
    local sd = love.sound.newSoundData(math.floor(rate * dur), rate, 16, 1)
    for i = 0, sd:getSampleCount() - 1 do
      sd:setSample(i, math.sin(2 * math.pi * freq * i / rate) * 0.4)
    end
    beepSrc = love.audio.newSource(sd)
  end)
  report("love.sound + love.audio", ok, ok and "440Hz src created" or tostring(err))

  -- Filesystem: write + read
  local testData = "syscheck_" .. os.time()
  ok, err = pcall(function()
    love.filesystem.write("_t.txt", testData)
    if love.filesystem.read("_t.txt") ~= testData then error("content mismatch") end
  end)
  report("love.filesystem r/w", ok, ok and "matched" or tostring(err))

  -- Filesystem: getInfo + enumerate
  ok, err = pcall(function()
    if not love.filesystem.getInfo("_t.txt") then error("getInfo nil") end
    local items = love.filesystem.getDirectoryItems("")
    if #items == 0 then error("empty") end
  end)
  report("love.filesystem info+enum", ok, ok and ("info OK, " .. #(love.filesystem.getDirectoryItems("") or {}) .. " items") or tostring(err))

  -- Physics: Box2D simulation
  ok, err = pcall(function()
    local w = love.physics.newWorld(0, 0, true)
    local b = love.physics.newBody(w, 100, 100, "dynamic")
    love.physics.newFixture(b, love.physics.newCircleShape(20))
    w:update(0.016)
    if b:getX() == 0 then error("position 0") end
    w:destroy()
  end)
  report("love.physics (Box2D)", ok, ok and "world+body+step OK" or tostring(err))

  -- Math: perlinNoise + RNG + triangulate
  local triCnt = 0
  ok, err = pcall(function()
    if type(love.math.perlinNoise(0.5, 0.7)) ~= "number" then error("perlin") end
    local rng = love.math.newRandomGenerator(os.time())
    rng:random(100)
    local v = love.math.triangulate({0,0, 100,0, 50,80})
    if not v then error("triangulate nil") end
    triCnt = #v
  end)
  report("love.math", ok, ok and ("perlin+triangulate(" .. triCnt .. ")+RNG OK") or tostring(err))

  -- Image: 运行时生成渐变 → 保存 PNG → 加载 → 验证尺寸 → 底部绘出
  ok, err = pcall(function()
    local iw, ih = 128, 32
    local id = love.image.newImageData(iw, ih)
    for y = 0, ih - 1 do
      for x = 0, iw - 1 do
        id:setPixel(x, y, x / iw, y / ih, 0.5, 1)
      end
    end
    local png = id:encode("png")
    love.filesystem.write("_gradient.png", png)
    testImg = love.graphics.newImage("_gradient.png")
    if testImg:getWidth() ~= iw or testImg:getHeight() ~= ih then
      error("size mismatch")
    end
  end)
  report("love.image gen→PNG→load", ok, ok and "128x32 gradient OK" or tostring(err))

  -- Canvas render-to-texture readback
  ok, err = pcall(function()
    local c = love.graphics.newCanvas(32, 32)
    love.graphics.setCanvas(c); love.graphics.clear(1, 0, 0, 1); love.graphics.setCanvas()
    local rp = {c:newImageData():getPixel(0, 0)}
    if rp[1] < 0.9 or rp[2] > 0.1 or rp[3] > 0.1 then error("not red") end
    c:release()
  end)
  report("Canvas:newImageData", ok, ok and "red pixel readback OK" or tostring(err))

  -- CJK Chinese font (auto-injected by love_host)
  ok, err = pcall(function()
    if not love.filesystem.getInfo("cjk_font.ttf") then error("not found") end
    if not love.graphics.newFont("cjk_font.ttf", 14) then error("newFont nil") end
  end)
  report("CJK font (cjk_font.ttf)", ok, ok and "loaded" or tostring(err))

  -- love.data: hash + pack/unpack + encode + compress
  ok, err = pcall(function()
    if #love.data.hash("md5", "hello") == 0 then error("hash empty") end
    local p = love.data.pack("string", "z", "hello")
    if love.data.unpack("z", p) ~= "hello" then error("pack/unpack") end
    if love.data.encode("string", "hex", "AB") ~= "4142" then error("hex encode") end
    local c = love.data.compress("string", "lz4", string.rep("x", 200))
    if not love.data.decompress("string", "lz4", c) then error("decompress nil") end
  end)
  report("love.data", ok, ok and "hash+pack+encode+compress OK" or tostring(err))

  -- love.thread: newThread + Channel communication
  ok, err = pcall(function()
    if not love.thread then error("module nil") end
    love.filesystem.write("_t.lua", [[
      local ch = love.thread.getChannel("_tc")
      ch:push({ok = 42})
    ]])
    local ch = love.thread.getChannel("_tc")
    local t = love.thread.newThread("_t.lua")
    t:start(); t:wait()
    local m = ch:pop()
    if not m or m.ok ~= 42 then error("channel: " .. tostring(m and m.ok)) end
    t:release()
  end)
  report("love.thread", ok, ok and "thread+channel OK" or tostring(err))

  -- Networking: LuaSocket module
  ok, err = pcall(function()
    local s = require("socket")
    if not s or not s.tcp then error("module/tcp nil") end
  end)
  report("require('socket')", ok, ok and "LuaSocket loaded" or tostring(err))

  -- Networking: LuaSocket HTTP (requires internet)
  if ok then
    ok, err = pcall(function()
      local http = require("socket.http")
      local b, code = http.request("http://httpbin.org/status/200")
      if code ~= 200 then error("HTTP " .. tostring(code)) end
    end)
    report("LuaSocket HTTP", ok, ok and "httpbin 200 OK" or tostring(err))
  end

  -- Joystick: module + getJoysticks (no hardware needed for probe)
  ok, err = pcall(function()
    if not love.joystick then error("module nil") end
    love.joystick.getJoysticks()
  end)
  report("love.joystick", ok, ok and ("module OK, " .. #(love.joystick.getJoysticks() or {}) .. " devices") or tostring(err))

  report("love.draw + callbacks", true)
end

local function tcolor(ok)
  return ok and {0.3, 0.9, 0.4} or {1.0, 0.35, 0.35}
end

function love.update(dt) end

function love.draw()
  local w, h = love.graphics.getDimensions()
  love.graphics.clear(0.06, 0.07, 0.12)
  love.graphics.setColor(0.3, 0.7, 1.0)
  love.graphics.print("LOVE SysCheck", 12, 10)

  local passed = 0
  for i = 1, testIdx do if results[i].ok then passed = passed + 1 end end
  love.graphics.setColor(1, 1, 1, 0.6)
  love.graphics.print(string.format("%d / %d pass", passed, testIdx), 12, 26)

  local y = 48
  for i = 1, testIdx do
    local r = results[i]
    love.graphics.setColor(tcolor(r.ok))
    love.graphics.print(string.format("  %s %s", r.ok and "✓" or "✗", r.name), 12, y)
    if r.detail and #r.detail > 0 then
      love.graphics.setColor(1, 1, 1, 0.45)
      love.graphics.print("    " .. r.detail, 12, y + 13)
      y = y + 13
    end
    y = y + 17
  end

  -- 测试生成的渐变图片
  if testImg then
    love.graphics.setColor(1, 1, 1)
    love.graphics.draw(testImg, 12, h - 48, 0, 2, 1)
  end
  love.graphics.setColor(1, 1, 0.6)
  love.graphics.print("Tap to beep · Logs: settings → Lua log", 12, h - 14)
end

local lastTap = 0
function love.touchpressed(id, x, y)
  local t = love.timer.getTime()
  if beepSrc and t - lastTap > 0.8 then
    lastTap = t
    beepSrc:clone():play()
  end
end

function love.keypressed(key, scancode, isrepeat)
  lastKey = key
end

function love.textinput(text)
  lastText = text
end
