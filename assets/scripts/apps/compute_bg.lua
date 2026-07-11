-- 整屏应用 · 算力演示 B: 后台续跑 (unload="back", 类比 love 的 run)
-- 切走导航栏/标签时【不暂停】, 计算在后台继续; 只有【返回选择界面】才 dispose 停掉。
-- 【返回选择界面】再进入 → 全新加载 → 从第 0 轮重来。
-- 观察: 记住"已算 N 轮", 切到主页/终端等几秒再回来 → N 明显变大(后台一直在算)。
local timer, rounds = nil, 0

local function tick()
  local s = 0
  for i = 1, 300000 do s = s + math.sqrt(i) end
  rounds = rounds + 1
  reactive("dynapp.computeB").set(string.format("已算 %d 轮 (s=%.0f)", rounds, s))
end
local function start() if not timer then timer = host.interval(200, tick) end end
local function stop() if timer then host.clear_interval(timer); timer = nil end end

return {
  title = "算力B · 后台续跑(back)",
  unload = "back",
  build = function()
    reactive("dynapp.computeB", "启动中…")
    start()
    return center(column({
      icon("bolt", { size = 44, color = "secondary" }),
      spacer(10),
      text("", { bind = "dynapp.computeB", size = 20, weight = "bold" }),
      spacer(8),
      text("back/续跑:切走 nav/标签仍在后台算; 只有【返回】才停",
        { color = "grey", size = 12, align = "center" }),
    }, { cross = "center" }))
  end,
  dispose = stop,  -- 返回/切 app: 停掉 (再进全新加载 → 0)
}
