-- api_music.lua
-- 网易云音乐 API 封装 (基于 BugPk API 代理)
-- 接口文档: https://api.bugpk.com/api/163_music
-- 支持: search / url / lyric / song

local api = {}

-- API 基础 URL，可通过 host.set("api_base_url", ...) 覆盖
api.DEFAULT_BASE = "https://api.bugpk.com/api/163_music"

local function base_url()
  return host.get("api_base_url") or api.DEFAULT_BASE
end

--- 发送 GET 请求
local function get(params, callback)
  -- 拼接 query string
  local parts = {}
  for k, v in pairs(params) do
    table.insert(parts, k .. "=" .. host.url_encode(tostring(v)))
  end
  local url = base_url() .. "?" .. table.concat(parts, "&")

  host.http{
    url     = url,
    method  = "GET",
    timeout = 15,
    on_done = function(res)
      if res.ok and res.body then
        local ok, data = pcall(json.decode, res.body)
        if ok and data then
          if data.code == 200 then
            callback(data.data, nil)
          else
            callback(nil, data.msg or "API 返回错误")
          end
        else
          callback(nil, "JSON 解析失败")
        end
      else
        callback(nil, "网络请求失败 (HTTP " .. tostring(res.status) .. ")")
      end
    end,
    on_error = function(err)
      callback(nil, "网络错误: " .. tostring(err))
    end,
  }
end

--- 搜索歌曲
--- @param keyword string 搜索关键词
--- @param callback function(songs, err)
---   songs = {{id, name, artists, album, picUrl, duration_ms}, ...}
function api.search(keyword, callback)
  get({ type = "search", s = keyword }, function(data, err)
    if data and data.songs then
      -- 标准化字段
      local songs = {}
      for _, s in ipairs(data.songs) do
        table.insert(songs, {
          id          = s.id,
          name        = s.name,
          artists     = s.artists or "",
          album       = s.album  or "",
          pic_url     = s.picUrl  or "",
          duration_ms = s.duration or 0,
        })
      end
      callback(songs, nil)
    else
      callback(nil, err or "搜索无结果")
    end
  end)
end

--- 获取歌曲播放链接
--- @param song_id number 歌曲 ID
--- @param callback function(url, err) url 为可直接播放的 mp3 链接
function api.get_url(song_id, callback)
  get({ type = "url", id = tostring(song_id) }, function(data, err)
    if data and #data > 0 then
      callback(data[1].url, nil)
    else
      callback(nil, err or "获取播放链接失败")
    end
  end)
end

--- 获取歌词 (LRC)
--- @param song_id number 歌曲 ID
--- @param callback function(lrc_text, err)
function api.get_lyric(song_id, callback)
  get({ type = "lyric", id = tostring(song_id) }, function(data, err)
    if data and data.lrc then
      callback(data.lrc, nil)
    else
      callback(nil, err or "暂无歌词")
    end
  end)
end

--- 获取歌曲详情
--- @param song_id number 歌曲 ID
--- @param callback function(detail, err) detail = {id, name, album, singer, picimg}
function api.get_detail(song_id, callback)
  get({ type = "song", id = tostring(song_id) }, function(data, err)
    if data then
      callback({
        id      = data.id,
        name    = data.name,
        album   = data.album  or "",
        singer  = data.singer or "",
        pic_img = data.picimg or "",
      }, nil)
    else
      callback(nil, err or "获取歌曲详情失败")
    end
  end)
end

return api