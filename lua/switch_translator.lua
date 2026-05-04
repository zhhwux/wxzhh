-- lua/switch_translator.lua

-- 0. 性能优化：缓存全局/高频调用的函数与对象
local ipairs = ipairs
local utf8_len = utf8.len
local yield = yield
local Candidate = Candidate
local Component = Component

-- 1. 配置定义
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
        candidate_config = {
            default = { type = "table", start = 0, dynamic_end = true }
        },
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
        candidate_config = {
            default = { type = "pinyin", start = 0, dynamic_end = true }
        }
    },
    {
        name = "sentence",
        option = "sentence",
        type = "script_translator",
        tag = "",
        -- 【修改点1】将静态数值改为动态函数
        max_candidates = function(schema_id, env)
            -- 检查 schema_id 是否为 wanxiang_pro 并且 yin 开关开启
            if not env then return 10 end  -- 安全处理
            local context = env.engine.context
            local yin_enabled = context:get_option("yin")
            return (schema_id == "wanxiang_pro" and yin_enabled) and 1 or 50
        end,
        priority = 50,
        min_input_length = 4,
        filter = function(schema_id, input_len)
            return schema_id == "wanxiang_pro" or input_len >= 8
        end,
        -- 将原主循环中的硬编码逻辑移入配置中，保持主循环的纯粹性
        candidate_filter = function(cand, env)
            local schema_id = env.engine.schema.schema_id
            if schema_id ~= "wanxiang_pro" then
                return cand.type == "completion" or cand.type == "sentence"
            end
            return true
        end,
        candidate_config = {
            wanxiang_pro = { type = "sentence", start = 0, dynamic_end = true },
            default = { type = "sentence", start = 0, dynamic_end = true }
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
        candidate_config = {
            default = { type = "table", start = 0, dynamic_end = true }
        },
        use_native_type = true
    },
}

-- 2. 缓存管理
local translator_cache = {}

local function get_translator(env, source)
    local name = source.name
    if not translator_cache[name] then
        local full_name = (source.type or "script_translator") .. "@" .. name
        translator_cache[name] = Component.Translator(env.engine, "", full_name)
    end
    return translator_cache[name]
end

-- 3. 辅助函数
local function create_candidate(env, source, cand, index, input_len)
    local schema_id = env.engine.schema.schema_id
    local cfg = source.candidate_config[schema_id] or source.candidate_config.default
    
    -- 复用传入的 input_len，避免重复调用 #env.engine.context.input
    local end_pos = cfg.dynamic_end and input_len or (cfg.end_pos or 0)
    local cand_type = source.use_native_type and cand.type or cfg.type
    
    local nc = Candidate(cand_type, cfg.start or 0, end_pos, cand.text, "")
    
    nc.quality = source.priority - index
    -- 优化字符串拼接逻辑
    nc.comment = cand.comment and (cand.comment .. " " .. source.tag) or source.tag
    nc.preedit = cand.preedit or nc.preedit
    
    return nc
end

local function should_enable_source(source, context, schema_id, input_len)
    if source.option and not context:get_option(source.option) then return false end
    if input_len < (source.min_input_length or 0) then return false end
    if source.filter and not source.filter(schema_id, input_len) then return false end
    return true
end

-- 4. 核心入口
local function lua_translator(input, seg, env)
    local context = env.engine.context
    local schema_id = env.engine.schema.schema_id
    local input_len = #context.input

    for _, source in ipairs(sources) do
        if should_enable_source(source, context, schema_id, input_len) then
            local translator = get_translator(env, source)
            local translation = translator and translator:query(input, seg)
            
            if translation then
                local count = 0
                local filter = source.candidate_filter
                
                -- 【修改点2】动态解析 max_candidates，兼容旧的数字配置和新的函数配置
                local max_cands = type(source.max_candidates) == "function" 
                                  and source.max_candidates(schema_id, env)  -- 这里添加 env 参数
                                  or source.max_candidates
                
                for cand in translation:iter() do
                    if not filter or filter(cand, env) then
                        count = count + 1
                        yield(create_candidate(env, source, cand, count, input_len))
                        
                        -- 【修改点3】使用解析后的 max_cands 进行判断
                        if count >= max_cands then 
                            break 
                        end
                    end
                end
            end
        end
    end
end

return lua_translator
