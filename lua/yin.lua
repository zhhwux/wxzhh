-- lua/yin.lua
-- 目标：通过 Lua 调用 script_translator 逻辑生成 wanxiang_pro 的候选词

local function yin_translator(input, seg, env)
    -- 1. 基础检查
    local ctx = env.engine.context
    if not ctx:get_option("yin") or #input == 0 then return end

    -- 2. 初始化内部 Translator (指向 wanxiang_pro)
    -- 我们在 env 变量中缓存组件，避免重复创建影响性能
    if not env.p_translator then
        -- 注意：这里第二个参数必须是 "" 或者唯一的命名空间
        -- 第三个参数 "@" 后面必须是你在某个 .schema.yaml 里定义过的 translator 节点
        -- 如果没有定义，我们可以利用默认的 script_translator
        env.p_translator = Component.Translator(env.engine, "", "script_translator@yin_engine")
    end

    -- 3. 构造 Candidate 的辅助函数
    local function create_cand(cand, index)
        -- 创建一个新的候选词对象，复制原候选词的文本
        local nc = Candidate("pinyin", seg.start, seg._end, cand.text, 1000000 - index)
        -- 这里你可以开始你的“智能”逻辑，目前先保留原始 Comment 并加个标记
        nc.comment = cand.comment .. "🎼"
        return nc
    end

    -- 4. 执行查询
    local translation = env.p_translator:query(input, seg)
    if not translation then return end

    -- 5. 遍历并生成候选
    local count = 0
    local iter, obj = translation:iter()
    while true do
        local cand = iter(obj)
        if not cand then break end
        
        count = count + 1
        yield(create_cand(cand, count))
        
        -- 限制数量，防止 Lua 循环过久导致卡顿
        if count >= 20 then break end
    end
end

return yin_translator
