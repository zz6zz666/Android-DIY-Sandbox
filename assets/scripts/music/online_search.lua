local api = require("music.api_music")
local lrc = require("music.lrc")
local P   = host.audio_player("online")

local online = {}

local search_results = {}
local current_song = nil
local lyrics = nil
local current_duration = 0

-- ============================================================
-- Tools
-- ============================================================
local function fmt_time(sec)
  return lrc.format_time(sec)
end

-- ============================================================
-- Reactive keys
-- ============================================================
local KEYS = {
  title   = "online.title",  artists = "online.artists",
  album   = "online.album",  position = "online.position",
  position_val = "online.position_val",
  duration = "online.duration", duration_val = "online.duration_val",
  lyric_text = "online.lyric_text",
  lyric_prev = "online.lyric_prev", lyric_next = "online.lyric_next",
  playing = "online.playing", art_url = "online.art_url",
  search_info = "online.search_info",
}

local function R(key, default)
  return reactive(key, default)
end

-- ============================================================
-- Progress/lyrics + page rebuild
-- ============================================================
local _rebuild = nil
local _ended = false

P:on("state", function(data)
  local pos = data.position or 0
  local dur = data.duration or 0
  if dur > 0 and dur ~= current_duration then
    current_duration = dur
    R(KEYS.duration).set(fmt_time(dur))
    R(KEYS.duration_val).set(dur)
  end
  R(KEYS.position).set(fmt_time(pos))
  R(KEYS.position_val).set(pos)
  R(KEYS.playing).set(data.playing == true)
  if lyrics and #lyrics > 0 then
    local idx = lrc.find_index(lyrics, pos)
    if idx then
      R(KEYS.lyric_text).set(lyrics[idx].text)
      R(KEYS.lyric_prev).set(idx > 1 and lyrics[idx - 1].text or "")
      R(KEYS.lyric_next).set(idx < #lyrics and lyrics[idx + 1].text or "")
    end
  end
end)

local function on_state_change()
  if _rebuild then _rebuild.set(_rebuild.get() + 1) end
end

local function push_playing(v)
  R(KEYS.playing).set(v)
end

P:on("started", function() push_playing(true); _ended=false; P:updateMediaSession({ state = "playing" }); on_state_change() end)
P:on("paused",  function() push_playing(false); P:updateMediaSession({ state = "paused" });  on_state_change() end)
P:on("resumed", function() push_playing(true);  P:updateMediaSession({ state = "playing" }); on_state_change() end)
P:on("stopped", function() _ended=true; push_playing(false); R(KEYS.position).set(fmt_time(0)); R(KEYS.position_val).set(0); P:updateMediaSession({ state = "stopped" }); on_state_change() end)
P:on("ended",   function() _ended=true; push_playing(false); R(KEYS.position).set(fmt_time(0)); R(KEYS.position_val).set(0); P:updateMediaSession({ state = "stopped" }); on_state_change() end)
P:on("error",   function(msg) on_state_change() end)

-- System media buttons
P:onMediaButton(function(action, position)
  if action == "play" then
    if current_song then
      if P.playing then -- already playing, nothing to do
      elseif _ended then _ended = false; play_online_song(current_song)
      else P:resume() end
    end
  elseif action == "pause" then P:pause()
  elseif action == "seek" then if position then P:seek(tonumber(position) or 0) end end
end)

-- ============================================================
-- Playback control
-- ============================================================

local function play_online_song(song)
  if not song then return end
  _ended = false
  P:stop()

  current_song = song
  lyrics = nil

  R(KEYS.title).set(song.name)
  R(KEYS.artists).set(song.artists)
  R(KEYS.album).set(song.album)
  R(KEYS.art_url).set(song.pic_url or "")
  R(KEYS.duration).set(fmt_time(song.duration_ms / 1000))
  R(KEYS.lyric_text).set("")
  R(KEYS.lyric_prev).set("")
  R(KEYS.lyric_next).set("")
  current_duration = song.duration_ms / 1000

  api.get_url(song.id, function(url, err)
    if url then
      api.get_lyric(song.id, function(lrc_text)
        if lrc_text then lyrics = lrc.parse(lrc_text) end
      end)
      P:play(url)
      P:enableMediaSession({
        title    = song.name,
        artist   = song.artists,
        album    = song.album,
        duration = math.floor(current_duration),
      })
    else
      host.toast("Failed to get playback URL")
    end
  end)
end

local function toggle_play_pause()
  if not current_song then host.toast("Please search first"); return end
  if P.playing then P:pause()
  elseif _ended then _ended = false; play_online_song(current_song)
  else P:resume() end
end

local function do_search(keyword)
  if not keyword or keyword == "" then host.toast("Enter a keyword"); return end
  search_results = {}
  R(KEYS.search_info).set("Searching...")
  local rv = state("online.results_version", 0)
  api.search(keyword, function(results, err)
    if results then
      search_results = results
      R(KEYS.search_info).set(#results > 0 and ("Found " .. #results) or "No results")
      rv.set(rv.get() + 1)
    else
      R(KEYS.search_info).set("Failed: " .. (err or "unknown"))
      rv.set(rv.get() + 1)
    end
  end)
end

-- ============================================================
-- Build UI
-- ============================================================

function online.build(ctx)
  R(KEYS.title, "")
  R(KEYS.artists, "")
  R(KEYS.album, "")
  R(KEYS.position, "00:00")
  R(KEYS.position_val, 0)
  R(KEYS.duration, "00:00")
  R(KEYS.duration_val, 0)
  R(KEYS.lyric_text, "")
  R(KEYS.lyric_prev, "")
  R(KEYS.lyric_next, "")
  R(KEYS.playing, false)
  R(KEYS.art_url, "")
  R(KEYS.search_info, "")
  _rebuild = state("online.rebuild", 0)
  _rebuild.get()

  local keyword_st = state("online.keyword", "")
  state("online.results_version", 0)

  local r_playing = R(KEYS.playing)
  local r_art_url = R(KEYS.art_url)

  local seek_max = (P.duration > 0 and P.duration) or (current_duration > 0 and current_duration) or 1

  local function build_results()
    local items = {}
    for _, song in ipairs(search_results) do
      local is_cur = current_song and current_song.id == song.id
      table.insert(items, tile(song.name, {
        subtitle = song.artists .. (song.album ~= "" and (" \194\183 " .. song.album) or ""),
        icon     = is_cur and "play_circle" or "music_note",
        trailing = is_cur and icon("volume_up", { color = "primary", size = 18 }) or nil,
        onTap = function() play_online_song(song) end,
      }))
    end
    if #items == 0 then
      if R(KEYS.search_info).get() == "Searching..." then
        items = { row({ spinner(), spacer(8), text("Searching...", { color = "grey" }) }, { main = "center" }) }
      else
        items = { text("Enter a keyword to search", { color = "grey", align = "center", size = 13 }) }
      end
    end
    return column(items, { gap = 0 })
  end

  local function build_now_playing()
    if not current_song then
      return column({
        divider(), spacer(16),
        center(text("Select a song to play", { color = "grey", size = 14 })),
        spacer(16),
      })
    end

    local art_comp
    local art = r_art_url.get()
    if art ~= "" then art_comp = image(art, { width = 160, height = 160 })
    else art_comp = icon("album", { size = 80, color = "grey" }) end

    local play_btn
    if r_playing.get() then
      play_btn = inkwell(
        icon("pause_circle", { size = 56, color = "primary" }),
        { onTap = toggle_play_pause })
    else
      play_btn = inkwell(
        icon("play_circle", { size = 56, color = "primary" }),
        { onTap = toggle_play_pause })
    end

    return column({
      divider(), spacer(8),
      text("Now Playing", { size = 13, color = "primary", weight = "bold" }),
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
      spacer(12),
      padding(
        row({
          text("", { bind = KEYS.position, size = 11, color = "grey" }),
          spacer(6),
          expanded(slider({
            bind = KEYS.position_val,
            min = 0,
            max = seek_max,
            onChanged = function(v) P:seek(v) end,
          })),
          spacer(6),
          text("", { bind = KEYS.duration, size = 11, color = "grey" }),
        }),
        { h = 0, v = 0 }),
      spacer(4),
      row({ play_btn }, { main = "center" }),
      spacer(8),
      text("\226\148\128\226\148\128 Lyrics \226\148\128\226\148\128", { size = 11, color = "grey", align = "center" }),
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
        hint = "Search songs...",
        value = keyword_st.get(),
        onChanged = function(v) keyword_st.set(v) end,
      })),
      spacer(8),
      iconbutton("search", function() do_search(keyword_st.get()) end, { tooltip = "Search" }),
    }, { gap = 0 }),
    spacer(8),
    text("", { bind = KEYS.search_info, size = 11, color = "grey" }),
    spacer(4),
    build_now_playing(),
    build_results(),
  }, { gap = 0 })
end

function online.dispose()
  P:stop()
  P:disableMediaSession()
end

return online
