-- 动态贴图 · 样式 C: 霓虹暗色 (由主页用 loadlua 动态加载)
return {
  name = "霓虹",
  build = function()
    return column({
      text("NEON", { size = 26, weight = "bold", color = "#39FF14" }),
      spacer(6),
      text("暗色背景 · 霓虹描边 · 发光阴影", { color = "#B0FFFFFF" }),
      spacer(10),
      row({
        chip("动态", { color = "#39FF14" }),
        spacer(8),
        chip("加载", { color = "#00E5FF" }),
      }),
    }, {
      cross = "start",
      style = {
        padding = 20,
        radius = 18,
        bg = "#0D0D0D",
        border = "#39FF14",
        borderWidth = 1.5,
        shadow = { color = "#5539FF14", blur = 28, dy = 0 },
      },
    })
  end,
}
