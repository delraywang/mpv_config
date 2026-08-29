-- uosc_danmaku 的排序弹幕合并扩展。
--
-- 本文件在原核心加载完成后执行：它不修改核心目录中的实现，而是包装
-- convert_danmaku_to_ass_events()，在传给原转换器前临时提供 latest 视图。

local mp = require("mp")
local msg = require("mp.msg")
local mp_options = require("mp.options")
local mp_utils = require("mp.utils")

local M = {}
DANMAKU_MERGE_EXTENSION = M
DANMAKU_CACHE = DANMAKU_CACHE or {}
DANMAKU_MERGED = DANMAKU_MERGED or {}

local RULE_VERSION = "1"
local DEFAULT_TIME_WINDOW = 5
local DEFAULT_MERGED_DISPLAY_TIME = 20
local DEFAULT_SUBTITLE_EXTRA_HEIGHT = 10
local RENDER_WIDTH = 1920
local RENDER_HEIGHT = 1080
local MERGED_HORIZONTAL_MARGIN = 40
local MERGED_VERTICAL_MARGIN = 24
local MERGED_SUBTITLE_GAP = 24
-- 为合成弹幕预留可见字幕的占用区域，避免与主/副字幕重叠。
local MERGED_AVOID_SUBTITLES = true

local extension_options = {
    log_success = true,
    merge_time_window = DEFAULT_TIME_WINDOW,
    merged_display_time = DEFAULT_MERGED_DISPLAY_TIME,
    merged_render_color = "",
    merged_subtitle_extra_height = DEFAULT_SUBTITLE_EXTRA_HEIGHT,
}

-- 此配置名不能依赖 mp.get_script_name()：入口脚本仍叫 uosc_danmaku。
mp_options.read_options(extension_options, "danmaku_merge_extension")

local original_convert = convert_danmaku_to_ass_events
if type(original_convert) ~= "function" then
    error("danmaku_merge_extension: convert_danmaku_to_ass_events is unavailable")
end

local last_logged_fingerprint = nil
local last_danmaku_table = nil

local function sorted_keys(tbl)
    local keys = {}
    for key in pairs(tbl or {}) do
        keys[#keys + 1] = key
    end
    table.sort(keys, function(a, b)
        return tostring(a) < tostring(b)
    end)
    return keys
end

local function clone_value(value, seen)
    if type(value) ~= "table" then
        return value
    end

    seen = seen or {}
    if seen[value] then
        return seen[value]
    end

    local copy = {}
    seen[value] = copy
    for key, item in pairs(value) do
        copy[clone_value(key, seen)] = clone_value(item, seen)
    end
    local metatable = getmetatable(value)
    if metatable then
        setmetatable(copy, metatable)
    end
    return copy
end

local function clone_item(item)
    if type(item) ~= "table" then
        error("danmaku item is not a table")
    end
    return clone_value(item)
end

-- 复制所有未知源元数据，只有 data 由调用方单独处理。
local function clone_source_metadata(source)
    if type(source) ~= "table" then
        error("danmaku source is not a table")
    end

    local copy = {}
    local seen = {}
    for key, value in pairs(source) do
        if key ~= "data" then
            copy[clone_value(key, seen)] = clone_value(value, seen)
        end
    end
    return copy
end

local function make_item_id(source_url, source_index)
    return tostring(source_url) .. "\0" .. tostring(source_index)
end

local function clone_sources_for_processing(sources)
    local working_sources = {}
    for _, source_url in ipairs(sorted_keys(sources)) do
        local source = sources[source_url]
        local copied_source = clone_source_metadata(source)

        if source.data == nil then
            copied_source.data = nil
        else
            if type(source.data) ~= "table" then
                error("source.data is not a table: " .. tostring(source_url))
            end
            copied_source.data = {}
            for source_index = 1, #source.data do
                local original_item = source.data[source_index]
                local item = clone_item(original_item)
                item.source = source_url
                item.source_index = source_index
                item.item_id = make_item_id(source_url, source_index)
                copied_source.data[source_index] = item
            end
        end

        working_sources[source_url] = copied_source
    end
    return working_sources
end

-- 用于交给原转换器的视图。这里不写 item_id，也不让任何副本共享原始对象。
local function clone_sources_view(sources)
    local view = {}
    for _, source_url in ipairs(sorted_keys(sources)) do
        local source = sources[source_url]
        local copied_source = clone_source_metadata(source)
        if source.data == nil then
            copied_source.data = nil
        else
            if type(source.data) ~= "table" then
                error("source.data is not a table: " .. tostring(source_url))
            end
            copied_source.data = {}
            for source_index = 1, #source.data do
                copied_source.data[source_index] = clone_item(source.data[source_index])
            end
        end
        view[source_url] = copied_source
    end
    return view
end

local function clone_sources_compatible(sources, data_kind)
    local result = {}
    for _, source_url in ipairs(sorted_keys(sources)) do
        local source = sources[source_url]
        local copied_source = clone_source_metadata(source)
        copied_source.generated_by = "danmaku_merge_extension"
        copied_source.data_kind = data_kind
        copied_source.data = {}
        result[source_url] = copied_source
    end
    return result
end

local function finite_number(value)
    local number = tonumber(value)
    if not number or number ~= number or number == math.huge or number == -math.huge then
        return nil
    end
    return number
end

local function get_item_time(item)
    return finite_number(item.orig_time ~= nil and item.orig_time or item.time)
end

-- 使用 mpv 的默认播放时间轴格式（HH:MM:SS），不依赖 uosc 的全局工具函数。
local function format_playback_time(value)
    local seconds = finite_number(value)
    if not seconds then
        return "00:00:00"
    end
    return mp.format_time(seconds)
end

local function get_merge_time_window()
    local value = finite_number(extension_options.merge_time_window)
    if not value or value < 0 then
        return DEFAULT_TIME_WINDOW
    end
    return value
end

local function get_merged_display_time()
    local value = finite_number(extension_options.merged_display_time)
    if not value or value <= 0 then
        return DEFAULT_MERGED_DISPLAY_TIME
    end
    return value
end

-- 空值表示保留每条合成项原本的颜色。支持 #RRGGBB、RRGGBB、0xRRGGBB
-- 以及十进制 RGB 整数；非法配置安全回退到原始颜色。
local function get_merged_render_color()
    local raw = extension_options.merged_render_color
    if type(raw) ~= "string" then
        return nil
    end
    raw = raw:match("^%s*(.-)%s*$") or ""
    if raw == "" then
        return nil
    end

    local value
    if raw:match("^%d+$") then
        value = tonumber(raw)
    else
        raw = raw:gsub("^#", ""):gsub("^0[xX]", "")
        if raw:match("^[%x]+$") and #raw == 6 then
            value = tonumber(raw, 16)
        end
    end
    if not value or value < 0 or value > 0xFFFFFF or value % 1 ~= 0 then
        return nil
    end
    return value
end

local function get_merged_subtitle_extra_height()
    local value = finite_number(extension_options.merged_subtitle_extra_height)
    if value == nil or value < 0 then
        return DEFAULT_SUBTITLE_EXTRA_HEIGHT
    end
    return value
end

local function option_enabled(value, default_value)
    if type(value) == "boolean" then
        return value
    end
    if type(value) == "string" then
        local normalized = value:lower()
        if normalized == "yes" or normalized == "true" or normalized == "1" then
            return true
        end
        if normalized == "no" or normalized == "false" or normalized == "0" then
            return false
        end
    end
    return default_value
end

local chinese_digits = {
    [1] = "一", [2] = "二", [3] = "三", [4] = "四", [5] = "五",
    [6] = "六", [7] = "七", [8] = "八", [9] = "九",
}

local chinese_order_to_number = {}
local function chinese_order_text(number)
    if number < 10 then
        return chinese_digits[number]
    end
    if number == 10 then
        return "十"
    end
    local tens = math.floor(number / 10)
    local ones = number % 10
    local prefix = chinese_digits[tens] .. "十"
    return ones == 0 and prefix or prefix .. chinese_digits[ones]
end

for number = 1, 99 do
    chinese_order_to_number[chinese_order_text(number)] = number
end

local chinese_numeric_characters = {
    ["一"] = true, ["二"] = true, ["三"] = true, ["四"] = true, ["五"] = true,
    ["六"] = true, ["七"] = true, ["八"] = true, ["九"] = true, ["十"] = true,
}

local function utf8_character_at(text, position)
    local first = text:byte(position)
    if not first then
        return nil, position
    end
    local length = 1
    if first >= 0xF0 and first <= 0xF7 then
        length = 4
    elseif first >= 0xE0 and first <= 0xEF then
        length = 3
    elseif first >= 0xC0 and first <= 0xDF then
        length = 2
    end
    return text:sub(position, position + length - 1), position + length
end

local separators = {
    "：", "．", "、", "，", "；", "！", "？", "－", "—",
    ":", ".", ",", ";", "!", "?", "-",
}

local function starts_with(text, prefix)
    return text:sub(1, #prefix) == prefix
end

-- 返回实际标点和去掉普通分隔空白后的正文；空标点用 nil 表示。
local function extract_separator(rest)
    local remainder = (rest or ""):gsub("^%s+", "")
    local separator = nil
    for _, candidate in ipairs(separators) do
        if starts_with(remainder, candidate) then
            separator = candidate
            remainder = remainder:sub(#candidate + 1):gsub("^%s+", "")
            break
        end
    end
    return separator, remainder
end

local function parse_arabic_order(text)
    local raw_prefix = text:match("^(%d+)")
    if not raw_prefix then
        return nil
    end

    local number = finite_number(raw_prefix)
    if not number or number < 1 or number % 1 ~= 0 then
        return nil
    end

    local separator, body = extract_separator(text:sub(#raw_prefix + 1))
    if body == "" then
        return nil
    end

    local zero_prefix = raw_prefix:match("^(0*)") or ""
    return {
        kind = "arabic",
        number = number,
        raw_prefix = raw_prefix,
        padding = {
            has_leading_zero = #zero_prefix > 0,
            leading_zero_count = #zero_prefix,
        },
        separator = separator,
        text_without_number = text:sub(#raw_prefix + 1),
        text_without_prefix = body,
    }
end

local function parse_chinese_order(text)
    local position = 1
    local collected = {}
    while position <= #text do
        local character, next_position = utf8_character_at(text, position)
        if not chinese_numeric_characters[character] then
            break
        end
        collected[#collected + 1] = character
        position = next_position
    end

    local raw_prefix = table.concat(collected)
    if raw_prefix == "" then
        return nil
    end
    local number = chinese_order_to_number[raw_prefix]
    if not number then
        return nil
    end

    local separator, body = extract_separator(text:sub(position))
    -- 中文数字很容易是正常正文的一部分；只有后接明确符号时才认定为排序序号。
    if separator == nil or body == "" then
        return nil
    end
    return {
        kind = "chinese",
        number = number,
        raw_prefix = raw_prefix,
        padding = {has_leading_zero = false, leading_zero_count = 0},
        separator = separator,
        text_without_number = text:sub(position),
        text_without_prefix = body,
    }
end

local roman_values = {
    I = 1, V = 5, X = 10, L = 50, C = 100, D = 500, M = 1000,
}

local roman_parts = {
    {1000, "M"}, {900, "CM"}, {500, "D"}, {400, "CD"},
    {100, "C"}, {90, "XC"}, {50, "L"}, {40, "XL"},
    {10, "X"}, {9, "IX"}, {5, "V"}, {4, "IV"}, {1, "I"},
}

local function roman_encode(number)
    local parts = {}
    local rest = number
    for _, pair in ipairs(roman_parts) do
        while rest >= pair[1] do
            parts[#parts + 1] = pair[2]
            rest = rest - pair[1]
        end
    end
    return table.concat(parts)
end

local function parse_roman_order(text)
    local raw_prefix = text:match("^([IVXLCDMivxlcdm]+)")
    if not raw_prefix then
        return nil
    end

    local upper = raw_prefix:upper()
    local number, previous = 0, 0
    for index = #upper, 1, -1 do
        local value = roman_values[upper:sub(index, index)]
        if not value then
            return nil
        end
        if value < previous then
            number = number - value
        else
            number = number + value
            previous = value
        end
    end
    if number < 1 or number > 3999 or roman_encode(number) ~= upper then
        return nil
    end

    local separator, body = extract_separator(text:sub(#raw_prefix + 1))
    if body == "" then
        return nil
    end
    local case_style = raw_prefix == raw_prefix:upper() and "upper"
        or (raw_prefix == raw_prefix:lower() and "lower" or "mixed")
    return {
        kind = "roman",
        number = number,
        raw_prefix = raw_prefix,
        roman_case = case_style,
        padding = {has_leading_zero = false, leading_zero_count = 0},
        separator = separator,
        text_without_number = text:sub(#raw_prefix + 1),
        text_without_prefix = body,
    }
end

-- 为后续用户扩展保留；默认不定义额外排序格式。
local function parse_custom_order(_text)
    return nil
end

local function parse_order_prefix(text)
    local normalized = (text or ""):gsub("^%s+", "")
    if normalized == "" then
        return nil
    end
    local first = normalized:sub(1, 1)
    if first:match("%d") then
        return parse_arabic_order(normalized)
    end
    local character = utf8_character_at(normalized, 1)
    if chinese_numeric_characters[character] then
        return parse_chinese_order(normalized)
    end
    if first:match("[IVXLCDMivxlcdm]") then
        return parse_roman_order(normalized)
    end
    return parse_custom_order(normalized)
end

-- 仅将“看起来像排序”的失败项记日志，普通文本保持安静。
local function looks_like_order_prefix(text)
    local normalized = (text or ""):gsub("^%s+", "")
    if normalized:match("^%d") then
        return true
    end
    local character = utf8_character_at(normalized, 1)
    if chinese_numeric_characters[character] then
        return true
    end
    local raw_roman = normalized:match("^([IVXLCDMivxlcdm]+)")
    if raw_roman then
        local rest = normalized:sub(#raw_roman + 1)
        if rest == "" or rest:match("^%s") then
            return true
        end
        for _, separator in ipairs(separators) do
            if starts_with(rest, separator) then
                return true
            end
        end
    end
    return false
end

local function normalize_color(value)
    local color = finite_number(value)
    if color == nil then
        return 0xFFFFFF
    end
    return math.floor(color)
end

local function is_valid_padding_format(anchor, candidate)
    if anchor.parsed.kind ~= "arabic" or candidate.parsed.kind ~= "arabic" then
        return true
    end

    local expected_zeroes = anchor.parsed.padding.leading_zero_count or 0
    local actual_zeroes = candidate.parsed.padding.leading_zero_count or 0
    if expected_zeroes == 0 then
        return actual_zeroes == 0
    end
    if candidate.parsed.number < 10 then
        return actual_zeroes == expected_zeroes
    end
    return actual_zeroes == 0 or actual_zeroes == expected_zeroes
end

local function is_valid_time_window(anchor, candidate, time_window)
    return math.abs(candidate.time - anchor.time) <= time_window
end

local function check_separator_consistency(records)
    local expected = records[1] and records[1].parsed.separator
    for _, record in ipairs(records) do
        if record.parsed.separator ~= expected then
            return false
        end
    end
    return true
end

local function check_style_consistency(records)
    local first = records[1]
    if not first then
        return false
    end
    local expected_type = first.item.type
    local expected_size = first.item.size
    local expected_color = normalize_color(first.item.color)
    for _, record in ipairs(records) do
        if record.item.type ~= expected_type
            or record.item.size ~= expected_size
            or normalize_color(record.item.color) ~= expected_color then
            return false
        end
    end
    return true
end

local function is_valid_order_transition(anchor, candidate)
    if anchor.parsed.kind ~= candidate.parsed.kind then
        return false, "排序格式不同"
    end
    if anchor.parsed.kind == "roman" and anchor.parsed.roman_case ~= candidate.parsed.roman_case then
        return false, "排序格式不同"
    end
    if not is_valid_padding_format(anchor, candidate) then
        return false, "补零格式不符合"
    end
    return true
end

local function bucket_key(record)
    local separator = record.parsed.separator == nil and "<none>" or record.parsed.separator
    return table.concat({
        record.parsed.kind,
        separator,
        tostring(record.item.type),
        tostring(record.item.size),
    }, "\0")
end

local function record_sorter(a, b)
    if a.time ~= b.time then
        return a.time < b.time
    end
    return a.source_index < b.source_index
end

local function lower_bound(records, value)
    local low, high = 1, #records + 1
    while low < high do
        local middle = math.floor((low + high) / 2)
        if records[middle].time < value then
            low = middle + 1
        else
            high = middle
        end
    end
    return low
end

local function has_duplicate_orders(records)
    local counts = {}
    for _, record in ipairs(records) do
        local number = record.parsed.number
        counts[number] = (counts[number] or 0) + 1
        if counts[number] > 1 then
            return true
        end
    end
    return false
end

local function group_candidates_by_color(records)
    local colors = {}
    for _, record in ipairs(records) do
        local color = normalize_color(record.item.color)
        local group = colors[color]
        if not group then
            group = {}
            colors[color] = group
        end
        group[#group + 1] = record
    end

    local ordered = {}
    for color in pairs(colors) do
        ordered[#ordered + 1] = color
    end
    table.sort(ordered)

    local groups = {}
    for _, color in ipairs(ordered) do
        groups[#groups + 1] = {color = color, records = colors[color]}
    end
    return groups
end

local function has_anchor_candidate(records)
    for _, record in ipairs(records) do
        if record.parsed.number == 1 then
            return true
        end
    end
    return false
end

local function choose_next_candidate(records, anchor)
    table.sort(records, function(a, b)
        local distance_a = math.abs(a.time - anchor.time)
        local distance_b = math.abs(b.time - anchor.time)
        if distance_a ~= distance_b then
            return distance_a < distance_b
        end
        return record_sorter(a, b)
    end)
    return records[1]
end

local function find_missing_orders(by_number, maximum)
    local missing = {}
    for number = 1, maximum do
        if not by_number[number] or #by_number[number] == 0 then
            missing[#missing + 1] = number
        end
    end
    return missing
end

local function format_missing_order(number, anchor)
    local parsed = anchor.parsed
    if parsed.kind == "arabic" then
        local zeroes = parsed.padding.leading_zero_count or 0
        if zeroes > 0 then
            return string.rep("0", zeroes) .. tostring(number)
        end
        return tostring(number)
    end
    if parsed.kind == "chinese" then
        return chinese_order_text(number)
    end
    if parsed.kind == "roman" then
        local text = roman_encode(number)
        return parsed.roman_case == "lower" and text:lower() or text
    end
    return tostring(number)
end

local function queue_unmerged_reason(transaction, reason, details)
    transaction.reason_counts[reason] = (transaction.reason_counts[reason] or 0) + 1
    transaction.logs.unmerged[#transaction.logs.unmerged + 1] = {
        kind = "reason",
        reason = reason,
        source = details and details.source,
        item_id = details and details.item_id,
        source_index = details and details.source_index,
    }
end

local function queue_missing_order(transaction, source_url, color, anchor, missing, maximum, color_split)
    local formatted_missing = {}
    for _, number in ipairs(missing) do
        formatted_missing[#formatted_missing + 1] = format_missing_order(number, anchor)
    end
    local key = table.concat({
        tostring(source_url), tostring(color), anchor.item.item_id,
        table.concat(formatted_missing, ","),
    }, "\0")
    if transaction.logged_missing[key] then
        return
    end
    transaction.logged_missing[key] = true
    transaction.reason_counts["排序数字不连续"] = (transaction.reason_counts["排序数字不连续"] or 0) + 1
    transaction.logs.unmerged[#transaction.logs.unmerged + 1] = {
        kind = "missing",
        source = source_url,
        color = color,
        anchor = anchor,
        range_end = maximum,
        missing = formatted_missing,
        color_split = color_split,
    }
end

local function queue_merge_result(transaction, source_url, merged_item, anchor)
    transaction.logs.merged[#transaction.logs.merged + 1] = {
        source = source_url,
        item = merged_item,
        anchor = anchor,
    }
end

local function merge_danmaku_group(source_url, selected, anchor)
    local text = {}
    for _, record in ipairs(selected) do
        -- 弹幕末尾的 ♡数字是常见的点赞/计数尾缀，不属于合并正文。
        local body = (record.parsed.text_without_prefix or ""):gsub("♡%d+$", "")
        if body == "" then
            return nil
        end
        text[#text + 1] = body
    end
    local first = selected[1]
    return {
        time = first.item.time,
        orig_time = first.item.orig_time,
        type = first.item.type,
        size = first.item.size,
        color = first.item.color,
        source = source_url,
        text = table.concat(text),
        range_start = 1,
        range_end = selected[#selected].parsed.number,
        items = (function()
            local items = {}
            for index, record in ipairs(selected) do
                items[index] = clone_item(record.item)
            end
            return items
        end)(),
        anchor_item_id = anchor.item.item_id,
    }
end

local function commit_merged_group(transaction, source_url, group_result)
    local destination = transaction.merged[source_url]
    if not destination or type(destination.data) ~= "table" then
        error("missing temporary merged source: " .. tostring(source_url))
    end
    table.insert(destination.data, group_result.merged_item)
    for _, item_id in ipairs(group_result.item_ids) do
        transaction.merged_item_ids[item_id] = true
    end
    queue_merge_result(transaction, source_url, group_result.merged_item, group_result.anchor)
end

local function build_candidate_groups(transaction, source_url, source)
    local buckets, anchors = {}, {}
    if source.blocked or source.data == nil then
        return buckets, anchors
    end

    for source_index, item in ipairs(source.data) do
        local context = {
            source = source_url,
            source_index = source_index,
            item_id = item.item_id,
        }
        local allow_merge = true
        if not transaction.filter_disabled then
            local ok, result = pcall(M.filter_before_merge, item, context)
            if ok then
                allow_merge = result ~= false
            else
                transaction.filter_disabled = true
                if not transaction.logs.filter_error then
                    transaction.logs.filter_error = tostring(result)
                end
            end
        end

        if not allow_merge then
            queue_unmerged_reason(transaction, "弹幕被过滤器排除", context)
        else
            local parsed = parse_order_prefix(item.text)
            if not parsed then
                if looks_like_order_prefix(item.text) then
                    queue_unmerged_reason(transaction, "疑似排序前缀解析失败", context)
                end
            else
                local time = get_item_time(item)
                if time then
                    local record = {
                        item = item,
                        parsed = parsed,
                        time = time,
                        source_index = source_index,
                        source = source_url,
                    }
                    local key = bucket_key(record)
                    buckets[key] = buckets[key] or {}
                    buckets[key][#buckets[key] + 1] = record
                    if parsed.number == 1 then
                        anchors[#anchors + 1] = record
                    end
                end
            end
        end
    end

    for _, records in pairs(buckets) do
        table.sort(records, record_sorter)
    end
    table.sort(anchors, record_sorter)
    return buckets, anchors
end

local function process_final_group(transaction, source_url, records, time_window, color, color_split)
    -- 不满足最小组规模或没有 1 号项时，没有可建立的序列；保持原样，
    -- 不将它们当成“匹配不足”的失败组继续处理。
    if #records < 2 or not has_anchor_candidate(records) then
        return
    end

    local anchor_candidates = {}
    for _, record in ipairs(records) do
        if record.parsed.number == 1 and not transaction.merged_item_ids[record.item.item_id] then
            anchor_candidates[#anchor_candidates + 1] = record
        end
    end
    table.sort(anchor_candidates, record_sorter)
    local anchor = anchor_candidates[1]
    if not anchor then
        return
    end

    if not check_separator_consistency(records) then
        queue_unmerged_reason(transaction, "排序后符号不同", anchor)
        return
    end
    if not check_style_consistency(records) then
        queue_unmerged_reason(transaction, "样式字段不同", anchor)
        return
    end

    local valid_by_number = {}
    local invalid_reason = nil
    for _, record in ipairs(records) do
        if not transaction.merged_item_ids[record.item.item_id] then
            if is_valid_time_window(anchor, record, time_window) then
                local valid, reason = is_valid_order_transition(anchor, record)
                if valid then
                    valid_by_number[record.parsed.number] = valid_by_number[record.parsed.number] or {}
                    valid_by_number[record.parsed.number][#valid_by_number[record.parsed.number] + 1] = record
                else
                    invalid_reason = invalid_reason or reason
                end
            end
        end
    end

    if invalid_reason then
        queue_unmerged_reason(transaction, invalid_reason, anchor)
    end

    local distinct_count, maximum = 0, 0
    for number, candidates in pairs(valid_by_number) do
        if #candidates > 0 then
            distinct_count = distinct_count + 1
            if number > maximum then
                maximum = number
            end
        end
    end
    if distinct_count < 2 or maximum < 2 then
        return
    end

    local missing = find_missing_orders(valid_by_number, maximum)
    local selected = {}
    for number = 1, maximum do
        if not valid_by_number[number] or #valid_by_number[number] == 0 then
            break
        end
        local candidate
        if number == 1 then
            candidate = anchor
        else
            candidate = choose_next_candidate(valid_by_number[number], anchor)
        end
        if not candidate then
            return
        end
        selected[#selected + 1] = candidate
    end

    if #selected < 2 then
        if #missing > 0 then
            queue_missing_order(transaction, source_url, color, anchor, missing, maximum, color_split)
        end
        return
    end
    local merged_item = merge_danmaku_group(source_url, selected, anchor)
    if not merged_item then
        return
    end

    local group_result = {merged_item = merged_item, item_ids = {}, anchor = anchor}
    for _, record in ipairs(selected) do
        group_result.item_ids[#group_result.item_ids + 1] = record.item.item_id
    end
    -- 只有 data 追加成功后，commit_merged_group 才会标记 item_id。
    commit_merged_group(transaction, source_url, group_result)
end

local function process_source(transaction, source_url, source, time_window)
    local buckets, anchors = build_candidate_groups(transaction, source_url, source)
    for _, anchor in ipairs(anchors) do
        if not transaction.merged_item_ids[anchor.item.item_id] then
            local records = buckets[bucket_key(anchor)] or {}
            local start_index = lower_bound(records, anchor.time - time_window)
            local initial_group = {}
            local index = start_index
            while records[index] and records[index].time <= anchor.time + time_window do
                local candidate = records[index]
                if not transaction.merged_item_ids[candidate.item.item_id] then
                    initial_group[#initial_group + 1] = candidate
                end
                index = index + 1
            end

            if #initial_group > 0 then
                if has_duplicate_orders(initial_group) then
                    for _, color_group in ipairs(group_candidates_by_color(initial_group)) do
                        -- 颜色拆分后的单条组，或没有序号 1 的组，不具备
                        -- 独立建立连续序列的条件，直接保留在 latest。
                        if #color_group.records >= 2 and has_anchor_candidate(color_group.records) then
                            process_final_group(
                                transaction, source_url, color_group.records, time_window,
                                color_group.color, true
                            )
                        end
                    end
                else
                    process_final_group(
                        transaction, source_url, initial_group, time_window,
                        normalize_color(anchor.item.color), false
                    )
                end
            end
        end
    end
end

local function build_latest(transaction)
    local latest = {}
    for _, source_url in ipairs(sorted_keys(transaction.working_sources)) do
        local source = transaction.working_sources[source_url]
        local copied_source = clone_source_metadata(source)
        copied_source.generated_by = "danmaku_merge_extension"
        copied_source.data_kind = "latest"
        if source.data == nil then
            copied_source.data = nil
        else
            copied_source.data = {}
            for _, item in ipairs(source.data) do
                if source.blocked or not transaction.merged_item_ids[item.item_id] then
                    copied_source.data[#copied_source.data + 1] = clone_item(item)
                end
            end
        end
        latest[source_url] = copied_source
    end
    return latest
end

local function deep_equal(left, right, seen)
    if left == right then
        return true
    end
    if type(left) ~= type(right) then
        return false
    end
    if type(left) ~= "table" then
        return false
    end
    seen = seen or {}
    if seen[left] == right then
        return true
    end
    seen[left] = right
    for key, value in pairs(left) do
        if not deep_equal(value, right[key], seen) then
            return false
        end
    end
    for key in pairs(right) do
        if left[key] == nil then
            return false
        end
    end
    return true
end

local function validate_sources_compatible(view, sources, data_kind)
    if type(view) ~= "table" or type(sources) ~= "table" then
        return false, "sources view is not a table"
    end
    for source_url, source in pairs(sources) do
        local copied_source = view[source_url]
        if type(copied_source) ~= "table" then
            return false, "missing source: " .. tostring(source_url)
        end
        for key, value in pairs(source) do
            if key ~= "data" then
                if type(value) == "table" and copied_source[key] == value then
                    return false, "source metadata table was shared: " .. tostring(source_url)
                end
                if not deep_equal(value, copied_source[key]) then
                    return false, "source metadata changed: " .. tostring(source_url)
                end
            end
        end
        if source.data == nil then
            if copied_source.data ~= nil then
                return false, "nil data changed: " .. tostring(source_url)
            end
        elseif type(copied_source.data) ~= "table" then
            return false, "missing data array: " .. tostring(source_url)
        end
    end
    for source_url in pairs(view) do
        if sources[source_url] == nil then
            return false, "unexpected source: " .. tostring(source_url)
        end
    end
    return true
end

local function validate_transaction(transaction, original_sources)
    local ok, err = validate_sources_compatible(transaction.merged, original_sources, "merged")
    if not ok then
        return false, err
    end
    ok, err = validate_sources_compatible(transaction.latest, original_sources, "latest")
    if not ok then
        return false, err
    end

    for source_url, source in pairs(transaction.working_sources) do
        if source.data then
            local remaining_ids = {}
            for _, item in ipairs(transaction.latest[source_url].data or {}) do
                if remaining_ids[item.item_id] then
                    return false, "duplicate latest item id: " .. tostring(item.item_id)
                end
                remaining_ids[item.item_id] = true
                if transaction.merged_item_ids[item.item_id] and not source.blocked then
                    return false, "merged item remained in latest: " .. tostring(item.item_id)
                end
            end
            for _, item in ipairs(source.data) do
                local used = transaction.merged_item_ids[item.item_id]
                if not source.blocked and not used and not remaining_ids[item.item_id] then
                    return false, "unmerged item missing from latest: " .. tostring(item.item_id)
                end
            end
        end
    end
    return true
end

local function fingerprint_part(parts, value)
    local text = tostring(value == nil and "<nil>" or value)
    parts[#parts + 1] = tostring(#text) .. ":" .. text
end

local function build_data_fingerprint(sources)
    local parts = {}
    fingerprint_part(parts, RULE_VERSION)
    fingerprint_part(parts, get_merge_time_window())
    fingerprint_part(parts, extension_options.log_success)
    for _, source_url in ipairs(sorted_keys(sources)) do
        local source = sources[source_url]
        fingerprint_part(parts, source_url)
        fingerprint_part(parts, source.blocked)
        if source.data == nil then
            fingerprint_part(parts, "nil-data")
        else
            fingerprint_part(parts, #source.data)
            for _, item in ipairs(source.data) do
                fingerprint_part(parts, item.time)
                fingerprint_part(parts, item.type)
                fingerprint_part(parts, item.size)
                fingerprint_part(parts, item.color)
                fingerprint_part(parts, item.text)
            end
        end
    end
    return table.concat(parts, "|")
end

local function flush_logs(transaction, sources)
    local fingerprint = build_data_fingerprint(sources)
    if last_logged_fingerprint == fingerprint then
        return
    end
    last_logged_fingerprint = fingerprint

    if transaction.logs.filter_error then
        msg.error("[danmaku-merge] filter_before_merge error; remaining items were allowed: "
            .. transaction.logs.filter_error)
    end

    if option_enabled(extension_options.log_success, true) then
        for _, entry in ipairs(transaction.logs.merged) do
            local item = entry.item
            msg.info(string.format(
                "[danmaku-merge] source=%s time=%s range=%s-%s text=%s",
                tostring(entry.source),
                format_playback_time(entry.anchor.time),
                format_missing_order(item.range_start, entry.anchor),
                format_missing_order(item.range_end, entry.anchor),
                tostring(item.text)
            ))
        end
        local merged_count = 0
        for _ in pairs(transaction.merged_item_ids) do
            merged_count = merged_count + 1
        end
        msg.info(string.format(
            "[danmaku-merge] success=%d merged=%d",
            #transaction.logs.merged, merged_count
        ))
    end

end

local function render_with_sources(sources, force)
    local owner = DANMAKU
    local original_sources = owner.sources
    local switched = false
    local result = nil
    local ok, traceback = xpcall(function()
        owner.sources = clone_sources_view(sources)
        switched = true
        COMMENTS = {}
        result = original_convert(force)
    end, debug.traceback)

    if switched then
        owner.sources = original_sources
    end
    return ok, result, traceback
end

local function render_with_full_copy(force)
    return render_with_sources(DANMAKU.sources, force)
end

-- 以下实现完全位于扩展中：不改动 uosc_danmaku 核心脚本，而是以 source
-- 兼容的临时视图交给原转换器渲染。
local last_snapshot_owner = nil
local last_source_snapshot_fingerprint = nil
local last_merged_snapshot_fingerprint = nil
-- 同一视频内已显示合成项的字号下限。字幕出现后不能把它从大字号缩小；
-- 字幕消失后仍允许随可用空间恢复到更大字号。
local merged_layout_font_floors = {}
local merged_layout_source_fingerprint = nil
-- ASS 的 Y 轴向下增长。这里保存已达到的最小 Y（最高位置），使字幕消失后
-- 合成项不会重新向下掉回底部。
local merged_layout_y_ceilings = {}

local function snapshot_value(value)
    if type(value) ~= "table" then
        return tostring(value == nil and "<nil>" or value)
    end
    local ok, encoded = pcall(mp_utils.format_json, value)
    return ok and encoded or tostring(value)
end

local function build_snapshot_fingerprint(sources)
    local parts = {RULE_VERSION}
    for _, source_url in ipairs(sorted_keys(sources)) do
        local source = sources[source_url]
        fingerprint_part(parts, source_url)
        for _, key in ipairs(sorted_keys(source)) do
            if key ~= "data" then
                fingerprint_part(parts, key)
                fingerprint_part(parts, snapshot_value(source[key]))
            end
        end
        if type(source.data) == "table" then
            fingerprint_part(parts, #source.data)
            for _, item in ipairs(source.data) do
                fingerprint_part(parts, item.time)
                fingerprint_part(parts, item.orig_time)
                fingerprint_part(parts, item.type)
                fingerprint_part(parts, item.size)
                fingerprint_part(parts, item.color)
                fingerprint_part(parts, item.text)
                fingerprint_part(parts, item.time_formate)
                fingerprint_part(parts, item.source_list and snapshot_value(item.source_list))
            end
        else
            fingerprint_part(parts, "nil-data")
        end
    end
    return table.concat(parts, "|")
end

local function extension_is_directory(path)
    local info = mp_utils.file_info(path)
    return info and not info.is_file
end

local function extension_ensure_directory(path)
    if extension_is_directory(path) then
        return true
    end
    local platform = mp.get_property_native("platform") or PLATFORM
    local request
    if platform == "windows" then
        -- gsub 会返回“替换后的字符串”和“替换次数”两个值；先存入局部变量，
        -- 避免替换次数作为整数混入 subprocess 的 args。
        local windows_path = path:gsub("/", "\\")
        request = { "cmd", "/C", "mkdir", windows_path }
    else
        request = { "mkdir", "-p", path }
    end
    local result = mp.command_native({
        name = "subprocess",
        playback_only = false,
        capture_stdout = true,
        capture_stderr = true,
        args = request,
    })
    return result and result.status == 0 and extension_is_directory(path)
end

local function get_snapshot_paths()
    local path = mp.get_property("path")
    if not path or is_protocol(path) then
        return nil, "网络视频没有本地播放目录"
    end
    local directory = get_parent_directory(path)
    local filename = mp.get_property("filename/no-ext")
    if not directory or not filename or filename == "" then
        return nil, "无法确定视频目录或文件名"
    end
    local root = mp_utils.join_path(directory:gsub("[/\\]+$", ""), ".mpv")
    local danmaku_directory = mp_utils.join_path(root, "danmaku")
    local start_directory = mp_utils.join_path(danmaku_directory, "start")
    local merged_directory = mp_utils.join_path(danmaku_directory, "merged")
    if not extension_ensure_directory(danmaku_directory)
        or not extension_ensure_directory(start_directory)
        or not extension_ensure_directory(merged_directory) then
        return nil, "无法创建弹幕快照目录"
    end
    return {
        source = mp_utils.join_path(danmaku_directory, filename .. ".json"),
        cache = mp_utils.join_path(start_directory, filename .. ".json"),
        merged = mp_utils.join_path(merged_directory, filename .. ".json"),
    }
end

local function write_snapshot(path, value)
    local ok, encoded = pcall(mp_utils.format_json, value)
    if not ok then
        return false, "JSON 编码失败: " .. tostring(encoded)
    end
    local file, open_error = io.open(path, "w")
    if not file then
        return false, tostring(open_error)
    end
    local write_ok, write_error = file:write(encoded)
    file:close()
    if not write_ok then
        return false, tostring(write_error)
    end
    return true
end

local function clear_merged_flags(sources)
    for _, source_url in ipairs(sorted_keys(sources)) do
        local source = sources[source_url]
        if type(source.data) == "table" then
            for _, item in ipairs(source.data) do
                if type(item) == "table" then
                    item.merged = nil
                end
            end
        end
    end
end

local function normalize_sources_and_build_cache(sources)
    clear_merged_flags(sources)
    local cache = {}
    for _, source_url in ipairs(sorted_keys(sources)) do
        local source = sources[source_url]
        local cached_source = clone_source_metadata(source)
        if source.data == nil then
            cached_source.data = nil
        else
            cached_source.data = {}
        end
        if type(source.data) == "table" then
            for _, item in ipairs(source.data) do
                if type(item) == "table" then
                    if item.orig_time == nil then
                        item.orig_time = item.time
                    end
                    item.time_formate = format_playback_time(item.time)
                    if parse_order_prefix(item.text) then
                        cached_source.data[#cached_source.data + 1] = clone_item(item)
                    end
                end
            end
        end
        cache[source_url] = cached_source
    end
    return cache
end

local function clone_sources_shape(sources)
    local result = {}
    for _, source_url in ipairs(sorted_keys(sources)) do
        local source = sources[source_url]
        local copied = clone_source_metadata(source)
        copied.data = source.data == nil and nil or {}
        result[source_url] = copied
    end
    return result
end

local function persist_source_snapshots(sources, cache)
    local fingerprint = build_snapshot_fingerprint(sources)
    if last_source_snapshot_fingerprint == fingerprint then
        return
    end
    local paths, path_error = get_snapshot_paths()
    if not paths then
        msg.warn("[danmaku-merge] 跳过 source/start 快照: " .. path_error)
        return
    end
    local ok, write_error = write_snapshot(paths.source, clone_sources_view(sources))
    if ok then
        ok, write_error = write_snapshot(paths.cache, cache)
    end
    if not ok then
        msg.warn("[danmaku-merge] 写入 source/start 快照失败: " .. tostring(write_error))
        return
    end
    last_source_snapshot_fingerprint = fingerprint
end

local function persist_merged_snapshot(merged)
    local fingerprint = build_snapshot_fingerprint(merged)
    if last_merged_snapshot_fingerprint == fingerprint then
        return
    end
    local paths, path_error = get_snapshot_paths()
    if not paths then
        msg.warn("[danmaku-merge] 跳过 merged 快照: " .. path_error)
        return
    end
    local ok, write_error = write_snapshot(paths.merged, merged)
    if not ok then
        msg.warn("[danmaku-merge] 写入 merged 快照失败: " .. tostring(write_error))
        return
    end
    last_merged_snapshot_fingerprint = fingerprint
end

local function order_format_key(parsed)
    if parsed.kind == "arabic" then
        return "arabic:" .. tostring(parsed.padding and parsed.padding.leading_zero_count or 0)
    end
    if parsed.kind == "roman" then
        return "roman:" .. tostring(parsed.roman_case)
    end
    return tostring(parsed.kind)
end

local function ordered_record_sorter(left, right)
    if left.parsed.number ~= right.parsed.number then
        return left.parsed.number < right.parsed.number
    end
    return record_sorter(left, right)
end

local function records_have_anchor(records)
    for _, record in ipairs(records) do
        if record.parsed.number == 1 then
            return true
        end
    end
    return false
end

local function all_records_match_style(records)
    local first = records[1]
    if not first then
        return false
    end
    local color = normalize_color(first.item.color)
    for _, record in ipairs(records) do
        if normalize_color(record.item.color) ~= color
            or record.item.type ~= first.item.type
            or record.item.size ~= first.item.size then
            return false
        end
    end
    return true
end

local function records_share_style(left, right)
    return normalize_color(left.item.color) == normalize_color(right.item.color)
        and left.item.type == right.item.type
        and left.item.size == right.item.size
end

local function all_records_match_format(records)
    local first = records[1]
    if not first then
        return false
    end
    local key = order_format_key(first.parsed)
    for _, record in ipairs(records) do
        if order_format_key(record.parsed) ~= key then
            return false
        end
    end
    return true
end

local function all_records_share_time(records)
    local first = records[1]
    if not first then
        return false
    end
    for _, record in ipairs(records) do
        if record.time ~= first.time then
            return false
        end
    end
    return true
end

local function source_records_for_merge(source_url, source)
    local records = {}
    if source.blocked or type(source.data) ~= "table" then
        return records
    end
    for source_index, item in ipairs(source.data) do
        if type(item) == "table" then
            local parsed = parse_order_prefix(item.text)
            local time = get_item_time(item)
            local allow = true
            if type(M.filter_before_merge) == "function" then
                local ok, result = pcall(M.filter_before_merge, item, {
                    source = source_url,
                    source_index = source_index,
                    item_id = make_item_id(source_url, source_index),
                })
                allow = ok and result ~= false
                if not ok then
                    msg.warn("[danmaku-merge] filter_before_merge 失败，已跳过过滤: " .. tostring(result))
                    allow = true
                end
            end
            if allow and parsed and time then
                records[#records + 1] = {
                    item = item,
                    item_id = make_item_id(source_url, source_index),
                    source_index = source_index,
                    source = source_url,
                    parsed = parsed,
                    time = time,
                }
            end
        end
    end
    table.sort(records, record_sorter)
    return records
end

local function group_records(records, key_fn)
    local grouped, keys = {}, {}
    for _, record in ipairs(records) do
        local key = key_fn(record)
        if not grouped[key] then
            grouped[key] = {}
            keys[#keys + 1] = key
        end
        grouped[key][#grouped[key] + 1] = record
    end
    table.sort(keys, function(left, right) return tostring(left) < tostring(right) end)
    local result = {}
    for _, key in ipairs(keys) do
        result[#result + 1] = grouped[key]
    end
    return result
end

-- Lua 的 %s 不覆盖 U+200A 等 Unicode 空白。部分来源还会在空白后附带
-- U+FE0E/U+FE0F 变体选择符，因此两者都要在合并边缘反复清除。
local merge_trim_tokens = {
    "\194\160", -- U+00A0 NO-BREAK SPACE
    "\225\154\128", -- U+1680 OGHAM SPACE MARK
    "\226\128\128", "\226\128\129", "\226\128\130", "\226\128\131",
    "\226\128\132", "\226\128\133", "\226\128\134", "\226\128\135",
    "\226\128\136", "\226\128\137", "\226\128\138", "\226\128\139",
    "\226\128\175", "\226\129\159", "\227\128\128", -- U+202F/U+205F/U+3000
    "\239\187\191", -- U+FEFF ZERO WIDTH NO-BREAK SPACE
    "\239\184\142", "\239\184\143", -- U+FE0E/U+FE0F variation selectors
}

local function trim_merged_text(text)
    while true do
        local before = text
        text = text:gsub("^%s+", ""):gsub("%s+$", "")
        for _, token in ipairs(merge_trim_tokens) do
            text = text:gsub("^" .. token, "")
            text = text:gsub(token .. "$", "")
        end
        if text == before then
            return text
        end
    end
end

local function records_are_continuous(records)
    for index = 2, #records do
        if records[index].parsed.number ~= records[index - 1].parsed.number + 1 then
            return false
        end
    end
    return true
end

local function missing_order_count(records)
    local count = 0
    for index = 2, #records do
        count = count + records[index].parsed.number - records[index - 1].parsed.number - 1
    end
    return count
end

local function clean_merged_piece(text)
    -- 所有参与合并的弹幕都遵循同一清洗顺序：首尾空白、点赞尾缀、再次首尾空白。
    text = trim_merged_text(text)
    if text:match("♡%d+$") then
        text = text:gsub("♡%d+$", "")
        text = trim_merged_text(text)
    end
    return text
end

local function join_merged_text(records)
    local all_without_separator = true
    local first_separator = records[1].parsed.separator
    local all_same_separator = true
    for _, record in ipairs(records) do
        if record.parsed.separator ~= nil then
            all_without_separator = false
        end
        if record.parsed.separator ~= first_separator then
            all_same_separator = false
        end
    end

    local parts = {}
    local continuous = records_are_continuous(records)
    -- 依照示例：1,2,4,5,7,8 共缺 2 项可合并；累计缺 3 项则跳过。
    if not continuous and missing_order_count(records) >= 3 then
        return nil
    end
    for _, record in ipairs(records) do
        local text
        if not continuous then
            -- 缺号时保留每条原始序号与符号，只清洗首尾空白和点赞/计数尾缀。
            text = record.item.text
        elseif all_without_separator or all_same_separator then
            text = record.parsed.text_without_prefix
        else
            text = record.parsed.text_without_number
        end
        if type(text) ~= "string" then
            return nil
        end
        text = clean_merged_piece(text)
        if text == "" then
            return nil
        end
        parts[#parts + 1] = text
    end
    return table.concat(parts)
end

local function make_merged_item(records)
    table.sort(records, ordered_record_sorter)
    local anchor = records[1]
    if not anchor or anchor.parsed.number ~= 1 then
        return nil
    end
    local text = join_merged_text(records)
    if not text then
        return nil
    end
    local merged = clone_item(anchor.item)
    merged.merged = nil
    merged.text = text
    merged.source_list = {}
    for _, record in ipairs(records) do
        merged.source_list[#merged.source_list + 1] = clone_item(record.item)
    end
    return merged, anchor
end

local merge_ordered_danmaku_group

-- 候选组已收集完成后，在满足序号、格式和样式规则时提交一条合成项。
local function merge_candidate_group_if_valid(transaction, source_url, candidates, time_window, split_depth)
    if #candidates < 2 or not records_have_anchor(candidates) then
        return
    end
    table.sort(candidates, ordered_record_sorter)
    local group_ids = {}
    for _, record in ipairs(candidates) do
        group_ids[#group_ids + 1] = record.item_id
    end
    local group_key = tostring(split_depth) .. "\0" .. table.concat(group_ids, "\0")
    if transaction.attempted_groups[group_key] then
        return
    end
    transaction.attempted_groups[group_key] = true

    if has_duplicate_orders(candidates) then
        -- 仅第一次重复时拆分。拆分后同色同格式仍重复，直接结束，保证递归有界。
        if split_depth >= 1 then
            return
        end
        for _, color_group in ipairs(group_records(candidates, function(record)
            return normalize_color(record.item.color)
        end)) do
            for _, format_group in ipairs(group_records(color_group, function(record)
                return order_format_key(record.parsed)
            end)) do
                if #format_group >= 2 and records_have_anchor(format_group) then
                    merge_ordered_danmaku_group(
                        transaction, source_url, format_group, time_window, split_depth + 1
                    )
                end
            end
        end
        return
    end

    if not all_records_match_style(candidates) then
        return
    end
    if not all_records_match_format(candidates) and not all_records_share_time(candidates) then
        return
    end

    local merged_item, anchor = make_merged_item(candidates)
    if not merged_item then
        return
    end
    local destination = transaction.merged[source_url]
    if not destination or type(destination.data) ~= "table" then
        error("missing merged destination: " .. tostring(source_url))
    end
    destination.data[#destination.data + 1] = merged_item
    for _, record in ipairs(candidates) do
        transaction.merged_item_ids[record.item_id] = true
    end
    transaction.logs[#transaction.logs + 1] = {
        source = source_url,
        anchor = anchor,
        item = merged_item,
    }
end

merge_ordered_danmaku_group = function(transaction, source_url, records, time_window, split_depth)
    if #records < 2 then
        return
    end
    local anchors = {}
    for _, record in ipairs(records) do
        if record.parsed.number == 1 and not transaction.merged_item_ids[record.item_id] then
            anchors[#anchors + 1] = record
        end
    end
    table.sort(anchors, record_sorter)
    for _, anchor in ipairs(anchors) do
        if not transaction.merged_item_ids[anchor.item_id] then
            local candidates = {}
            for _, candidate in ipairs(records) do
                if not transaction.merged_item_ids[candidate.item_id]
                    and math.abs(candidate.time - anchor.time) <= time_window
                    -- 时间窗内可能存在另一组不同颜色、类型或字号的序号弹幕。
                    -- 它们不属于当前 1 号项的候选组，不能使正确组整体失效。
                    and records_share_style(anchor, candidate) then
                    candidates[#candidates + 1] = candidate
                end
            end
            merge_candidate_group_if_valid(transaction, source_url, candidates, time_window, split_depth)
        end
    end
end

local function commit_merged_flags(sources, merged_item_ids)
    for _, source_url in ipairs(sorted_keys(sources)) do
        local source = sources[source_url]
        if type(source.data) == "table" then
            for source_index, item in ipairs(source.data) do
                item.merged = merged_item_ids[make_item_id(source_url, source_index)] and true or nil
            end
        end
    end
end

local function build_normal_render_sources(sources)
    local view = {}
    for _, source_url in ipairs(sorted_keys(sources)) do
        local source = sources[source_url]
        local copied = clone_source_metadata(source)
        copied.data = source.data == nil and nil or {}
        if type(source.data) == "table" then
            for _, item in ipairs(source.data) do
                if item.merged ~= true then
                    copied.data[#copied.data + 1] = clone_item(item)
                end
            end
        end
        view[source_url] = copied
    end
    return view
end

local function render_with_source_data(force)
    return render_with_sources(build_normal_render_sources(DANMAKU.sources), force)
end

function M.prepare_danmaku_lists()
    local owner = DANMAKU
    if type(owner) ~= "table" or type(owner.sources) ~= "table" then
        msg.error("[danmaku-merge] invalid DANMAKU.sources")
        return false
    end
    if last_snapshot_owner ~= owner then
        last_snapshot_owner = owner
        last_source_snapshot_fingerprint = nil
        last_merged_snapshot_fingerprint = nil
        DANMAKU_CACHE = {}
        DANMAKU_MERGED = {}
    end

    -- 事务边界：失败时清除 merged 标记并回退到原 sources，避免半成品进入渲染。
    local original_sources = owner.sources
    local ok, transaction_or_error = xpcall(function()
        local cache = normalize_sources_and_build_cache(original_sources)
        DANMAKU_CACHE = cache
        local source_fingerprint = build_snapshot_fingerprint(original_sources)
        if merged_layout_source_fingerprint ~= source_fingerprint then
            merged_layout_source_fingerprint = source_fingerprint
            merged_layout_font_floors = {}
            merged_layout_y_ceilings = {}
        end
        persist_source_snapshots(original_sources, cache)

        local transaction = {
            merged = clone_sources_shape(original_sources),
            merged_item_ids = {},
            attempted_groups = {},
            logs = {},
        }
        local time_window = get_merge_time_window()
        for _, source_url in ipairs(sorted_keys(original_sources)) do
            local records = source_records_for_merge(source_url, original_sources[source_url])
            merge_ordered_danmaku_group(transaction, source_url, records, time_window, 0)
        end
        local valid, validation_error = validate_sources_compatible(transaction.merged, original_sources, "merged")
        if not valid then
            error(validation_error)
        end
        if owner.sources ~= original_sources then
            error("DANMAKU.sources changed during merge transaction")
        end

        commit_merged_flags(original_sources, transaction.merged_item_ids)
        DANMAKU_MERGED = transaction.merged
        owner.latest = nil
        owner.merged = nil
        persist_merged_snapshot(DANMAKU_MERGED)
        return transaction
    end, debug.traceback)

    if not ok then
        clear_merged_flags(original_sources)
        DANMAKU_MERGED = clone_sources_shape(original_sources)
        owner.latest = nil
        owner.merged = nil
        msg.error("[danmaku-merge] extension error; rendering original source data:\n" .. transaction_or_error)
        return false
    end

    if option_enabled(extension_options.log_success, true) then
        msg.info(string.format("[danmaku-merge] success=%d", #transaction_or_error.logs))
    end
    return true
end

-- 合成弹幕不再复用核心的固定底部弹幕转换。核心转换会再次执行固定行分配、
-- 去重及屏蔽；在普通弹幕已渲染后，这可能使一个本应独立布局的合成项没有
-- 生成事件。这里直接生成最小的事件结构，随后统一由本扩展的布局器定位。
local function merged_color_tag(color)
    local value = math.max(0, math.min(tonumber(color) or 0xFFFFFF, 0xFFFFFF))
    local rgb = string.format("%06X", value)
    return string.format("{\\c&H%s%s%s&}", rgb:sub(5, 6), rgb:sub(3, 4), rgb:sub(1, 2))
end

local function merged_source_time(source, item)
    local base_time = get_item_time(item)
    if not base_time then
        return nil
    end

    -- 与核心的 delay_segments 语义一致：到达某个分段起点后，累加该段延迟。
    local delay = 0
    local segments = type(source.delay_segments) == "table" and clone_value(source.delay_segments) or {}
    table.sort(segments, function(left, right)
        return (finite_number(left and left.start) or 0) < (finite_number(right and right.start) or 0)
    end)
    for _, segment in ipairs(segments) do
        local start = finite_number(segment and segment.start)
        if start and base_time >= start then
            delay = delay + (finite_number(segment.delay) or 0)
        end
    end
    return base_time + delay, base_time
end

local function build_merged_comments(sources)
    local comments = {}
    local fix_time = get_merged_display_time()
    local configured_color = get_merged_render_color()
    for _, source_url in ipairs(sorted_keys(sources)) do
        local source = sources[source_url]
        if not source.blocked and type(source.data) == "table" then
            for _, item in ipairs(source.data) do
                if type(item) == "table" and type(item.text) == "string" and item.text ~= "" then
                    local appear_time, original_time = merged_source_time(source, item)
                    if appear_time then
                        comments[#comments + 1] = {
                            orig_time = original_time,
                            start_time = appear_time,
                            end_time = appear_time + fix_time,
                            delay = appear_time - original_time,
                            style = "BTM",
                            text = merged_color_tag(configured_color or item.color),
                            clean_text = item.text,
                            -- 保持在普通 displayarea 内，实际 ASS 位置由布局器写入。
                            pos = { RENDER_WIDTH / 2, 0 },
                            move = nil,
                            source = source_url,
                        }
                    end
                end
            end
        end
    end
    return comments
end

local function get_merged_render_geometry()
    local render_height = RENDER_HEIGHT
    local osd_width = finite_number(mp.get_property_number("osd-width"))
    local osd_height = finite_number(mp.get_property_number("osd-height"))
    local ratio = nil
    if osd_width and osd_height and osd_width > 0 and osd_height > 0 then
        ratio = osd_width / osd_height
        if RENDER_WIDTH / RENDER_HEIGHT < ratio then
            render_height = RENDER_WIDTH / ratio
        end
    end

    local font_size = finite_number(options and options.fontsize) or 50
    if ratio and RENDER_WIDTH / RENDER_HEIGHT < ratio then
        -- 与 render.lua 中宽屏时的字体调整保持一致。
        font_size = font_size - ratio * 2
    end
    return {
        width = RENDER_WIDTH,
        height = render_height,
        osd_width = osd_width or RENDER_WIDTH,
        osd_height = osd_height or RENDER_HEIGHT,
        font_size = math.max(1, math.floor(font_size)),
    }
end

local function subtitle_is_visible(track_property, visibility_property)
    local track_id = mp.get_property_native(track_property)
    if track_id == nil or track_id == "no" then
        return false
    end
    return mp.get_property_bool(visibility_property, true)
end

local function runtime_number(primary_property, option_property, fallback)
    return finite_number(mp.get_property_number(primary_property))
        or finite_number(mp.get_property_number(option_property))
        or fallback
end

local function visible_subtitle_line_count(text_property)
    local text = mp.get_property_native(text_property)
    text = type(text) == "string" and text or ""
    text = text:gsub("\\N", "\n"):gsub("\r", "")
    local text_lines = 0
    for _ in text:gmatch("[^\n]+") do
        text_lines = text_lines + 1
    end
    if text_lines > 0 then
        return text_lines
    end
    -- 没有当前字幕文本或条目时不预留空白区域。这样选中了字幕轨、但正处于
    -- 两句字幕间隙时，合成弹幕仍会回到底部。
    return 0
end

local function subtitle_reserved_height(geometry, secondary)
    local scale_property = secondary and "secondary-sub-scale" or "sub-scale"
    local text_property = secondary and "secondary-sub-text" or "sub-text"
    local font_size = runtime_number("sub-font-size", "options/sub-font-size", 38)
    local scale = runtime_number(scale_property, "options/" .. scale_property, 1)
    local outline = runtime_number("sub-outline-size", "options/sub-outline-size", 1.65)
    local blur = runtime_number("sub-blur", "options/sub-blur", 0)
    local shadow = math.abs(runtime_number("sub-shadow-offset", "options/sub-shadow-offset", 0))
    local line_count = visible_subtitle_line_count(text_property)
    if line_count == 0 then
        return 0
    end
    -- sub-font-size 与弹幕 ASS 的字号一样会随 OSD 画布整体缩放。此前又按
    -- ASS/OSD 高度缩小了一次，在 3840x2019 窗口中将预留高度错误减半。
    -- 这里直接使用逻辑字号，并用较保守的行高覆盖实际字形、行距与描边。
    local glyph_height = font_size * scale * 1.55
    local decoration = outline * 2 + blur * 2 + shadow
    -- 为字幕描边、实际行距差异及合成弹幕留出额外缓冲；该值随主/副字幕
    -- 各自的缩放同步变化。
    local extra_height = get_merged_subtitle_extra_height() * scale
    local reserve = glyph_height * line_count + decoration + extra_height
    -- 即使异常字幕属性报出过大的字号或行数，也不能让单条字幕轨占满画面。
    return math.min(reserve, geometry.height * 0.45)
end

-- sub-pos 是字幕在画面中的纵向位置百分比。预留高度以当前 mpv 字幕字号、
-- 缩放、边框和可见行数计算，而不是使用固定弹幕字号。
local function get_subtitle_bottom_limit(geometry)
    local render_height = geometry.height
    local limit = render_height - MERGED_VERTICAL_MARGIN
    local function add_subtitle(track_property, visibility_property, position_property, secondary)
        if subtitle_is_visible(track_property, visibility_property) then
            local position = finite_number(mp.get_property_number(position_property)) or 100
            -- 底部弹幕只需要为画面下半部的字幕让位。字幕定位在上半部时，
            -- 原先的“字幕上沿作为底边界”算法会得到负值并错误隐藏所有合成项；
            -- 此时合成弹幕保持在底部即可避开该字幕。
            if position <= 50 then
                return
            end
            local subtitle_y = render_height * position / 100
            local reserve = subtitle_reserved_height(geometry, secondary)
            if reserve > 0 then
                limit = math.min(limit, subtitle_y - reserve - MERGED_SUBTITLE_GAP)
            end
        end
    end

    add_subtitle("current-tracks/sub/id", "sub-visibility", "sub-pos", false)
    add_subtitle("current-tracks/sub2/id", "secondary-sub-visibility", "secondary-sub-pos", true)
    return limit
end

local function character_display_units(character)
    if character == "\t" then
        return 4
    end
    local byte = character:byte(1)
    return byte and byte >= 0x80 and 2 or 1
end

-- 按与核心 get_str_width() 相同的“ASCII 1 / 非 ASCII 2”宽度规则折行。
local function wrap_merged_text(text, font_size, available_width)
    local max_units = math.max(1, math.floor(available_width / (font_size / 2)))
    local lines, line = {}, {}
    local line_units = 0
    local function flush_line()
        lines[#lines + 1] = table.concat(line)
        line, line_units = {}, 0
    end

    local position = 1
    text = tostring(text or ""):gsub("\r", "")
    while position <= #text do
        local character, next_position = utf8_character_at(text, position)
        position = next_position
        if character == "\n" then
            flush_line()
        else
            local units = character_display_units(character)
            if #line > 0 and line_units + units > max_units then
                flush_line()
            end
            line[#line + 1] = character
            line_units = line_units + units
        end
    end
    if #line > 0 or #lines == 0 then
        flush_line()
    end
    return lines
end

local function ass_escape_merged_line(text)
    return text:gsub("\\", "\\\\")
        :gsub("{", "\\{")
        :gsub("}", "\\}")
end

local function format_wrapped_merged_text(lines)
    local escaped = {}
    for index, line in ipairs(lines) do
        escaped[index] = ass_escape_merged_line(line)
    end
    return table.concat(escaped, "\\N"):gsub("x(%d+)$", "{\\b1\\i1}x%1")
end

local function event_color_tag(event)
    local text = event and event.text or ""
    local start_position = text:find("{\\c&H", 1, true)
    if start_position then
        local end_position = text:find("}", start_position, true)
        if end_position then
            return text:sub(start_position, end_position)
        end
    end
    return "{\\c&HFFFFFF&}"
end

-- render.lua 会将事件文本中的 \fs 放大 1.5 倍；仅在文本过高而必须缩小时
-- 写入该标签，普通情况下继续使用全局弹幕字号。
local function make_merged_text_layout(clean_text, available_width, default_font_size, requested_font_size)
    local font_size = math.max(1, math.floor(requested_font_size))
    local font_tag = ""
    if font_size < default_font_size then
        local encoded_size = math.max(1, math.floor(font_size / 1.5 + 0.5))
        font_size = encoded_size * 1.5
        font_tag = string.format("{\\fs%d}", encoded_size)
    end
    local lines = wrap_merged_text(clean_text, font_size, available_width)
    return {
        font_size = font_size,
        font_tag = font_tag,
        lines = lines,
        height = #lines * font_size,
    }
end

local function fit_merged_text_layout(clean_text, available_width, default_font_size, max_height)
    local requested_size = default_font_size
    while true do
        local layout = make_merged_text_layout(
            clean_text, available_width, default_font_size, requested_size
        )
        if layout.height <= max_height or requested_size <= 1 then
            return layout
        end
        requested_size = math.max(1, math.floor(requested_size * 0.8))
    end
end

local function find_bottom_slot(active, top, bottom, height, gap)
    local y = bottom - height
    while y >= top do
        local collision = nil
        for _, item in ipairs(active) do
            if y < item.y + item.height + gap and y + height + gap > item.y then
                if not collision or item.y > collision.y then
                    collision = item
                end
            end
        end
        if not collision then
            return y
        end
        y = collision.y - height - gap
    end
    return nil
end

local function merged_layout_key(event)
    return table.concat({
        tostring(event.source or ""),
        string.format("%.3f", tonumber(event.start_time) or 0),
        string.format("%.3f", tonumber(event.end_time) or 0),
        tostring(event.clean_text or ""),
    }, "\0")
end

local function prepare_merged_comment_layout(comments)
    local geometry = get_merged_render_geometry()
    local top = MERGED_VERTICAL_MARGIN
    -- 合并弹幕刻意不读取 options.displayarea；开启时仅为画面下半部字幕预留区域。
    local bottom = geometry.height - MERGED_VERTICAL_MARGIN
    if MERGED_AVOID_SUBTITLES then
        bottom = math.min(get_subtitle_bottom_limit(geometry), bottom)
    end
    if bottom <= top then
        -- 字幕参数异常或预留高度过大时，降级回最底部布局，避免把合成
        -- 弹幕整体清空。此降级路径可能与字幕重叠，但能确保仍可显示。
        bottom = geometry.height - MERGED_VERTICAL_MARGIN
    end
    local available_height = math.max(1, bottom - top)
    local available_width = math.max(1, geometry.width - MERGED_HORIZONTAL_MARGIN * 2)
    local active = {}

    for _, event in ipairs(comments) do
        local next_active = {}
        for _, item in ipairs(active) do
            if item.end_time >= event.start_time then
                next_active[#next_active + 1] = item
            end
        end
        active = next_active

        local clean_text = type(event.clean_text) == "string" and event.clean_text or ""
        local layout = fit_merged_text_layout(
            clean_text, available_width, geometry.font_size, available_height
        )
        local layout_key = merged_layout_key(event)
        local font_floor = merged_layout_font_floors[layout_key]
        if font_floor and layout.font_size < font_floor then
            -- 字幕使可用高度变小时，保持之前已经显示过的字号，不能反向缩小。
            layout = make_merged_text_layout(
                clean_text, available_width, geometry.font_size, font_floor
            )
        end
        local gap = math.max(12, layout.font_size * 0.25)
        local y = find_bottom_slot(active, top, bottom, layout.height, gap)

        -- 同一时间段的合并弹幕优先向上堆叠。空间不足时再逐步缩小当前项，
        -- 以确保完整文本仍能落入可见区域。
        local requested_size = layout.font_size
        local minimum_size = font_floor or 1
        while not y and requested_size > minimum_size do
            requested_size = math.max(1, math.floor(requested_size * 0.8))
            if requested_size < minimum_size then
                requested_size = minimum_size
            end
            layout = make_merged_text_layout(
                clean_text, available_width, geometry.font_size, requested_size
            )
            gap = math.max(12, layout.font_size * 0.25)
            y = find_bottom_slot(active, top, bottom, layout.height, gap)
        end
        y = y or top
        local y_ceiling = merged_layout_y_ceilings[layout_key]
        if y_ceiling and y > y_ceiling then
            y = y_ceiling
        end
        merged_layout_y_ceilings[layout_key] = math.min(y_ceiling or y, y)
        merged_layout_font_floors[layout_key] = math.max(font_floor or 0, layout.font_size)

        event.style = "BTM"
        event.move = nil
        -- render.lua 会用 event.pos 的 Y 值套用 displayarea 过滤。实际位置由
        -- text 内的 \pos 决定，所以这里保持为 0，以让合并弹幕不受 displayarea
        -- 限制，同时不改动普通弹幕的显示范围行为。
        event.pos = {geometry.width / 2, 0}
        event.text = string.format(
            "{\\pos(%d,%.1f)}%s%s%s",
            geometry.width / 2, y, event_color_tag(event), layout.font_tag,
            format_wrapped_merged_text(layout.lines)
        )
        active[#active + 1] = {
            y = y,
            height = layout.height,
            end_time = event.end_time,
        }
    end
end

local function comment_sorter(left, right)
    if left.start_time ~= right.start_time then
        return left.start_time < right.start_time
    end
    if left.end_time ~= right.end_time then
        return left.end_time < right.end_time
    end
    return tostring(left.source or "") < tostring(right.source or "")
end

function M.render_merged_danmaku()
    local valid, validation_error = validate_sources_compatible(DANMAKU_MERGED, DANMAKU.sources, "merged")
    if not valid then
        return false, validation_error
    end

    local latest_comments = COMMENTS
    if type(latest_comments) ~= "table" then
        return false, "latest comments are not available"
    end

    local has_merged_items = false
    for _, source in pairs(DANMAKU_MERGED) do
        if not source.blocked and type(source.data) == "table" and #source.data > 0 then
            has_merged_items = true
            break
        end
    end
    if not has_merged_items then
        return true
    end

    local merged_comments = build_merged_comments(DANMAKU_MERGED)
    if #merged_comments == 0 then
        return true
    end
    table.sort(merged_comments, comment_sorter)
    local ok, layout_error = xpcall(function()
        prepare_merged_comment_layout(merged_comments)
        for _, event in ipairs(latest_comments) do
            merged_comments[#merged_comments + 1] = event
        end
        table.sort(merged_comments, comment_sorter)
    end, debug.traceback)
    if not ok then
        COMMENTS = latest_comments
        return false, layout_error
    end
    -- render.lua 只读取全局 COMMENTS；合成项完成独立布局后必须替换为合并列表。
    COMMENTS = merged_comments
    return true
end

function convert_danmaku_to_ass_events(force)
    local prepared = M.prepare_danmaku_lists()
    if prepared then
        local rendered, result, render_error = render_with_source_data(force)
        if rendered then
            local merged_rendered, merged_error = M.render_merged_danmaku()
            if not merged_rendered then
                msg.error("[danmaku-merge] merged render failed; rendering source only:\n" .. tostring(merged_error))
            end
            return result
        end
        clear_merged_flags(DANMAKU.sources)
        DANMAKU_MERGED = clone_sources_shape(DANMAKU.sources)
        msg.error("[danmaku-merge] source render failed; falling back to complete data:\n" .. tostring(render_error))
    end

    local rendered, result, render_error = render_with_full_copy(force)
    if not rendered then
        msg.error("[danmaku-merge] full-copy render failed:\n" .. tostring(render_error))
    end
    return result
end

-- 字幕轨道、可见性或位置在播放中变化时，重新计算合并弹幕的避让位置。
local subtitle_layout_refresh_timer = nil
local function schedule_subtitle_layout_refresh()
    if not ENABLED or type(COMMENTS) ~= "table" or type(DANMAKU) ~= "table" then
        return
    end
    if subtitle_layout_refresh_timer then
        subtitle_layout_refresh_timer:kill()
    end
    subtitle_layout_refresh_timer = mp.add_timeout(0.1, function()
        subtitle_layout_refresh_timer = nil
        local ok, refresh_error = xpcall(function()
            convert_danmaku_to_ass_events(true)
            if type(render) == "function" then
                render()
            end
        end, debug.traceback)
        if not ok then
            msg.error("[danmaku-merge] subtitle layout refresh failed:\n" .. tostring(refresh_error))
        end
    end)
end

mp.observe_property("sub-pos", "number", schedule_subtitle_layout_refresh)
mp.observe_property("secondary-sub-pos", "number", schedule_subtitle_layout_refresh)
mp.observe_property("sid", "native", schedule_subtitle_layout_refresh)
mp.observe_property("secondary-sid", "native", schedule_subtitle_layout_refresh)
mp.observe_property("sub-visibility", "bool", schedule_subtitle_layout_refresh)
mp.observe_property("secondary-sub-visibility", "bool", schedule_subtitle_layout_refresh)
mp.observe_property("sub-text", "string", schedule_subtitle_layout_refresh)
mp.observe_property("secondary-sub-text", "string", schedule_subtitle_layout_refresh)
mp.observe_property("sub-font-size", "number", schedule_subtitle_layout_refresh)
mp.observe_property("sub-scale", "number", schedule_subtitle_layout_refresh)
mp.observe_property("secondary-sub-scale", "number", schedule_subtitle_layout_refresh)
mp.observe_property("sub-outline-size", "number", schedule_subtitle_layout_refresh)
mp.observe_property("sub-blur", "number", schedule_subtitle_layout_refresh)
mp.observe_property("sub-shadow-offset", "number", schedule_subtitle_layout_refresh)
