-- online_search.lua
-- 在线音乐搜索页面：搜索 → 选歌 → 播放 + 歌词
-- 播放后端: media_player.lua (mpv 优先 → termux-media-player 回退)

local api   = require("music.api_music")
local lrc   = require("music.lrc")
local audio = require("music.media_player")

local online = {}

-- ============================================================
-- 模块级状态
-- ============================================================
local search_results = {}
local current_song = nil
local lyrics = nil
local is_playing = false
local current_duration = 0
local _unsub_fn = nil

-- ============================================================
-- 工具
-- ============================================================

local function fmt_time(sec)
  return lrc.format_time(sec)
end

local function make_progress_bar(pos, duration, width)
  width = width or 14
  if duration <= 0 then return string.rep("─", width) end
  local filled = math.floor(math.min(pos / duration, 1.0) * width + 0.5)
  return string.rep("━", filled) .. string.rep("─", width - filled)
end

-- ============================================================
-- 反应式键
-- ============================================================
local KEYS = {
  status = "online.status", title = "online.title",
  artists = "online.artists", album = "online.album",
  position = "online.position", duration = "online.duration",
  progress_bar = "online.progress_bar",
  lyric_text = "online.lyric_text",
  lyric_prev = "online.lyric_prev", lyric_next = "online.lyric_next",
  is_playing = "online.is_playing", art_url = "online.art_url",
  search_info = "online.search_info",
}

local function R(key, default)
  return reactive(key, default)
end

-- ============================================================
-- 播放控制
-- ============================================================

local function _update_ui(pos, dur)
  pos = tonumber(pos) or 0
  dur = tonumber(dur) or 0
  if dur > 0 and dur ~= current_duration then
    current_duration = dur
    R(KEYS.duration).set(fmt_time(dur))
  end
  R(KEYS.position).set(fmt_time(pos))
  R(KEYS.progress_bar).set(make_progress_bar(pos, dur > 0 and dur or current_duration))
  if lyrics and #lyrics > 0 then
    local idx = lrc.find_index(lyrics, pos)
    if idx then
      R(KEYS.lyric_text).set(lyrics[idx].text)
      R(KEYS.lyric_prev).set(idx > 1 and lyrics[idx - 1].text or "")
      R(KEYS.lyric_next).set(idx < #lyrics and lyrics[idx + 1].text or "")
    end
  end
end

local function handle_audio_event(channel, evttype, data)
  if channel ~= "default" then return end
  if evttype == "state" and type(data) == "table" then
    if not is_playing then return end
    _update_ui(data.playing and data.position or 0, data.duration or 0)
  elseif evttype == "error" then
    R(KEYS.status).set("播放失败: " .. (data.msg or "unknown"))
    is_playing = false
    R(KEYS.is_playing).set(false)
  elseif evttype == "stopped" or evttype == "ended" then
    is_playing = false
    R(KEYS.is_playing).set(false)
    R(KEYS.status).set("已停止")
  elseif evttype == "started" then
    if type(data) == "table" and data.duration then
      current_duration = tonumber(data.duration) or current_duration
      R(KEYS.duration).set(fmt_time(current_duration))
    end
    is_playing = true
    R(KEYS.is_playing).set(true)
    R(KEYS.status).set("正在播放")
  end
end

local function subscribe_events()
  if _unsub_fn then _unsub_fn() end
  _unsub_fn = audio.on_event(handle_audio_event)
end

local function unsubscribe_events()
  if _unsub_fn then _unsub_fn(); _unsub_fn = nil end
end

local function play_online_song(song)
  if not song then return end
  unsubscribe_events()
  audio.stop()

  current_song = song
  lyrics = nil
  is_playing = false

  R(KEYS.title).set(song.name)
  R(KEYS.artists).set(song.artists)
  R(KEYS.album).set(song.album)
  R(KEYS.art_url).set(song.pic_url or "")
  R(KEYS.status).set("正在获取播放链接…")
  R(KEYS.position).set("00:00")
  R(KEYS.duration).set(fmt_time(song.duration_ms / 1000))
  R(KEYS.progress_bar).set(make_progress_bar(0, song.duration_ms / 1000))
  R(KEYS.lyric_text).set("")
  R(KEYS.lyric_prev).set("")
  R(KEYS.lyric_next).set("")
  current_duration = song.duration_ms / 1000

  -- 获取播放 URL
  api.get_url(song.id, function(url, err)
    if url then
      -- 异步获取歌词
      api.get_lyric(song.id, function(lrc_text)
        if lrc_text then lyrics = lrc.parse(lrc_text) end
      end)
      -- 开始播放
      is_playing = false
      R(KEYS.is_playing).set(false)
      R(KEYS.status).set("加载中…")
      audio.play(url)
      subscribe_events()
    else
      R(KEYS.status).set("获取链接失败: " .. (err or "未知"))
      host.toast("获取播放链接失败")
    end
  end)
end

local function toggle_play_pause()
  if not current_song then host.toast("请先搜索并选择一首歌曲"); return end
  if is_playing then
    is_playing = false
    audio.pause()
    R(KEYS.is_playing).set(false)
    R(KEYS.status).set("已暂停")
  else
    is_playing = true
    audio.resume()
    R(KEYS.is_playing).set(true)
    R(KEYS.status).set("正在播放")
  end
end

local function do_search(keyword)
  if not keyword or keyword == "" then host.toast("请输入搜索关键词"); return end
  search_results = {}
  R(KEYS.search_info).set("搜索中…")
  api.search(keyword, function(songs, err)
    if songs then
      search_results = songs
      R(KEYS.search_info).set("找到 " .. #songs .. " 首")
      if #songs == 0 then host.toast("未找到相关歌曲") end
    else
      search_results = {}
      R(KEYS.search_info).set("搜索失败")
      host.toast("搜索失败: " .. (err or ""))
    end
    state("online.results_version").set((state("online.results_version").get() or 0) + 1)
  end)
end

-- ============================================================
-- 构建 UI
-- ============================================================

function online.build(ctx)
  R(KEYS.status, "就绪")
  R(KEYS.title, "在线音乐")
  R(KEYS.artists, "")
  R(KEYS.album, "")
  R(KEYS.position, "00:00")
  R(KEYS.duration, "00:00")
  R(KEYS.progress_bar, string.rep("─", 14))
  R(KEYS.lyric_text, "")
  R(KEYS.lyric_prev, "")
  R(KEYS.lyric_next, "")
  R(KEYS.is_playing, false)
  R(KEYS.art_url, "")
  R(KEYS.search_info, "")

  local keyword_st = state("online.keyword", "")
  state("online.results_version", 0)

  local r_is_playing = R(KEYS.is_playing)
  local r_art_url    = R(KEYS.art_url)

  local function build_results()
    local items = {}
    for _, song in ipairs(search_results) do
      local is_cur = current_song and current_song.id == song.id
      table.insert(items, tile(song.name, {
        subtitle = song.artists .. (song.album ~= "" and (" · " .. song.album) or ""),
        icon     = is_cur and "play_circle" or "music_note",
        trailing = is_cur and icon("volume_up", { color = "primary", size = 18 }) or nil,
        onTap = function() play_online_song(song) end,
      }))
    end
    if #items == 0 then
      if R(KEYS.search_info).get() == "搜索中…" then
        items = { row({ spinner(), spacer(8), text("搜索中…", { color = "grey" }) }, { main = "center" }) }
      else
        items = { text("输入关键词搜索歌曲", { color = "grey", align = "center", size = 13 }) }
      end
    end
    return column(items, { gap = 0 })
  end

  local function build_now_playing()
    if not current_song then
      return column({
        divider(), spacer(16),
        center(text("选择一首歌曲开始播放", { color = "grey", size = 14 })),
        spacer(16),
      })
    end

    local art_comp
    local art = r_art_url.get()
    if art ~= "" then art_comp = image(art, { width = 160, height = 160 })
    else art_comp = icon("album", { size = 80, color = "grey" }) end

    local play_btn
    if r_is_playing.get() then
      play_btn = iconbutton("pause_circle_filled", toggle_play_pause, { tooltip = "暂停", color = "primary" })
    else
      play_btn = iconbutton("play_circle_filled", toggle_play_pause, { tooltip = "播放", color = "primary" })
    end

    return column({
      divider(), spacer(8),
      text("正在播放", { size = 13, color = "primary", weight = "bold" }),
      spacer(8),
      row({
        center(art_comp), spacer(12),
        expanded(column({
          text("", { bind = KEYS.title, size = 16, weight = "bold", maxLines = 2, ellipsis = true }),
          spacer(2),
          text("", { bind = KEYS.artists, size = 13, color = "grey", maxLines = 1 }),
          text("", { bind = KEYS.album, size = 12, color = "grey", maxLines = 1 }),
        }, { gap = 0 })),
      }),
      spacer(8),
      column({
        text("", { bind = KEYS.progress_bar, size = 16, color = "primary", align = "center" }),
        spacer(2),
        row({
          text("", { bind = KEYS.position, size = 11, color = "grey" }),
          spacer(),
          text("", { bind = KEYS.duration, size = 11, color = "grey" }),
        }),
        spacer(2),
        text("", { bind = KEYS.status, size = 10, color = "grey", align = "center" }),
      }, { gap = 0 }),
      spacer(4),
      row({ play_btn }, { main = "center" }),
      spacer(8),
      text("── 歌词 ──", { size = 11, color = "grey", align = "center" }),
      spacer(4),
      text("", { bind = KEYS.lyric_prev, size = 12, color = "grey", align = "center", maxLines = 1, ellipsis = true }),
      spacer(2),
      text("", { bind = KEYS.lyric_text, size = 14, color = "primary", weight = "bold", align = "center", maxLines = 1, ellipsis = true }),
      spacer(2),
      text("", { bind = KEYS.lyric_next, size = 12, color = "grey", align = "center", maxLines = 1, ellipsis = true }),
      spacer(4),
    }, { gap = 0 })
  end

  return column({
    row({
      expanded(textfield({
        hint = "搜索歌曲、歌手…",
        value = keyword_st.get(),
        onChanged = function(v) keyword_st.set(v) end,
      })),
      spacer(8),
      button("搜索", function() do_search(keyword_st.get()) end, { icon = "search" }),
    }, { gap = 4 }),
    spacer(4),
    row({
      text("", { bind = KEYS.search_info, size = 11, color = "grey" }),
      spacer(),
      text("API: BugPk", { size = 10, color = "grey" }),
    }),
    spacer(4),
    build_results(),
    build_now_playing() or text(""),
  }, { gap = 0 })
end

function online.dispose()
  unsubscribe_events()
  audio.stop()
  is_playing = false
end

return online