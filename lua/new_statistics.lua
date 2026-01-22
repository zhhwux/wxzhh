local schema_name = "万象虎"
local software_name = rime_api.get_distribution_code_name() or ""
local software_version = rime_api.get_distribution_version() or ""
-- 合并平台名称和版本信息
local platform_info = software_name
if software_version ~= "" then
    platform_info = platform_info .. " " .. software_version
end

-- 表序列化工具
table.serialize = function(tbl)
    local lines = {"{"}
    for k, v in pairs(tbl) do
        local key = (type(k) == "string") and ("[\"" .. k .. "\"]") or ("[" .. k .. "]")
        local val
        if type(v) == "table" then
            val = table.serialize(v)
        elseif type(v) == "string" then
            val = '"' .. v .. '"'
        else
            val = tostring(v)
        end
        table.insert(lines, string.format("    %s = %s,", key, val))
    end
    table.insert(lines, "}")
    return table.concat(lines, "\n")
end

-- 保存统计到文件
local function save_stats()
    local path = rime_api.get_user_data_dir() .. "/lua/input_stats.lua"
    local file = io.open(path, "w")
    if not file then return end
    file:write("input_stats = " .. table.serialize(input_stats) .. "\n")
    file:close()
end

-- 临时统计报告
local function format_custom_summary(temp_stats)
    local end_ts = temp_stats.last_slash_time or os.time()
    local duration_sec = end_ts - temp_stats.start_time
    local minutes = duration_sec / 60
    
    local speed = 0
    if minutes > 0 then
        speed = math.floor((temp_stats.length / minutes) * 100) / 100
    end
    
    return string.format(
        "\n%s\n"..
        "◉ 开始时间：%s\n"..
        "◉ 结束时间：%s\n"..
        "◉ 统计时长：%d分 %d秒\n"..
        "◉ 输入条数：%d条\n"..
        "◉ 总字数：%d字\n"..
        "◉ 平均速度：%.2f 字/分钟\n"..
        "◉ 最快一分钟输入：%d字\n"..
        "%s\n",
        string.rep("─", 14),
        os.date("%Y-%m-%d %H:%M:%S", temp_stats.start_time),
        os.date("%Y-%m-%d %H:%M:%S", end_ts),
        math.floor(minutes), math.floor(duration_sec % 60),
        temp_stats.count,
        temp_stats.length,
        speed,
        temp_stats.fastest,
        string.rep("─", 14)
    )
end

-- 转换器：处理/st和/en命令
local function translator(input, seg, env)
    if input:sub(1, 1) ~= "/" then return end
    
    -- 开始临时统计
    if input == "/st" then
        env.pending_start = true
        yield(Candidate("info", seg.start, seg._end, "", ""))

    -- 结束临时统计并生成报告
    elseif input == "/en" then
        if env.is_collecting then
            env.is_collecting = false
            local report = format_custom_summary(env.temp_stats)
            yield(Candidate("stat", seg.start, seg._end, report, "input_stats_summary"))
        else
            yield(Candidate("stat", seg.start, seg._end, "※ 当前没有进行中的统计", ""))
        end

    -- 记录斜杠时间
    elseif env.is_collecting and input == "/" then
        env.temp_stats.last_slash_time = os.time()
        yield(Candidate("info", seg.start, seg._end, "", ""))
    end
end

-- 判断是否为统计命令
local function is_summary_command(text)
    return text == "/st" or text == "/en"
end

local function init(env)
    local ctx = env.engine.context

    -- 初始化统计状态
    env.is_collecting = false
    env.pending_start = false
    env.temp_stats = nil

    -- 注册提交通知回调
    ctx.commit_notifier:connect(function()
        local commit_text = ctx:get_commit_text()
        if not commit_text then return end

        -- 处理等待开始的状态
        if env.pending_start and commit_text == "" then
            env.is_collecting = true
            env.temp_stats = {
                count = 0,
                length = 0,
                fastest = 0,
                recent = {},
                last_slash_time = nil,
                start_time = os.time()
            }
            env.pending_start = false
        end
        
        -- 重置等待状态
        if env.pending_start and commit_text ~= "" then
            env.pending_start = false
        end
        
        -- 排除统计命令
        if commit_text == "" or is_summary_command(commit_text) then return end
        
        -- 关键过滤：排除以特殊符号开头的文本（如时间、日期候选）
        if commit_text:match("^[※◉]") then return end
        
        -- 排除我们自己生成的统计候选
        local cand = ctx:get_selected_candidate()
        if cand and cand.comment == "input_stats_summary" then return end

        -- 计算输入长度
        local input_length = utf8.len(commit_text) or string.len(commit_text)

        -- 更新临时统计
        if env.is_collecting then            
            env.temp_stats.count = env.temp_stats.count + 1
            env.temp_stats.length = env.temp_stats.length + input_length

            -- 更新最近一分钟输入速度
            local ts = os.time()
            table.insert(env.temp_stats.recent, {ts = ts, len = input_length})
            local threshold = ts - 60
            local total = 0
            local i = 1
            while i <= #env.temp_stats.recent do
                if env.temp_stats.recent[i].ts >= threshold then
                    total = total + env.temp_stats.recent[i].len
                    i = i + 1
                else
                    table.remove(env.temp_stats.recent, i)
                end
            end
            if total > env.temp_stats.fastest then
                env.temp_stats.fastest = total
            end
        end
    end)
end

return { init = init, func = translator }
