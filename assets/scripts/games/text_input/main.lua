-- text_input demo: echoes keyboard/IME input in real time
require("love_host")

local input = ""           -- accumulated text
local cursorOn = true
local blinkT = 0
local events = {}          -- recent love.textinput events (max 5)
local maxEvents = 5

function love.load()
  love.graphics.setBackgroundColor(0.08, 0.09, 0.14)
  love.keyboard.setTextInput(true)
  print("[text_input] ready: type on keyboard or use IME")
end

function love.textinput(text)
  input = input .. text
  table.insert(events, text)
  if #events > maxEvents then table.remove(events, 1) end
  print("[text_input] textinput: '" .. text .. "'")
end

function love.keypressed(key, scancode, isrepeat)
  if key == "backspace" then
    -- remove last UTF-8 character
    local len = #input
    if len > 0 then
      -- remove last byte until we find a non-continuation byte
      while len > 0 and input:byte(len) >= 128 and input:byte(len) < 192 do
        len = len - 1
      end
      input = input:sub(1, len - 1)
    end
  elseif key == "return" or key == "kpenter" then
    input = input .. "\n"
  elseif key == "space" then
    input = input .. " "
  end
end

function love.update(dt)
  blinkT = blinkT + dt
  if blinkT > 0.5 then
    blinkT = 0
    cursorOn = not cursorOn
  end
end

function love.draw()
  local w, h = love.graphics.getDimensions()
  local x, y = 20, 40
  local lineH = 22

  love.graphics.setColor(0.5, 0.7, 1.0)
  love.graphics.print("Text Input Demo", x, 10)

  -- input box area
  love.graphics.setColor(0.12, 0.14, 0.20)
  love.graphics.rectangle("fill", x, y, w - 40, 60)
  love.graphics.setColor(0.3, 0.35, 0.45)
  love.graphics.rectangle("line", x, y, w - 40, 60)

  -- typed text
  love.graphics.setColor(0.9, 1.0, 0.6)
  local display = input
  if cursorOn then display = display .. "|" end
  love.graphics.printf(display, x + 8, y + 8, w - 56, "left")

  -- events log
  y = y + 80
  love.graphics.setColor(1, 1, 1, 0.5)
  love.graphics.print("Recent love.textinput events:", x, y)
  y = y + lineH
  for i = #events, 1, -1 do
    love.graphics.setColor(0.6, 0.8, 1.0, 0.7)
    local label = string.format("  #%d: '%s'", i, events[i])
    love.graphics.print(label, x, y)
    y = y + lineH
  end

  -- instructions
  y = h - 60
  love.graphics.setColor(1, 1, 0.5, 0.6)
  love.graphics.print("Type on keyboard / use IME  |  Backspace deletes  |  Enter = newline", x, y)
  love.graphics.print("Input chars: " .. #input, x, y + 16)
  love.graphics.setColor(0.6, 0.9, 0.6, 0.7)
  love.graphics.print("中文输入测试 — CJK font fallback", x, y + 32)
end
