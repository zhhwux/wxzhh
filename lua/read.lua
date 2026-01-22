-- 优化版10.3：改进开关控制，支持在连续输入中检测/，并在read.txt不存在时自动关闭阅读状态
local io = require("io")
local RIME_DATA_DIR = rime_api.get_user_data_dir() or ""
local READ_TXT_PATH = RIME_DATA_DIR .. "/custom_phrase/read.txt"
local READ_STATE_PATH = RIME_DATA_DIR .. "/lua/read_state.txt"
local M = {}

-- 开关状态变量（存储在M中，模块级变量）
M.read_mode_enabled = false  -- 默认关闭

-- 双索引配置（全局=总行数(存文件)，局部=当前缓存行索引(不存)）
local FORCE_CONFIG = {
    line_cache = {},          -- 存储行（每行一个字符串）
    segment_cache = {},       -- 当前行的分割候选词
    global_line_index = 0,    -- 已读取的总行数（存文件）
    cache_start_line = 0,     -- 当前缓存的起始行号
    cache_end_line = 0,       -- 当前缓存的结束行号
    current_line_index = 0,   -- 在当前缓存中的行索引
    segment_index = 0,        -- 当前行内的分割单位索引
    is_show = true,
    is_auto_switch = true,
    file_not_found = false,   -- 文件不存在标志
    file_fully_read = false,  -- 文件完全读完标志
    separators = {"，", "、", "。", "；", ",", ";", "？", "!", "！", "?", "：", ":", "…"}  -- 行内分隔符，不包含换行符
}

-- 稳控+缓存配置
local CACHE_CONFIG = {
    cache_line_count = 1000,  -- 每次缓存的行数
    max_global_line_index = 1000000,  -- 最大行数限制
    parse_max_loop = 1000
}

-- 保存全局行索引
function M.save_read_state()
    local save_idx = math.min(FORCE_CONFIG.global_line_index, CACHE_CONFIG.max_global_line_index)
    local ok, file = pcall(io.open, READ_STATE_PATH, "w", 65001)
    if ok and file then
        file:write(tostring(save_idx))
        file:close()
    end
end

-- 加载全局行索引
function M.load_read_state()
    local ok, file = pcall(io.open, READ_STATE_PATH, "r", 65001)
    if not ok or not file then
        return 0
    end
    local saved_idx = tonumber(file:read("*a")) or 0
    file:close()
    return math.min(saved_idx, CACHE_CONFIG.max_global_line_index)
end

-- 检查文件是否存在
local function file_exists(file_path)
    local file, err = io.open(file_path, "r", 65001)
    if file then
        file:close()
        return true
    end
    return false
end

-- 按行读取缓存
local function read_lines_by_skip(file_path, skip_lines, take_lines)
    local file, err = io.open(file_path, "r", 65001)
    if not file then
        return nil, true, 0, "file_error"
    end
    
    local lines = {}
    local lines_read = 0
    
    -- 跳过已读行
    for _ = 1, skip_lines do
        local line = file:read("*l")
        if not line then
            file:close()
            return {}, true, 0, "file_end"  -- 文件已读完
        end
    end
    
    -- 读取指定行数
    for _ = 1, take_lines do
        local line = file:read("*l")
        if not line then
            break
        end
        table.insert(lines, line)
        lines_read = lines_read + 1
    end
    
    file:close()
    return lines, false, lines_read, "success"
end

-- 解析一行文本，按标点分割
local function parse_line_segments(line_text)
    if not line_text or line_text == "" then
        return {}
    end
    
    local segments = {}
    local i = 1
    local line_len = #line_text
    local loop_cnt = 0
    
    while i <= line_len and loop_cnt < CACHE_CONFIG.parse_max_loop do
        loop_cnt = loop_cnt + 1
        local found = false
        local min_pos = line_len + 1
        local matched_sep = ""
        
        for _, sep in ipairs(FORCE_CONFIG.separators) do
            local pos = line_text:find(sep, i, true)
            if pos and pos < min_pos then
                min_pos = pos
                matched_sep = sep
                found = true
            end
        end
        
        if found then
            local seg = line_text:sub(i, min_pos + #matched_sep - 1)
            local clean_seg = seg:gsub("^%s+", ""):gsub("%s+$", "")
            if clean_seg ~= "" and #clean_seg > 0 then
                table.insert(segments, clean_seg)
            end
            i = min_pos + #matched_sep
        else
            -- 处理行尾剩余内容
            local seg = line_text:sub(i)
            local clean_seg = seg:gsub("^%s+", ""):gsub("%s+$", "")
            if clean_seg ~= "" and #clean_seg > 0 then
                table.insert(segments, clean_seg)
            end
            break
        end
    end
    
    return segments
end

-- 核心续读：按行缓存
function M.load_read_txt()
    FORCE_CONFIG.line_cache = {}
    FORCE_CONFIG.segment_cache = {}
    FORCE_CONFIG.file_not_found = false
    FORCE_CONFIG.file_fully_read = false
    
    -- 检查文件是否存在
    if not file_exists(READ_TXT_PATH) then
        FORCE_CONFIG.file_not_found = true
        FORCE_CONFIG.line_cache = {"custom_phrase/read.txt未找到，阅读模式已关闭"}
        FORCE_CONFIG.segment_cache = {"custom_phrase/read.txt未找到，阅读模式已关闭"}
        FORCE_CONFIG.cache_start_line = 0
        FORCE_CONFIG.cache_end_line = 0
        FORCE_CONFIG.current_line_index = 1
        FORCE_CONFIG.segment_index = 0
        M.read_mode_enabled = false  -- 文件不存在时自动关闭阅读状态
        return
    end
    
    -- 强制以文件值为准
    local saved_index = M.load_read_state()
    FORCE_CONFIG.global_line_index = saved_index
    FORCE_CONFIG.cache_start_line = saved_index
    
    -- 读取文件
    local lines, is_file_all_read, lines_read, status = read_lines_by_skip(READ_TXT_PATH, saved_index, CACHE_CONFIG.cache_line_count)
    
    if status == "file_error" then
        FORCE_CONFIG.line_cache = {"读取文件失败，请检查文件路径"}
        FORCE_CONFIG.segment_cache = {"读取文件失败，请检查文件路径"}
        FORCE_CONFIG.cache_start_line = 0
        FORCE_CONFIG.cache_end_line = 0
        FORCE_CONFIG.current_line_index = 1
        FORCE_CONFIG.segment_index = 0
        M.read_mode_enabled = false  -- 文件读取失败时自动关闭阅读状态
        return
    end
    
    if is_file_all_read and #lines == 0 then
        FORCE_CONFIG.file_fully_read = true
        FORCE_CONFIG.line_cache = {"已读完整个文件"}
        FORCE_CONFIG.segment_cache = {"已读完整个文件"}
        FORCE_CONFIG.cache_start_line = saved_index
        FORCE_CONFIG.cache_end_line = saved_index
        FORCE_CONFIG.current_line_index = 1
        FORCE_CONFIG.segment_index = 0
        return
    end
    
    if not lines or #lines == 0 then
        FORCE_CONFIG.line_cache = {"文件为空"}
        FORCE_CONFIG.segment_cache = {"文件为空"}
        FORCE_CONFIG.cache_start_line = 0
        FORCE_CONFIG.cache_end_line = 0
        FORCE_CONFIG.current_line_index = 1
        FORCE_CONFIG.segment_index = 0
        M.read_mode_enabled = false  -- 文件为空时自动关闭阅读状态
        return
    end
    
    -- 存储行缓存
    FORCE_CONFIG.line_cache = lines
    FORCE_CONFIG.current_line_index = 1
    FORCE_CONFIG.segment_index = 0
    FORCE_CONFIG.cache_end_line = saved_index + lines_read
    
    -- 预分割第一行
    if #lines > 0 then
        FORCE_CONFIG.segment_cache = parse_line_segments(lines[1])
    end
end

-- 获取当前候选词
function M.get_current_candidate()
    -- 检查文件是否存在
    if FORCE_CONFIG.file_not_found then
        M.read_mode_enabled = false  -- 文件不存在时自动关闭阅读状态
        return "custom_phrase/read.txt未找到，阅读模式已关闭"
    end
    
    -- 检查文件是否已读完
    if FORCE_CONFIG.file_fully_read then
        return "已读完整个文件"
    end
    
    -- 如果行缓存为空，尝试加载
    if #FORCE_CONFIG.line_cache == 0 then
        M.load_read_txt()
    end
    
    -- 再次检查文件状态
    if FORCE_CONFIG.file_not_found then
        M.read_mode_enabled = false  -- 文件不存在时自动关闭阅读状态
        return "custom_phrase/read.txt未找到，阅读模式已关闭"
    end
    
    if FORCE_CONFIG.file_fully_read then
        return "已读完整个文件"
    end
    
    -- 如果行缓存仍然为空，说明文件已读完或有其他问题
    if #FORCE_CONFIG.line_cache == 0 then
        M.read_mode_enabled = false  -- 文件读取失败时自动关闭阅读状态
        return "文件为空或读取失败，阅读模式已关闭"
    end
    
    -- 检查当前行是否有效
    if FORCE_CONFIG.current_line_index < 1 or FORCE_CONFIG.current_line_index > #FORCE_CONFIG.line_cache then
        FORCE_CONFIG.current_line_index = 1
        FORCE_CONFIG.segment_index = 0
        FORCE_CONFIG.segment_cache = parse_line_segments(FORCE_CONFIG.line_cache[1])
    end
    
    -- 获取当前行
    local current_line = FORCE_CONFIG.line_cache[FORCE_CONFIG.current_line_index] or ""
    
    -- 如果当前行的分割缓存为空，重新分割
    if #FORCE_CONFIG.segment_cache == 0 then
        FORCE_CONFIG.segment_cache = parse_line_segments(current_line)
    end
    
    -- 如果当前行分割后仍然为空（空行或只有空格），跳过此行
    if #FORCE_CONFIG.segment_cache == 0 then
        FORCE_CONFIG.current_line_index = FORCE_CONFIG.current_line_index + 1
        FORCE_CONFIG.global_line_index = FORCE_CONFIG.global_line_index + 1
        FORCE_CONFIG.segment_index = 0
        
        -- 保存进度
        M.save_read_state()
        
        -- 递归获取下一个候选
        return M.get_current_candidate()
    end
    
    -- 返回当前候选
    local segment_text = FORCE_CONFIG.segment_cache[FORCE_CONFIG.segment_index + 1] or current_line
    return segment_text
end

-- 切换到下一个候选
function M.next_candidate()
    -- 检查文件状态
    if FORCE_CONFIG.file_not_found then
        M.read_mode_enabled = false  -- 文件不存在时自动关闭阅读状态
        return "custom_phrase/read.txt未找到，阅读模式已关闭"
    end
    
    if FORCE_CONFIG.file_fully_read then
        return "已读完整个文件"
    end
    
    if not FORCE_CONFIG.is_auto_switch then
        return M.get_current_candidate()
    end
    
    -- 行缓存为空的情况
    if #FORCE_CONFIG.line_cache == 0 then
        M.load_read_txt()
        if FORCE_CONFIG.file_not_found then
            M.read_mode_enabled = false  -- 文件不存在时自动关闭阅读状态
            return "custom_phrase/read.txt未找到，阅读模式已关闭"
        end
        if FORCE_CONFIG.file_fully_read then
            return "已读完整个文件"
        end
        if #FORCE_CONFIG.line_cache == 0 then
            M.read_mode_enabled = false  -- 文件读取失败时自动关闭阅读状态
            return "文件为空或读取失败，阅读模式已关闭"
        end
    end
    
    -- 当前行索引检查
    if FORCE_CONFIG.current_line_index < 1 or FORCE_CONFIG.current_line_index > #FORCE_CONFIG.line_cache then
        FORCE_CONFIG.current_line_index = 1
        FORCE_CONFIG.segment_index = 0
        FORCE_CONFIG.segment_cache = parse_line_segments(FORCE_CONFIG.line_cache[1] or "")
    end
    
    -- 行内分割缓存为空的情况
    if #FORCE_CONFIG.segment_cache == 0 then
        local current_line = FORCE_CONFIG.line_cache[FORCE_CONFIG.current_line_index] or ""
        FORCE_CONFIG.segment_cache = parse_line_segments(current_line)
        
        -- 如果分割后仍然为空，跳过此行
        if #FORCE_CONFIG.segment_cache == 0 then
            FORCE_CONFIG.current_line_index = FORCE_CONFIG.current_line_index + 1
            FORCE_CONFIG.global_line_index = FORCE_CONFIG.global_line_index + 1
            FORCE_CONFIG.segment_index = 0
            
            M.save_read_state()
            return M.get_current_candidate()
        end
    end
    
    -- 移动到下一个分割单位
    FORCE_CONFIG.segment_index = FORCE_CONFIG.segment_index + 1
    
    -- 检查是否超过当前行的分割单位数
    if FORCE_CONFIG.segment_index >= #FORCE_CONFIG.segment_cache then
        -- 移动到下一行
        FORCE_CONFIG.current_line_index = FORCE_CONFIG.current_line_index + 1
        FORCE_CONFIG.global_line_index = FORCE_CONFIG.global_line_index + 1
        FORCE_CONFIG.segment_index = 0
        FORCE_CONFIG.segment_cache = {}
        
        -- 保存全局行进度
        M.save_read_state()
        
        -- 检查是否超过缓存范围
        if FORCE_CONFIG.current_line_index > #FORCE_CONFIG.line_cache then
            M.load_read_txt()
            
            if FORCE_CONFIG.file_not_found then
                M.read_mode_enabled = false  -- 文件不存在时自动关闭阅读状态
                return "custom_phrase/read.txt未找到，阅读模式已关闭"
            end
            
            if FORCE_CONFIG.file_fully_read then
                return "已读完整个文件"
            end
            
            if #FORCE_CONFIG.line_cache == 0 then
                M.read_mode_enabled = false  -- 文件读取失败时自动关闭阅读状态
                return "文件为空或读取失败，阅读模式已关闭"
            end
        else
            -- 预分割下一行
            local next_line = FORCE_CONFIG.line_cache[FORCE_CONFIG.current_line_index] or ""
            FORCE_CONFIG.segment_cache = parse_line_segments(next_line)
        end
    end
    
    return M.get_current_candidate()
end

-- 核心入口函数
function M.auto_switch_candidate()
    return M.next_candidate()
end

-- 处理开关控制指令
local function handle_switch_commands(input, env)
    local context = env.engine.context
    local input_text = context.input
    local preedit_text = context:get_preedit().text or ""
    
    -- 检查是否输入了/re指令
    if input_text:find("/re") == 1 then
        M.read_mode_enabled = true
        -- 清除输入，避免上屏
        context:clear()
        return true
    end
    
    -- 检查是否输入了单独的/指令
    if input_text == "/" and M.read_mode_enabled then
        M.read_mode_enabled = false
        context:clear()
        return true
    end
    
    -- 检查在连续输入中是否包含了/（新功能：在阅读模式下输入/即可关闭）
    if M.read_mode_enabled and preedit_text:find("/") then
        M.read_mode_enabled = false
        context:clear()
        env.engine.context.input = "/"
        return true
    end
    
    return false
end

-- 主处理函数
function M.func(input, env)
    local context = env.engine.context
    
    -- 处理开关指令
    if handle_switch_commands(input, env) then
        return
    end
    
    -- 如果阅读模式未启用，则输出正常候选
    if not M.read_mode_enabled then
        for cand in input:iter() do
            yield(cand)
        end
        return
    end

    -- 阅读模式启用，输出阅读候选
    local input_len = #context.input or 1
    local curr_text = M.auto_switch_candidate() or "正常续读中"
    local Candidate = Candidate or env.engine.Candidate or rime.Candidate
    local s, e = 0, input_len

    -- 第一候选
    if Candidate and FORCE_CONFIG.is_show then
        local ok, cand = pcall(Candidate, "custom", s, e, curr_text, "")
        yield(ok and cand or {text=curr_text, start=s, ["end"]=e})
    end
    -- 第二候选（空）
    if Candidate then
        local ok, cand = pcall(Candidate, "custom", s, e, "", "")
        yield(ok and cand or {text="", start=s, ["end"]=e})
    end
end

function M.init(env)
    M.read_mode_enabled = false  -- 默认关闭阅读模式
    M.load_read_txt()
end

function M.fini(env)
    -- 已注释：禁止退出时覆盖手动改的进度，完全以read_state.txt为准
    -- M.save_read_state()
end

return M
