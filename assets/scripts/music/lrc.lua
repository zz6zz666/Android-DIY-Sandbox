-- lrc.lua
-- LRC 歌词解析工具。支持标准 [mm:ss.xx] 格式、多时间戳行、ID 标签。

local lrc = {}

--- 将秒数格式化为 mm:ss
function lrc.format_time(sec)
  sec = tonumber(sec) or 0
  local m = math.floor(sec / 60)
  local s = math.floor(sec % 60)
  return string.format("%02d:%02d", m, s)
end

--- 解析 LRC 文本内容，返回按时间排序的歌词数组 { {time=秒, text="歌词"}, ... }
--- @param content string LRC 文件文本内容
--- @return table 歌词行数组
function lrc.parse(content)
  local lyrics = {}
  if not content or content == "" then
    return lyrics
  end

  for line in content:gmatch("[^\r\n]+") do
    -- 提取该行所有时间戳 [mm:ss.xx] 或 [mm:ss]
    local timestamps = {}
    for mm, ss in line:gmatch("%[(%d+):(%d+%.?%d*)%]") do
      local t = tonumber(mm) * 60 + tonumber(ss)
      table.insert(timestamps, t)
    end

    -- 跳过无时间戳的行 (ID 标签如 [ti:], [ar:], [al:], [offset:] 等)
    if #timestamps > 0 then
      -- 去掉所有时间戳标记得到歌词文本
      local text = line:gsub("%[%d+:%d+%.?%d*%]", "")
      -- 去掉首尾空白
      text = text:match("^%s*(.-)%s*$")
      if text ~= "" then
        for _, t in ipairs(timestamps) do
          table.insert(lyrics, { time = t, text = text })
        end
      end
    end
  end

  -- 按时间升序排列
  table.sort(lyrics, function(a, b) return a.time < b.time end)

  return lyrics
end

--- 根据当前播放位置（秒）查找应显示的歌词行索引
--- @param lyrics table lrc.parse 返回的数组
--- @param position_sec number 当前播放时间（秒）
--- @return number|nil 当前歌词行索引 (1-based)，找不到返回 nil
function lrc.find_index(lyrics, position_sec)
  if not lyrics or #lyrics == 0 then
    return nil
  end
  local idx = nil
  -- 从后往前找第一个 time <= position_sec 的行
  for i = #lyrics, 1, -1 do
    if lyrics[i].time <= position_sec then
      idx = i
      break
    end
  end
  return idx
end

--- 获取当前歌词行附近的行（用于滚动显示）
--- @param lyrics table
--- @param current_index number|nil 当前行索引
--- @param before number 前行数
--- @param after number 后行数
--- @return table { {text, active}, ... } 含 active 标记的歌词行
function lrc.get_visible(lyrics, current_index, before, after)
  before = before or 3
  after = after or 3
  local result = {}

  if not lyrics or #lyrics == 0 then
    return result
  end

  local start_idx = math.max(1, (current_index or 1) - before)
  local end_idx = math.min(#lyrics, (current_index or 1) + after)

  for i = start_idx, end_idx do
    table.insert(result, {
      text  = lyrics[i].text,
      time  = lyrics[i].time,
      active = (i == current_index),
      index = i,
    })
  end

  return result
end

return lrc