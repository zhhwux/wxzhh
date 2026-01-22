-- 更可靠的 iOS 检测
local function is_ios_device()
    return os.getenv("HOME") and os.getenv("HOME"):find("/var/mobile/") ~= nil
end

-- 模块级局部变量（用于非iOS设备）
local commit_history = {}
local history_index = 1
local history_count = 0

local function init(env)
    local config = env.engine.schema.config
    
    -- 静态配置读取（核心逻辑：根据quick_text状态控制触发键列表）
    local quick_text_pattern = config:get_string("recognizer/patterns/quick_text")
    env.default_trigger = "''" -- 内置默认触发键（固定为''）
    env.trigger_list = {} -- 最终生效的自定义触发键列表（触发最新历史）

    -- 按quick_text配置状态分类处理
    if quick_text_pattern == nil then
        -- 情况1：quick_text不存在 → 仅添加默认''
        table.insert(env.trigger_list, env.default_trigger)
    elseif quick_text_pattern ~= "" then
        -- 情况2：quick_text存在且非空 → 同时添加默认'' + 配置项
        table.insert(env.trigger_list, env.default_trigger)
        table.insert(env.trigger_list, quick_text_pattern)
    end
    -- 情况3：quick_text存在且为空 → 不添加任何自定义触发键（禁用''）

    env.double_more_trigger = "'`" -- 保留原固定双符号触发（触发全部历史，不改动）
    
    -- iOS设备：使用文件持久化保存（完全保留原逻辑）
    if is_ios_device() then
        -- 初始化历史记录
        env.commit_history = {}
        env.history_index = 1
        env.history_count = 0
        
        -- 持久化文件路径 (iOS专用)
        env.persistence_file = os.getenv("HOME") .. "/Documents/rime_history.txt"
        
        -- 从文件加载历史记录
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
        
        -- 保存历史记录到文件
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
        
        -- 加载历史记录
        load_history()
        
        -- 提交通知器 (iOS专用)
        env.commit_notifier = env.engine.context.commit_notifier:connect(function(ctx)
            local text = ctx:get_commit_text()
            if text == "" then return end
            
            env.commit_history[env.history_index] = text
            env.history_index = env.history_index % 100 + 1
            env.history_count = math.min(env.history_count + 1, 100)
            
            -- iOS: 每次提交后立即保存
            env.save_history()
        end)
    else
        -- 非iOS设备: 使用模块闭包变量（完全保留原逻辑）
        -- 直接创建填充好的循环缓冲区
        if #commit_history == 0 then
            for i = 1, 100 do 
                commit_history[i] = false  -- 使用false标记空槽位
            end
            history_index = 1
            history_count = 0
        end
        
        -- 将模块变量引用到env中
        env.commit_history = commit_history
        env.history_index = history_index
        env.history_count = history_count
        
        -- 提交通知器 (非iOS专用)
        env.commit_notifier = env.engine.context.commit_notifier:connect(function(ctx)
            local text = ctx:get_commit_text()
            if text == "" then return end
            
            env.commit_history[env.history_index] = text
            env.history_index = env.history_index % 100 + 1
            env.history_count = math.min(env.history_count + 1, 100)
        end)
    end
    
    -- 更新通知器（iOS和非iOS共用，整合所有触发逻辑）
    env.update_notifier = env.engine.context.update_notifier:connect(function(ctx)
        local input = ctx.input
        
        -- 处理清除历史记录命令（完全保留原逻辑）
        if input == "/spql" then
            -- 清除所有历史记录
            for i = 1, 100 do
                env.commit_history[i] = false
            end
            env.history_index = 1
            env.history_count = 0
            
            -- iOS设备：更新持久化文件
            if is_ios_device() and env.save_history then
                env.save_history()
            end
            
            -- 显示清除成功提示
            env.engine:commit_text("历史记录已清除")
            ctx:clear()
            return
        end
        
        -- 原'`触发逻辑（优先处理，始终生效，触发全部历史）
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
        
        -- 自定义触发键逻辑（触发最新历史，按trigger_list匹配）
        local matched = false
        for _, trigger in ipairs(env.trigger_list) do
            if #input == #trigger and input == trigger then -- 匹配长度+内容
                local last_index = (env.history_index - 2) % 100 + 1
                if env.commit_history[last_index] then
                    env.engine:commit_text(env.commit_history[last_index])
                    ctx:clear()
                    matched = true
                    break
                end
            end
        end
        if matched then return end -- 匹配成功则退出
    end)
end

local function fini(env)
    -- iOS设备：保存历史记录（完全保留原逻辑）
    if is_ios_device() and env.save_history then
        env.save_history()
    end
    
    -- 断开事件监听
    if env.update_notifier then 
        env.update_notifier:disconnect() 
    end
    if env.commit_notifier then 
        env.commit_notifier:disconnect() 
    end
    
    -- 非iOS设备：保留历史记录在闭包中（下次初始化时仍可用）
end

-- 处理器（适配所有触发键长度，避免报错）
local function processor(key_event, env)
    local input_len = #env.engine.context.input
    -- 1. 优先适配'`触发（长度2），始终激活
    if input_len == 2 then
        return true
    end
    -- 2. 适配自定义触发键列表（非空时，匹配任意触发键长度即激活）
    if #env.trigger_list > 0 then
        for _, trigger in ipairs(env.trigger_list) do
            if input_len == #trigger then
                return true
            end
        end
    end
    -- 3. 无匹配时不激活
    return false
end

return { init = init, fini = fini, func = processor }
