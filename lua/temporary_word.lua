-- # 自造简词系统 2026-04-27 15:03:05

-- 基础依赖
local function safe_require(name)
    local status, lib = pcall(require, name)
    if status then return lib end
    return nil
end

local userdb = safe_require("wanxiang/userdb")

local rime_api, os_time, io_open = rime_api, os.time, io.open
local table_insert, table_concat, string_format, string_sub, string_find, string_match = 
      table.insert, table.concat, string.format, string.sub, string.find, string.match
local utf8_len, utf8_offset = utf8.len, utf8.offset

-- ==============================================
-- 工具函数库
-- ==============================================
local Utils = {}

function Utils.get_path(is_ios, is_user_txt)
    local base = is_ios and os.getenv("HOME").."/Documents/" or rime_api.get_user_data_dir().."/"
    if is_user_txt then 
        return rime_api.get_user_data_dir().."/custom_phrase/user.txt" 
    end
    return base .. (is_ios and "rime_user_words.lua" or "custom_phrase/jianci.lua")
end

function Utils.save_lua_table(path, data)
    local lines = {"local user_words = {"}
    for k, v in pairs(data) do
        local safe_k = k:gsub('\\', '\\\\'):gsub('"', '\\"')
        table_insert(lines, string_format('    ["%s"] = {code = "%s", time = %d},', safe_k, v.code, v.time or 0))
    end
    table_insert(lines, "}\nreturn user_words")
    local fd = io_open(path, "w+")
    if fd then fd:write(table_concat(lines, "\n")) fd:close() return true end
    return false
end

function Utils.utf8_sub(str, s, e)
    local len = utf8_len(str)
    if not len or len <= 0 or s > e then return "" end
    local start_byte = utf8_offset(str, s)
    local end_byte = utf8_offset(str, (e > len and len or e) + 1) or (#str + 1)
    return string_sub(str, start_byte, end_byte - 1)
end

function Utils.trim_invalid_chars(env, text)
    local code_table = env.code_table
    if not code_table or not text then return text end
    local len = utf8_len(text)
    if not len or len <= 0 then return "" end

    local first = 1
    for i = 1, len do
        local c = Utils.utf8_sub(text, i, i)
        if code_table:fetch(c) then first = i break end
    end

    local last = len
    for i = len, 1, -1 do
        local c = Utils.utf8_sub(text, i, i)
        if code_table:fetch(c) then last = i break end
    end

    return first > last and "" or Utils.utf8_sub(text, first, last)
end

-- ==============================================
-- 码表与数据库构建逻辑
-- ==============================================
local CodeTableDB = { dbs = {} }
local META_VERSION_KEY = "code_table_version"
local CURRENT_VERSION = "1.0"

function CodeTableDB.init(env, mode)
    local db_name = mode == "tiger" and "lua/tiger_code" or "lua/wubi_code"
    local source_file = mode == "tiger" and "tiger_code_table.lua" or "wubi_code_table.lua"
    
    local success, db = pcall(function() return userdb.LevelDb(db_name) end)
    if not success or not db then return end
    
    db:open_read_only()
    local db_ver = db:meta_fetch(META_VERSION_KEY)
    
    if db_ver ~= CURRENT_VERSION then
        db:close()
        db:open()
        local paths = {
            rime_api.get_user_data_dir() .. "/lua/" .. source_file,
            rime_api.get_shared_data_dir() .. "/lua/" .. source_file
        }
        local code_data = nil
        for _, p in ipairs(paths) do
            local f = loadfile(p)
            if f then 
                local s, res = pcall(f)
                if s then code_data = res break end
            end
        end
        if code_data then
            db:empty()
            for char, code in pairs(code_data) do db:update(char, code) end
            db:meta_update(META_VERSION_KEY, CURRENT_VERSION)
        end
        db:close()
        db:open_read_only()
    end
    CodeTableDB.dbs[db_name] = db
    env.code_table = { fetch = function(_, char) return db:fetch(char) end }
end

local function get_tiger_code(env, word)
    local ct = env.code_table
    if not ct then return "" end
    local len = utf8_len(word)
    if not len then return "" end
    local valid = {}
    for i = 1, len do
        local char = Utils.utf8_sub(word, i, i)
        local code = ct:fetch(char)
        if code and code ~= "" then table_insert(valid, {c = char, raw = code}) end
    end
    local v_cnt = #valid
    if v_cnt == 2 then 
        return string_sub(valid[1].raw, 1, 2) .. string_sub(valid[2].raw, 1, 2)
    elseif v_cnt == 3 then 
        return string_sub(valid[1].raw, 1, 1) .. string_sub(valid[2].raw, 1, 1) .. string_sub(valid[3].raw, 1, 2)
    elseif v_cnt >= 4 then
        local c1 = string_sub(valid[1].raw, 1, 1)
        local c2 = string_sub(valid[2].raw, 1, 1)
        local c3 = string_sub(valid[3].raw, 1, 1)
        local c4_idx = (env.jianci_mode == "1234") and 4 or v_cnt
        local c4 = string_sub(valid[c4_idx].raw, 1, 1)
        return c1 .. c2 .. c3 .. c4
    end
    return ""
end

-- ==============================================
-- 主模块逻辑
-- ==============================================
local M = {}

function M.build_reverse_index(env)
    env.reverse_index = {}
    for w, data in pairs(env.permanent_user_words) do
        local c = data.code
        if not env.reverse_index[c] then env.reverse_index[c] = {} end
        table_insert(env.reverse_index[c], {w = w, time = data.time or 0})
    end
    for _, list in pairs(env.reverse_index) do
        table.sort(list, function(a, b) return a.time > b.time end)
    end
end

function M.init(env)
    local config = env.engine.schema.config
    local mode = config:get_string("char_word/dictionary") == "wubici" and "wubi" or "tiger"
    CodeTableDB.init(env, mode)
    env.is_ios = os.getenv("HOME") and os.getenv("HOME"):find("/var/mobile/") ~= nil
    env.jianci_mode = config:get_string("enum/jianci") or "1230"
    
    local path = Utils.get_path(env.is_ios)
    local f = loadfile(path)
    env.permanent_user_words = f and f() or {}
    
    M.build_reverse_index(env)
    M.process_user_txt(env, false, false) 
    
    env.commit_history, env.commit_dict = {}, {}
    env.commit_conn = env.engine.context.commit_notifier:connect(function(ctx)
        M.update_history(env, ctx:get_commit_text())
    end)
end

function M.process_user_txt(env, load_into_mem, allow_create)
    local path = Utils.get_path(env.is_ios, true)
    local file_lines, need_write = {}, false
    if load_into_mem then 
        env.file_user_words = {}
        env.file_reverse_index = {}
    end

    local f = io_open(path, "r")
    if not f then 
        if allow_create then
            local new_f = io_open(path, "w")
            if new_f then 
                new_f:write("") 
                new_f:close() 
            end
        end
        return 0, 0
    end

    local lines = {}
    for line in f:lines() do
        table_insert(lines, line)
    end
    f:close()

    local processed_count = 0
    local skipped_count = 0

    for i, line in ipairs(lines) do
        -- 跳过空行、纯空格行和注释行
        if line == "" or string_match(line, "^%s*$") or string_match(line, "^#") then
            skipped_count = skipped_count + 1
            goto continue
        end

        -- 极简解析规则 (支持格式: word, word\tcode, word\tcode\tweight, word\tweight)
        local word, rest = string_match(line, "^([^\t]+)\t?(.*)$")
        if not word then
            skipped_count = skipped_count + 1
            goto continue
        end

        local code = string_match(rest, "^%a+")

        if code then
            -- 存在有效编码，直接加载，不修改原行
            if load_into_mem then env.file_user_words[word] = code end
            processed_count = processed_count + 1
        else
            -- 缺失编码或编码不合法(例如只有权重)，自动生成并补全
            code = get_tiger_code(env, word)
            if code and code ~= "" then
                if load_into_mem then env.file_user_words[word] = code end
                lines[i] = rest == "" and (word .. "\t" .. code) or (word .. "\t" .. code .. "\t" .. rest)
                processed_count = processed_count + 1
                need_write = true
            else
                skipped_count = skipped_count + 1
            end
        end

        ::continue::
    end

    if need_write then
        local fd = io_open(path, "w")
        if fd then 
            for _, line in ipairs(lines) do
                fd:write(line .. "\n")
            end
            fd:close()
        end
    end

    if load_into_mem and env.file_user_words then
        env.file_reverse_index = {}
        for w, c in pairs(env.file_user_words) do
            if not env.file_reverse_index[c] then
                env.file_reverse_index[c] = {}
            end
            table_insert(env.file_reverse_index[c], w)
        end
        
        for _, list in pairs(env.file_reverse_index) do
            table.sort(list, function(a, b) 
                return utf8_len(a) < utf8_len(b)
            end)
        end
    end
    
    return processed_count, skipped_count
end

function M.update_history(env, text)
    text = Utils.trim_invalid_chars(env, text)
    if not text or text == "" then return end

    local code = get_tiger_code(env, text)
    if code == "" then return end

    local input_len = #env.engine.context.input

    if input_len == 4 then
        if env.commit_dict[text] or env.permanent_user_words[text] then
            env.permanent_user_words[text] = { code = code, time = os_time() }
            M.build_reverse_index(env)
            Utils.save_lua_table(Utils.get_path(env.is_ios), env.permanent_user_words)
        end
        return 
    end

    if env.commit_dict[text] then
        for i, v in ipairs(env.commit_history) do
            if v == text then table.remove(env.commit_history, i) break end
        end
    end
    table_insert(env.commit_history, text)
    env.commit_dict[text] = code

    if #env.commit_history > 100 then
        local old = table.remove(env.commit_history, 1)
        env.commit_dict[old] = nil
    end
end

function M.func(input, env)
    local ic = env.engine.context.input
    if ic == "" then return end

    if ic:sub(1,1) == "/" then
        local cmd_map = {
            ["/jcql"] = function() 
                env.permanent_user_words, env.commit_dict, env.commit_history = {}, {}, {}
                env.reverse_index = {}
                env.file_user_words = {}
                env.file_reverse_index = {}
                Utils.save_lua_table(Utils.get_path(env.is_ios), {})
                return "※ 简词已清空" 
            end,
            ["/wjjc"] = function() 
                local processed, skipped = M.process_user_txt(env, true, true)
                return string_format("※ 文件简词已加载 (处理:%d 跳过:%d)", processed or 0, skipped or 0)
            end,
            ["/zyj"] = function()
                M.process_user_txt(env, true, true)
                if not env.file_user_words or next(env.file_user_words) == nil then 
                    return "※ user.txt 为空" 
                end
                local count, t = 0, os_time()
                for w, c in pairs(env.file_user_words) do
                    if not env.permanent_user_words[w] then
                        env.permanent_user_words[w] = {code = c, time = t}
                        count = count + 1
                    end
                end
                M.build_reverse_index(env)
                Utils.save_lua_table(Utils.get_path(env.is_ios), env.permanent_user_words)
                return string_format("※ 已转 %d 条至永久库", count)
            end,
            ["/zwj"] = function()
                local path = Utils.get_path(env.is_ios, true)
                local fw = io_open(path, "a+") 
                if not fw then return "※ 无法操作文件" end
                for w, d in pairs(env.permanent_user_words) do
                    fw:write(string_format("%s\t%s\n", w, d.code))
                end
                fw:close()
                return "※ 已导出至文件"
            end
        }
        if cmd_map[ic] then yield(Candidate("cmd", 0, #ic, cmd_map[ic](), "")) return end
    end

    local combined, seen = {}, {}
    for i = #env.commit_history, 1, -1 do
        local w = env.commit_history[i]
        if env.commit_dict[w] == ic then
            table_insert(combined, {t = w, m = "*"})
            seen[w] = true
        end
    end

    if env.reverse_index and env.reverse_index[ic] then
        for _, item in ipairs(env.reverse_index[ic]) do
            if not seen[item.w] then
                table_insert(combined, {t = item.w, m = "⭐"})
                seen[item.w] = true
            end
        end
    end

    if env.file_reverse_index and env.file_reverse_index[ic] then
        for _, word in ipairs(env.file_reverse_index[ic]) do
            if not seen[word] then
                table_insert(combined, {t = word, m = "📁"})
                seen[word] = true
            end
        end
    end

    local count = 0
    for cand in input:iter() do
        count = count + 1
        yield(cand)
        if count == 1 then
            for _, v in ipairs(combined) do yield(Candidate("user", 0, #ic, v.t, v.m)) end
        end
    end
    if count == 0 then
        for _, v in ipairs(combined) do yield(Candidate("user", 0, #ic, v.t, v.m)) end
    end
end

function M.fini(env)
    if env.commit_conn then env.commit_conn:disconnect() end
    for _, db in pairs(CodeTableDB.dbs) do if db then db:close() end end
end

return M
