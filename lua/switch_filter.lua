local M = {}

-- ========== 准备区 ==========
local utf8_len = utf8.len
local string_gmatch = string.gmatch
local string_sub = string.sub
local string_match = string.match
local string_gsub = string.gsub
local byte = string.byte

-- 快速汉字检测
local function is_chinese_char(codepoint)
    return (codepoint >= 0x4e00 and codepoint <= 0x9fff) or       -- 基本
           (codepoint >= 0x3400 and codepoint <= 0x4dbf) or       -- 扩A
           (codepoint >= 0x20000 and codepoint <= 0x2a6df) or     -- 扩B
           (codepoint >= 0x2a700 and codepoint <= 0x2b73f) or     -- 扩C
           (codepoint >= 0x2b740 and codepoint <= 0x2b81f) or     -- 扩D
           (codepoint >= 0x2b820 and codepoint <= 0x2ceaf) or     -- 扩E
           (codepoint >= 0x2ceb0 and codepoint <= 0x2ebef) or     -- 扩F
           (codepoint >= 0x30000 and codepoint <= 0x3134f) or     -- 扩G
           (codepoint >= 0x31350 and codepoint <= 0x323af) or     -- 扩H
           (codepoint >= 0x2EBF0 and codepoint <= 0x2EE5F) or     -- 扩I
           (codepoint >= 0x2e80 and codepoint <= 0x2eff) or       -- 部首扩展
           (codepoint >= 0x2f00 and codepoint <= 0x2fdf) or       -- 康熙部首
           (codepoint >= 0xf900 and codepoint <= 0xfadf) or       -- 兼容
           (codepoint >= 0x2f800 and codepoint <= 0x2fa1f) or     -- 兼补
           (codepoint >= 0x2ff0 and codepoint <= 0x2fff) or       -- 汉字结构
           (codepoint >= 0x3100 and codepoint <= 0x312f) or       -- 注音
           (codepoint >= 0x31a0 and codepoint <= 0x31bf)          -- 注音扩展
end

local function contains_chinese_fast(text)
    for i = 1, #text do
        local b = byte(text, i)
        if b >= 0xe0 then
            local codepoint
            if b >= 0xf0 then
                -- 4字节UTF8字符（对应扩B及以上汉字）
                if i + 3 <= #text then
                    codepoint = ((b - 0xf0) * 0x40000) + ((byte(text, i+1) - 0x80) * 0x1000) +
                               ((byte(text, i+2) - 0x80) * 0x40) + (byte(text, i+3) - 0x80)
                end
            else
                -- 3字节UTF8字符（对应基本、扩A等汉字）
                if i + 2 <= #text then
                    codepoint = ((b - 0xe0) * 0x1000) + ((byte(text, i+1) - 0x80) * 0x40) + 
                               (byte(text, i+2) - 0x80)
                end
            end
            if codepoint and is_chinese_char(codepoint) then
                return true
            end
        end
    end
    return false
end

local function is_all_chinese_fast(text)
    local i = 1
    local len = #text
    while i <= len do
        local b = byte(text, i)
        if b < 0x80 then
            -- ASCII字符：直接判定非汉字
            return false
        elseif b >= 0xF0 then
            -- 4字节UTF8：必须是扩B及以上汉字
            if i + 3 > len then return false end
            local codepoint = ((b - 0xF0) * 0x40000) + ((byte(text, i+1) - 0x80) * 0x1000) +
                             ((byte(text, i+2) - 0x80) * 0x40) + (byte(text, i+3) - 0x80)
            if not is_chinese_char(codepoint) then return false end
            i = i + 4
        elseif b >= 0xE0 then
            -- 3字节UTF8：必须是基本、扩A等汉字
            if i + 2 > len then return false end
            local codepoint = ((b - 0xE0) * 0x1000) + ((byte(text, i+1) - 0x80) * 0x40) + 
                             (byte(text, i+2) - 0x80)
            if not is_chinese_char(codepoint) then return false end
            i = i + 3
        else
            -- 2字节UTF8（0x80-0xE0）：非汉字（如日文假名、半角符号）
            return false
        end
    end
    return true
end

-- 字符类型快速检测
local function is_alnum_char(c)
    return (c >= 0x41 and c <= 0x5A) or (c >= 0x61 and c <= 0x7A) or (c >= 0x30 and c <= 0x39)
end

local function contains_alnum(text)
    for i = 1, #text do
        if is_alnum_char(byte(text, i)) then
            return true
        end
    end
    return false
end

local function contains_digit(text)
    for i = 1, #text do
        local b = byte(text, i)
        if b >= 0x30 and b <= 0x39 then
            return true
        end
    end
    return false
end

local function contains_alpha(text)
    for i = 1, #text do
        local b = byte(text, i)
        if (b >= 0x41 and b <= 0x5A) or (b >= 0x61 and b <= 0x7A) then
            return true
        end
    end
    return false
end

-- 快速获取属性
local function get_cand_props(cand)
    local text = cand.text
    local preedit = cand.preedit or ""
    local comment = cand.comment or ""
    local ctype = cand.type
    
    return {
        cand = cand,
        text = text,
        preedit = preedit,
        comment = comment,
        type = ctype,
        text_len = utf8_len(text),
        preedit_len = utf8_len(preedit),
        comment_len = #comment,
        is_all_chinese = is_all_chinese_fast(text),
        has_digit = contains_digit(text),
        has_alpha = contains_alpha(text),
        has_chinese = contains_chinese_fast(text)
    }
end

function M.init(env)
    local function alt_lua_punc(s)
        if s then
            return s:gsub('([%.%+%-%*%?%[%]%^%$%(%)%%])', '%%%1')
        else
            return ''
        end
    end

    local config = env.engine.schema.config
    local ns = 'search'
    env.tiger_four = ""

    local search_key = config:get_string('key_binder/search') or config:get_string(ns .. '/key') or '`'
    env.search_key_alt = alt_lua_punc(search_key)
    env.search_key = search_key
    env.code_pattern = config:get_string(ns .. '/code_pattern') or '[a-z;]'

    -- 初始化延迟清除相关变量
    env.cand_counter = 0  -- 候选计数器
    env.delayed_clear = false  -- 延迟清除标志
    env.start_clear = 0  -- 开始清除的时间点（计数器值）
    env.clear_delay = 5  -- 延迟的候选数量（可调整）
    env.last_input = ""  -- 上次输入，用于检测输入变化

    -- 保留原事件监听逻辑
    env.select_notifier = env.engine.context.select_notifier:connect(function(ctx)
        local input = ctx.input
        if env.search_key_alt then
            local code = input:match('^(.-)' .. env.search_key_alt)
            if not code or #code == 0 then return end
            
            local preedit = ctx:get_preedit()
            local no_search_string = ctx.input:match('^(.-)' .. env.search_key_alt)
            local edit = preedit.text:match('^(.-)' .. env.search_key_alt)
            env.have_select_commit = true
            
            if edit and edit:match(env.code_pattern or '[a-z;]') then
                ctx.input = no_search_string .. env.search_key
            else
                ctx.input = no_search_string
                ctx:commit()
            end
        end
    end)
end

-- 主处理函数 - 流式处理
function M.func(input, env)
    local context = env.engine.context
    local input_str = context.input
    local input_len = #input_str
    local input_preedit = context:get_preedit().text
    
    -- 创建一个上下文标识符，用于检测是否是全新的输入
    local current_context = input_str .. "|" .. tostring(context.composition:back())
    
    -- 检测上下文是否变化，如果是全新输入则重置延迟清除状态
    if env.last_context ~= current_context then
        env.cand_counter = 0
        env.delayed_clear = false
        env.start_clear = 0
        env.last_context = current_context
    end
    
    local input_first_char = ""
    if input_len > 0 then
        -- 快速取首字符（UTF-8 兼容），直接截取首字符避免 utf8 库开销
        input_first_char = string_sub(input_str, 1, 1):lower()
    end
    
    -- 计算输入码的字母数
    local input_letter_count = 0
    for i = 1, input_len do
        local b = byte(input_str, i)
        if (b >= 0x41 and b <= 0x5A) or (b >= 0x61 and b <= 0x7A) then
            input_letter_count = input_letter_count + 1
        end
    end
    
    local last_char = input_len > 0 and string_sub(input_str, -1) or ""
    local last_two = input_len > 1 and string_sub(input_str, -2) or ""
    
    -- 预计算选项
    local en_on = context:get_option("english_word")
    local char_on = context:get_option("char")
    local word_on = context:get_option("word")
    local sentence_on = context:get_option("sentence")
    local yin_on = context:get_option("yin")
    local chinese_english_on = context:get_option("chinese_english")
    
    local is_radical_mode = false
    local seg = context.composition:back()
    if seg and (seg:has_tag("radical_lookup") or seg:has_tag("reverse_stroke") or 
                seg:has_tag("add_user_dict") or seg:has_tag("yin_add_user")) then
        is_radical_mode = true
    end
    
    local is_prefix_input = input_preedit:find("^[VRNU/;]")
    local has_backslash = input_str:find("\\")
    local has_backtick = input_preedit:find("`")
    
    local zm_candidates = {}
    local chinese_alpha = {}
    local before_digit = {}
    local table_digit = {}
    
    -- 流式处理：逐个处理候选词
    for cand in input:iter() do
        local props = get_cand_props(cand)
        local ctype = props.type
        -- 增加候选计数器
        env.cand_counter = env.cand_counter + 1
        
        -- 检查是否需要执行延迟清除
        if env.delayed_clear then
            if env.cand_counter - env.start_clear >= env.clear_delay then
                context.candidates:clear()
                env.delayed_clear = false
                -- 清除后，我们不再处理当前候选，直接跳过
                goto continue
            else
                -- 在延迟期间，正常处理其他候选
                -- 继续执行下面的处理逻辑
            end
        end
        
        -- 特殊处理：成对符号包裹
        if has_backslash then
            yield(cand)
            goto continue
        end
        
        -- 时间候选词

        if ctype == "time" or ctype == "date" or ctype == "day_summary" or 
           ctype == "xq" or ctype == "oww" or ctype == "ojq" or 
           ctype == "holiday_summary" or ctype == "birthday_reminders" then
            yield(cand)
            goto continue
        end
        
        -- 文件候选词
        if ctype == input_str then
            yield(cand)
            goto continue
        end
        
        -- 前缀候选词
        if is_prefix_input then
            yield(cand)
            goto continue
        end
        
        -- 反查候选词
        if is_radical_mode then
            yield(cand)
            goto continue
        end
        
        -- 跳过特定字符
        if props.text == "呣" or props.text == "呒" then
            goto continue
        end

        -- 拼音候选词
        if props.comment:find(";") then
            if yin_on or has_backtick then
                yield(cand)
            end
            goto continue
        end
        
        -- 无注释和预编辑文本的候选词
        if props.comment_len == 0 and props.preedit_len == 0 then
            -- 字母候选词
            if props.text:lower() == input_str:lower() then
                if en_on then
                    zm_candidates[#zm_candidates+1] = cand
                end
                goto continue
            end
            
            -- z历史候选词
            if input_len == 1 then
                yield(cand)
            end
            goto continue
        end

        if props.is_all_chinese then
            -- 全汉字候选词
            if props.comment_len == 0 then
                -- 无注释的候选词
                if input_letter_count == 0 then
                    yield(cand)  -- 预测候选词
                elseif props.preedit_len >= 5 then
                    if sentence_on and not has_backtick then
                        if ctype == "user_phrase" then
                            yield(cand)
                        elseif ctype == "phrase" and not props.preedit:find("['_*]") and props.text_len == 1 then
                        elseif ctype == "phrase" and props.comment:find("[/]") then
                        else
                            yield(cand)
                        end
                    end
                elseif props.text_len >= 2 then
                    -- 虎词
                    if (char_on and word_on) or word_on then
                        yield(cand)
                    end
                else
                    -- 虎单
                    if (char_on and word_on) or char_on then
                        yield(cand)
                    end
                end
            else
                if sentence_on and not has_backtick then
                    if ctype == "sentence" then -- 句子
                        yield(cand)
                    elseif ctype == "user_phrase" then -- 用户自造词
                        yield(cand)
                    else
                        if ctype == "phrase" and input_len < 4 and not props.preedit:find("['_*]") then
                            if not chinese_english_on and not yin_on and not en_on then
                                -- 设置延迟清除标志
                                env.delayed_clear = true
                                env.start_clear = env.cand_counter
                                -- 跳过当前候选，不yield
                                goto continue
                            end
                        else
                               yield(cand)
                        end
                    end
                end
                
            end
        else
            if props.has_digit then
                -- 数字候选词
                if ctype == "user_table" then
                    yield(cand)
                elseif ctype == "table" then
                    table_digit[#table_digit+1] = cand
                elseif ctype == "completion" then
                    before_digit[#before_digit+1] = cand
                else
                    before_digit[#before_digit+1] = cand
                end
            elseif props.has_alpha then
              local input_lower = input_str:lower()  -- 预计算小写输入串，避免重复转换
              local text_lower = props.text:lower()  -- 候选文本转小写，实现大小写不敏感匹配
              local text_contains_input = input_lower ~= "" and text_lower:find(input_lower, 1, true) ~= nil
              if ctype == "user_table" then
                    yield(cand)
              elseif en_on or yin_on or chinese_english_on then
                if (props.has_chinese and ctype == "completion") or (not text_contains_input and ctype == "completion") then
                    chinese_alpha[#chinese_alpha+1] = cand
                else
                    yield(cand)
                end
              end
            else
                -- 符号候选词
                local preedit_letter_count = 0
                for i = 1, props.preedit_len do
                    local b = byte(props.preedit, i)
                    if (b >= 0x41 and b <= 0x5A) or (b >= 0x61 and b <= 0x7A) then
                        preedit_letter_count = preedit_letter_count + 1
                    end
                end
                
                if preedit_letter_count == 0 then
                    yield(cand)  -- 0码符号
                elseif ctype == "user_table" then
                    yield(cand)  -- 用户快符
                elseif preedit_letter_count == 2 then
                    yield(cand)  -- 2码符号
                elseif preedit_letter_count == 1 then
                  if (char_on and not word_on) then
                    yield(cand)  -- 1码快符
                  end
                else
                    yield(cand)  -- 其他快符
                end
            end
        end
        
        ::continue::
    end

        for _, cand in ipairs(zm_candidates) do
            yield(cand)
        end
        for _, cand in ipairs(table_digit) do
            yield(cand)
        end
        
    if en_on or yin_on then
        for _, cand in ipairs(chinese_alpha) do
            yield(cand)
        end
        for _, cand in ipairs(before_digit) do
            yield(cand)
        end
    end
    
end

function M.fini(env)
    if env.select_notifier then
        env.select_notifier:disconnect()
    end
end

return M
