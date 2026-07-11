-- 整屏应用 · 时钟 (由「动态」页用 loadlua 动态加载)
-- 约定: 返回 { title=显示名, build=function(ctx) return 组件 end, dispose=可选清理 }。
-- timer 存在模块级 upvalue: 模块被加载一次并缓存, build/dispose 复用同一实例。
local timer

return {
  title = "时钟",
  build = function()
    reactive("dynapp.clock", os.date("%H:%M:%S"))
    if not timer then
      timer = host.interval(1000, function()
        reactive("dynapp.clock").set(os.date("%H:%M:%S"))
      end)
    end
    return center(column({
      text("", { bind = "dynapp.clock", size = 64, weight = "bold" }),
      spacer(8),
      text(os.date("%Y-%m-%d %A"), { size = 18, color = "grey" }),
      spacer(24),
      chip("整屏动态加载的应用 (返回上级会停掉定时器)", { color = "primary" }),
    }, { cross = "center" }))
  end,
  -- 加载页在卸载本应用时调用: 停掉定时器, 释放资源。
  dispose = function()
    if timer then host.clear_interval(timer); timer = nil end
  end,
}
