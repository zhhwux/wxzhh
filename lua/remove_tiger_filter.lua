
local M = {}

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

    -- 筛选虎单与虎词
    local tigress_candidates = {}
    local yjc_tigress = {}
    local other_tigress = {}
    local tiger_candidates = {}
    local useless_candidates = {}
    local yc_candidates = {}
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
        elseif utf8.len(cand.text) >= 2 then
            table.insert(tigress_candidates, cand)
        else
            table.insert(tiger_candidates, cand)
        end
    end
    
    -- 输出包含数字但不包含字母的候选词
    for _, cand in ipairs(digit_candidates) do
        yield(cand)
    end

    -- 🐯 虎单开关
    if context:get_option("tiger") then
        for _, cand in ipairs(tiger_candidates) do
            yield(cand)
        end
    end

    -- 🐯 虎词开关
    if context:get_option("tigress") then
        for _, cand in ipairs(tigress_candidates) do
            if utf8.len(cand.preedit) == 1 then
                table.insert(yjc_tigress, cand) 
            else
                table.insert(other_tigress, cand)
            end
        end   
        for _, cand in ipairs(yjc_tigress) do
            yield(cand)
        end
        for _, cand in ipairs(other_tigress) do
            yield(cand)
        end
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

    -- 📝 非用户词库句子置顶开关
    if context:get_option("sentence") then
        -- 分离 cand.type == "sentence" 的候选词
        local sentence_candidates = {}
        local remaining_candidates = {}
        for _, cand in ipairs(other_candidates) do
            if cand.type == "sentence" then
                table.insert(sentence_candidates, cand)
            else
                table.insert(remaining_candidates, cand)
            end
        end
        
        for _, cand in ipairs(sentence_candidates) do
            yield(cand)
        end
        
        for _, cand in ipairs(remaining_candidates) do
            yield(cand)
        end
    else
        for _, cand in ipairs(other_candidates) do
            yield(cand)
        end
    end

    -- 字母候选词
    for _, cand in ipairs(alnum_candidates) do
        yield(cand)
    end

    -- 反查候选词
    for _, cand in ipairs(fc_candidates) do
        yield(cand)
    end

    -- 预测候选词
    for _, cand in ipairs(yc_candidates) do
        yield(cand)
    end

end

return M

