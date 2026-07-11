-- 整屏应用 · 调色板 (由「动态」页用 loadlua 动态加载)
return {
  title = "调色板",
  build = function()
    local colors = {
      "#F44336", "#E91E63", "#9C27B0", "#3F51B5",
      "#2196F3", "#00BCD4", "#009688", "#4CAF50",
      "#CDDC39", "#FFC107", "#FF9800", "#FF5722",
    }
    local cells = {}
    for _, c in ipairs(colors) do
      cells[#cells + 1] = center(
        column({ text(c, { color = "white", size = 12, weight = "bold" }) }, {
          main = "center",
          cross = "center",
          style = { height = 90, radius = 14, bg = c,
                    shadow = { color = "#33000000", blur = 10, dy = 4 } },
        })
      )
    end
    return padding(grid(cells, { columns = 3, gap = 12, ratio = 1.2, scroll = true }), 16)
  end,
}
