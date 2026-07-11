-- bounce.love: 一个浅色圆盘缓慢移动、碰壁反弹 (带果冻挤压效果), 点它切换蓝/橙。
-- 左上角显示画布尺寸与朝向: 旋转后画布为横向 (w>h), 用于直观验证横屏旋转是否生效。
require("love_host")   -- freeze 支持 (包装 love.run)

local x, y = 140, 140
local vx, vy = 110, 86        -- 移动较慢
local r = 46
local sqx, sqy = 1, 1         -- 果冻挤压缩放 (回弹时形变)

local PALETTE = {
  { 0.56, 0.74, 1.0 },        -- 浅蓝
  { 1.0, 0.80, 0.52 },        -- 浅橙
}
local ci = 1

local function squash(axis)
  if axis == "x" then sqx, sqy = 0.9, 1.1 else sqx, sqy = 1.1, 0.9 end
end

-- 点到圆盘上就切换浅蓝/浅橙 (验证触摸命中)。兼容像素或归一化坐标。
local function hit(px, py)
  local w, h = love.graphics.getDimensions()
  if px <= 1.0 and py <= 1.0 then px, py = px * w, py * h end
  local dx, dy = px - x, py - y
  if dx * dx + dy * dy <= (r * 1.4) * (r * 1.4) then
    ci = (ci % #PALETTE) + 1
  end
end
-- 注意: 触摸会同时合成一次 mouse 事件, 用 istouch 过滤, 否则一次点击触发两次 → 变色抵消。
function love.touchpressed(id, px, py) hit(px, py) end
function love.mousepressed(px, py, button, istouch) if not istouch then hit(px, py) end end

function love.update(dt)
  local w, h = love.graphics.getDimensions()
  x = x + vx * dt
  y = y + vy * dt
  if x - r < 0 then x = r; vx = math.abs(vx); squash("x") end
  if x + r > w then x = w - r; vx = -math.abs(vx); squash("x") end
  if y - r < 0 then y = r; vy = math.abs(vy); squash("y") end
  if y + r > h then y = h - r; vy = -math.abs(vy); squash("y") end
  local k = math.min(1, dt * 7)
  sqx = sqx + (1 - sqx) * k
  sqy = sqy + (1 - sqy) * k
end

function love.draw()
  local w, h = love.graphics.getDimensions()
  love.graphics.clear(0.07, 0.08, 0.12)
  local c = PALETTE[ci]
  love.graphics.setColor(c[1], c[2], c[3])
  love.graphics.push()
  love.graphics.translate(x, y)
  love.graphics.scale(sqx, sqy)
  love.graphics.circle("fill", 0, 0, r)
  love.graphics.pop()
  love.graphics.setColor(1, 1, 1, 0.92)
  love.graphics.print(string.format("BOUNCE  %d x %d  %s", w, h, w >= h and "landscape" or "portrait"), 8, 8)
end
