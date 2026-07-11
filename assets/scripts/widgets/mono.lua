-- 动态贴图 · 样式 B: 极简单色 (由主页用 loadlua 动态加载)
return {
  name = "极简",
  build = function()
    return row({
      column({
        icon("bolt", { color = "black", size = 26 }),
      }, { style = { padding = 14, radius = 16, bg = "#FFEB3B" } }),
      spacer(14),
      expanded(column({
        text("极简卡片", { size = 18, weight = "bold" }),
        spacer(2),
        text("留白 · 单色块 · 细边框", { color = "grey" }),
        spacer(2),
        text("样式 B", { color = "grey", size = 12 }),
      }, { cross = "start" })),
    }, {
      cross = "center",
      style = {
        padding = 18,
        radius = 18,
        bg = "surface",
        border = "#22000000",
        borderWidth = 1,
      },
    })
  end,
}
