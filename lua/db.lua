--2026-02-11 07:29:50
local wanxiang = require('wanxiang')
local userdb = require("lib/userdb")

-- ==================== 日志记录函数 ====================
local function log_rebuild(module_name, reason, duration)
    local log_dir = rime_api.get_user_data_dir() .. "/lua/data"
    local log_file_path = log_dir .. "/db_rebuild.log"

    local log_file = io.open(log_file_path, "a")
    if log_file then
        local timestamp = os.date("%Y-%m-%d %H:%M:%S")
        local log_entry
        if duration then
            log_entry = string.format("[%s] 模块: %-15s 原因: %s 耗时: %.3f秒\n", timestamp, module_name, reason, duration)
        else
            log_entry = string.format("[%s] 模块: %-15s 原因: %s\n", timestamp, module_name, reason)
        end
        log_file:write(log_entry)
        log_file:close()
        print("重建日志: " .. log_entry:gsub("\n", ""))
    end
end

-- ==================== 中文词库模块 (tigress_ci_dict) ====================
local tigress_ci_dict = {
    status = "pending",
    tigress_path = wanxiang.get_filename_with_fallback("tiger_dicts/tigress/tigress_ci.dict.yaml"),
    wubici_path = wanxiang.get_filename_with_fallback("wubici.dict.yaml"),
    current_db_name = nil,
    current_dict_path = nil,
    INTERNAL_VERSION = "tigress_ci_v8" -- 替代 wanxiang.version
}

local ENTRY_SEP = string.char(1)
tigress_ci_dict.META_KEY = "db_version"

function tigress_ci_dict.process_batch(db, entries_batch)
    for _, item in ipairs(entries_batch) do
        local entry = item.text .. "\t" .. item.weight .. "\t" .. item.code
        if item.code_len >= 4 then
            local prefix = item.code:sub(1, 3)
            local exist_data = db:fetch(prefix) or ""
            local new_data = exist_data ~= "" and (exist_data .. ENTRY_SEP .. entry) or entry
            db:update(prefix, new_data)
        end
    end
end

function tigress_ci_dict.build_db(dict_name)
    if tigress_ci_dict.status ~= "pending" then return end

    if dict_name == "tigress" then
        tigress_ci_dict.current_dict_path = tigress_ci_dict.tigress_path
        tigress_ci_dict.current_db_name = "lua/tigress"
    elseif dict_name == "wubici" then
        tigress_ci_dict.current_dict_path = tigress_ci_dict.wubici_path
        tigress_ci_dict.current_db_name = "lua/wubici"
    else
        tigress_ci_dict.status = "done"
        return
    end

    local file = io.open(tigress_ci_dict.current_dict_path, "r")
    if not file then
        log_rebuild("tigress_ci_dict", "错误: 字典文件不存在 " .. tigress_ci_dict.current_dict_path)
        tigress_ci_dict.status = "done"
        return
    end
    file:close()

    local db
    local success, err = pcall(function()
        db = userdb.LevelDb(tigress_ci_dict.current_db_name)
        db:open()

        local db_ver = db:meta_fetch(tigress_ci_dict.META_KEY)
        local needs_rebuild = (db_ver ~= tigress_ci_dict.INTERNAL_VERSION)

        if needs_rebuild then
            local start_time = os.clock()
            db:empty()
            local file = io.open(tigress_ci_dict.current_dict_path, "r")
            local entries_batch = {}
            for line in file:lines() do
                if not line:match("^%s*#") and not line:match("^%s*$") then
                    local text, code, weight = line:match("^([^\t]+)\t([^\t]+)\t(%d+)")
                    if text and code and weight then
                        local code_lower = code:lower()
                        table.insert(entries_batch, {
                            text = text, weight = tonumber(weight),
                            code = code_lower, code_len = #code_lower
                        })
                        if #entries_batch >= 1000 then
                            tigress_ci_dict.process_batch(db, entries_batch)
                            entries_batch = {}
                        end
                    end
                end
            end
            if #entries_batch > 0 then tigress_ci_dict.process_batch(db, entries_batch) end
            file:close()
            db:meta_update(tigress_ci_dict.META_KEY, tigress_ci_dict.INTERNAL_VERSION)
            log_rebuild("tigress_ci_dict", "重建完成", os.clock() - start_time)
        end
        db:close()
    end)
    if not success then log_rebuild("tigress_ci_dict", "失败: " .. tostring(err)) end
    tigress_ci_dict.status = "done"
end

tigress_ci_dict.Query = { db = nil, status = "pending" }
function tigress_ci_dict.Query.init(db_name)
    if tigress_ci_dict.Query.status ~= "pending" then return end
    tigress_ci_dict.Query.db = userdb.LevelDb(db_name)
    tigress_ci_dict.Query.db:open_read_only()
    tigress_ci_dict.Query.status = "done"
end

function tigress_ci_dict.Query.get_candidates(prefix)
    if tigress_ci_dict.Query.status ~= "done" or not prefix or #prefix ~= 3 then return {} end
    local data_str = tigress_ci_dict.Query.db:fetch(prefix) or ""
    if data_str == "" then return {} end
    local cand_list = {}
    for entry in string.gmatch(data_str, "[^" .. ENTRY_SEP .. "]+") do
        local text, weight_str, code = entry:match("^([^\t]+)\t(%d+)\t([^\t]+)$")
        if text and weight_str and code then
            table.insert(cand_list, {
                text = text, weight = tonumber(weight_str),
                code = code, code_len = #code, remaining = code:sub(4)
            })
        end
    end
    return cand_list
end

function tigress_ci_dict.init(env)
    local dict_name = env.engine.schema.config:get_string("char_word/dictionary") or "tigress"
    tigress_ci_dict.build_db(dict_name)
    tigress_ci_dict.Query.init(tigress_ci_dict.current_db_name)
    env.engine_ctx = env.engine.context
    env.max_results = 50
end

function tigress_ci_dict.fini(env)
    if tigress_ci_dict.Query.db then tigress_ci_dict.Query.db:close() end
    tigress_ci_dict.Query.status = "pending"
    tigress_ci_dict.status = "pending"
end

function tigress_ci_dict.func(input, env)
    local ctx = env.engine_ctx
    if not ctx or not ctx:get_option("completion") then
        for cand in input:iter() do yield(cand) end
        return
    end
    for cand in input:iter() do yield(cand) end
    local input_code = ctx.input:gsub("%s+", ""):lower()
    if #input_code ~= 3 then return end
    local cand_list = tigress_ci_dict.Query.get_candidates(input_code)
    if #cand_list > 0 then
        table.sort(cand_list, function(a, b)
            if a.weight ~= b.weight then return a.weight > b.weight end
            return a.code_len < b.code_len
        end)
        for i, item in ipairs(cand_list) do
            yield(Candidate("tigress_ci", 0, #ctx.input, item.text, "~" .. item.remaining))
            if i >= env.max_results then break end
        end
    end
end

-- ==================== 英文词库模块 (en_dict) ====================
local function en_dict_func(env)
    local DBBuilder = {
        status = "pending",
        en_dict_path = wanxiang.get_filename_with_fallback("dicts/en.dict.yaml"),
        db_name = "lua/en_dict",
        INTERNAL_VERSION = "en_dict_v11_2"
    }

    local function process_entries_by_length(file_path, target_len, db, en_depth)
        local file = io.open(file_path, "r")
        if not file then return end
        local batch = {}
        for line in file:lines() do
            if not line:match("^%s*#") and not line:match("^%s*$") then
                local text, code = line:match("^([^\t]+)\t([^\t]*)")
                if text and code and #code == target_len then
                    local type_rank = text:match("^[a-z]+$") and 1 or (text:match("^[A-Za-z]+$") and 2 or 3)
                    table.insert(batch, {text = text, code = code:lower(), type_rank = type_rank})
                end
            end
        end
        file:close()

        if #batch > 0 then
            table.sort(batch, function(a, b) return a.text < b.text end)
            local prefix_groups = {}
            for _, entry in ipairs(batch) do
                local code_len = #entry.code
                local start_i = math.max(1, code_len - en_depth)
                for i = start_i, code_len do
                    local prefix = entry.code:sub(1, i)
                    prefix_groups[prefix] = prefix_groups[prefix] or {}
                    table.insert(prefix_groups[prefix], entry.text .. "\t" .. entry.code .. "\t" .. entry.type_rank)
                end
            end
            for prefix, entries in pairs(prefix_groups) do
                local combined = table.concat(entries, ENTRY_SEP)
                local existing = db:fetch(prefix) or ""
                db:update(prefix, existing ~= "" and (existing .. ENTRY_SEP .. combined) or combined)
            end
        end
    end

    local function build_en_db()
        if DBBuilder.status ~= "pending" then return end

        local en_enabled = env.engine.schema.config:get_bool("enum/en")
        if en_enabled == false then
            DBBuilder.status = "disabled"
            return
        end

        local db = userdb.LevelDb(DBBuilder.db_name)
        local success, err = pcall(function()
            db:open()
            local db_ver = db:meta_fetch("version")
            local needs_rebuild = (db_ver ~= DBBuilder.INTERNAL_VERSION)

            if needs_rebuild then
                local start_time = os.clock()
                db:empty()

                local max_len = 0
                local file = io.open(DBBuilder.en_dict_path, "r")
                if file then
                    for line in file:lines() do
                        local code = line:match("^[^\t]+\t([^\t]+)")
                        if code and #code > max_len then max_len = #code end
                    end
                    file:close()
                else
                    error("找不到英文词库文件: " .. DBBuilder.en_dict_path)
                end

                for l = 2, max_len do
                    process_entries_by_length(DBBuilder.en_dict_path, l, db, 4)
                end
                db:meta_update("version", DBBuilder.INTERNAL_VERSION)
                log_rebuild("en_dict", "重建完成", os.clock() - start_time)
            end
            db:close()
        end)

        if not success then
            log_rebuild("en_dict", "构建失败: " .. tostring(err))
            DBBuilder.status = "error"
        else
            DBBuilder.status = "done"
        end
    end

    local Query = { db = nil, status = "pending" }
    return {
        init = function()
            build_en_db()
            if DBBuilder.status == "done" then
                Query.db = userdb.LevelDb(DBBuilder.db_name)
                Query.db:open_read_only()
                Query.status = "done"
            end
            env.max_additional_chars = 4
        end,
        fini = function()
            if Query.db then Query.db:close() end
            Query.status = "pending"
        end,
        func = function(ctx, input_code)
            if Query.status ~= "done" or #input_code == 0 then return {} end
            local data = Query.db:fetch(input_code:lower()) or ""
            if data == "" then return {} end
            local limit_len = #input_code + (env.max_additional_chars or 4)
            local res = {}
            for entry in string.gmatch(data, "[^" .. ENTRY_SEP .. "]+") do
                local text, code, rank = entry:match("^([^\t]+)\t([^\t]+)\t(%d+)$")
                if text and #code <= limit_len then
                    table.insert(res, {text = text, code_len = #code, rank = tonumber(rank)})
                end
            end
            table.sort(res, function(a, b)
                if a.code_len ~= b.code_len then return a.code_len < b.code_len end
                if a.rank ~= b.rank then return a.rank < b.rank end
                return a.text < b.text
            end)
            local cands = {}
            for i, v in ipairs(res) do
                table.insert(cands, Candidate("english", 0, #ctx.input, v.text, ""))
                if i >= 50 then break end
            end
            return cands
        end
    }
end

-- ==================== 注音模块 (zhuyin) ====================
local function zhuyin_func(env)
    local DBBuilder = {
        preset_file_path = wanxiang.get_filename_with_fallback("dicts/jichu.pro.dict.yaml"),
        user_override_path = rime_api.get_user_data_dir() .. "/custom_phrase/py.txt",
        status = "pending",
        version = "zhuyin_v2"
    }

    local function process_comment_raw(raw)
        if not raw then return "" end
        local p = raw:gsub(";[^' ]*[' ]", " ")
        local last = p:find(";[^;]*$")
        if last then p = p:sub(1, last - 1) end
        return p:gsub("%s+", " "):gsub("^%s*(.-)%s*$", "%1")
    end

    local function init_db_from_file(path, db, zhuyin_enum)
        local file = io.open(path, "r")
        if not file then return end
        for line in file:lines() do
            local key, raw_val = line:match("^([^\t]+)\t([^\t]*)")
            if key and raw_val then
                local c_len = utf8.len(key)
                if c_len > 1 and c_len <= zhuyin_enum then
                    db:update(key, process_comment_raw(raw_val))
                end
            end
        end
        file:close()
    end

    local function build_zhuyin_db()
        if DBBuilder.status ~= "pending" then return end

        local zhuyin_enum = tonumber(env.engine.schema.config:get_string("enum/zhuyin")) or 4
        if zhuyin_enum <= 1 then
            DBBuilder.status = "done"
            return
        end

        local db = userdb.LevelDb("lua/zhuyin")
        db:open()
        local db_ver = db:meta_fetch("version")
        local target_ver = DBBuilder.version .. "_e" .. zhuyin_enum

        if db_ver ~= target_ver then
            local start_time = os.clock()
            db:empty()
            init_db_from_file(DBBuilder.preset_file_path, db, zhuyin_enum)
            init_db_from_file(DBBuilder.user_override_path, db, zhuyin_enum)
            db:meta_update("version", target_ver)
            log_rebuild("zhuyin", "重建完成", os.clock() - start_time)
        end
        db:close()
        DBBuilder.status = "done"
    end

    local Query = { db = nil, status = "pending", dict = nil, enum = 4 }

    return {
        init = function()
            Query.enum = tonumber(env.engine.schema.config:get_string("enum/zhuyin")) or 4
            build_zhuyin_db()
            if Query.enum > 1 then
                Query.db = userdb.LevelDb("lua/zhuyin")
                Query.db:open_read_only()
            end
            Query.dict = ReverseLookup("wanxiang_pro")
            Query.status = "done"
        end,
        fini = function()
            if Query.db then Query.db:close() end
            Query.status = "pending"
        end,
        func = function(ctx, cand)
            if not ctx:get_option("pinyin") then return cand end

            local text = cand:get_genuine().text
            local c_len = utf8.len(text)
            local comment = nil

            if c_len == 1 then
                local raw = Query.dict:lookup(text)
                if raw then comment = raw:gsub(";[^%s]*", "") end
            elseif Query.enum > 1 and c_len <= Query.enum and Query.db then
                comment = Query.db:fetch(text)
            end

            if comment and comment ~= "" then
                cand:get_genuine().comment = comment
            end
            return cand
        end
    }
end

-- ==================== 主模块 (merged_dict) ====================
local merged_dict = {}

function merged_dict.init(env)
    env.zhuyin = zhuyin_func(env)
    env.zhuyin.init()

    env.tigress_ci = tigress_ci_dict
    env.tigress_ci.init(env)

    env.en_dict = en_dict_func(env)
    env.en_dict.init()

    env.engine_ctx = env.engine.context
end

function merged_dict.fini(env)
    if env.tigress_ci then env.tigress_ci.fini(env) end
    if env.en_dict then env.en_dict.fini() end
    if env.zhuyin then env.zhuyin.fini() end
    collectgarbage()
end

function merged_dict.func(input, env)
    local ctx = env.engine_ctx
    if not ctx then
        for cand in input:iter() do yield(cand) end
        return
    end

    local enable_pinyin = ctx:get_option("pinyin")
    for cand in input:iter() do
        if enable_pinyin then
            yield(env.zhuyin.func(ctx, cand))
        else
            yield(cand)
        end
    end

    if ctx:get_option("completion") and #ctx.input == 3 then
        env.tigress_ci.func(input, env)
    end

    if ctx:get_option("english_word") and #ctx.input > 0 then
        local en_cands = env.en_dict.func(ctx, ctx.input:gsub("%s+", ""))
        for _, c in ipairs(en_cands) do yield(c) end
    end
end

return merged_dict
