local lrc = require("music.lrc")
local P   = host.audio_player("player")

local player = {}

local playlist = {}
local current_index = 0
local music_dir = ""
local current_duration = 0
local lyrics = nil

-- ============================================================
-- Tools
-- ============================================================
local function fmt_time(sec)
  return require("music.lrc").format_time(sec)
end

local AUDIO_EXTS = {
  mp3 = true, flac = true, wav = true, ogg = true,
  m4a = true, aac = true, wma = true, opus = true,
  ape = true, aiff = true, aif = true,
}

local COVER_NAMES = {
  "cover.jpg", "cover.png", "cover.webp",
  "folder.jpg", "folder.png",
  "album.jpg", "album.png",
  "AlbumArt.jpg", "AlbumArt.png",
  "front.jpg", "front.png",
  "Cover.jpg", "Cover.png",
}

local function get_ext(filename)
  local ext = filename:match("%.([^%.]+)$")
  return ext and ext:lower() or ""
end

local function is_audio_file(filename)
  return AUDIO_EXTS[get_ext(filename)] == true
end

local function find_cover_art(music_path)
  local dir = music_path:match("^(.*)/")
  if not dir then return nil end
  for _, name in ipairs(COVER_NAMES) do
    local p = dir .. "/" .. name
    if host.exists(p) then return p end
  end
  return nil
end

local function find_lrc_file(music_path)
  local base = music_path:gsub("%.[^%.]+$", "")
  local p = base .. ".lrc"
  if host.exists(p) then return p end
  p = base .. ".LRC"
  if host.exists(p) then return p end
  return nil
end

-- ============================================================
-- Reactive keys
-- ============================================================
local KEYS = {
  title     = "player.title",
  artist    = "player.artist",
  album     = "player.album",
  position  = "player.position",
  duration  = "player.duration",
  playing   = "player.playing",
  art_path  = "player.art_path",
  lyric_text = "player.lyric_text",
  lyric_prev = "player.lyric_prev",
  lyric_next = "player.lyric_next",
  music_dir = "player.music_dir",
  song_count = "player.song_count",
  backend   = "player.backend",
}

local function R(key, default)
  return reactive(key, default)
end

-- ============================================================
-- Progress/lyrics + page rebuild
-- ============================================================
local _rebuild = nil

P:on("state", function(data)
  local pos = data.position or 0
  local dur = data.duration or 0
  if dur > 0 and dur ~= current_duration then
    current_duration = dur
    R(KEYS.duration).set(fmt_time(dur))
  end
  R(KEYS.position).set(fmt_time(pos))
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

P:on("started", function() push_playing(true);  P:updateMediaSession({ state = "playing" }); on_state_change() end)
P:on("paused",  function() push_playing(false); P:updateMediaSession({ state = "paused" });  on_state_change() end)
P:on("resumed", function() push_playing(true);  P:updateMediaSession({ state = "playing" }); on_state_change() end)
P:on("stopped", function() push_playing(false); R(KEYS.position).set(fmt_time(0)); P:updateMediaSession({ state = "stopped" }); on_state_change() end)
P:on("ended",   function() push_playing(false); R(KEYS.position).set(fmt_time(0)); P:updateMediaSession({ state = "stopped" }); on_state_change() end)
P:on("error",   function(msg) on_state_change() end)

-- System media buttons
P:onMediaButton(function(action, position)
  if action == "play" then
    if #playlist > 0 then
      if current_index == 0 then play_index(1) else P:resume() end
    end
  elseif action == "pause" then P:pause()
  elseif action == "skip_next" then next_song()
  elseif action == "skip_prev" then prev_song()
  elseif action == "seek" then if position then P:seek(tonumber(position) or 0) end end
end)

-- ============================================================
-- Playback control
-- ============================================================

local function play_index(idx)
  if idx < 1 or idx > #playlist then return end
  if current_index > 0 then P:stop() end

  current_index = idx
  local song = playlist[idx]

  current_duration = song.duration or 0
  lyrics = nil

  R(KEYS.title).set(song.title)
  R(KEYS.artist).set(song.artist)
  R(KEYS.album).set(song.album)
  R(KEYS.duration).set(fmt_time(current_duration))
  R(KEYS.lyric_text).set("")
  R(KEYS.lyric_prev).set("")
  R(KEYS.lyric_next).set("")

  local art = song.art_path or find_cover_art(song.path)
  if art then song.art_path = art; R(KEYS.art_path).set(art)
  else R(KEYS.art_path).set("") end

  local lrc_path = song.lrc_path or find_lrc_file(song.path)
  if lrc_path then
    song.lrc_path = lrc_path
    local ok, content = pcall(host.read_file, lrc_path)
    if ok and content then lyrics = lrc.parse(content) end
  end

  P:play(song.path)
  P:enableMediaSession({
    title    = song.title,
    artist   = song.artist,
    album    = song.album,
    duration = current_duration,
  })
end

local function toggle_play_pause()
  if #playlist == 0 then host.toast("\232\175\183\229\133\136\230\137\171\230\143\143\233\159\179\228\185\144\231\155\174\229\189\149"); return end
  if current_index == 0 then play_index(1); return end
  if P.playing then P:pause() else P:resume() end
end

local function next_song()
  if #playlist == 0 then return end
  local idx = current_index + 1
  if idx > #playlist then idx = 1 end
  play_index(idx)
end

local function prev_song()
  if #playlist == 0 then return end
  local idx = current_index - 1
  if idx < 1 then idx = #playlist end
  play_index(idx)
end

-- ============================================================
-- Scan directory
-- ============================================================

local function rescan_and_rebuild()
  if music_dir == "" then return end
  local ok, items = pcall(host.list_dir, music_dir)
  local files = {}
  if ok and items then
    for _, it in ipairs(items) do
      if not it.isDir and is_audio_file(it.name) then
        table.insert(files, {
          path = it.path, name = it.name,
          title = it.name:gsub("%.[^%.]+$", ""),
          artist = "\230\156\170\231\159\165\232\137\186\230\156\175\229\174\182",
          album = "", duration = 0,
          lrc_path = nil, art_path = nil,
        })
      end
    end
  end
  table.sort(files, function(a, b) return a.name < b.name end)

  playlist = files
  current_index = 0; lyrics = nil
  P:stop()

  R(KEYS.song_count).set(#files .. " \233\166\150")

  if #files > 0 then
    for _, song in ipairs(files) do
      song.lrc_path = find_lrc_file(song.path)
      song.art_path = find_cover_art(song.path)
    end
    host.toast("\229\183\178\230\137\171\230\143\143\229\136\176 " .. #files .. " \233\166\150\230\173\140\230\155\178")
  else
    host.toast("\230\156\170\230\137\190\229\136\176\233\159\179\228\185\144\230\150\135\228\187\182")
  end
end

-- ============================================================
-- Build UI
-- ============================================================

function player.build(ctx)
  local r_title     = R(KEYS.title, "\233\128\137\230\139\169\228\184\128\233\166\150\230\173\140\230\155\178")
  local r_artist    = R(KEYS.artist, "")
  local r_album     = R(KEYS.album, "")
  local r_playing   = R(KEYS.playing, false)
  local r_art_path  = R(KEYS.art_path, "")
  local r_music_dir = R(KEYS.music_dir, music_dir)
  R(KEYS.position, "00:00")
  R(KEYS.duration, "00:00")
  R(KEYS.lyric_text, "")
  R(KEYS.lyric_prev, "")
  R(KEYS.lyric_next, "")
  R(KEYS.song_count, "0 \233\166\150")
  R(KEYS.backend, "Love Audio")
  _rebuild = state("player.rebuild", 0)
  _rebuild.get()

  local view_st = state("player.view", "player")

  -- seek slider: read from raw properties (updated on rebuild)
  local seek_max = (P.duration > 0 and P.duration) or (current_duration > 0 and current_duration) or 1
  local seek_val = P.position or 0

  local function build_playlist_view()
    local items = {}
    for i, song in ipairs(playlist) do
      local is_cur = (i == current_index)
      table.insert(items, tile(song.title, {
        subtitle = song.artist .. (song.album ~= "" and (" \194\183 " .. song.album) or ""),
        icon     = is_cur and "play_circle" or "music_note",
        trailing = is_cur and icon("volume_up", { color = "primary", size = 18 }) or nil,
        onTap = function() play_index(i); view_st.set("player") end,
      }))
    end
    if #items == 0 then
      items = {
        text("\230\146\173\230\148\190\229\136\151\232\161\168\228\184\186\231\169\186", { color = "grey", align = "center" }),
        text("\232\175\183\229\133\136\230\137\171\230\143\143\233\159\179\228\185\144\231\155\174\229\189\149", { color = "grey", align = "center", size = 13 }),
      }
    end
    return column(items, { gap = 0 })
  end

  local function build_player_view()
    local has_song = (current_index > 0 and #playlist > 0)

    local art_comp
    if r_art_path.get() ~= "" then
      art_comp = image(r_art_path.get(), { width = 240, height = 240 })
    else
      art_comp = icon("album", { size = 120, color = "grey" })
    end

    local play_pause_btn
    if r_playing.get() then
      play_pause_btn = inkwell(
        icon("pause_circle", { size = 56, color = "primary" }),
        { onTap = toggle_play_pause })
    else
      play_pause_btn = inkwell(
        icon("play_circle", { size = 56, color = "primary" }),
        { onTap = toggle_play_pause })
    end

    local lyrics_section
    if has_song then
      lyrics_section = column({
        divider(), spacer(6),
        text("\226\148\128\226\148\128 \230\173\140\232\175\141 \226\148\128\226\148\128", { size = 12, color = "grey", align = "center" }),
        spacer(6),
        text("", { bind = KEYS.lyric_prev, size = 13, color = "grey", align = "center", maxLines = 1, ellipsis = true }),
        spacer(4),
        text("", { bind = KEYS.lyric_text, size = 16, color = "primary", weight = "bold", align = "center", maxLines = 1, ellipsis = true }),
        spacer(4),
        text("", { bind = KEYS.lyric_next, size = 13, color = "grey", align = "center", maxLines = 1, ellipsis = true }),
        spacer(8),
      }, { gap = 0 })
    else
      lyrics_section = column({
        divider(), spacer(20),
        text("\230\154\130\230\151\160\230\173\140\232\175\141", { size = 13, color = "grey", align = "center" }),
        spacer(20),
      })
    end

    return column({
      center(card({ padding(center(art_comp), 16) })),
      spacer(8),
      center(column({
        text("", { bind = KEYS.title, size = 18, weight = "bold", align = "center", maxLines = 1, ellipsis = true }),
        spacer(2),
        row({
          text("", { bind = KEYS.artist, size = 14, color = "grey", maxLines = 1, ellipsis = true }),
          text("", { bind = KEYS.album,  size = 14, color = "grey", maxLines = 1, ellipsis = true }),
        }, { main = "center", gap = 8 }),
      }, { gap = 0 })),
      spacer(16),
      padding(
        row({
          text("", { bind = KEYS.position, size = 11, color = "grey" }),
          spacer(6),
          expanded(slider({
            value = seek_val,
            min = 0,
            max = seek_max,
            onChanged = function(v) P:seek(v) end,
          })),
          spacer(6),
          text("", { bind = KEYS.duration, size = 11, color = "grey" }),
        }),
        { h = 0, v = 0 }),
      spacer(4),
      row({
        iconbutton("skip_previous", prev_song, { tooltip = "\228\184\138\228\184\128\233\166\150", color = "grey" }),
        spacer(20),
        play_pause_btn,
        spacer(20),
        iconbutton("skip_next", next_song, { tooltip = "\228\184\139\228\184\128\233\166\150", color = "grey" }),
      }, { main = "center" }),
      spacer(4),
      lyrics_section,
    }, { gap = 0 })
  end

  local top_bar = row({
    iconbutton("folder_open", function()
      host.input({
        title = "\232\174\190\231\189\174\233\159\179\228\185\144\231\155\174\229\189\149",
        hint = "/storage/emulated/0/Music",
        default = music_dir ~= "" and music_dir or "/storage/emulated/0/Music",
      }, function(path)
        if path and path ~= "" then
          music_dir = path
          r_music_dir.set(path)
          rescan_and_rebuild()
        end
      end)
    end, { tooltip = "\232\174\190\231\189\174\233\159\179\228\185\144\231\155\174\229\189\149" }),
    expanded(column({
      text("\233\159\179\228\185\144\230\146\173\230\148\190\229\153\168", { size = 18, weight = "bold" }),
      text("", { bind = KEYS.song_count, size = 11, color = "grey" }),
    }, { gap = 0 })),
    function()
      if view_st.get() == "player" then
        return iconbutton("queue_music", function() view_st.set("playlist") end, { tooltip = "\230\146\173\230\148\190\229\136\151\232\161\168" })
      else
        return iconbutton("album", function() view_st.set("player") end, { tooltip = "\230\173\163\229\156\168\230\146\173\230\148\190" })
      end
    end,
  }, { gap = 8 })

  if view_st.get() == "player" then
    return column({ top_bar, divider(), build_player_view() }, { gap = 0 })
  else
    return column({
      top_bar, divider(),
      text("", { bind = KEYS.music_dir, size = 11, color = "grey" }),
      spacer(4),
      function()
        if music_dir == "" then
          return button("\232\174\190\231\189\174\233\159\179\228\185\144\231\155\174\229\189\149", function()
            host.input({
              title = "\233\159\179\228\185\144\231\155\174\229\189\149\232\183\175\229\190\132",
              hint = "/storage/emulated/0/Music",
              default = "/storage/emulated/0/Music",
            }, function(path)
              if path and path ~= "" then music_dir = path; r_music_dir.set(path); rescan_and_rebuild() end
            end)
          end, { variant = "outlined", icon = "folder_open" })
        else
          return row({
            expanded(text(music_dir, { size = 12, color = "grey", maxLines = 1, ellipsis = true })),
            button("\233\135\141\230\150\176\230\137\171\230\143\143", rescan_and_rebuild, { variant = "tonal", icon = "refresh" }),
          })
        end
      end,
      spacer(8),
      build_playlist_view(),
    }, { gap = 0 })
  end
end

function player.dispose()
  if current_index > 0 then P:stop() end
  P:disableMediaSession()
end

return player
