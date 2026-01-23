-- 辅助码拆分提示模块 (chaifen) - 终极整合版
local CF = {}
-- 二级缓存：schema_id -> {dict=词典实例, mode=模式, char_cache=字符拆分缓存, display_mode=显示模式}
local global_cache = {}
-- 预编译正则（复用平衡版优化）
local SPECIAL_CHAR_PATTERN = "[`*]"
local EXCLUDE_PATTERN = "^[ZVRNU/;]"
-- 局部引用内置函数（减少全局查找开销）
local utf8_len, utf8_char, table_concat = utf8.len, utf8.char, table.concat

-- 【按方案缓存初始化】支持多方案无缝切换
function CF.init(env)
    local schema_id = env.engine.schema.schema_id
    local schema_config = env.engine.schema.config

    -- 方案已缓存则直接复用，避免重复加载词典
    if not global_cache[schema_id] then
        local char_word_dict = schema_config:get_string("char_word/dictionary")
        -- 匹配词典模式
        local mode, dict_name
        if char_word_dict == "wubici" then
            mode = "wubi"
            dict_name = "wubi_lookup"
        else
            mode = "tiger"
            dict_name = "tiger_lookup"
        end
        -- 初始化方案缓存项
        global_cache[schema_id] = {
            dict = ReverseLookup(dict_name),
            mode = mode,
            char_cache = {}, -- 字符拆分结果缓存
            display_mode = schema_config:get_string("enum/chaifen") or "all"
        }
    end

    -- 挂载当前方案缓存到环境变量
    env.current_cache = global_cache[schema_id]
end

-- 【带字符缓存的单字拆分】核心性能优化点
local function process_single_char(cache, char)
    -- 命中缓存直接返回，避免重复查询词典
    if cache.char_cache[char] then
        return cache.char_cache[char]
    end
    local result = cache.dict:lookup(char)
    local res = (result and result ~= "") and result or char
    cache.char_cache[char] = res -- 写入缓存
    return res
end

function CF.run(cand, env)
    local cache = env.current_cache
    if not cache or not cache.dict or #cand.text == 0 then
        return nil
    end

    -- 单字处理：所有模式都支持
    if utf8_len(cand.text) == 1 then
        local append = process_single_char(cache, cand.text)
        return append ~= cand.text and append or nil
    end

    -- 多字处理：按显示模式过滤（短路判断减少分支）
    if cache.display_mode ~= "all" then
        return nil
    end

    local parts = {}
    local has_chaifen = false
    -- 用utf8.codes高效遍历字符（复用平衡版优化）
    for _, code in utf8.codes(cand.text) do
        local char = utf8_char(code)
        local part = process_single_char(cache, char)
        table.insert(parts, part)
        if part ~= char then
            has_chaifen = true
        end
    end

    return has_chaifen and table_concat(parts, " ") or nil
end

-- 清理当前方案的字符缓存（按需调用）
function CF.clear_char_cache(schema_id)
    if global_cache[schema_id] then
        global_cache[schema_id].char_cache = {}
    end
end

local ZH = {}

-- 【短路判断优化】初始化上下文配置，减少无效计算
function ZH.init(env)
    local context = env.engine.context
    local preedit = context:get_preedit().text
    env.chaifen_enabled = false

    -- 优先级1：直接检查开关选项（最快路径）
    if context:get_option("chaifen") then
        env.chaifen_enabled = true
        return
    end

    -- 优先级2：检查激进词模式
    local seg = context.composition:back()
    if seg and (seg:has_tag("yin_add_user") or seg:has_tag("rvlk1") or seg:has_tag("rvlk2")) then
        env.chaifen_enabled = true
        return
    end

    -- 优先级3：检查特殊字符（预编译正则提速）
    if #preedit == 0 or not preedit:find(SPECIAL_CHAR_PATTERN) then
        return
    end

    -- 最终判断：排除指定前缀
    env.chaifen_enabled = not preedit:find(EXCLUDE_PATTERN)
end

function ZH.func(input, env)
    -- 初始化方案缓存（多方案兼容）
    CF.init(env)
    -- 初始化上下文状态（短路判断，快速返回）
    ZH.init(env)

    -- 未启用则直接透传候选词，减少后续开销
    if not env.chaifen_enabled then
        for cand in input:iter() do
            yield(cand)
        end
        return
    end

    -- 启用状态下处理候选词
    for cand in input:iter() do
        local cf_comment = CF.run(cand, env)
        if cf_comment then
            cand:get_genuine().comment = cf_comment
        end
        yield(cand)
    end
end

-- 对外暴露清理缓存接口（按需调用，比如词典更新后）
return {
    CF = CF,
    ZH = ZH,
    func = ZH.func,
    clear_char_cache = CF.clear_char_cache
}
