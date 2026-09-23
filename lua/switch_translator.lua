-- lua/switch_translator.lua

-- [[ 历史修复记录 ]] 保留记录用于后续可能的进一步优化，已解决方案设置评分，满分为10
-- 问题A：遇到无候选的情况就会卡死（已解决）
-- 1. 曾尝试 iter_count 计数器：无效。卡死发生在 C++ 内部搜索，Lua 还没跑完循环。
-- 2. 曾尝试修正 seg._end 边界：无效。虽规范了边界，但未阻止底层算法的递归爆炸。
-- 3. 当前尝试：输入预检 (Input Sanitization)。
--    原因：script_translator (sentence) 在处理长字符串且末尾有无候选字符(如/)时，
--    会触发极其耗时的回溯搜索。通过正则限制非 wanxiang_pro 方案在输入特殊符号时
--    不触发 sentence 翻译器。（评分：7分）
-- 问题B：在切换方案后，会延续上一方案的设定如prism，而我的不同方案最大的区别就在于prism不同，这就导致了错误生成了其它方案的候选（已解决）
-- 问题C：全局 translator_cache 跨 Session 持有悬垂 Engine* 裸指针，在万象虎输入 8 码触发 sentence 时导致 Fcitx5 发生 SIGSEGV 崩溃（已解决）
-- 1. 废除模块级全局 translator_cache，改用 env 级生命周期隔离，随当前 Session/Engine 自动回收与重建。

local ipairs = ipairs
local utf8_len = utf8.len
local yield = yield
local Candidate = Candidate
local Component = Component

local sources = {
    {
        name = "char_word",
        option = nil,
        type = "table_translator",
        tag = "",
        max_candidates = 5,
        priority = 300,
        min_input_length = 0,
        candidate_filter = function(cand, env)
            local char_len = utf8_len(cand.text)
            local context = env.engine.context
            if context:get_option("char") and char_len == 1 then return true end
            if context:get_option("word") and char_len > 1 then return true end
            return false
        end,
        candidate_config = { fallback = { type = "table", start = 0, dynamic_end = true } },
        use_native_type = true
    },
    {
        name = "yin_engine",
        option = "yin",
        type = "script_translator",
        tag = "",
        max_candidates = 20,
        priority = -1,
        min_input_length = 0,
        filter = function(schema_id, input_len) 
            return schema_id ~= "wanxiang_pro" 
        end,
        candidate_config = { fallback = { type = "pinyin", start = 0, dynamic_end = true } }
    },
    {
        name = "sentence",
        option = "sentence",
        type = "script_translator",
        tag = "",
        max_candidates = function(schema_id, env)
            if not env then return 10 end
            local context = env.engine.context
            local yin_enabled = context:get_option("yin")
            return (schema_id == "wanxiang_pro" and yin_enabled) and 1 or 50
        end,
        priority = 50,
        min_input_length = 4,
        -- 【问题A 修复点】：输入合法性检查
        check_input = function(input, schema_id)
            if schema_id == "wanxiang_pro" then return true end
            -- 非 wanxiang 方案下，如果输入包含非字母字符（如/），直接跳过，防止底层递归回溯
            return string.match(input, "^[a-z]+$") ~= nil
        end,
        filter = function(schema_id, input_len)
            return schema_id == "wanxiang_pro" or input_len >= 8
        end,
        candidate_filter = function(cand, env)
            local schema_id = env.engine.schema.schema_id
            if schema_id ~= "wanxiang_pro" then
                return cand.type == "completion" or cand.type == "sentence"
            end
            return true
        end,
        candidate_config = {
            wanxiang_pro = { type = "sentence", start = 0, dynamic_end = true },
            fallback = { type = "sentence", start = 0, dynamic_end = true }
        },
        use_native_type = true
    },
    {
        name = "wx_english",
        option = "english_word",
        type = "table_translator",
        tag = "",
        max_candidates = 100,
        priority = 300,
        min_input_length = 0,
        filter = function(schema_id, input_len) 
            return schema_id ~= "wanxiang_pro" 
        end,
        candidate_config = { fallback = { type = "table", start = 0, dynamic_end = true } },
        use_native_type = true
    },
}

-- 2. 辅助函数：判断是否启用该源
local function should_enable_source(source, context, schema_id, full_input_len)
    if source.option and not context:get_option(source.option) then return false end
    if full_input_len < (source.min_input_length or 0) then return false end
    if source.filter and not source.filter(schema_id, full_input_len) then return false end
    return true
end

-- 3. 获取翻译器：使用 env 隔离，随当前 Session/Engine 生命周期自动创建与销毁（彻底杜绝野指针崩溃与跨方案污染）
local function get_translator(env, source)
    if not env.translators then
        env.translators = {}
    end
    local name = source.name
    if not env.translators[name] then
        local full_name = (source.type or "script_translator") .. "@" .. name
        env.translators[name] = Component.Translator(env.engine, "", full_name)
    end
    return env.translators[name]
end

-- 4. 辅助函数：创建候选词
local function create_candidate(env, source, cand, index, input_len, seg)
    local schema_id = env.engine.schema.schema_id
    local cfg = source.candidate_config[schema_id] or source.candidate_config.fallback
    
    -- 确保 end_pos 不会越过当前 segment 的边界
    local end_pos = cfg.dynamic_end and input_len or (cfg.end_pos or 0)
    if end_pos > seg._end then end_pos = seg._end end
    
    local cand_type = source.use_native_type and cand.type or cfg.type
    local nc = Candidate(cand_type, cfg.start or 0, end_pos, cand.text, "")
    
    nc.quality = source.priority - index
    nc.comment = cand.comment and (cand.comment .. " " .. source.tag) or source.tag
    nc.preedit = cand.preedit or nc.preedit
    
    return nc
end

-- 5. 核心入口
local function lua_translator(input, seg, env)
    if input == "" then return end
    
    local context = env.engine.context
    local schema_id = env.engine.schema.schema_id
    local full_input_len = #context.input -- 原始全量输入长度

    for _, source in ipairs(sources) do
        -- 输入合法性预检（解决 Problem A）
        local input_ok = true
        if source.check_input then
            input_ok = source.check_input(input, schema_id)
        end

        if input_ok and should_enable_source(source, context, schema_id, full_input_len) then
            local translator = get_translator(env, source)
            local translation = translator and translator:query(input, seg)
            
            if translation then
                local count = 0
                local filter = source.candidate_filter
                local max_cands = type(source.max_candidates) == "function" 
                                  and source.max_candidates(schema_id, env)
                                  or source.max_candidates
                
                for cand in translation:iter() do
                    if not filter or filter(cand, env) then
                        count = count + 1
                        -- 注意：这里传入的 input_len 应该是当前 segment 的相对长度或 context.input 长度
                        -- 保持与你原始逻辑一致
                        yield(create_candidate(env, source, cand, count, #input, seg))
                        if count >= max_cands then break end
                    end
                end
            end
        end
    end
end

return lua_translator
