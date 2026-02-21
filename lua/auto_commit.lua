
local M = {}

-- 局部化高频函数
local utf8_len = utf8.len
local table_insert = table.insert

-- 第一套候选词映射（虎码单字模式）
local letter_map_tiger = {
    q = "都", w = "得", e = "突然", r = "了", t = "我们", y = "当然", u = "工作", i = "为什么", o = "是", p = "行",
    a = "来", s = "说", d = "中", f = "一", g = "就", h = "道", j = "人", k = "能", l = "而", 
    z = "可", x = "和", c = "不", v = "要", b = "如", n = "在", m = "大"
}

-- 第二套候选词映射（虎词模式）
local letter_map_tigress = {
    q = "特别", w = "怎么", e = "突然", r = "因为", t = "我们", y = "当然", u = "工作", i = "为什么", o = "自己", p = "起来",
    a = "那个", s = "出来", d = "哪个", f = "开始", g = "地方", h = "孩子", j = "什么", k = "没有", l = "而且", 
    z = "可以", x = "应该", c = "不是", v = "这个", b = "如果", n = "现在", m = "所以"
}

-- 第一套候选词映射（五笔单字模式1）
local letter_map_wubi_one = {
    q = "我", w = "人", e = "有", r = "的", t = "和", y = "主", u = "产", i = "不", o = "为", p = "这",
    a = "工", s = "要", d = "在", f = "地", g = "一", h = "上", j = "是", k = "中", l = "国", 
    z = "", x = "经", c = "以", v = "发", b = "了", n = "民", m = "同"
}

-- 第二套候选词映射（五笔单字模式2）
local letter_map_wubi_two = {
    q = "金", w = "八", e = "月", r = "白", t = "禾", y = "言", u = "立", i = "水", o = "火", p = "之",
    a = "工", s = "要", d = "在", f = "地", g = "王", h = "目", j = "日", k = "口", l = "田", 
    z = "", x = "弓", c = "又", v = "女", b = "子", n = "已", m = "山"
}

-- 初始化函数
function M.init(env)
    env.tiger_four = "" -- 用于保存4码时的第一候选，用于5码顶屏
    env.last_four_input = "" -- 记录4码时的输入
end

-- 主要处理函数
function M.func(input, env)
    local context = env.engine.context
    local config = env.engine.schema.config
    local input_str = context.input
    local input_len = utf8_len(input_str)
    local last_char = input_str:sub(-1)  -- 获取最后一个字符
    
    -- ========== 条件一：配置项开关 ==========
    local four_auto_commit = config:get_bool("char_word/four_auto_commit") or false -- 4码唯一自动上屏
    local four_auto_clear = config:get_bool("char_word/four_auto_clear") or false   -- 4码空码自动清屏
    local five_commit_four = config:get_bool("char_word/five_commit_four") or false -- 5码顶屏
    
    -- ========== 条件二：虎单虎词开关 ==========
    local char_option = context:get_option("char")   -- 虎单开关
    local word_option = context:get_option("word") -- 虎词开关
    local schema_id = env.engine.schema.schema_id == "wanxiang_pro"

    -- ========== 反查模式 ==========
    local is_radical_mode = false
    local seg = context.composition:back()
    if seg and (seg:has_tag("radical_lookup") or seg:has_tag("reverse_stroke") or 
                seg:has_tag("add_user_dict") or seg:has_tag("yin_add_user") or seg:has_tag("rvlk1")) then
        is_radical_mode = true
    end
    
    if context:get_option("sentence") or schema_id or is_radical_mode then
        for cand in input:iter() do
            yield(cand)
        end
        return
    end
    
    -- ========== 收集所有候选词 ==========
    local all_candidates = {}
    local candidate_count = 0
    
    for cand in input:iter() do
        table_insert(all_candidates, cand)
        candidate_count = candidate_count + 1
    end
    
    if (char_option or word_option) then
        if input_len == 4 then
            -- 4码唯一自动上屏
            if candidate_count == 1 and four_auto_commit then
                -- 输出该候选词（确保候选词被正确处理）
                yield(all_candidates[1])
                -- 然后自动上屏
                env.engine:commit_text(all_candidates[1].text)
                context:clear()
                env.tiger_four = ""
                env.last_four_input = ""
                return  -- 直接返回，不再处理后续
            -- 4码空码自动清屏
            elseif candidate_count == 0 and four_auto_clear then
                context:clear()
                env.tiger_four = ""
                env.last_four_input = ""
                return  -- 直接返回，不再处理后续
            else
                -- 保存第一候选用于5码顶屏
                if candidate_count > 0 then
                    env.tiger_four = all_candidates[1].text
                    env.last_four_input = input_str
                end
                -- 输出所有候选
                for _, cand in ipairs(all_candidates) do
                    yield(cand)
                end
            end
            
        elseif input_len == 5 then
            -- 5码顶屏
            if five_commit_four and env.tiger_four ~= "" and 
               env.last_four_input ~= "" and
               input_str:sub(1, utf8_len(env.last_four_input)) == env.last_four_input then
                
                -- 顶屏上屏
                env.engine:commit_text(env.tiger_four)
                env.tiger_four = ""
                local config = env.engine.schema.config
                local char_word_dict = config:get_string("char_word/dictionary")
                -- 虎单候选词生成
                local manual_cand
                if char_option and char_word_dict == "tigress" then
                    local cand_text = letter_map_tiger[last_char] or ""
                    if cand_text ~= "" then
                        manual_cand = Candidate("manual", 0, input_len, cand_text, "")
                        yield(manual_cand)
                    end
                end
                
                -- 虎词候选词生成
                if word_option and char_word_dict == "tigress" then
                    local cand_text = letter_map_tigress[last_char] or ""
                    if cand_text ~= "" then
                        manual_cand = Candidate("manual", 0, input_len, cand_text, "")
                        yield(manual_cand)
                    end
                end
                
                -- 五笔候选词生成
                if char_option and char_word_dict == "wubici" then
                    local cand_text1 = letter_map_wubi_one[last_char] or ""
                    if cand_text1 ~= "" then
                        manual_cand = Candidate("manual", 0, input_len, cand_text1, "")
                        yield(manual_cand)
                    end
                    
                    local cand_text2 = letter_map_wubi_two[last_char] or ""
                    if cand_text2 ~= "" then
                        manual_cand = Candidate("manual", 0, input_len, cand_text2, "")
                        yield(manual_cand)
                    end
                end
                
                env.last_four_input = ""
                env.engine.context.input = last_char
                
            else
                -- 正常输出
                for _, cand in ipairs(all_candidates) do
                    yield(cand)
                end
            end
            
        else
            -- 其他码长，正常输出
            for _, cand in ipairs(all_candidates) do
                yield(cand)
            end
        end
    end
end

-- 清理函数
function M.fini(env)
    env.tiger_four = ""
    env.last_four_input = ""
end

return M