-- 同级目录字幕智能自动加载。
-- 仅在 sub-auto=no 时运行；其他 sub-auto 模式交由 mpv 原生规则处理。

local mp = require("mp")
local utils = require("mp.utils")
local script_options = require("mp.options")

local options = {
  enabled = true,
  show_osd = true,
  extensions = "ass,ssa,srt,vtt,sub,idx,sup,pgs",
  minimum_score_gap = 10,
}
script_options.read_options(options, "episode_sub_autoload")

local FORMAT_BONUS = {
  ass = 8,
  ssa = 7,
  srt = 6,
  vtt = 5,
  idx = 4,
  sup = 3,
  pgs = 2,
  sub = 1,
}

local NOISE_TOKENS = {
  aac = true,
  ac3 = true,
  atmos = true,
  av1 = true,
  bdrip = true,
  bluray = true,
  brrip = true,
  cam = true,
  ddp = true,
  dv = true,
  dts = true,
  dtsma = true,
  dual = true,
  dub = true,
  extended = true,
  hevc = true,
  hdr = true,
  hdr10 = true,
  flac = true,
  h264 = true,
  h265 = true,
  hdtv = true,
  opus = true,
  proper = true,
  repack = true,
  remux = true,
  truehd = true,
  rip = true,
  uhd = true,
  web = true,
  webdl = true,
  webmux = true,
  webrip = true,
  x264 = true,
  x265 = true,
}

local LANGUAGE_ALIASES = {
  zh = "zh",
  chs = "zh",
  cht = "zh",
  chi = "zh",
  zho = "zh",
  sc = "zh",
  cn = "zh",
  tw = "zh",
  hk = "zh",
  ["zh-cn"] = "zh",
  ["zh-tw"] = "zh",
  ["zh-hans"] = "zh",
  ["zh-hant"] = "zh",
  en = "en",
  eng = "en",
  english = "en",
  ja = "ja",
  jpn = "ja",
  japanese = "ja",
  ko = "ko",
  kor = "ko",
  korean = "ko",
  fr = "fr",
  fra = "fr",
  fre = "fr",
  french = "fr",
  de = "de",
  deu = "de",
  ger = "de",
  german = "de",
  es = "es",
  spa = "es",
  spanish = "es",
  pt = "pt",
  por = "pt",
  portuguese = "pt",
  ru = "ru",
  rus = "ru",
  russian = "ru",
  it = "it",
  ita = "it",
  italian = "it",
}

local processed_path = nil

local function is_protocol(path)
  return type(path) == "string" and (path:find("^%a[%w.+-]-://") ~= nil or path:find("^%a[%w.+-]-:%?") ~= nil)
end

local function normalize_path(path)
  local ok, normalized = pcall(mp.command_native, { "normalize-path", path })
  if ok and type(normalized) == "string" and normalized ~= "" then
    return normalized
  end
  return path
end

local function get_extension(filename)
  local extension = filename:match("%.([^.]+)$")
  return extension and extension:lower() or ""
end

local function remove_extension(filename)
  return filename:gsub("%.[^.]+$", "")
end

local function split_csv(value)
  local values = {}
  for item in tostring(value or ""):gmatch("[^,]+") do
    item = item:match("^%s*(.-)%s*$"):lower()
    if item ~= "" then
      values[item] = true
    end
  end
  return values
end

local function is_supported_subtitle(filename, extensions)
  return extensions[get_extension(filename)] == true
end

local function is_language_token(token)
  return LANGUAGE_ALIASES[token] ~= nil
end

local function is_resolution_token(token)
  return token:match("^%d+[pi]$") ~= nil or token:match("^%d%d%d+%dx%d%d%d+$") ~= nil
end

local function tokenized_name(stem)
  local text = tostring(stem or ""):lower()
  -- 仅替换 ASCII 分隔符，保留中文及其他 UTF-8 标题字符。
  text = text:gsub("[%s%._%-%[%]%(%)%{%},;:!%?%+~]+", " ")

  local tokens = {}
  for token in text:gmatch("%S+") do
    tokens[#tokens + 1] = token
  end
  return tokens
end

local function is_episode_token(token)
  return token:match("^s%d+e%d+$") ~= nil
      or token:match("^s%d+ep%d+$") ~= nil
      -- 仅将小范围的 N×N 形式看作“季x集”；1920x1080 等分辨率不是集号。
      or (not is_resolution_token(token) and token:match("^%d%d?x%d%d?%d?$") ~= nil)
      or token:match("^ep%d+$") ~= nil
      or token:match("^e%d+$") ~= nil
      or token:match("^第%d+集$") ~= nil
      or token == "episode"
      or token == "ep"
      or token == "e"
      or token == "第"
      or token == "集"
end

local function build_match_key(stem)
  local kept = {}
  for _, token in ipairs(tokenized_name(stem)) do
    local is_resolution = is_resolution_token(token)
    local is_bit_depth = token:match("^%d+bit$") ~= nil
    if not NOISE_TOKENS[token] and not is_language_token(token) and not is_resolution and not is_bit_depth then
      kept[#kept + 1] = token
    end
  end
  return table.concat(kept, " ")
end

local function build_title_tokens(stem)
  local result = {}
  local seen = {}
  for _, token in ipairs(tokenized_name(stem)) do
    local is_number = token:match("^%d+$") ~= nil
    local is_resolution = is_resolution_token(token)
    local is_bit_depth = token:match("^%d+bit$") ~= nil
    if
        not NOISE_TOKENS[token]
        and not is_language_token(token)
        and not is_episode_token(token)
        and not is_number
        and not is_resolution
        and not is_bit_depth
        and not seen[token]
    then
      seen[token] = true
      result[#result + 1] = token
    end
  end
  return result
end

local function make_episode(season, first, last)
  season = season and tonumber(season) or nil
  first = tonumber(first)
  last = last and tonumber(last) or first
  if not first or not last or first < 0 or last < first or last > 999 then
    return nil
  end
  if season and (season < 0 or season > 99) then
    return nil
  end
  return { season = season, first = first, last = last }
end

local function parse_episode(stem)
  local text = tostring(stem or ""):lower()
  -- range 保留连字符，普通格式则移除所有常见分隔符。
  local ranged = text:gsub("[%s%._%[%]%(%)%{%},;:!%?%+]+", "")
  local compact = ranged:gsub("[%-~]", "")
  local season, first, last

  season, first, last = ranged:match("s(%d+)e(%d+)[%-~]e(%d+)")
  if not season then
    season, first, last = ranged:match("s(%d+)e(%d+)[%-~](%d+)")
  end
  if not season then
    season, first, last = ranged:match("s(%d+)ep(%d+)[%-~]ep(%d+)")
  end
  if not season then
    season, first, last = ranged:match("s(%d+)ep(%d+)[%-~](%d+)")
  end
  if season then
    local parsed = make_episode(season, first, last)
    if parsed then
      return parsed
    end
  end

  season, first, last = ranged:match("(%d+)x(%d+)[%-~](%d+)")
  if season then
    local parsed = make_episode(season, first, last)
    if parsed then
      return parsed
    end
  end

  season, first = compact:match("s(%d+)e(%d+)")
  if not season then
    season, first = compact:match("s(%d+)ep(%d+)")
  end
  if not season then
    season, first = compact:match("(%d+)x(%d+)")
  end
  if season then
    local parsed = make_episode(season, first)
    if parsed then
      return parsed
    end
  end

  first, last = text:match("第%s*(%d+)%s*[%-~到至]%s*第?%s*(%d+)%s*集")
  if first then
    return make_episode(nil, first, last)
  end
  first = text:match("第%s*(%d+)%s*集")
  if first then
    return make_episode(nil, first)
  end

  local range_spaced = " " .. text:gsub("[%s%._%[%]%(%)%{%},;:!%?%+]+", " ") .. " "
  first, last = range_spaced:match("%f[%a]episode%s*(%d+)%s*[%-%~]%s*(%d+)")
  if first then
    return make_episode(nil, first, last)
  end
  first, last = range_spaced:match("%f[%a]ep%s*(%d+)%s*[%-%~]%s*(%d+)")
  if first then
    return make_episode(nil, first, last)
  end
  local spaced = " " .. text:gsub("[%s%._%-%[%]%(%)%{%},;:!%?%+~]+", " ") .. " "
  first = spaced:match("%f[%a]episode%s*(%d+)") or spaced:match("%f[%a]ep%s*(%d+)") or spaced:match("%f[%a]e%s*(%d+)")
  if first then
    return make_episode(nil, first)
  end

  local bare = nil
  for _, token in ipairs(tokenized_name(stem)) do
    if token:match("^%d%d?%d?$") then
      if bare ~= nil then
        return nil
      end
      bare = token
    end
  end
  return bare and make_episode(nil, bare) or nil
end

local function episodes_match(video_episode, subtitle_episode)
  if not video_episode or not subtitle_episode then
    return nil
  end
  if video_episode.season and subtitle_episode.season and video_episode.season ~= subtitle_episode.season then
    return nil
  end
  if math.max(video_episode.first, subtitle_episode.first) > math.min(video_episode.last, subtitle_episode.last) then
    return nil
  end
  if video_episode.season and subtitle_episode.season then
    return 70
  elseif video_episode.season or subtitle_episode.season then
    return 60
  end
  return 55
end

local function direct_name_score(video_key, subtitle_key)
  if video_key == "" or subtitle_key == "" then
    return nil
  end
  if video_key == subtitle_key then
    return 100, "同名"
  end
  if #video_key >= 6 and subtitle_key:find(video_key, 1, true) then
    return 85, "同名扩展"
  end
  return nil
end

local function title_similarity(video_tokens, subtitle_tokens)
  if #video_tokens == 0 or #subtitle_tokens == 0 then
    return 0
  end
  local lookup = {}
  for _, token in ipairs(video_tokens) do
    lookup[token] = true
  end
  local common = 0
  for _, token in ipairs(subtitle_tokens) do
    if lookup[token] then
      common = common + 1
    end
  end
  return math.floor((20 * common) / math.max(#video_tokens, #subtitle_tokens))
end

local function add_language(list, seen, language)
  if language and not seen[language] then
    seen[language] = true
    list[#list + 1] = language
  end
end

local function detect_languages(stem)
  local text = tostring(stem or ""):lower()
  local result, seen = {}, {}
  if
      text:find("简中", 1, true)
      or text:find("简体", 1, true)
      or text:find("繁中", 1, true)
      or text:find("繁体", 1, true)
      or text:find("中文字幕", 1, true)
  then
    add_language(result, seen, "zh")
  end
  for _, token in ipairs(tokenized_name(text)) do
    add_language(result, seen, LANGUAGE_ALIASES[token])
  end
  return result
end

local function preferred_languages()
  local result, seen = {}, {}
  for item in tostring(mp.get_property("options/slang", "") or ""):gmatch("[^,]+") do
    local token = item:match("^%s*(.-)%s*$"):lower()
    add_language(result, seen, LANGUAGE_ALIASES[token] or token)
  end
  return result
end

local function language_bonus(candidate_languages, preferred)
  for rank, wanted in ipairs(preferred) do
    for _, available in ipairs(candidate_languages) do
      if wanted == available then
        -- 语言优先级需要足以跨过默认分差阈值，否则中英两个同集字幕会被误判为歧义。
        return math.max(10, 50 - (rank - 1) * 15)
      end
    end
  end
  return 0
end

local function has_subtitle_track()
  local tracks = mp.get_property_native("track-list", {})
  for _, track in ipairs(tracks or {}) do
    if track.type == "sub" then
      return true
    end
  end
  return false
end

local function get_current_local_file()
  local path = mp.get_property("path", "")
  if path == "" or is_protocol(path) then
    return nil
  end
  path = normalize_path(path)
  local info = utils.file_info(path)
  if not info or not info.is_file then
    return nil
  end
  local directory, filename = utils.split_path(path)
  if not directory or directory == "" or not filename or filename == "" then
    return nil
  end
  return path, directory:gsub("[/\\]+$", ""), filename
end

local function find_candidates(directory, video_filename)
  local extensions = split_csv(options.extensions)
  local files, error = utils.readdir(directory, "files")
  if not files then
    return {}, error or "无法读取目录"
  end
  table.sort(files, function(left, right)
    return left:lower() < right:lower()
  end)

  local present = {}
  for _, filename in ipairs(files) do
    present[filename:lower()] = true
  end

  local video_stem = remove_extension(video_filename)
  local video_key = build_match_key(video_stem)
  local video_title = build_title_tokens(video_stem)
  local video_episode = parse_episode(video_stem)
  local preferred = preferred_languages()
  local candidates = {}

  for _, filename in ipairs(files) do
    local extension = get_extension(filename)
    local stem = remove_extension(filename)
    local paired_idx = extension == "sub" and present[(stem .. ".idx"):lower()]
    if is_supported_subtitle(filename, extensions) and not paired_idx then
      local subtitle_key = build_match_key(stem)
      local base, reason = direct_name_score(video_key, subtitle_key)
      local episode_score = episodes_match(video_episode, parse_episode(stem))
      if not base and episode_score then
        base, reason = episode_score, "集号"
      end
      if base then
        local languages = detect_languages(stem)
        local similarity = title_similarity(video_title, build_title_tokens(stem))
        local score = base + similarity + language_bonus(languages, preferred) + (FORMAT_BONUS[extension] or 0)
        candidates[#candidates + 1] = {
          filename = filename,
          path = utils.join_path(directory, filename),
          reason = reason,
          score = score,
        }
      end
    end
  end
  return candidates
end

local function show_message(message)
  mp.msg.info(message)
  if options.show_osd then
    mp.osd_message(message, 3)
  end
end

local function process_current_file()
  if not options.enabled then
    return
  end
  local sub_auto = (mp.get_property("options/sub-auto", "no") or "no"):lower()
  if sub_auto ~= "no" then
    mp.msg.verbose("sub-auto=" .. sub_auto .. "，跳过智能字幕匹配并使用 mpv 原生规则")
    return
  end
  local path, directory, filename = get_current_local_file()
  if not path then
    mp.msg.verbose("字幕自动加载仅处理本地文件")
    return
  end
  if processed_path == path then
    return
  end
  processed_path = path
  mp.msg.verbose("开始扫描同级字幕: " .. filename)

  if has_subtitle_track() then
    mp.msg.verbose("当前视频已有字幕轨，跳过自动字幕匹配: " .. filename)
    return
  end

  local candidates, error = find_candidates(directory, filename)
  if #candidates == 0 then
    show_message("未找到匹配字幕")
    if error then
      mp.msg.warn("字幕目录扫描失败: " .. tostring(error))
    end
    return
  end

  table.sort(candidates, function(left, right)
    if left.score ~= right.score then
      return left.score > right.score
    end
    return left.filename:lower() < right.filename:lower()
  end)

  local best = candidates[1]
  local next_best = candidates[2]
  local minimum_gap = math.max(0, tonumber(options.minimum_score_gap) or 10)
  if next_best and best.score - next_best.score < minimum_gap then
    show_message("未找到唯一匹配的字幕")
    mp.msg.info(
      string.format(
        "字幕候选分差不足: %s (%d) / %s (%d)",
        best.filename,
        best.score,
        next_best.filename,
        next_best.score
      )
    )
    return
  end

  local ok, command_result, command_error = pcall(mp.commandv, "sub-add", best.path, "select", best.filename)
  if not ok or command_result == nil then
    show_message("加载字幕失败")
    mp.msg.error("无法加载字幕 " .. best.path .. ": " .. tostring(ok and command_error or command_result))
    return
  end
  show_message("已自动加载字幕：" .. best.filename)
  mp.msg.info(string.format("已按%s匹配字幕: %s (得分 %d)", best.reason, best.path, best.score))
end

mp.register_event("start-file", function()
  processed_path = nil
end)

mp.register_event("file-loaded", process_current_file)

mp.msg.info("正在运行 同级字幕智能自动加载")
