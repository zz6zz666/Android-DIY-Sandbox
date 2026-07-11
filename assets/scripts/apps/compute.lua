-- 整屏应用 · 算力演示 A: 切走即卸载 (unload="hidden")
-- 切走导航栏/标签 或 退后台 → pause 停掉(不在后台白算); 回来 → resume 从第 0 轮重新开始。
-- 观察: 记住"已算 N 轮", 切到终端等几秒再回来 → N 归零重来(证明切走时确实被卸载停掉了)。
local timer, rounds = nil, 0

local function tick()
  local s = 0
  for i = 1, 300000 do s = s + math.sqrt(i) end
  rounds = rounds + 1
  reactive("dynapp.computeA").set(string.format("已算 %d 轮 (s=%.0f)", rounds, s))
end
local function start() if not timer then timer = host.interval(200, tick) end end
local function stop() if timer then host.clear_interval(timer); timer = nil end end

return {
  title = "算力A · 切走即卸载(hidden)",
  unload = "hidden",
  build = function()
    reactive("dynapp.computeA", "启动中…")
    rounds = 0
    start()
    return center(column({
      icon("layers_clear", { size = 44, color = "primary" }),
      spacer(10),
      text("", { bind = "dynapp.computeA", size = 20, weight = "bold" }),
      spacer(8),
      text("hidden/卸载:切走 nav/标签/退后台 → 停掉; 回来从 0 重来",
        { color = "grey", size = 12, align = "center" }),
    }, { cross = "center" }))
  end,
  pause = stop,                              -- 切走: 停掉 (不在后台白算)
  resume = function() rounds = 0; start() end, -- 回来: 从 0 重新开始
  dispose = stop,
}
