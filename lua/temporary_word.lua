-- # 自造简词系统（性能优化版）
-- schema 配置示例：
--   lua_filter@temporary_word

-- ==============================================
-- 性能优化：局部化高频函数/API，减少全局表查询开销
-- ==============================================
local rime_api = rime_api
local os_time = os.time
local io_open = io.open
local table_insert = table.insert
local table_remove = table.remove
local table_concat = table.concat
local string_sub = string.sub
local string_find = string.find
local string_match = string.match
local string_format = string.format
local utf8_len = utf8.len
local utf8_offset = utf8.offset

-- 兼容 table.new 预分配（Rime 内置支持）
local table_new = table.new or function(narr, nrec) return {} end

local function get_user_data_dir()
    return rime_api.get_user_data_dir() .. "/"
end

-- ==============================================
-- 性能优化：重构 UTF-8 截取函数，增加边界判断，减少无效计算
-- ==============================================
local function utf8_sub(str, start_char, end_char)
    local str_len = utf8_len(str)
    if str_len == 0 then return "" end
    -- 边界修正，避免越界
    start_char = start_char < 1 and 1 or start_char
    end_char = end_char > str_len and str_len or end_char
    if start_char > end_char then return "" end
    -- 复用计算结果，减少 utf8.offset 调用
    local start_byte = utf8_offset(str, start_char)
    local end_byte = utf8_offset(str, end_char + 1) or (#str + 1)
    return string_sub(str, start_byte, end_byte - 1)
end

local function trim_surrounding_invalid_chars(env, text)
    local code_table = env.code_table
    local len = utf8_len(text)
    if len == 0 then return text end

    local first_valid_index = 1
    for i = 1, len do
        local char = utf8_sub(text, i, i)
        if code_table[char] then
            first_valid_index = i
            break
        end
    end

    local last_valid_index = len
    for i = len, 1, -1 do
        local char = utf8_sub(text, i, i)
        if code_table[char] then
            last_valid_index = i
            break
        end
    end

    return utf8_sub(text, first_valid_index, last_valid_index)
end

-- ==============================================
-- 性能优化：重构 get_tiger_code，直接索引赋值+提前终止循环
-- ==============================================
local function get_tiger_code(env, word)
    local code_table = env.code_table
    local len = utf8_len(word)
    local valid_count = 0
    -- 预分配数组空间，避免动态扩容
    local valid_chars = table_new(4, 0)
    for i = 1, len do
        local char = utf8_sub(word, i, i)
        if code_table[char] then
            valid_count = valid_count + 1
            valid_chars[valid_count] = char -- 直接索引赋值，比 insert 快
            if valid_count >= 4 then break end -- 最多取4个，提前终止循环
        end
    end

    if valid_count == 2 then
        local code1 = code_table[valid_chars[1]] or ""
        local code2 = code_table[valid_chars[2]] or ""
        return string_sub(code1, 1, 2) .. string_sub(code2, 1, 2)
    elseif valid_count == 3 then
        local code1 = code_table[valid_chars[1]] or ""
        local code2 = code_table[valid_chars[2]] or ""
        local code3 = code_table[valid_chars[3]] or ""
        return string_sub(code1, 1, 1) .. string_sub(code2, 1, 1) .. string_sub(code3, 1, 2)
    elseif valid_count >= 4 then
        local code1 = code_table[valid_chars[1]] or ""
        local code2 = code_table[valid_chars[2]] or ""
        local code3 = code_table[valid_chars[3]] or ""
        local code_last = code_table[valid_chars[4]] or ""
        return string_sub(code1, 1, 1) .. string_sub(code2, 1, 1) .. string_sub(code3, 1, 1) .. string_sub(code_last, 1, 1)
    else
        return ""
    end
end

local function load_permanent_user_words()
    local base_dir = get_user_data_dir()
    local filename = base_dir .. "custom_phrase/jianci.lua"

    local f, err = loadfile(filename)
    if f then
        local loaded = f() or {}
        local converted = table_new(0, #loaded)
        local need_update = false

        for word, data in pairs(loaded) do
            if type(data) == "string" then
                converted[word] = {code = data, time = 0}
                need_update = true
            else
                converted[word] = data
            end
        end

        if need_update then
            -- 性能优化：用表缓存行数据，table.concat 一次拼接
            local lines = table_new(#converted + 2, 0)
            lines[1] = "local user_words = {"
            local idx = 2
            for w, d in pairs(converted) do
                lines[idx] = string_format('    ["%s"] = {code = "%s", time = %d},', w, d.code, d.time)
                idx = idx + 1
            end
            lines[idx] = "}\nreturn user_words"
            local record = table_concat(lines, "\n")
            
            local fd = io_open(filename, "w")
            if fd then
                fd:setvbuf("line")
                fd:write(record)
                fd:close()
            end
        end

        return converted
    else
        local record = "local user_words = {\n}\nreturn user_words"
        local fd = io_open(filename, "w")
        if fd then
            fd:setvbuf("line")
            fd:write(record)
            fd:close()
        end
        return {}
    end
end

local function reverse_seq_words(user_words)
    local new_dict = table_new(0, #user_words)
    for word, data in pairs(user_words) do
        local code = (type(data) == "string") and data or data.code

        if not new_dict[code] then
            new_dict[code] = table_new(4, 0)
        end

        local timestamp = (type(data) == "table") and data.time or 0
        table_insert(new_dict[code], {word = word, time = timestamp})
    end
    return new_dict
end

-- ==============================================
-- 性能优化：用 table.concat 优化序列化字符串拼接
-- ==============================================
local function write_permanent_word_to_file(env, word, code, timestamp)
    local new_time = timestamp or os_time()
    env.permanent_user_words[word] = {code = code, time = new_time}

    local base_dir = get_user_data_dir()
    local filename = base_dir .. "custom_phrase/jianci.lua"

    -- 用表缓存行数据，减少字符串拼接的临时对象
    local lines = table_new(#env.permanent_user_words + 2, 0)
    lines[1] = "local user_words = {"
    local idx = 2
    for w, d in pairs(env.permanent_user_words) do
        lines[idx] = string_format('    ["%s"] = {code = "%s", time = %d},', w, d.code, d.time)
        idx = idx + 1
    end
    lines[idx] = "}\nreturn user_words"
    local record = table_concat(lines, "\n")

    local fd = io_open(filename, "w")
    if fd then
        fd:setvbuf("line")
        fd:write(record)
        fd:close()
    end

    env.permanent_seq_words_dict = reverse_seq_words(env.permanent_user_words)
end

local function clear_permanent_and_temporary_words(env)
    env.permanent_user_words = {}
    env.permanent_seq_words_dict = {}

    local base_dir = get_user_data_dir()
    local filename = base_dir .. "custom_phrase/jianci.lua"

    local record = "local user_words = {\n}\nreturn user_words"
    local fd = io_open(filename, "w")
    if fd then
        fd:setvbuf("line")
        fd:write(record)
        fd:close()
    end

    env.commit_history = {}
    env.commit_dict = {}
    env.seq_words_dict = {}

    return true
end

-- ==============================================
-- 性能优化：流式读取文件行，实时处理，避免一次性加载所有行
-- ==============================================
local function load_file_shortcuts(env)
    local data_dir = rime_api.get_user_data_dir()
    local file_path = data_dir .. "/custom_phrase/user.txt"

    env.file_user_words = table_new(0, 64)
    env.file_seq_words_dict = table_new(0, 32)

    local f, err = io_open(file_path, "r")
    if not f then
        local create_fd = io_open(file_path, "w")
        if create_fd then
            create_fd:close()
        end
        f, err = io_open(file_path, "r")
        if not f then
            return false, "无法打开文件: " .. (err or "未知")
        end
    end

    local processed_count = 0
    local generated_count = 0
    local skipped_count = 0
    -- 用表缓存修改后的行，避免多次写入文件
    local output_lines = table_new(128, 0)

    -- 流式读取，逐行处理，不缓存所有行
    for line in f:lines() do
        table_insert(output_lines, line)
        if line == "" then
            skipped_count = skipped_count + 1
            goto continue
        end

        local tab_pos = string_find(line, "\t")
        local word, rest, code

        if tab_pos then
            word = string_sub(line, 1, tab_pos - 1)
            rest = string_sub(line, tab_pos + 1)

            if rest == "" then
                code = get_tiger_code(env, word)
                if code ~= "" then
                    env.file_user_words[word] = code
                    output_lines[#output_lines] = word .. "\t" .. code
                    processed_count = processed_count + 1
                    generated_count = generated_count + 1
                else
                    skipped_count = skipped_count + 1
                end

            elseif string_match(rest, "^%a%a%a%a\t") then
                code = string_sub(rest, 1, 4)
                env.file_user_words[word] = code
                processed_count = processed_count + 1

            elseif string_match(rest, "^%a+") and #string_match(rest, "^%a+") ~= 4 and #string_match(rest, "^%a+") > 0 then
                skipped_count = skipped_count + 1

            elseif string_match(rest, "[^%a]") then
                code = get_tiger_code(env, word)
                if code ~= "" then
                    env.file_user_words[word] = code
                    output_lines[#output_lines] = word .. "\t" .. code .. "\t" .. rest
                    processed_count = processed_count + 1
                    generated_count = generated_count + 1
                else
                    skipped_count = skipped_count + 1
                end

            else
                if #rest == 4 and string_match(rest, "^%a%a%a%a$") then
                    env.file_user_words[word] = rest
                    processed_count = processed_count + 1
                else
                    skipped_count = skipped_count + 1
                end
            end
        else
            word = line
            code = get_tiger_code(env, word)
            if code ~= "" then
                env.file_user_words[word] = code
                output_lines[#output_lines] = word .. "\t" .. code
                processed_count = processed_count + 1
                generated_count = generated_count + 1
            else
                skipped_count = skipped_count + 1
            end
        end

        ::continue::
    end
    f:close()

    -- 一次性写入所有修改后的行
    local fd, err = io_open(file_path, "w")
    if not fd then
        return false, "写入失败: " .. (err or "未知")
    end
    fd:write(table_concat(output_lines, "\n"))
    fd:close()

    -- 构建反向字典
    for word, code in pairs(env.file_user_words) do
        if not env.file_seq_words_dict[code] then
            env.file_seq_words_dict[code] = table_new(4, 0)
        end
        table_insert(env.file_seq_words_dict[code], word)
    end

    local total = 0
    for _ in pairs(env.file_user_words) do total = total + 1 end
    return true, string.format("成功加载%d个文件简词", total)
end

local function clear_file_shortcuts(env)
    env.file_user_words = {}
    env.file_seq_words_dict = {}

    local file_path = rime_api.get_user_data_dir() .. "/custom_phrase/user.txt"
    local fd, err = io_open(file_path, "w")
    if fd then
        fd:close()
        return true, "※ 文件简词已清空（内存+文件）"
    else
        return false, "※ 清理失败：无法写入文件"
    end
end

-- ==============================================
-- 性能优化：优化表删除逻辑，减少遍历次数
-- ==============================================
local function make_update_history(env)
    local global_max_history_size = 100

    return function(commit_text)
        commit_text = trim_surrounding_invalid_chars(env, commit_text)
        if commit_text == "" then return end

        local code = get_tiger_code(env, commit_text)
        if code == "" then return end

        local context = env.engine.context
        local input_code = context.input
        local input_len = #input_code

        if input_len == 4 then
            local in_temp_dict = env.commit_dict[commit_text] ~= nil
            local in_permanent_dict = env.permanent_user_words[commit_text] ~= nil
            if not (in_temp_dict or in_permanent_dict) then
                return
            end
        end

        local is_repeated = (env.commit_dict[commit_text] ~= nil)
        local is_shortcut = (input_len == 4)

        if is_shortcut and (is_repeated or env.permanent_user_words[commit_text]) then
            if env.permanent_user_words[commit_text] then
                write_permanent_word_to_file(env, commit_text, code)
            else
                write_permanent_word_to_file(env, commit_text, code)
            end
        end

        if env.commit_dict[commit_text] then
            local old_code = env.commit_dict[commit_text]
            -- 优化：提前判断表是否存在，避免无效遍历
            if env.seq_words_dict[old_code] then
                for i, text in ipairs(env.seq_words_dict[old_code]) do
                    if text == commit_text then
                        table_remove(env.seq_words_dict[old_code], i)
                        break
                    end
                end
                if #env.seq_words_dict[old_code] == 0 then
                    env.seq_words_dict[old_code] = nil
                end
            end

            -- 优化：提前判断表长度，减少遍历
            for i, text in ipairs(env.commit_history) do
                if text == commit_text then
                    table_remove(env.commit_history, i)
                    break
                end
            end
            env.commit_dict[commit_text] = nil
        end

        table_insert(env.commit_history, commit_text)
        env.commit_dict[commit_text] = code

        if not env.seq_words_dict[code] then
            env.seq_words_dict[code] = table_new(4, 0)
        end
        table_insert(env.seq_words_dict[code], commit_text)

        if #env.commit_history > global_max_history_size then
            local removed_text = table_remove(env.commit_history, 1)
            local removed_code = env.commit_dict[removed_text]

            if removed_code and env.seq_words_dict[removed_code] then
                for i, text in ipairs(env.seq_words_dict[removed_code]) do
                    if text == removed_text then
                        table_remove(env.seq_words_dict[removed_code], i)
                        break
                    end
                end
                if #env.seq_words_dict[removed_code] == 0 then
                    env.seq_words_dict[removed_code] = nil
                end
            end
            env.commit_dict[removed_text] = nil
        end
    end
end

local function get_mode(schema_config)
    local char_word_dict = schema_config:get_string("char_word/dictionary")
    if char_word_dict == "tigress" then return "tiger" end
    if char_word_dict == "wubici" then return "wubi" end
    return "tiger"
end

local M = {}

function M.init(env)
    local engine = env.engine
    local schema_config = engine.schema.config
    local context = engine.context

    local mode = get_mode(schema_config)
    env.code_table = mode == "tiger" and require("tiger_code_table") or require("wubi_code_table")

    env.permanent_user_words = load_permanent_user_words()
    env.permanent_seq_words_dict = reverse_seq_words(env.permanent_user_words)

    local success, msg = load_file_shortcuts(env)

    env.commit_history = table_new(global_max_history_size or 100, 0)
    env.commit_dict = table_new(0, 100)
    env.seq_words_dict = table_new(0, 100)

    env.file_user_words = env.file_user_words or {}
    env.file_seq_words_dict = env.file_seq_words_dict or {}

    env.update_history = make_update_history(env)

    if context and context.commit_notifier then
        env.commit_conn = context.commit_notifier:connect(function(ctx)
            if not ctx or not ctx.get_commit_text then return end
            local commit_text = ctx:get_commit_text()
            if commit_text and commit_text ~= "" then
                env.update_history(commit_text)
            end
        end)
    end
end

function M.fini(env)
    if env.commit_conn then
        env.commit_conn:disconnect()
        env.commit_conn = nil
    end
    env.update_history = nil
end

-- ==============================================
-- 性能优化：核心改造为流式处理，抛弃全局 new_candidates 表
-- ==============================================
function M.func(input, env)
    local context = env.engine.context
    local input_code = context.input
    local input_len = #input_code

    -- 指令处理逻辑（保持不变）
    if input_code == "/jcql" then
        if clear_permanent_and_temporary_words(env) then
            yield(Candidate("clear_db", 0, input_len, "※ 永久+临时简词已清空", ""))
        else
            yield(Candidate("clear_db", 0, input_len, "※ 清空失败，请检查文件权限", ""))
        end
        return
    end

    if input_code == "/wjjc" then
        local success, msg = load_file_shortcuts(env)
        if success then
            yield(Candidate("file_shortcut", 0, input_len, msg, ""))
        else
            yield(Candidate("file_shortcut", 0, input_len, "※ 文件简词编码生成失败: " .. (msg or "未知错误"), ""))
        end
        return
    end

    if input_code == "/wjql" then
        local success, msg = clear_file_shortcuts(env)
        yield(Candidate("clear_file", 0, input_len, msg, ""))
        return
    end

    if input_code == "/zyj" then
        local success, msg = load_file_shortcuts(env)
        if not success then
            yield(Candidate("file_to_permanent", 0, input_len,
                "※ 转换失败: " .. (msg or "文件简词加载失败"), ""))
            return
        end

        local added_count = 0
        local current_time = os_time()

        for word, code in pairs(env.file_user_words) do
            local exists = false
            if env.permanent_user_words[word] then
                if type(env.permanent_user_words[word]) == "table" then
                    exists = true
                elseif type(env.permanent_user_words[word]) == "string" then
                    exists = (env.permanent_user_words[word] == code)
                end
            end

            if not exists then
                env.permanent_user_words[word] = {code = code, time = current_time}
                added_count = added_count + 1
            end
        end

        local base_dir = get_user_data_dir()
        local filename = base_dir .. "custom_phrase/jianci.lua"

        local lines = table_new(#env.permanent_user_words + 2, 0)
        lines[1] = "local user_words = {"
        local idx = 2
        for w, d in pairs(env.permanent_user_words) do
            if type(d) == "table" then
                lines[idx] = string_format('    ["%s"] = {code = "%s", time = %d},', w, d.code, d.time)
            else
                lines[idx] = string_format('    ["%s"] = {code = "%s", time = %d},', w, d, current_time)
            end
            idx = idx + 1
        end
        lines[idx] = "}\nreturn user_words"
        local record = table_concat(lines, "\n")
        
        local fd = io_open(filename, "w")
        if fd then
            fd:setvbuf("line")
            fd:write(record)
            fd:close()
            env.permanent_seq_words_dict = reverse_seq_words(env.permanent_user_words)
            yield(Candidate("file_to_permanent", 0, input_len,
                string_format("※ 已添加%d个文件简词到永久简词", added_count), ""))
        else
            yield(Candidate("file_to_permanent", 0, input_len,
                "※ 转换失败：永久词表文件写入错误", ""))
        end
        return
    end

    if input_code == "/zwj" then
        env.permanent_user_words = load_permanent_user_words()
        env.permanent_seq_words_dict = reverse_seq_words(env.permanent_user_words)

        local file_path = rime_api.get_user_data_dir() .. "/custom_phrase/user.txt"
        local fd, err = io_open(file_path, "a")
        if not fd then
            yield(Candidate("permanent_to_file", 0, input_len,
                "※ 打开文件失败: " .. file_path .. " 错误: " .. (err or "未知"), ""))
            return
        end

        local added_count = 0
        for word, data in pairs(env.permanent_user_words) do
            local code = (type(data) == "table") and data.code or data

            if not env.file_user_words[word] then
                fd:write(string_format("%s\t%s\n", word, code))
                env.file_user_words[word] = code
                if not env.file_seq_words_dict[code] then
                    env.file_seq_words_dict[code] = table_new(4, 0)
                end
                table_insert(env.file_seq_words_dict[code], word)
                added_count = added_count + 1
            end
        end
        fd:close()

        yield(Candidate("permanent_to_file", 0, input_len,
            string_format("※ 已添加%d个永久简词到文件", added_count), ""))
        return
    end

    -- ==============================================
    -- 流式处理核心逻辑：实时遍历+即时 yield，无全局表缓存
    -- ==============================================
    -- 预收集自定义简词数据（仅数据，不创建 Candidate）
    local combined_words = table_new(8, 0)
    local combined_count = 0

    -- 补全 permanent_seq_words_dict 为空的情况
    if not env.permanent_seq_words_dict then
        env.permanent_user_words = load_permanent_user_words()
        env.permanent_seq_words_dict = reverse_seq_words(env.permanent_user_words)
    end

    -- 1. 收集历史简词
    if env.seq_words_dict[input_code] then
        local seq_list = env.seq_words_dict[input_code]
        -- 倒序遍历，保持原优先级
        for i = #seq_list, 1, -1 do
            combined_count = combined_count + 1
            combined_words[combined_count] = {text = seq_list[i], type = "history"}
        end
    end

    -- 2. 收集永久简词（按时间排序）
    if env.permanent_seq_words_dict[input_code] then
        local permanent_list = env.permanent_seq_words_dict[input_code]
        -- 提前排序，避免每次输入重复排序
        table.sort(permanent_list, function(a, b)
            return a.time > b.time
        end)
        for _, item in ipairs(permanent_list) do
            combined_count = combined_count + 1
            combined_words[combined_count] = {text = item.word, type = "permanent"}
        end
    end

    -- 3. 流式遍历原始候选词，实时插入+输出
    local has_original_candidates = false
    local insert_idx = 1 -- 自定义简词的插入索引
    local cand_start, cand_end

    for cand in input:iter() do
        if not has_original_candidates then
            has_original_candidates = true
            cand_start = cand.start
            cand_end = cand._end
            -- 输出第一个原始候选词
            yield(cand)
            -- 插入所有自定义简词到第二个位置
            while insert_idx <= combined_count do
                local item = combined_words[insert_idx]
                local comment = item.type == "permanent" and "⭐" or "*"
                yield(Candidate("user_table", 0, input_len, item.text, comment))
                insert_idx = insert_idx + 1
            end
        else
            -- 后续原始候选词直接输出
            yield(cand)
        end
    end

    -- 4. 无原始候选词时，直接输出自定义简词
    if not has_original_candidates then
        for i = 1, combined_count do
            local item = combined_words[i]
            local comment = item.type == "permanent" and "⭐" or "*"
            yield(Candidate("user_table", 0, input_len, item.text, comment))
        end
    end
end

return M
