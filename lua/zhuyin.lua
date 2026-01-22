-- 带调全拼注释模块（基于原始注释处理）
local zhuyin = {}

local ZY = {}

function ZY.init(env)
    env.zhuyin_dict = ReverseLookup("wanxiang_pro")
end

function ZY.fini(env)
    env.zhuyin_dict = nil
    collectgarbage()
end

local function process_existing_comment(comment)
    if not comment or comment == "" then return comment end
    -- 删除分号与单引号/空格间内容
    local processed = comment:gsub(";[^' ]*[' ]", " ")
    -- 删除末尾分号内容
    local last_semicolon = processed:find(";[^;]*$")
    if last_semicolon then processed = processed:sub(1, last_semicolon - 1) end
    -- 清理多余空格
    return processed:gsub("%s+", " "):gsub("^%s*(.-)%s*$", "%1")
end

local function process_annotation(raw, is_single_char)
    if not raw or raw == "" then return raw end
    if is_single_char then
        return raw:gsub(";[^%s]*", "")  -- 单字保留多音
    end
    return raw:match("^([^;]*)") or raw  -- 多字取首音
end

function ZY.run(cand, env)
    local dict = env.zhuyin_dict
    if not dict or #cand.text == 0 then return nil end
    
    local char_count = select(2, cand.text:gsub("[^\128-\193]", ""))
    -- 从全局变量获取原始注释
    local raw_comment = _RIME_RAW_CAND_COMMENT and _RIME_RAW_CAND_COMMENT[cand.text] or nil
    
    -- 1. 注释有分号：原生注释处理（优先，清理分号后内容）
    if raw_comment and raw_comment:find(";") then
        return process_existing_comment(raw_comment)
    
    -- 2. 注释没有分号（含无注释）：单字显示所有发音
    elseif char_count == 1 then
        local raw = dict:lookup(cand.text)
        -- 无注释时 raw 为 nil，process_annotation 会返回 nil，最终不显示注释
        return process_annotation(raw, true)
    
    -- 3. 注释没有分号（含无注释）：多字每字取首音
    elseif char_count > 1 then
        local parts, has_annotation = {}, false
        for char in cand.text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
            local raw = dict:lookup(char)
            local part = process_annotation(raw, false) or char
            table.insert(parts, part)
            if part ~= char then has_annotation = true end
        end
        -- 无注释时 has_annotation 为 false，返回 nil 不显示注释
        return has_annotation and table.concat(parts, " ") or nil
    end
    return nil
end

function zhuyin.init(env)
    ZY.init(env)
    -- 读取注音开关配置
    local config = env.engine.schema.config
    env.settings = {
        pinyin_switch = config:get_bool("super_comment/pinyin") or true
    }
end

function zhuyin.fini(env)
    ZY.fini(env)
end

function zhuyin.func(input, env)
    local is_tone_comment = env.engine.context:get_option("pinyin")
    
    for cand in input:iter() do
        if is_tone_comment then
            local zy_comment = ZY.run(cand, env)
            if zy_comment then
                cand:get_genuine().comment = zy_comment
            end
        end
        yield(cand)
    end
end

return zhuyin
