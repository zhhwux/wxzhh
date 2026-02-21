
--2026-02-14 11:46:51
local function is_ios_device()
    return os.getenv("HOME") and os.getenv("HOME"):find("/var/mobile/") ~= nil
end

-- 模块级局部变量（用于非iOS设备）
local commit_history = {}
local history_index = 1
local history_count = 0

local function init(env)
    local config = env.engine.schema.config
    
    -- 静态配置读取
    local quick_text_pattern = config:get_string("recognizer/patterns/quick_text")
    env.quick_text_pattern = quick_text_pattern -- 保存配置值用于后续判断
    
    env.default_trigger = "''" -- 内置默认触发键
    env.trigger_list = {} -- 最终生效的自定义触发键列表

    -- 按quick_text配置状态分类处理
    if quick_text_pattern == nil then
        table.insert(env.trigger_list, env.default_trigger)
    elseif quick_text_pattern ~= "" then
        table.insert(env.trigger_list, env.default_trigger)
        table.insert(env.trigger_list, quick_text_pattern)
    end

    env.double_more_trigger = "'`" -- 固定双符号触发（触发全部历史）
    
    -- iOS设备：使用文件持久化保存
    if is_ios_device() then
        env.commit_history = {}
        env.history_index = 1
        env.history_count = 0
        env.persistence_file = os.getenv("HOME") .. "/Documents/rime_history.txt"
        
        local function load_history()
            local file = io.open(env.persistence_file, "r")
            if not file then return end
            local data = file:read("*a")
            file:close()
            if #data > 0 then
                local saved = {}
                for entry in string.gmatch(data, "[^\n]+") do
                    table.insert(saved, entry)
                end
                local count = #saved
                if count > 100 then count = 100 end
                for i = 1, 100 do
                    local pos = (i <= count) and (i) or nil
                    env.commit_history[i] = saved[pos] or false
                end
                env.history_count = count
                env.history_index = (count % 100) + 1
            end
        end
        
        env.save_history = function()
            local content = {}
            for i = 1, math.min(env.history_count, 100) do
                local idx = (env.history_index - env.history_count - 1 + i) % 100
                if idx <= 0 then idx = idx + 100 end
                if env.commit_history[idx] then
                    table.insert(content, env.commit_history[idx])
                end
            end
            local file = io.open(env.persistence_file, "w")
            if file then
                file:write(table.concat(content, "\n"))
                file:close()
            end
        end
        load_history()
        
        env.commit_notifier = env.engine.context.commit_notifier:connect(function(ctx)
            local text = ctx:get_commit_text()
            if text == "" then return end
            env.commit_history[env.history_index] = text
            env.history_index = env.history_index % 100 + 1
            env.history_count = math.min(env.history_count + 1, 100)
            env.save_history()
        end)
    else
        -- 非iOS设备
        if #commit_history == 0 then
            for i = 1, 100 do commit_history[i] = false end
            history_index = 1
            history_count = 0
        end
        env.commit_history = commit_history
        env.history_index = history_index
        env.history_count = history_count
        
        env.commit_notifier = env.engine.context.commit_notifier:connect(function(ctx)
            local text = ctx:get_commit_text()
            if text == "" then return end
            env.commit_history[env.history_index] = text
            env.history_index = env.history_index % 100 + 1
            env.history_count = math.min(env.history_count + 1, 100)
        end)
    end
    
    -- 更新通知器
    env.update_notifier = env.engine.context.update_notifier:connect(function(ctx)
        local input = ctx.input
        
        -- 1. 处理清除命令
        if input == "/spql" then
            for i = 1, 100 do env.commit_history[i] = false end
            env.history_index = 1
            env.history_count = 0
            if is_ios_device() and env.save_history then env.save_history() end
            env.engine:commit_text("历史记录已清除")
            ctx:clear()
            return
        end

        -- 2. 修改点：如果输入是 ;; 且 quick_text 配置不是 ;; 则上屏中文分号
        if input == ";;" and env.quick_text_pattern ~= ";;" then
            env.engine:commit_text("；")
            ctx:clear()
            return
        end
        
        -- 3. 处理 '` 触发（全部历史）
        if #input == 2 and input == env.double_more_trigger and env.history_count > 0 then
            local output = {}
            local start_idx = env.history_index - env.history_count
            if start_idx < 1 then start_idx = start_idx + 100 end
            for i = 1, env.history_count do
                local idx = (start_idx + i - 2) % 100 + 1
                if env.commit_history[idx] then
                    output[i] = env.commit_history[idx]
                end
            end
            env.engine:commit_text(table.concat(output))
            ctx:clear()
            return
        end
        
        -- 4. 处理 trigger_list（最新历史）
        local matched = false
        for _, trigger in ipairs(env.trigger_list) do
            if #input == #trigger and input == trigger then
                local last_index = (env.history_index - 2) % 100 + 1
                if env.commit_history[last_index] then
                    env.engine:commit_text(env.commit_history[last_index])
                    ctx:clear()
                    matched = true
                    break
                end
            end
        end
        if matched then return end
    end)
end

local function fini(env)
    if is_ios_device() and env.save_history then
        env.save_history()
    end
    if env.update_notifier then env.update_notifier:disconnect() end
    if env.commit_notifier then env.commit_notifier:disconnect() end
end

-- 处理器
local function processor(key_event, env)
    local input_len = #env.engine.context.input
    -- 长度为2时（包括 ;; 和 '`），激活处理器
    if input_len == 2 then
        return true
    end
    -- 匹配自定义触发键长度
    if #env.trigger_list > 0 then
        for _, trigger in ipairs(env.trigger_list) do
            if input_len == #trigger then
                return true
            end
        end
    end
    return false
end

return { init = init, fini = fini, func = processor }
