-- 【核心对比总结】
-- 仅2处模块有差异（其余100%一致），下方仅展示差异段落及对应原版代码，相同代码已省略
-- 1. SV模块：修复闪退（用缓存表替代Rime属性设置）
-- 2. CR模块：增加词典加载容错（避免加载失败阻塞输入）

local wanxiang = require('wanxiang')

local tone_map = {
    ['ā']='a', ['á']='a', ['ǎ']='a', ['à']='a',
    ['ē']='e', ['é']='e', ['ě']='e', ['è']='e',
    ['ī']='i', ['í']='i', ['ǐ']='i', ['ì']='i',
    ['ō']='o', ['ó']='o', ['ǒ']='o', ['ò']='o', ['ň']='n',
    ['ū']='u', ['ú']='u', ['ǔ']='u', ['ù']='u', ['ǹ']='n',
    ['ǖ']='ü', ['ǘ']='ü', ['ǚ']='ü', ['ǜ']='ü', ['ń']='n',
}

local function remove_pinyin_tone(s)
    local result = {}
    for uchar in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        table.insert(result, tone_map[uchar] or uchar)
    end
    return table.concat(result)
end

-- ----------------------
-- # 辅助码拆分提示模块
-- PRO 专用
-- ----------------------
local CF = {}
function CF.init(env)
    if wanxiang.is_pro_scheme(env) then
        CF.get_dict(env)
    end
end

function CF.fini(env)
    env.chaifen_dict = nil
    collectgarbage()
end

function CF.get_dict(env)
    if env.chaifen_dict == nil then
        env.chaifen_dict = ReverseLookup("wanxiang_chaifen")
    end
    return env.chaifen_dict
end

function CF.get_comment(cand, env, is_chaifen_enabled)
    if not is_chaifen_enabled then return "" end
    local dict = CF.get_dict(env)
    if not dict then return "" end

    local raw = dict:lookup(cand.text)
    if not raw or raw == "" then return "" end

    local tpl = (env and env.settings and env.settings.chaifen) or ""

    if tpl ~= "" then
        local left, right = tpl:match("^(.-)chaifen(.-)$")
        if left then
            return left .. raw .. right
        end
    end

    return raw
end

-- ----------------------
-- # 错音错字提示模块（修复版）
-- ----------------------
local CR = {}
local corrections_cache = nil -- 用于缓存已加载的词典
function CR.init(env)
    CR.style = env.settings.corrector_type or '{comment}'
    if corrections_cache then return end
    local auto_delimiter = env.settings.auto_delimiter
    local is_pro = wanxiang.is_pro_scheme(env)
    local path = (is_pro and "dicts/cuoyin.pro.dict.yaml") or "dicts/cuoyin.dict.yaml"
    
    -- 修复：新增pcall包裹（原版无此句，直接调用wanxiang.load_file_with_fallback）
    local ok, file, close_file, err = pcall(wanxiang.load_file_with_fallback, path)
    if not ok or not file then
        log.error(string.format("[super_comment]: 加载失败 %s，错误: %s", path, err or "未知错误"))
        corrections_cache = {} -- 修复：新增空缓存初始化（原版无此句，加载失败直接return）
        return
    end
    
    corrections_cache = {}
    for line in file:lines() do
        if not line:match("^#") then
            local text, code, weight, comment = line:match("^(.-)\t(.-)\t(.-)\t(.-)$")
            if text and code then
                text = text:match("^%s*(.-)%s*$")
                code = code:match("^%s*(.-)%s*$")
                comment = comment and comment:match("^%s*(.-)%s*$") or ""
                comment = comment:gsub("%s+", auto_delimiter)
                code = code:gsub("%s+", auto_delimiter)
                corrections_cache[code] = { text = text, comment = comment }
            end
        end
    end
    close_file()
end

-- 【CR模块 - 原版差异段落】（仅与修复版不同部分）
-- function CR.init(env)
--     CR.style = env.settings.corrector_type or '{comment}'
--     if corrections_cache then return end
--     local auto_delimiter = env.settings.auto_delimiter
--     local is_pro = wanxiang.is_pro_scheme(env)
--     local path = (is_pro and "dicts/cuoyin.pro.dict.yaml") or "dicts/cuoyin.dict.yaml"
--     local file, close_file, err = wanxiang.load_file_with_fallback(path)
--     if not file then
--         log.error(string.format("[super_comment]: 加载失败 %s，错误: %s", path, err))
--         return
--     end
--     corrections_cache = {}
--     for line in file:lines() do
--         if not line:match("^#") then
--             local text, code, weight, comment = line:match("^(.-)\t(.-)\t(.-)\t(.-)$")
--             if text and code then
--                 text = text:match("^%s*(.-)%s*$")
--                 code = code:match("^%s*(.-)%s*$")
--                 comment = comment and comment:match("^%s*(.-)%s*$") or ""
--                 comment = comment:gsub("%s+", auto_delimiter)
--                 code = code:gsub("%s+", auto_delimiter)
--                 corrections_cache[code] = { text = text, comment = comment }
--             end
--         end
--     end
--     close_file()
-- end

function CR.get_comment(cand)
    local correction = corrections_cache and corrections_cache[cand.comment] or nil
    if not (correction and cand.text == correction.text) then
        return nil
    end
    local tpl = CR.style or "comment"
    local left, right = tpl:match("^(.-)comment(.-)$")

    if left then
        return left .. correction.comment .. right
    else
        return correction.comment
    end
end

-- ----------------------
-- 部件组字返回的注释
-- ----------------------
---@return string
local function get_az_comment(_, env, initial_comment)
    if not initial_comment or initial_comment == "" then return "〔无〕" end
    local final_comment = nil
    local auto_delimiter = env.settings.auto_delimiter or " "
    local segments = {}
    for segment in initial_comment:gmatch("[^%s]+") do
        table.insert(segments, segment)
    end
    local semicolon_count = select(2, segments[1]:gsub(";", ""))
    local pinyins = {}
    local fuzhu = nil
    for _, segment in ipairs(segments) do
        local pinyin = segment:match("^[^;~]+")
        local fz = nil

        if semicolon_count == 1 then
            fz = segment:match(";(.+)$")
        else
            fz = nil
        end

        if pinyin then table.insert(pinyins, pinyin) end
        if not fuzhu and fz and fz ~= "" then fuzhu = fz end
    end

    if #pinyins > 0 then
        local pinyin_str = table.concat(pinyins, ",")
        if fuzhu then
            final_comment = string.format("〔音%s 辅%s〕", pinyin_str, fuzhu)
        else
            final_comment = string.format("〔音%s〕", pinyin_str)
        end
    end
    return final_comment or "〔无〕"
end

-- ----------------------
-- # 辅助码提示或带调全拼注释模块 (Fuzhu)
-- ----------------------
local function get_fz_comment(cand, env, initial_comment)
    local length = utf8.len(cand.text)
    if length > env.settings.candidate_length then
        return ""
    end
    local auto_delimiter = env.settings.auto_delimiter or " "
    local segments = {}
    for segment in string.gmatch(initial_comment, "[^" .. auto_delimiter .. "]+") do
        table.insert(segments, segment)
    end

    local use_tone = env.engine.context:get_option("tone_hint")
    local fuzhu_type = use_tone and "tone" or "fuzhu"

    local first_segment = segments[1] or ""
    local semicolon_count = select(2, first_segment:gsub(";", ""))
    local fuzhu_comments = {}
    if semicolon_count == 0 then
        return initial_comment:gsub(auto_delimiter, " ")
    else
        for _, segment in ipairs(segments) do
            if fuzhu_type == "tone" then
                local before = segment:match("^(.-);")
                if before and before ~= "" then
                    table.insert(fuzhu_comments, before)
                end
            else
                local after = segment:match(";(.+)$")
                if after and after ~= "" then
                    table.insert(fuzhu_comments, after)
                end
            end
        end
    end

    if #fuzhu_comments > 0 then
        if fuzhu_type == "tone" then
            return table.concat(fuzhu_comments, " ")
        else
            return table.concat(fuzhu_comments, "/")
        end
    else
        return ""
    end
end

-- ----------------------
-- SV模块（修复版 - 核心修复）
-- ----------------------
local SV = {}
-- 修复：新增缓存表（原版无此句）
SV.cache = {}
local function front_input(ctx)
    if not ctx then return "" end
    local raw_full = ctx.input or ""
    local caret    = ctx.caret_pos or #raw_full
    return raw_full:sub(1, caret)
end
function SV.init(env)
    env._sv_seq_sig          = ""
    env._sv_last_pre         = ""
    env._saved_input_for_seq = ""
    local ctx = env.engine.context
    env._sv_ctx_conn = ctx.update_notifier:connect(function(c)
        local raw_in = front_input(c)
        local pre = env._sv_last_pre or ""
        if pre == "" or raw_in == "" then return end
        local sig = raw_in .. "\t" .. pre
        if env._sv_seq_sig == sig then return end
        -- 修复：用缓存表替代属性设置（原版为下方2句）
        SV.cache.sequence_preedit_key = raw_in
        SV.cache.sequence_preedit_val = pre
        env._sv_seq_sig = sig
    end)
end
function SV.fini(env)
    if env._sv_ctx_conn then
        env._sv_ctx_conn:disconnect()
        env._sv_ctx_conn = nil
    end
    env._sv_seq_sig          = nil
    env._sv_last_pre         = nil
    env._saved_input_for_seq = nil
    -- 修复：清理缓存表（原版无此句）
    SV.cache = {}
end
function SV.update_preedit(env, preedit)
    local ctx = env.engine.context
    if not ctx then return end
    local raw_in = front_input(ctx)
    preedit = preedit or ""
    if raw_in == "" or preedit == "" then return end
    if env._saved_input_for_seq ~= raw_in then
        env._saved_input_for_seq = raw_in
        env._sv_last_pre         = preedit
    end
end
-- 修复：新增数据读取接口（原版无此函数）
function SV.get_cache(key)
    return SV.cache[key] or ""
end

-- 【SV模块 - 原版差异段落】（仅与修复版不同部分）
-- local SV = {}
-- local function front_input(ctx)
--     if not ctx then return "" end
--     local raw_full = ctx.input or ""
--     local caret    = ctx.caret_pos or #raw_full
--     return raw_full:sub(1, caret)
-- end
-- function SV.init(env)
--     env._sv_seq_sig          = ""
--     env._sv_last_pre         = ""
--     env._saved_input_for_seq = ""
--     local ctx = env.engine.context
--     env._sv_ctx_conn = ctx.update_notifier:connect(function(c)
--         local raw_in = front_input(c)
--         local pre = env._sv_last_pre or ""
--         if pre == "" or raw_in == "" then return end
--         local sig = raw_in .. "\t" .. pre
--         if env._sv_seq_sig == sig then return end
--         -- 原版闪退核心代码（修复版已替换）
--         c:set_property("sequence_preedit_key", raw_in)
--         c:set_property("sequence_preedit_val", pre)
--         env._sv_seq_sig = sig
--     end)
-- end
-- function SV.fini(env)
--     if env._sv_ctx_conn then
--         env._sv_ctx_conn:disconnect()
--         env._sv_ctx_conn = nil
--     end
--     env._sv_seq_sig          = nil
--     env._sv_last_pre         = nil
--     env._saved_input_for_seq = nil
-- end
-- function SV.update_preedit(env, preedit)
--     local ctx = env.engine.context
--     if not ctx then return end
--     local raw_in = front_input(ctx)
--     preedit = preedit or ""
--     if raw_in == "" or preedit == "" then return end
--     if env._saved_input_for_seq ~= raw_in then
--         env._saved_input_for_seq = raw_in
--         env._sv_last_pre         = preedit
--     end
-- end

-- ----------------------
-- 对 cand.preedit 应用 tone_preedit/0..9 的映射
-- ----------------------
local function apply_tone_preedit(env, cand)
    if not cand or not cand.preedit or cand.preedit == "" then
        return
    end

    if not env.tone_map then
        env.tone_map = {}
        local cfg = env.engine.schema.config
        for d = 0, 9 do
            local k = tostring(d)
            local v = cfg:get_string("tone_preedit/" .. k)
            if v and v ~= "" then
                env.tone_map[k] = v
            end
        end
    end

    local preedit = cand.preedit
    local converted = preedit:gsub("([^%d%s]+)(%d+)", function(body, digits)
        local mapped = digits:gsub("%d", function(d)
            return env.tone_map[d] or d
        end)
        return body .. mapped
    end)

    if converted ~= preedit then
        cand.preedit = converted
    end
end

-- ----------------------
-- 主模块
-- ----------------------
local ZH = {}
function ZH.init(env)
    local config = env.engine.schema.config
    local delimiter = config:get_string('speller/delimiter') or " '"
    local auto_delimiter = delimiter:sub(1, 1)
    local manual_delimiter = delimiter:sub(2, 2)
    env.settings = {
        delimiter = delimiter,
        auto_delimiter = auto_delimiter,
        manual_delimiter = manual_delimiter,
        corrector_enabled = config:get_bool("super_comment/corrector") or true,
        corrector_type = config:get_string("super_comment/corrector_type") or "{comment}",
        chaifen = config:get_string("super_comment/chaifen") or "〔chaifen〕",
        candidate_length = tonumber(config:get_string("super_comment/candidate_length")) or 1,
    }
    CR.init(env)
    CF.init(env)
    SV.init(env)
end
function ZH.fini(env)
    CF.fini(env)
    SV.fini(env)
    corrections_cache = nil
end
function ZH.func(input, env)
    local config = env.engine.schema.config
    local context = env.engine.context
    local input_str = context.input
    local is_radical_mode = wanxiang.is_in_radical_mode(env)
    local schema_id = env.engine.schema.schema_id or ""
    local is_wanxiang_pro = (schema_id == "wanxiang_pro")
    local should_skip_candidate_comment = wanxiang.is_function_mode_active(context) or input_str == ""
    local is_tone_comment = env.engine.context:get_option("tone_hint")
    local is_comment_hint = env.engine.context:get_option("fuzhu_hint")
    local is_chaifen_enabled = env.engine.context:get_option("chaifen_switch") or false
    local delimiter = env.settings.delimiter
    local auto_delimiter = env.settings.auto_delimiter
    local manual_delimiter = env.settings.manual_delimiter
    local visual_delim = config:get_string("speller/visual_delimiter") or " "
    local tone_isolate = config:get_bool("speller/tone_isolate")
    local is_tone_display = context:get_option("tone_display")
    local is_full_pinyin = context:get_option("full_pinyin")
    local index = 0
    local enable_auto_phrase = config:get_bool("add_user_dict/enable_auto_phrase") or false
    local enable_user_dict = config:get_bool("add_user_dict/enable_user_dict") or false

    for cand in input:iter() do
        local genuine_cand = cand:get_genuine()
        local preedit = genuine_cand.preedit or ""
        local initial_comment = genuine_cand.comment
        local final_comment = initial_comment
        index = index + 1

        SV.update_preedit(env, preedit)

        if is_radical_mode then
            goto after_preedit
        end
        if not is_tone_display and not is_full_pinyin then
            goto after_preedit
        end
        if (not initial_comment or initial_comment == "") then
            goto after_preedit
        end
        do
            local input_parts = {}
            local current_segment = ""
            for i = 1, #preedit do
                local char = preedit:sub(i, i)
                if char == auto_delimiter or char == manual_delimiter then
                    if #current_segment > 0 then
                        table.insert(input_parts, current_segment)
                        current_segment = ""
                    end
                    table.insert(input_parts, char)
                else
                    current_segment = current_segment .. char
                end
            end
            if #current_segment > 0 then
                table.insert(input_parts, current_segment)
            end

            local pinyin_segments = {}
            for segment in string.gmatch(initial_comment, "[^" .. auto_delimiter .. manual_delimiter .. "]+") do
                local pinyin = segment:match("^[^;]+")
                if pinyin then
                    pinyin = pinyin:gsub("[%[%]]", "")
                    table.insert(pinyin_segments, pinyin)
                end
            end

            local pinyin_index = 1
            for i, part in ipairs(input_parts) do
                if part == auto_delimiter or part == manual_delimiter then
                    input_parts[i] = visual_delim
                else
                    local body, tone = part:match("([%a]+)([^%a]+)")
                    local py = pinyin_segments[pinyin_index]

                    if py then
                        if is_wanxiang_pro then
                            input_parts[i] = py
                            pinyin_index = pinyin_index + 1
                        elseif i == #input_parts and #part == 1 then
                            local prefix = py:sub(1, 2)
                            local first_char = part:sub(1,1):lower()
                            if first_char == "s" or first_char == "c" or first_char == "z" then
                                input_parts[i] = part
                            else
                                if prefix == "zh" or prefix == "ch" or prefix == "sh" then
                                    input_parts[i] = prefix
                                else
                                    input_parts[i] = part
                                end
                            end
                        else
                            if tone_isolate then
                                input_parts[i] = py .. (tone or "")
                            else
                                input_parts[i] = py
                            end
                            pinyin_index = pinyin_index + 1
                        end
                    end
                end
            end

            if is_full_pinyin then
                for idx, part in ipairs(input_parts) do
                    input_parts[idx] = remove_pinyin_tone(part)
                end
            end

            genuine_cand.preedit = table.concat(input_parts)
        end
        ::after_preedit::
        apply_tone_preedit(env, genuine_cand)
        if should_skip_candidate_comment then
            yield(genuine_cand)
            goto continue
        end
        -- ① 辅助码注释或者声调注释
        if is_comment_hint then
            local fz_comment = get_fz_comment(cand, env, initial_comment)
            if fz_comment then
                final_comment = fz_comment
            end
        elseif is_tone_comment then
            local fz_comment = get_fz_comment(cand, env, initial_comment)
            if fz_comment then
                final_comment = fz_comment
            end
        else
            final_comment = ""
        end

        -- ② 拆分注释
        if is_chaifen_enabled then
            local cf_comment = CF.get_comment(cand, env, is_chaifen_enabled)
            if cf_comment and cf_comment ~= "" then
                final_comment = cf_comment
            end
        end

        -- ③ 错音错字提示
        if env.settings.corrector_enabled then
            local cr_comment = CR.get_comment(cand)
            if cr_comment and cr_comment ~= "" then
                final_comment = cr_comment
            end
        end

        -- ④ 反查模式提示
        if is_radical_mode then
            local az_comment = get_az_comment(cand, env, initial_comment)
            if az_comment and az_comment ~= "" then
                final_comment = az_comment
            end
        end
        -- 应用注释
        if final_comment ~= initial_comment then
            genuine_cand.comment = final_comment
        end

        yield(genuine_cand)
        ::continue::
    end
end
return ZH
