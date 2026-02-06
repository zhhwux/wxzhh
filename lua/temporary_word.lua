-- # 修复版自造简词系统 - DB稳定版（仅码表使用LevelDB）
-- 码表使用LevelDB（大数据量），用户词库使用文件（小数据量）

local wanxiang = require('wanxiang')
local userdb = require("lib/userdb")

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
local table_new = table_new or function(narr, nrec) return {} end

-- ==============================================
-- 统一的数据库管理器（仅用于码表）
-- ==============================================
local DBManager = {
    dbs = {},
    status = "pending"
}

-- 安全的路径处理（参考优化后的脚本）
local function ensure_dir_exist(dir)
    if not dir or dir == "" then return true end

    -- 使用纯Lua方法，避免os.execute
    local lfs = package.loaded.lfs
    if lfs then
        local ok, err = pcall(lfs.mkdir, dir)
        if not ok then
            io.stderr:write("警告：无法创建目录 '" .. dir .. "': " .. tostring(err) .. "\n")
            return false
        end
        return true
    else
        -- 回退方案：尝试创建空文件来间接创建目录
        local test_file = dir .. "/.test"
        local fd, err = io.open(test_file, "w")
        if fd then
            fd:close()
            os.remove(test_file)
            return true
        end
        io.stderr:write("警告：目录创建失败 '" .. dir .. "': " .. tostring(err) .. "\n")
        return false
    end
end

-- 安全的数据库操作（仅用于码表）
local function safe_db_operation(db_name, operation, ...)
    local db = DBManager.dbs[db_name]
    if not db then
        io.stderr:write("错误：数据库未打开: " .. db_name .. "\n")
        return nil, "数据库未打开"
    end

    local ok, result = pcall(operation, db, ...)
    if not ok then
        io.stderr:write("错误：数据库操作失败 '" .. db_name .. "': " .. tostring(result) .. "\n")
        return nil, result
    end

    return result, nil
end

-- 打开数据库（带重试机制，参考中文词典脚本）
local function open_db_with_retry(db_name, mode, max_retries)
    max_retries = max_retries or 3

    for i = 1, max_retries do
        local ok, err = pcall(function()
            local db = userdb.LevelDb(db_name)
            if mode == "read_only" then
                db:open_read_only()
            else
                db:open()
            end
            DBManager.dbs[db_name] = db
        end)

        if ok then
            if i > 1 then
                io.stderr:write("信息：数据库 '" .. db_name .. "' 第" .. i .. "次重试成功\n")
            end
            return true
        end

        if i < max_retries then
            -- 短暂等待后重试
            local sleep_time = 0.1 * i  -- 指数退避
            if os.execute then
                if os.getenv("OS") and os.getenv("OS"):find("Windows") then
                    os.execute("timeout /t " .. math.ceil(sleep_time) .. " >nul 2>&1")
                else
                    os.execute("sleep " .. sleep_time)
                end
            end
        end
    end

    return false, "数据库打开失败: " .. db_name
end

-- 关闭数据库
local function close_db(db_name)
    local db = DBManager.dbs[db_name]
    if db then
        local ok, err = pcall(db.close, db)
        if not ok then
            io.stderr:write("警告：关闭数据库失败 '" .. db_name .. "': " .. tostring(err) .. "\n")
        end
        DBManager.dbs[db_name] = nil
    end
end

-- 关闭所有数据库
local function close_all_dbs()
    for db_name, _ in pairs(DBManager.dbs) do
        close_db(db_name)
    end
    DBManager.status = "pending"
end

-- ==============================================
-- 码表数据库模块（参考中文词典脚本）
-- ==============================================
local CodeTableDB = {
    db_name = nil,
    status = "pending"
}

local META_KEY_VERSION = "code_table_version"
local CURRENT_VERSION = "1.0"

function CodeTableDB.init(env, mode)
    if CodeTableDB.status ~= "pending" then return end

    -- 1. 确定数据库名称和路径
    CodeTableDB.db_name = mode == "tiger" and "lua/tiger_code" or "lua/wubi_code"
    local source_file = mode == "tiger" and "tiger_code_table.lua" or "wubi_code_table.lua"

    -- 2. 确保目录存在
    local user_lua_dir = rime_api.get_user_data_dir() .. "/lua"
    local user_lua_data_dir = user_lua_dir .. "/data"
    ensure_dir_exist(user_lua_data_dir)

    -- 3. 打开数据库（只读模式，因为码表是静态的）
    local ok, err = open_db_with_retry(CodeTableDB.db_name, "read_only")
    if not ok then
        io.stderr:write("错误：无法打开码表数据库: " .. tostring(err) .. "\n")
        CodeTableDB.status = "error"
        return
    end

    -- 4. 检查并可能重建数据库（参考优化脚本的版本检查）
    local db = DBManager.dbs[CodeTableDB.db_name]
    local db_version = safe_db_operation(CodeTableDB.db_name, db.meta_fetch, META_KEY_VERSION)

    local needs_rebuild = false
    if not db_version or db_version ~= CURRENT_VERSION then
        needs_rebuild = true
    end

    if needs_rebuild then
        io.stderr:write("信息：码表数据库需要重建...\n")

        -- 关闭只读模式，重新打开进行写入
        close_db(CodeTableDB.db_name)

        -- 重新打开进行写入
        local ok, err = open_db_with_retry(CodeTableDB.db_name, "write")
        if not ok then
            io.stderr:write("错误：无法以写入模式打开码表数据库: " .. tostring(err) .. "\n")
            CodeTableDB.status = "error"
            return
        end

        -- 清空数据库
        local db_write = DBManager.dbs[CodeTableDB.db_name]
        local empty_ok, empty_err = pcall(db_write.empty, db_write)
        if not empty_ok then
            io.stderr:write("错误：清空码表数据库失败: " .. tostring(empty_err) .. "\n")
            CodeTableDB.status = "error"
            return
        end

        -- 加载码表文件
        local code_table_data = {}
        local success, loaded = pcall(function()
            local paths = {
                rime_api.get_user_data_dir() .. "/lua/" .. source_file,
                rime_api.get_shared_data_dir() .. "/lua/" .. source_file
            }

            for _, path in ipairs(paths) do
                local f, err = loadfile(path)
                if f then
                    return f()
                end
            end
            return nil
        end)

        if success and loaded then
            code_table_data = loaded
        else
            io.stderr:write("错误：无法加载码表文件: " .. source_file .. "\n")
        end

        -- 批量写入数据（参考优化脚本的批量操作）
        local count = 0
        local batch_size = 100
        local batch = {}

        for char, code in pairs(code_table_data) do
            table.insert(batch, {char = char, code = code})

            if #batch >= batch_size then
                for _, item in ipairs(batch) do
                    local ok, err = pcall(db_write.update, db_write, item.char, item.code)
                    if ok then
                        count = count + 1
                    else
                        io.stderr:write("警告：写入字符失败 '" .. item.char .. "': " .. tostring(err) .. "\n")
                    end
                end
                batch = {}

                -- 进度日志
                io.stderr:write("信息：已写入码表数据: " .. count .. " 个字符\n")
            end
        end

        -- 写入剩余数据
        for _, item in ipairs(batch) do
            local ok, err = pcall(db_write.update, db_write, item.char, item.code)
            if ok then
                count = count + 1
            end
        end

        -- 更新版本元数据
        local meta_ok, meta_err = pcall(db_write.meta_update, db_write, META_KEY_VERSION, CURRENT_VERSION)
        if not meta_ok then
            io.stderr:write("警告：更新元数据失败: " .. tostring(meta_err) .. "\n")
        end

        io.stderr:write("信息：码表数据库重建完成，共写入: " .. count .. " 个字符\n")

        -- 重新关闭并以只读模式打开
        close_db(CodeTableDB.db_name)
        local ok, err = open_db_with_retry(CodeTableDB.db_name, "read_only")
        if not ok then
            io.stderr:write("错误：重建后无法以只读模式打开码表数据库: " .. tostring(err) .. "\n")
            CodeTableDB.status = "error"
            return
        end
    end

    -- 5. 创建查询接口（参考优化脚本的Query模块）
    env.code_table = {
        fetch = function(self, char)
            if CodeTableDB.status ~= "done" then
                return nil
            end

            local db = DBManager.dbs[CodeTableDB.db_name]
            if not db then
                return nil
            end

            local ok, result = pcall(db.fetch, db, char)
            if not ok then
                io.stderr:write("警告：查询码表失败 '" .. char .. "': " .. tostring(result) .. "\n")
                return nil
            end

            return result
        end
    }

    CodeTableDB.status = "done"
    io.stderr:write("信息：码表数据库初始化完成\n")
end

function CodeTableDB.fini()
    if CodeTableDB.db_name then
        close_db(CodeTableDB.db_name)
    end
    CodeTableDB.status = "pending"
end

-- ==============================================
-- 用户词库使用文件存储（小数据量，无需DB）
-- ==============================================

-- 兼容性函数
local function is_ios_device()
    local home = os.getenv("HOME")
    return home and home:find("/var/mobile/") ~= nil
end

local function get_user_data_dir()
    return is_ios_device() and os.getenv("HOME").."/Documents/"
                           or rime_api.get_user_data_dir().."/"
end

local function utf8_sub(str, start_char, end_char)
    local str_len = utf8_len(str)
    if str_len == 0 then return "" end
    -- 边界修正，避免越界
    start_char = start_char < 1 and 1 or start_char
    end_char = end_char > str_len and str_len or end_char
    if start_char > end_char then return "" end
    -- 复用计算结果
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
        if code_table:fetch(char) then
            first_valid_index = i
            break
        end
    end

    local last_valid_index = len
    for i = len, 1, -1 do
        local char = utf8_sub(text, i, i)
        if code_table:fetch(char) then
            last_valid_index = i
            break
        end
    end

    return utf8_sub(text, first_valid_index, last_valid_index)
end

local function get_tiger_code(env, word)
    local code_table = env.code_table
    local len = utf8_len(word)
    local valid_count = 0
    -- 预分配数组空间，避免动态扩容
    local valid_chars = table_new(8, 0)  -- 扩容为8，兼容全量有效字收集

    -- 全量收集所有有效字（不提前终止，保证1230模式能取到真正的最后一个有效字）
    for i = 1, len do
        local char = utf8_sub(word, i, i)
        if code_table:fetch(char) then
            valid_count = valid_count + 1
            valid_chars[valid_count] = char -- 直接索引赋值，比 insert 快
        end
    end

    if valid_count == 2 then
        local code1 = code_table:fetch(valid_chars[1]) or ""
        local code2 = code_table:fetch(valid_chars[2]) or ""
        return string_sub(code1, 1, 2) .. string_sub(code2, 1, 2)
    elseif valid_count == 3 then
        local code1 = code_table:fetch(valid_chars[1]) or ""
        local code2 = code_table:fetch(valid_chars[2]) or ""
        local code3 = code_table:fetch(valid_chars[3]) or ""
        return string_sub(code1, 1, 1) .. string_sub(code2, 1, 1) .. string_sub(code3, 1, 2)
    elseif valid_count >= 4 then
        -- 读取配置模式，默认1230（前3+末字）
        local jianci_mode = env.jianci_mode or "1230"
        local code1 = code_table:fetch(valid_chars[1]) or ""
        local code2 = code_table:fetch(valid_chars[2]) or ""
        local code3 = code_table:fetch(valid_chars[3]) or ""
        local code4 = ""

        if jianci_mode == "1234" then
            -- 1234模式：取前4个有效字的首码
            code4 = code_table:fetch(valid_chars[4]) or ""
        else
            -- 1230模式(默认)：取最后1个有效字的首码（原逻辑）
            local last_valid_char = valid_chars[valid_count]
            code4 = code_table:fetch(last_valid_char) or ""
        end
        -- 拼接4个首码，保持4位长度
        return string_sub(code1, 1, 1) .. string_sub(code2, 1, 1) .. string_sub(code3, 1, 1) .. string_sub(code4, 1, 1)
    else
        return ""
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

-- 加载用户词库文件（优化版，参考回退版本）
local function load_permanent_user_words()
    local base_dir = get_user_data_dir()
    local filename = base_dir .. (is_ios_device() and "rime_user_words.lua" or "custom_phrase/jianci.lua")

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
                if log and log.info then
                    log.info("[tiger_user_words] Converted old format to new format.")
                end
            else
                if log and log.error then
                    log.error("[tiger_user_words] Failed to update file to new format.")
                end
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
            if log and log.info then
                log.info("[tiger_user_words] Created initial user_words.lua")
            end
        else
            if log and log.error then
                log.error("[tiger_user_words] Failed to create user_words.lua: " .. (err or "unknown error"))
            end
        end
        return {}
    end
end

-- 保存用户词到文件（优化版，参考回退版本）
local function write_permanent_word_to_file(env, word, code, timestamp)
    local new_time = timestamp or os_time()
    env.permanent_user_words[word] = {code = code, time = new_time}

    local base_dir = get_user_data_dir()
    local filename = base_dir .. (is_ios_device() and "rime_user_words.lua" or "custom_phrase/jianci.lua")

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
        if log and log.info then
            log.info("[永久简词] 已更新词条: "..word.." (时间戳:"..new_time..")")
        end
    else
        if log and log.error then
            log.error("[永久简词] 文件写入失败: "..filename)
        end
    end

    env.permanent_seq_words_dict = reverse_seq_words(env.permanent_user_words)
end

local function clear_permanent_and_temporary_words(env)
    env.permanent_user_words = {}
    env.permanent_seq_words_dict = {}

    local base_dir = get_user_data_dir()
    local filename = base_dir .. (is_ios_device() and "rime_user_words.lua" or "custom_phrase/jianci.lua")

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

local function import_from_non_ios_path(env)
    if not is_ios_device() then
        if log and log.info then
            log.info("[自造简词] 非iOS设备无需导入")
        end
        return false
    end

    local non_ios_file = rime_api.get_user_data_dir().."/custom_phrase/jianci.lua"
    local ios_file = get_user_data_dir().."rime_user_words.lua"

    local non_ios_words = {}
    local non_ios_f = loadfile(non_ios_file)
    if non_ios_f then
        non_ios_words = non_ios_f() or {}
    else
        if log and log.warning then
            log.warning("[自造简词] 导入失败：无法加载非iOS词表")
        end
        return false
    end

    local ios_words = {}
    local ios_f = loadfile(ios_file)
    if ios_f then
        ios_words = ios_f() or {}
    else
        local fd = io_open(ios_file, "w")
        if fd then
            fd:write("local user_words = {\n}\nreturn user_words")
            fd:close()
            ios_words = {}
        else
            if log and log.warning then
                log.warning("[自造简词] 导入失败：无法创建iOS词表文件")
            end
            return false
        end
    end

    local before_count = 0
    for _ in pairs(ios_words) do before_count = before_count + 1 end

    local merged_count = 0
    for word, data in pairs(non_ios_words) do
        if not ios_words[word] then
            if type(data) == "string" then
                ios_words[word] = {code = data, time = 0}
            else
                ios_words[word] = data
            end
            merged_count = merged_count + 1
        end
    end

    local after_count = 0
    for _ in pairs(ios_words) do after_count = after_count + 1 end

    if after_count == before_count then
        if log and log.info then
            log.info("[自造简词] 增量合并完成：没有新词条需要导入")
        end
    elseif after_count < before_count + merged_count then
        if log and log.warning then
            log.warning(string_format("[自造简词] 合并异常：预期%d新增，实际%d新增",
                merged_count, after_count - before_count))
        end
        merged_count = after_count - before_count
    end

    local lines = table_new(#ios_words + 2, 0)
    lines[1] = "local user_words = {"
    local idx = 2
    for w, d in pairs(ios_words) do
        if type(d) == "string" then
            lines[idx] = string_format('    ["%s"] = "%s",', w, d)
        else
            lines[idx] = string_format('    ["%s"] = {code = "%s", time = %d},', w, d.code, d.time)
        end
        idx = idx + 1
    end
    lines[idx] = "}\nreturn user_words"
    local record = table_concat(lines, "\n")

    local fd = io_open(ios_file, "w")
    if not fd then
        if log and log.warning then
            log.warning("[自造简词] 导入失败：无法写入iOS文件")
        end
        return false
    end

    fd:write(record)
    fd:close()
    if log and log.info then
        log.info(string_format("[自造简词] 增量合并完成：新增%d词条，总词条%d",
            merged_count, after_count))
    end
    return true, merged_count, after_count
end

local function export_to_non_ios_path()
    if not is_ios_device() then
        if log and log.info then
            log.info("[自造简词] 非iOS设备无需导出")
        end
        return false
    end

    local ios_file = get_user_data_dir().."rime_user_words.lua"
    local non_ios_file = rime_api.get_user_data_dir().."/custom_phrase/jianci.lua"

    local f = io_open(ios_file, "r")
    if not f then
        if log and log.warning then
            log.warning("[自造简词] 导出失败：iOS词表文件不存在")
        end
        return false
    end

    local content = f:read("*a")
    f:close()

    local dir = rime_api.get_user_data_dir().."/lua/"
    if not os.rename(dir, dir) then
        os.execute("mkdir -p "..dir)
    end

    local fd = io_open(non_ios_file, "w")
    if not fd then
        if log and log.warning then
            log.warning("[自造简词] 导出失败：无法写入非iOS路径")
        end
        return false
    end

    fd:write(content)
    fd:close()
    if log and log.info then
        log.info("[自造简词] 已导出永久词表到非iOS路径")
    end
    return true
end

local function load_file_shortcuts(env)
    local data_dir = rime_api.get_user_data_dir()
    local file_path = data_dir .. "/custom_phrase/user.txt"

    env.file_user_words = table_new(0, 64)
    env.file_seq_words_dict = table_new(0, 32)

    local f, err = io_open(file_path, "r")
    if not f then
        if log and log.warning then
            log.warning("[文件简词] 文件不存在，创建空文件: " .. file_path)
        end
        local create_fd = io_open(file_path, "w")
        if create_fd then
            create_fd:close()
            if log and log.info then
                log.info("[文件简词] 成功创建空文件: " .. file_path)
            end
        else
            if log and log.error then
                log.error("[文件简词] 创建文件失败: " .. file_path .. " 错误: " .. (err or "未知"))
            end
            return false, "创建文件失败: " .. (err or "未知")
        end
        f, err = io_open(file_path, "r")
        if not f then
            if log and log.error then
                log.error("[文件简词] 无法打开创建的文件: " .. file_path .. " 错误: " .. (err or "未知"))
            end
            return false, "无法打开文件: " .. (err or "未知")
        end
    end

    local output_lines = table_new(128, 0)
    local processed_count = 0
    local generated_count = 0
    local skipped_count = 0

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
        if log and log.warning then
            log.warning("[文件简词] 无法写入文件: " .. file_path .. " 错误: " .. (err or "未知"))
        end
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
    return true, string_format("成功加载%d个文件简词", total)
end

local function clear_file_shortcuts(env)
    env.file_user_words = {}
    env.file_seq_words_dict = {}

    local file_path = rime_api.get_user_data_dir() .. "/custom_phrase/user.txt"
    local fd, err = io_open(file_path, "w")
    if fd then
        fd:close()
        if log and log.info then
            log.info("[文件简词清理] 文件已清空: " .. file_path)
        end
        return true, "※ 文件简词已清空（内存+文件）"
    else
        if log and log.error then
            log.error("[文件简词清理] 文件操作失败: " .. file_path .. " 错误: " .. (err or "未知"))
        end
        return false, "※ 清理失败：无法写入文件"
    end
end

-- ==============================================
-- 重构更新历史函数（使用文件存储）
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
            -- 使用文件保存
            write_permanent_word_to_file(env, commit_text, code)
        end

        if env.commit_dict[commit_text] then
            local old_code = env.commit_dict[commit_text]

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

-- ==============================================
-- 主模块
-- ==============================================
local M = {}

function M.init(env)
    local engine = env.engine
    local schema_config = engine.schema.config
    local context = engine.context

    -- 1. 确定模式
    local mode = get_mode(schema_config)

    -- 2. 初始化码表数据库（使用LevelDB）
    CodeTableDB.init(env, mode)

    -- 3. 读取简词取码模式配置
    env.jianci_mode = schema_config:get_string("enum/jianci") or "1230"

    -- 4. 加载用户词（使用文件存储）
    env.permanent_user_words = load_permanent_user_words()
    env.permanent_seq_words_dict = reverse_seq_words(env.permanent_user_words)

    -- 5. 加载文件简词
    local success, msg = load_file_shortcuts(env)
    if success then
        io.stderr:write("信息：文件简词初始化成功: " .. msg .. "\n")
    else
        io.stderr:write("警告：文件简词初始化失败: " .. msg .. "\n")
    end

    -- 6. 初始化内存数据结构
    env.commit_history = table_new(100, 0)
    env.commit_dict = table_new(0, 100)
    env.seq_words_dict = table_new(0, 100)

    -- 7. 创建更新历史函数
    env.update_history = make_update_history(env)

    -- 8. 连接提交通知器
    if context and context.commit_notifier then
        env.commit_conn = context.commit_notifier:connect(function(ctx)
            if not ctx or not ctx.get_commit_text then return end
            local commit_text = ctx:get_commit_text()
            if commit_text and commit_text ~= "" then
                env.update_history(commit_text)
            end
        end)
    end

    io.stderr:write("信息：造词系统初始化完成\n")
end

function M.fini(env)
    -- 1. 断开连接
    if env.commit_conn then
        env.commit_conn:disconnect()
        env.commit_conn = nil
    end

    env.update_history = nil

    -- 2. 关闭码表数据库
    close_all_dbs()
    CodeTableDB.fini()

    -- 3. 用户词库使用文件存储，无需特殊清理

    io.stderr:write("信息：造词系统清理完成\n")
end

-- ==============================================
-- 主处理函数（保持原有逻辑）
-- ==============================================
function M.func(input, env)
    local context = env.engine.context
    local input_code = context.input

    -- 特殊命令处理
    if input_code == "/jcql" then
        if clear_permanent_and_temporary_words(env) then
            yield(Candidate("clear_db", 0, #input_code, "※ 永久+临时简词已清空", ""))
        else
            yield(Candidate("clear_db", 0, #input_code, "※ 清空失败，请检查文件权限", ""))
        end
        return
    end

    if input_code == "/jcdr" then
        local success, merged_count, total_count = import_from_non_ios_path(env)
        if success then
            env.permanent_user_words = load_permanent_user_words()
            env.permanent_seq_words_dict = reverse_seq_words(env.permanent_user_words)
            if merged_count > 0 then
                yield(Candidate("import", 0, #input_code,
                    string_format("※ 导入完成：新增%d词条，总词条%d", merged_count, total_count), ""))
            else
                yield(Candidate("import", 0, #input_code,
                    string_format("※ 导入完成：无新词条，总词条%d", total_count), ""))
            end
        else
            yield(Candidate("import", 0, #input_code, "※ 导入失败，请检查文件路径", ""))
        end
        return
    end

    if input_code == "/jcdc" then
        if export_to_non_ios_path() then
            local total_count = 0
            for _ in pairs(env.permanent_user_words) do total_count = total_count + 1 end
            yield(Candidate("export", 0, #input_code,
                string_format("※ 已导出%d词条到非iOS路径", total_count), ""))
        else
            yield(Candidate("export", 0, #input_code, "※ 导出失败，请检查文件权限", ""))
        end
        return
    end

    if input_code == "/wjjc" then
        local success, msg = load_file_shortcuts(env)
        if success then
            yield(Candidate("file_shortcut", 0, #input_code, msg, ""))
        else
            yield(Candidate("file_shortcut", 0, #input_code, "※ 文件简词编码生成失败: " .. (msg or "未知错误"), ""))
        end
        return
    end

    if input_code == "/wjql" then
        local success, msg = clear_file_shortcuts(env)
        yield(Candidate("clear_file", 0, #input_code, msg, ""))
        return
    end

    if input_code == "/zyj" then
        local success, msg = load_file_shortcuts(env)
        if not success then
            yield(Candidate("file_to_permanent", 0, #input_code,
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
        local filename = base_dir .. (is_ios_device() and "rime_user_words.lua" or "custom_phrase/jianci.lua")

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
            yield(Candidate("file_to_permanent", 0, #input_code,
                string_format("※ 已添加%d个文件简词到永久简词", added_count), ""))
        else
            yield(Candidate("file_to_permanent", 0, #input_code,
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
            yield(Candidate("permanent_to_file", 0, #input_code,
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

        yield(Candidate("permanent_to_file", 0, #input_code,
            string_format("※ 已添加%d个永久简词到文件", added_count), ""))
        return
    end

    -- 重新加载永久用户词表，如果为nil
    if env.permanent_seq_words_dict == nil then
        env.permanent_user_words = load_permanent_user_words()
        env.permanent_seq_words_dict = reverse_seq_words(env.permanent_user_words)
    end

    local input_len = #input_code
    local combined_words = table_new(8, 0)
    local combined_count = 0
    local candidate_count = 0

    -- 获取自造简词
    if env.seq_words_dict[input_code] then
        local seq_list = env.seq_words_dict[input_code]
        -- 倒序遍历，保持原优先级
        for i = #seq_list, 1, -1 do
            combined_count = combined_count + 1
            combined_words[combined_count] = {text = seq_list[i], type = "history"}
        end
    end

    if env.permanent_seq_words_dict[input_code] then
        local permanent_list = {}
        for _, item in ipairs(env.permanent_seq_words_dict[input_code]) do
            table_insert(permanent_list, {
                text = item.word,
                time = item.time
            })
        end

        table.sort(permanent_list, function(a, b)
            return a.time > b.time
        end)

        for _, item in ipairs(permanent_list) do
            combined_count = combined_count + 1
            combined_words[combined_count] = {text = item.text, type = "permanent"}
        end
    end

    -- 获取文件简词
    if env.file_seq_words_dict[input_code] then
        for _, word in ipairs(env.file_seq_words_dict[input_code]) do
            combined_count = combined_count + 1
            combined_words[combined_count] = {text = word, type = "file"}
        end
    end

    -- 遍历原有候选词（A版的流式处理逻辑）
    for cand in input:iter() do
        candidate_count = candidate_count + 1

        if candidate_count == 1 then
            -- 第一个候选词直接输出
            yield(cand)

            -- 如果有自造简词，在第一个候选词后输出
            if combined_count > 0 then
                for i = 1, combined_count do
                    local word_info = combined_words[i]
                    local comment
                    if word_info.type == "permanent" then
                        comment = "⭐"
                    elseif word_info.type == "file" then
                        comment = "📁"
                    else
                        comment = "*"
                    end
                    yield(Candidate("user_table", 0, input_len, word_info.text, comment))
                end
            end
        else
            -- 其他候选词正常输出
            yield(cand)
        end
    end

    -- 如果没有原有候选词，只输出自造简词
    if candidate_count == 0 and combined_count > 0 then
        for i = 1, combined_count do
            local word_info = combined_words[i]
            local comment
            if word_info.type == "permanent" then
                comment = "⭐"
            elseif word_info.type == "file" then
                comment = "📁"
            else
                comment = "*"
            end
            yield(Candidate("user_table", 0, input_len, word_info.text, comment))
        end
    end
end

return M
