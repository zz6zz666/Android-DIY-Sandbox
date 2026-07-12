-- music/main.lua
-- 音乐播放器 — 页内用 tabs 切子页（本地音乐 / 在线搜索 / 设置）

app.page("music", function(ctx)
  local t = state("music.tab", 1)
  local p = require("music.player")
  local o = require("music.online_search")

  local api_settings_page = function()
    local api_url_st = state("api.url", host.get("api_base_url") or "https://api.bugpk.com/api/163_music")
    return {
      card("API 端点", {
        text("当前使用的 API 地址：", { size = 12, color = "grey" }),
        spacer(4),
        text(api_url_st.get(), { size = 13, maxLines = 3, ellipsis = true }),
        spacer(12),
        button("修改 API 地址", function()
          host.input({
            title   = "自定义 API 端点",
            hint    = "https://api.bugpk.com/api/163_music",
            default = api_url_st.get(),
          }, function(url)
            if url and url ~= "" then
              host.set("api_base_url", url)
              api_url_st.set(url)
              host.toast("API 地址已更新")
            end
          end)
        end, { variant = "outlined", icon = "edit" }),
        spacer(8),
        button("恢复默认", function()
          host.set("api_base_url", nil)
          api_url_st.set("https://api.bugpk.com/api/163_music")
          host.toast("已恢复默认 API 地址")
        end, { variant = "text" }),
      }),
      spacer(8),
      card("API 说明", {
        text("接口基于 BugPk 网易云音乐代理。", { size = 12, color = "grey" }),
        spacer(4),
        text("自定义 API 需兼容相同参数和返回格式。", { size = 12, color = "grey" }),
      }),
    }
  end

  return tabs({
    active = t.get(),
    onSelect = function(i) t.set(i) end,
    items = {
      {
        title = "本地音乐", icon = "music_note",
        content = lifecycle({
          child     = p.build(ctx),
          onDispose = function() p.dispose() end,
        }),
      },
      {
        title = "在线搜索", icon = "search",
        content = lifecycle({
          child     = o.build(ctx),
          onDispose = function() o.dispose() end,
        }),
      },
      {
        title = "设置", icon = "settings",
        content = api_settings_page(),
      },
    },
  })
end)
