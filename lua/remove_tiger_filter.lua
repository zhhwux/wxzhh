
local M = {}

-- **获取辅助码**
function M.run_fuzhu(cand, env, initial_comment)
    local patterns = {
        moqi = "[^;]*;([^;]*);",
        flypy = "[^;]*;[^;]*;([^;]*);",
        zrm = "[^;]*;[^;]*;[^;]*;([^;]*);",
        jdh = "[^;]*;[^;]*;[^;]*;[^;]*;([^;]*);",
        cj = "[^;]*;[^;]*;[^;]*;[^;]*;[^;]*;([^;]*);",
        tiger = "[^;]*;[^;]*;[^;]*;[^;]*;[^;]*;[^;]*;([^;]*);",
        wubi = "[^;]*;[^;]*;[^;]*;[^;]*;[^;]*;[^;]*;[^;]*;([^;]*);",
        hanxin = "[^;]*;[^;]*;[^;]*;[^;]*;[^;]*;[^;]*;[^;]*;[^;]*;([^;]*)"
    }

    local pattern = patterns[env.settings.fuzhu_type]
    if not pattern then return {}, {} end  

    local full_fuzhu_list, first_fuzhu_list = {}, {}

    for segment in initial_comment:gmatch("[^%s]+") do
        local match = segment:match(pattern)
        if match then
            for sub_match in match:gmatch("[^,]+") do
                table.insert(full_fuzhu_list, sub_match)
                local first_char = sub_match:sub(1, 1)
                if first_char and first_char ~= "" then
                    table.insert(first_fuzhu_list, first_char)
                end
            end
        end
    end

    return full_fuzhu_list, first_fuzhu_list
end
-- **初始化**
function M.init(env)
    local config = env.engine.schema.config
    env.settings = {
        fuzhu_type = config:get_string("super_comment/fuzhu_type") or ""
    }
end
    -- **判断是否为字母或数字和特定符号**
local function is_alnum(text)
    return text:match("[%w%s.·-_']") ~= nil
end

-- 判断是否包含数字但不包含字母
local function contains_digit_no_alpha(text)
    return text:match("%d") ~= nil and not text:match("[%a]")  -- 包含数字且不包含字母
end

-- 判断是否包含字母
local function contains_alpha(text)
    return text:match("[%a]") ~= nil  -- %a 匹配字母字符
end

-- 判断是否只包含指定标点符号
local function contains_only_punctuation(text)
    return text:match("^[\\\\,.，#&*+=~%s；：？%‰%-%^—～！…→←（）“”%%%[%]]*$") ~= nil or text:match("^[、。《》]*$") ~= nil 
end

-- 判断注释是否不包含分号
local function contains_no_semicolons(comment)
    return not comment:find(";")
end

-- 主逻辑
function M.func(input, env)
    local context = env.engine.context

    -- 候选词存储
    local fc_candidates = {}    -- 反查候选词
    local digit_candidates = {}  -- 包含数字但不包含字母的候选词
    local alnum_candidates = {}  -- 包含字母的候选词
    local punctuation_candidates = {}  -- 只包含指定标点符号的候选词
    local unique_candidates = {}  -- 没有注释的候选词
    local tiger_sentence = {}  -- 注释不包含分号
    local other_candidates = {}

    -- 候选词收集
    for cand in input:iter() do
        local text = cand.text or ""
        local seg = context.composition:back()
        env.is_radical_mode = seg and (
            seg:has_tag("radical_lookup") 
            or seg:has_tag("reverse_stroke") 
            or seg:has_tag("add_user_dict")
        ) or false
        if env.is_radical_mode then
            table.insert(fc_candidates, cand)
        elseif contains_digit_no_alpha(text) then
            table.insert(digit_candidates, cand)
        elseif contains_alpha(text) then
            table.insert(alnum_candidates, cand)
        elseif contains_only_punctuation(text) and  contains_no_semicolons(cand.comment) then 
            table.insert(punctuation_candidates, cand)
        elseif cand.comment == "" then
            table.insert(unique_candidates, cand)
        elseif contains_no_semicolons(cand.comment) then 
            table.insert(tiger_sentence, cand)
        else
            table.insert(other_candidates, cand)
        end
    end

    -- 输出包含数字但不包含字母的候选词
    for _, cand in ipairs(digit_candidates) do
        yield(cand)
    end

    -- 反查候选词
    for _, cand in ipairs(fc_candidates) do
        yield(cand)
    end

    local tiger_tigress = {}    -- 虎单与虎词
    local other_tigress = {}
    local useless_candidates = {}
    local yc_candidates = {}    -- 预测候选词
    
    local input_preedit = context:get_preedit().text
    for _, cand in ipairs(unique_candidates) do
    local letter_count = 0
    for _ in input_preedit:gmatch("%a") do 
        letter_count = letter_count + 1
    end
    local cand_length = utf8.len(cand.preedit)
    
        if letter_count == 0 then
            table.insert(yc_candidates, cand)
        elseif letter_count ~= cand_length then
            table.insert(useless_candidates, cand)
        elseif cand_length  >= 5 then
            table.insert(tiger_sentence, cand)
        else
            table.insert(tiger_tigress, cand)
        end
    end
    
    local tigress_candidates = {}    -- 虎词候选词
    local tiger_candidates = {}      -- 虎单候选词
    for _, cand in ipairs(tiger_tigress) do
        if utf8.len(cand.text) >= 2 then
            table.insert(tigress_candidates, cand)
        else
            table.insert(tiger_candidates, cand)
        end
    end

    -- 🐯 虎单开关与虎词开关
    if context:get_option("tiger") and context:get_option("tigress") then
        for _, cand in ipairs(tiger_tigress) do
            yield(cand)
        end
    elseif context:get_option("tiger") then
        for _, cand in ipairs(tiger_candidates) do
            yield(cand)
        end
    elseif context:get_option("tigress") then
        for _, cand in ipairs(tigress_candidates) do
            yield(cand)
        end
    else
    end

    -- 🐯 虎句开关
    if context:get_option("tiger-sentence") then
    -- 拆分虎句组为第一组和第二组
        local first_tiger = {}
        local rest_tiger = {}
        local first_group_assigned = false
        for _, cand in ipairs(tiger_sentence) do
            if not first_group_assigned then
            -- 如果还没有分配第一个候选到第一组，则将当前候选放入第一组
                table.insert(first_tiger, cand)
                first_group_assigned = true  -- 标记已经分配了第一个候选   
            else
                table.insert(rest_tiger, cand)
            end
        end   
        if context:get_option("simple") then
            for _, cand in ipairs(first_tiger) do
                yield(cand)
            end      
            else
            for _, cand in ipairs(rest_tiger) do
                yield(cand)
            end
        end   
    end

    -- 输出特定符号
    for _, cand in ipairs(punctuation_candidates) do
        yield(cand)
    end


    local input_code = env.engine.context.input
    local input_len = utf8.len(input_code)

    -- **缓存候选项，防止迭代器被消耗**
    local first_cand = nil
    local candidates = {}

    for _, cand in ipairs(other_candidates) do
        if not first_cand then first_cand = cand end
        table.insert(candidates, cand)
    end

    -- **如果输入码长 > 4，则直接输出默认排序**
    if input_len > 4 then
        for _, cand in ipairs(candidates) do yield(cand) end
        return
    end
    -- **如果第一个候选是字母/数字，则直接返回默认候选**
    if first_cand and is_alnum(first_cand.text) then
        for _, cand in ipairs(candidates) do yield(cand) end
        return
    end
    local single_char_cands, alnum_cands, other_cands = {}, {}, {}

    if input_len >= 3 and input_len <= 4 then
        -- **分类候选**
        for _, cand in ipairs(candidates) do
            if is_alnum(cand.text) then
                table.insert(alnum_cands, cand)
            elseif utf8.len(cand.text) == 1 then
                table.insert(single_char_cands, cand)
            else
                table.insert(other_cands, cand)
            end
        end

        local last_char = input_code:sub(-1)
        local last_two = input_code:sub(-2)
        local has_match = false
        local moved, reordered = {}, {}

        -- **如果 `other_cands` 为空，说明所有非字母数字候选都是单字**
        if #other_cands == 0 then
            for _, cand in ipairs(single_char_cands) do
                table.insert(moved, cand)
                has_match = true
            end
        else
            -- **匹配 `first` 和 `full`**
            for _, cand in ipairs(single_char_cands) do
                local full, first = M.run_fuzhu(cand, env, cand.comment or "")
                local matched = false

                if input_len == 4 then
                    for _, code in ipairs(full) do
                        if code == last_two then
                            matched = true
                            has_match = true
                            break
                        end
                    end
                else
                    for _, code in ipairs(first) do
                        if code == last_char then
                            matched = true
                            has_match = true
                            break
                        end
                    end
                end

                if matched then
                    table.insert(moved, cand)
                else
                    table.insert(reordered, cand)
                end
            end
        end
        -- **动态排序逻辑**
        if has_match then
            for _, v in ipairs(other_cands) do yield(v) end
            for _, v in ipairs(moved) do yield(v) end
            for _, v in ipairs(reordered) do yield(v) end
            for _, v in ipairs(alnum_cands) do yield(v) end
        else
            for _, v in ipairs(other_cands) do yield(v) end
            for _, v in ipairs(alnum_cands) do yield(v) end
            for _, v in ipairs(moved) do yield(v) end
            for _, v in ipairs(reordered) do yield(v) end
        end
    else  -- **处理 input_len < 3 的情况**
        for _, cand in ipairs(candidates) do yield(cand) end
    end


    -- 字母候选词
    for _, cand in ipairs(alnum_candidates) do
        yield(cand)
    end

    -- 预测候选词
    for _, cand in ipairs(yc_candidates) do
        yield(cand)
    end

end

return M

