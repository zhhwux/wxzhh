
-- 读取 RIME 配置文件中的符号映射表
local function load_mapping_from_config(config)
    local symbol_map = {}
    local keys = "qwertyuiopasdfghjklzxcvbnm1234567890"
    
    for key in keys:gmatch(".") do
        local symbol = config:get_string("quick_symbol_text/" .. key)
        if symbol then
            symbol_map[key] = symbol
        end
    end
    return symbol_map
end

-- 默认符号映射表
local default_mapping = {
    q = "“", w = "？", e = "（", r = "）", t = "~", y = "·", u = "『", i = "』", o = "〖", p = "〗",
    a = "！", s = "……", d = "、", f = "“", g = "”", h = "‘", j = "’", k = "【", l = "】",
    z = "。", x = "？", c = "！", v = "——", b = "%", n = "《", m = "》",
    ["1"] = "①", ["2"] = "②", ["3"] = "③", ["4"] = "④", ["5"] = "⑤", 
    ["6"] = "⑥", ["7"] = "⑦", ["8"] = "⑧", ["9"] = "⑨", ["0"] = "⓪"
}

-- 初始化符号输入的状态
local function init(env)
    local config = env.engine.schema.config
    -- 加载符号映射表，优先使用 RIME 配置，未找到的键使用默认值
    env.mapping = default_mapping
    local custom_mapping = load_mapping_from_config(config)
    for k, v in pairs(custom_mapping) do
        env.mapping[k] = v  -- 仅替换配置中存在的键
    end
    
    if config:get_string("recognizer/patterns/quick_text") then
        env.double_symbol_pattern_text1 = "^" .. string.sub(config:get_string("recognizer/patterns/quick_text"), 2, 2)  .. "$" 
    else
        env.double_symbol_pattern_text1 = "''"
    end
    
    env.double_symbol_pattern_text2 = "''"
    
    -- 初始化最后提交内容
    env.last_commit_text = "欢迎使用万象拼音！"
    
    -- 连接提交通知器
    env.engine.context.commit_notifier:connect(function(ctx)
        local commit_text = ctx:get_commit_text()
        if commit_text ~= "" then
            env.last_commit_text = commit_text  -- 更新最后提交内容到env
        end
    end)
end

-- 处理符号和文本的重复上屏逻辑
local function processor(key_event, env)
    local engine = env.engine
    local context = engine.context
    local input = context.input

    -- 检查用户是否输入单击符号 `
    if string.match(input, env.double_symbol_pattern_text2) or string.match(input, env.double_symbol_pattern_text1) then
        -- 提交历史记录中的最新文本
        engine:commit_text(env.last_commit_text)  -- 从env获取最后提交内容
        context:clear()
        return 1  -- 终止处理
    end
end
return { init = init, func = processor }