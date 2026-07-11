-- 动态贴图 · 样式 A: 极光渐变 (由主页用 loadlua 动态加载)
-- 约定: 返回一个 { name=显示名, build=function(ctx) return 组件 end } 模块。
return {
  name = "极光",
  build = function()
    return column({
      row({
        icon("auto_awesome", { color = "white", size = 22 }),
        spacer(8),
        text("极光", { size = 20, weight = "bold", color = "white" }),
      }, { cross = "center" }),
      spacer(8),
      text("线性渐变 · 大圆角 · 柔和阴影", { color = "white" }),
      spacer(2),
      text("样式 A", { color = "#CCFFFFFF", size = 12 }),
    }, {
      cross = "start",
      style = {
        padding = 20,
        radius = 22,
        gradient = { type = "linear", colors = { "#7C4DFF", "#00E5FF" } },
        shadow = { color = "#553F51B5", blur = 24, dy = 8 },
      },
    })
  end,
}
