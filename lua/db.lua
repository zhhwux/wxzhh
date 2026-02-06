local wanxiang = require('wanxiang')
local userdb = require("lib/userdb")

-- ==================== 可复用函数 ====================
-- 确保目录存在（复用自三个脚本）
local function ensure_dir_exist(dir)
    local sep = package.config:sub(1, 1)
    dir = dir:gsub([["]], [[\"]])
    if sep == "/" then
        os.execute('mkdir -p "' .. dir .. '" 2>/dev/null')
    else
        os.execute('if not exist "' .. dir .. '" mkdir "' .. dir .. '"')
    end
end

-- ==================== 日志记录函数 ====================
local function log_rebuild(module_name, reason, duration)
    -- 直接尝试写入日志文件，不先创建目录
    local log_file_path = rime_api.get_user_data_dir() .. "/lua/data/db_rebuild.log"
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
        -- 同时打印到控制台便于调试
        print("重建日志: " .. log_entry:gsub("\n", ""))
    end
end

-- ==================== 中文词库模块 (tigress_ci_dict) ====================
-- 保持原始版本逻辑，不使用闭包
local tigress_ci_dict = {
    status = "pending",
    tigress_path = wanxiang.get_filename_with_fallback("tiger_dicts/tigress/tigress_ci.dict.yaml"),
    wubici_path = wanxiang.get_filename_with_fallback("wubici.dict.yaml"),
    current_db_name = nil,
    current_dict_path = nil
}

local ENTRY_SEP = string.char(1)

tigress_ci_dict.META_KEY = {
    version = "tigress_ci_v8"
}

function tigress_ci_dict.ensure_dir_exist(dir)
    local sep = package.config:sub(1, 1)
    dir = dir:gsub([["]], [[\"]])
    if sep == "/" then
        os.execute('mkdir -p "' .. dir .. '" 2>/dev/null')
    else
        os.execute('if not exist "' .. dir .. '" mkdir "' .. dir .. '"')
    end
end

function tigress_ci_dict.init_db_from_file(path, db)
    local file = io.open(path, "r")
    if not file then return end

    local entries = {}
    for line in file:lines() do
        if not line:match("^%s*#") and not line:match("^%s*$") then
            local text, code, weight = line:match("^([^\t]+)\t([^\t]+)\t(%d+)")
            if text and code and weight and text ~= "" and code ~= "" then
                local code_lower = code:lower()
                table.insert(entries, {
                    text = text,
                    weight = tonumber(weight),
                    code = code_lower,
                    code_len = #code_lower
                })
            end
        end
    end
    file:close()

    for _, item in ipairs(entries) do
        local entry = item.text .. "\t" .. item.weight .. "\t" .. item.code
        if item.code_len >= 4 then
            local prefix = item.code:sub(1, 3)
            local exist_data = db:fetch(prefix) or ""
            local new_data = exist_data ~= "" and (exist_data .. ENTRY_SEP .. entry) or entry
            db:update(prefix, new_data)
        end
    end
end

-- 新增的批处理函数，用于分批处理数据避免内存问题
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
    if tigress_ci_dict.status ~= "pending" then
        log_rebuild("tigress_ci_dict", "状态不是pending，跳过重建，当前状态: " .. tostring(tigress_ci_dict.status))
        return
    end

    local dist = rime_api.get_distribution_code_name() or ""
    if dist ~= "hamster" and dist ~= "hamster3" and dist ~= "Weasel" then
        local user_lua_dir = rime_api.get_user_data_dir() .. "/lua"
        tigress_ci_dict.ensure_dir_exist(user_lua_dir .. "/data")
    end

    if dict_name == "tigress" then
        tigress_ci_dict.current_dict_path = tigress_ci_dict.tigress_path
        tigress_ci_dict.current_db_name = "lua/tigress"
    elseif dict_name == "wubici" then
        tigress_ci_dict.current_dict_path = tigress_ci_dict.wubici_path
        tigress_ci_dict.current_db_name = "lua/wubici"
    else
        log_rebuild("tigress_ci_dict", "未知词典名称: " .. tostring(dict_name))
        tigress_ci_dict.status = "done"  -- 标记为完成，避免无限重试
        return
    end

    -- 检查词典文件是否存在
    local file = io.open(tigress_ci_dict.current_dict_path, "r")
    if not file then
        log_rebuild("tigress_ci_dict", "词典文件不存在: " .. tostring(tigress_ci_dict.current_dict_path))
        tigress_ci_dict.status = "done"  -- 标记为完成，避免无限重试
        return
    end
    file:close()

    local db
    local success, err = pcall(function()
        db = userdb.LevelDb(tigress_ci_dict.current_db_name)
        db:open()

        -- ========== 回退到原版版本号检查逻辑 ==========
        local needs_rebuild = false
        local reason = "版本号一致"
        local db_ver = db:meta_fetch(tigress_ci_dict.META_KEY.version)
        if db_ver ~= wanxiang.version then
            needs_rebuild = true
            reason = "版本号不一致或不存在"
        end
        -- =========================================================

        if needs_rebuild then
            local start_time = os.clock()
            local start_memory = collectgarbage("count")
            log_rebuild("tigress_ci_dict", reason)

            -- 分批处理，避免内存爆炸
            local batch_size = 1000
            local batch_count = 0
            local total_entries = 0

            -- 先清空数据库
            db:empty()

            -- 重新读取文件并分批处理
            local file = io.open(tigress_ci_dict.current_dict_path, "r")
            if not file then
                error("无法重新打开词典文件")
            end

            local entries_batch = {}

            for line in file:lines() do
                if not line:match("^%s*#") and not line:match("^%s*$") then
                    local text, code, weight = line:match("^([^\t]+)\t([^\t]+)\t(%d+)")
                    if text and code and weight and text ~= "" and code ~= "" then
                        local code_lower = code:lower()
                        table.insert(entries_batch, {
                            text = text,
                            weight = tonumber(weight),
                            code = code_lower,
                            code_len = #code_lower
                        })
                        total_entries = total_entries + 1

                        -- 每处理一定数量的条目就写入一次
                        if #entries_batch >= batch_size then
                            tigress_ci_dict.process_batch(db, entries_batch)
                            entries_batch = {}
                            batch_count = batch_count + 1

                            -- 每批处理后记录进度
                            if batch_count % 10 == 0 then
                                log_rebuild("tigress_ci_dict", string.format("处理进度: %d批，共%d条", batch_count, total_entries))
                            end
                        end
                    end
                end
            end

            -- 处理剩余条目
            if #entries_batch > 0 then
                tigress_ci_dict.process_batch(db, entries_batch)
            end

            file:close()

            -- 更新版本号
            db:meta_update(tigress_ci_dict.META_KEY.version, wanxiang.version)

            local end_time = os.clock()
            local end_memory = collectgarbage("count")
            local duration = end_time - start_time
            local memory_change = end_memory - start_memory
            log_rebuild("tigress_ci_dict", string.format("重建完成，处理了%d条，耗时: %.3f秒，内存变化: %.2f KB", total_entries, duration, memory_change))
        else
            log_rebuild("tigress_ci_dict", "使用现有数据库")
        end

        db:close()
    end)

    if not success then
        log_rebuild("tigress_ci_dict", "重建失败: " .. tostring(err))
        if db then
            pcall(db.close, db)  -- 尝试关闭数据库
        end
        tigress_ci_dict.status = "pending"  -- 保持pending状态，下次重试
        return
    end

    tigress_ci_dict.status = "done"
end

tigress_ci_dict.Query = {
    db = nil,
    status = "pending",
    current_db_name = nil
}

function tigress_ci_dict.Query.init(db_name)
    if tigress_ci_dict.Query.status ~= "pending" then return end
    tigress_ci_dict.Query.db = userdb.LevelDb(db_name)
    tigress_ci_dict.Query.db:open_read_only()
    tigress_ci_dict.Query.current_db_name = db_name
    tigress_ci_dict.Query.status = "done"
end

function tigress_ci_dict.Query.get_candidates(prefix)
    if tigress_ci_dict.Query.status ~= "done" or not prefix or #prefix ~= 3 then
        return {}
    end

    local data_str = tigress_ci_dict.Query.db:fetch(prefix) or ""
    if data_str == "" then return {} end

    local cand_list = {}
    for entry in string.gmatch(data_str, "[^" .. ENTRY_SEP .. "]+") do
        local split1 = entry:find("\t")
        if not split1 then break end

        local split2 = entry:find("\t", split1 + 1)
        if not split2 then break end

        local code_len = #entry - split2

        if code_len >= 4 then
            local text, weight_str, code = entry:match("^([^\t]+)\t(%d+)\t([^\t]+)$")
            if text and weight_str and code then
                local remaining = code:sub(4)
                table.insert(cand_list, {
                    text = text,
                    weight = tonumber(weight_str),
                    code = code,
                    code_len = code_len,
                    remaining = remaining
                })
            end
        end
    end
    return cand_list
end

function tigress_ci_dict.init(env)
    local dict_name = env.engine.schema.config:get_string("char_word/dictionary") or "tigress"

    local success, err = pcall(function()
        tigress_ci_dict.build_db(dict_name)
        tigress_ci_dict.Query.init(tigress_ci_dict.current_db_name)
        env.engine_ctx = env.engine.context
        env.max_results = 50
        env.current_dict = dict_name
    end)

    if not success then
        log_rebuild("tigress_ci_dict", "初始化失败: " .. tostring(err))
        -- 设置为pending，避免在后续func调用中崩溃
        tigress_ci_dict.status = "pending"
    end
end

function tigress_ci_dict.fini(env)
    if tigress_ci_dict.Query.db and tigress_ci_dict.Query.status == "done" then
        tigress_ci_dict.Query.db:close()
    end
    tigress_ci_dict.Query.status = "pending"
    tigress_ci_dict.status = "pending"
    tigress_ci_dict.current_db_name = nil
    tigress_ci_dict.current_dict_path = nil
    env.engine_ctx = nil
    collectgarbage()
end

function tigress_ci_dict.func(input, env)
    local ctx = env.engine_ctx
    if not ctx then
        for cand in input:iter() do
            yield(cand)
        end
        return
    end

    local enable_completion = ctx:get_option("completion")
    if not enable_completion then
        for cand in input:iter() do
            yield(cand)
        end
        return
    end

    for cand in input:iter() do
        yield(cand)
    end

    local input_code = ctx.input:gsub("^%s+", ""):gsub("%s+$", "")
    if #input_code ~= 3 then
        return
    end

    input_code = input_code:lower()
    local cand_list = tigress_ci_dict.Query.get_candidates(input_code)

    if #cand_list > 0 then
        table.sort(cand_list, function(a, b)
            if a.weight ~= b.weight then
                return a.weight > b.weight
            end
            if a.code_len ~= b.code_len then
                return a.code_len < b.code_len
            end
            return a.text < b.text
        end)

        local count = 0
        for _, item in ipairs(cand_list) do
            local cand = Candidate("tigress_ci", 0, #ctx.input, item.text, "~" .. item.remaining)
            yield(cand)
            count = count + 1
            if env.max_results and count >= env.max_results then
                break
            end
        end
    end
end

-- ==================== 英文词库模块 (en_dict) - 修复版 ====================
local function en_dict_func(env)
    local DBBuilder = {
        status = "pending",
        en_dict_path = wanxiang.get_filename_with_fallback("dicts/en.dict.yaml"),
        db_name = "lua/en_dict"
    }

    local ENTRY_SEP = string.char(1)

    DBBuilder.META_KEY = {
        version = "en_dict_v8"
    }

    -- ==================== 定义处理函数（先定义，后使用） ====================
    local function process_entries_by_length(file_path, target_len, db)
        local file = io.open(file_path, "r")
        if not file then
            error("无法打开文件: " .. tostring(file_path))
        end

        local batch = {}  -- 该长度的所有词
        local processed_count = 0

        -- 读取该长度的所有词
        for line in file:lines() do
            if not line:match("^%s*#") and not line:match("^%s*$") then
                local cand_text, code = line:match("^([^\t]+)\t([^\t]*)")
                if cand_text and code and cand_text ~= "" and code ~= "" then
                    local code_lower = code:lower()
                    if #code_lower == target_len then
                        -- 计算词类型排名
                        local type_rank
                        if cand_text:match("^[a-z]+$") then
                            type_rank = 1
                        elseif cand_text:match("^[A-Za-z]+$") then
                            type_rank = 2
                        elseif cand_text:match("^[A-Za-z ]+$") then
                            type_rank = 3
                        else
                            type_rank = 4
                        end

                        table.insert(batch, {
                            text = cand_text,
                            code = code_lower,
                            type_rank = type_rank
                        })

                        processed_count = processed_count + 1

                        -- 每处理1000个词记录一次进度
                        if processed_count % 1000 == 0 then
                            log_rebuild("en_dict", string.format("长度%d处理进度: %d个", target_len, processed_count))
                        end
                    end
                end
            end
        end

        file:close()

        -- ==================== 在内存中对当前批次排序 ====================
        if #batch > 0 then
            -- 按文本排序（同一长度内）
            table.sort(batch, function(a, b)
                if a.type_rank ~= b.type_rank then
                    return a.type_rank < b.type_rank
                end
                return a.text < b.text
            end)

            -- ==================== 按前缀分组并写入数据库 ====================
            local prefix_groups = {}

            -- 为每个词生成前缀并分组
            for _, entry in ipairs(batch) do
                for i = 1, #entry.code do
                    local prefix = entry.code:sub(1, i)
                    if not prefix_groups[prefix] then
                        prefix_groups[prefix] = {}
                    end
                    table.insert(prefix_groups[prefix], {
                        text = entry.text,
                        code = entry.code,
                        type_rank = entry.type_rank
                    })
                end
            end

            -- 修复：计算前缀数量（使用pairs而不是#）
            local prefix_count = 0
            for _ in pairs(prefix_groups) do
                prefix_count = prefix_count + 1
            end

            -- 写入数据库（每个前缀一次性写入）
            for prefix, entries in pairs(prefix_groups) do
                local values = {}
                for _, entry in ipairs(entries) do
                    local value = entry.text .. "\t" .. entry.code .. "\t" .. entry.type_rank
                    table.insert(values, value)
                end
                local combined_value = table.concat(values, ENTRY_SEP)

                -- 读取已有数据并合并
                local existing = db:fetch(prefix) or ""
                if existing ~= "" then
                    combined_value = existing .. ENTRY_SEP .. combined_value
                end

                db:update(prefix, combined_value)
            end

            log_rebuild("en_dict", string.format("长度%d处理完成，共%d个词，%d个前缀", target_len, #batch, prefix_count))
        else
            log_rebuild("en_dict", string.format("长度%d没有词", target_len))
        end
    end

    -- ==================== 分批处理函数 ====================
    local function batch_preprocess(file_path)
        -- 第一阶段：统计文件中不同编码长度的词的数量分布
        local file = io.open(file_path, "r")
        if not file then
            return nil, "无法打开文件: " .. tostring(file_path)
        end

        -- 统计每个编码长度的词的数量
        local length_counts = {}
        local max_code_len = 0
        local total_entries = 0
        local line_count = 0

        for line in file:lines() do
            line_count = line_count + 1
            if not line:match("^%s*#") and not line:match("^%s*$") then
                local cand_text, code = line:match("^([^\t]+)\t([^\t]*)")
                if cand_text and code and cand_text ~= "" and code ~= "" then
                    local code_len = #code:lower()
                    length_counts[code_len] = (length_counts[code_len] or 0) + 1
                    if code_len > max_code_len then
                        max_code_len = code_len
                    end
                    total_entries = total_entries + 1
                end
            end

            -- 每处理10000行记录一次进度
            if line_count % 10000 == 0 then
                log_rebuild("en_dict", string.format("统计进度: %d行", line_count))
            end
        end

        file:close()

        log_rebuild("en_dict", string.format("统计完成: %d个词，最大编码长度: %d", total_entries, max_code_len))

        -- ==================== 从编码长度2开始处理 ====================
        -- 打开数据库，准备写入
        local db = userdb.LevelDb(DBBuilder.db_name)
        db:open()
        db:empty()  -- 清空数据库

        -- 从长度2开始处理（跳过长度1）
        local start_len = 2
        for code_len = start_len, max_code_len do
            if length_counts[code_len] and length_counts[code_len] > 0 then
                local count = length_counts[code_len]
                log_rebuild("en_dict", string.format("处理编码长度为%d的词，共%d个", code_len, count))

                -- 处理该长度的所有词
                local success, err = pcall(function()
                    process_entries_by_length(file_path, code_len, db)
                end)

                if not success then
                    log_rebuild("en_dict", string.format("处理编码长度%d失败: %s，跳过", code_len, tostring(err)))
                    -- 继续处理下一个长度，不中断整个流程
                end
            end
        end

        db:close()
        return true, nil
    end

    -- ==================== 新的构建函数 ====================
    local function build_en_db()
        if DBBuilder.status ~= "pending" then return end

        local dist = rime_api.get_distribution_code_name() or ""
        if dist ~= "hamster" and dist ~= "hamster3" and dist ~= "Weasel" then
            local user_lua_dir = rime_api.get_user_data_dir() .. "/lua"
            ensure_dir_exist(user_lua_dir .. "/data")
        end

        local en_db = userdb.LevelDb(DBBuilder.db_name)
        en_db:open()

        local needs_rebuild = false
        local reason = "版本号一致"
        local stored_version = en_db:meta_fetch(DBBuilder.META_KEY.version)
        if not stored_version or stored_version ~= wanxiang.version then
            needs_rebuild = true
            reason = "版本号不一致或不存在"
        end

        if needs_rebuild then
            local start_time = os.clock()
            local start_memory = collectgarbage("count")
            log_rebuild("en_dict", reason)

            -- 关闭数据库，准备重新构建
            en_db:close()

            -- 分批处理（从长度2开始）
            local success, err = batch_preprocess(DBBuilder.en_dict_path)

            if not success then
                log_rebuild("en_dict", "重建失败: " .. tostring(err))
                DBBuilder.status = "pending"
                return
            end

            -- 重新打开数据库，更新版本号
            en_db = userdb.LevelDb(DBBuilder.db_name)
            en_db:open()
            en_db:meta_update(DBBuilder.META_KEY.version, wanxiang.version)
            en_db:close()

            local end_time = os.clock()
            local end_memory = collectgarbage("count")
            local total_duration = end_time - start_time
            local memory_change = end_memory - start_memory

            log_rebuild("en_dict", string.format("重建完成，总计: %.3f秒，内存变化: %.2f KB", total_duration, memory_change))
        else
            log_rebuild("en_dict", "使用现有数据库")
            en_db:close()
        end

        DBBuilder.status = "done"
    end

    -- ==================== 查询模块 ====================
    local Query = {
        db = nil,
        status = "pending"
    }

    function Query.init()
        if Query.status ~= "pending" then return end
        Query.db = userdb.LevelDb(DBBuilder.db_name)
        Query.db:open_read_only()
        Query.status = "done"
    end

    function Query.get_candidates(prefix, limit_len)
        if Query.status ~= "done" or not prefix or prefix == "" then
            return {}
        end

        local data_str = Query.db:fetch(prefix) or ""
        if data_str == "" then return {} end

        local cand_list = {}
        for entry in string.gmatch(data_str, "[^" .. ENTRY_SEP .. "]+") do
            local split1 = entry:find("\t")
            if not split1 then break end

            local split2 = entry:find("\t", split1 + 1)
            if not split2 then break end

            local code_len = split2 - split1 - 1

            -- 【关键截断】如果当前词的编码长度超过了限制，由于数据库是按长度排序的，
            -- 后续所有的词都会更长，直接停止循环，不再处理后续成千上万个长词。
            if code_len > limit_len then
                break
            end

            local text, code, type_rank = entry:match("^([^\t]+)\t([^\t]+)\t(%d+)$")
            if text and code and type_rank then
                table.insert(cand_list, {
                    text = text,
                    code = code,
                    code_len = code_len,
                    text_len = #text,
                    type_rank = tonumber(type_rank)
                })
            end
        end
        return cand_list
    end

    -- ==================== 返回模块接口 ====================
    return {
        init = function()
            build_en_db()
            Query.init()
            env.max_additional_chars = 4
            env.max_results = 50
        end,

        fini = function()
            if Query.db and Query.status == "done" then
                Query.db:close()
            end
            Query.status = "pending"
            DBBuilder.status = "pending"
        end,

        func = function(ctx, input_code)
            if #input_code == 0 then return {} end

            input_code = input_code:lower()
            local limit_len = #input_code + (env.max_additional_chars or 4)

            local cand_list = Query.get_candidates(input_code, limit_len)

            if #cand_list > 0 then
                table.sort(cand_list, function(a, b)
                    if a.code_len ~= b.code_len then return a.code_len < b.code_len end
                    if a.text_len ~= b.text_len then return a.text_len < b.text_len end
                    if a.type_rank ~= b.type_rank then return a.type_rank < b.type_rank end
                    return a.text < b.text
                end)

                local results = {}
                local count = 0
                for _, item in ipairs(cand_list) do
                    local cand = Candidate("english", 0, #ctx.input, item.text, "")
                    table.insert(results, cand)
                    count = count + 1
                    if env.max_results and count >= env.max_results then
                        break
                    end
                end
                return results
            end
            return {}
        end
    }
end

-- ==================== 注音模块 (zhuyin) ====================
local function zhuyin_func(env)
    local DBBuilder = {
        preset_file_path = wanxiang.get_filename_with_fallback("dicts/jichu.pro.dict.yaml"),
        user_override_path = rime_api.get_user_data_dir() .. "/custom_phrase/py.txt",
        status = "pending",
        version = "zhuyin_v1"
    }

    DBBuilder.META_KEY = {
        version = "zhuyin_version"
    }

    local function process_comment_raw(raw)
        if not raw or raw == "" then
            return ""
        end
        local processed = raw:gsub(";[^' ]*[' ]", " ")
        local last_semicolon = processed:find(";[^;]*$")
        if last_semicolon then
            processed = processed:sub(1, last_semicolon - 1)
        end
        processed = processed:gsub("%s+", " "):gsub("^%s*(.-)%s*$", "%1")
        return processed
    end

    local function init_db_from_file(path, db)
        local file = io.open(path, "r")
        if not file then return end

        for line in file:lines() do
            local key, raw_value = line:match("^([^\t]+)\t([^\t]*)")
            if key and raw_value and #key > 1 then
                local value = process_comment_raw(raw_value)
                db:update(key, value)
            end
        end
        file:close()
    end

    local function build_zhuyin_db(config)
        if DBBuilder.status ~= "pending" then return end

        local dist = rime_api.get_distribution_code_name() or ""
        if dist ~= "hamster" and dist ~= "hamster3" and dist ~= "Weasel" then
            local user_lua_dir = rime_api.get_user_data_dir() .. "/lua"
            ensure_dir_exist(user_lua_dir .. "/data")
        end

        local zhuyin_db = userdb.LevelDb("lua/zhuyin")
        zhuyin_db:open()

        local needs_rebuild = false
        local reason = "版本号一致"
        local stored_version = zhuyin_db:meta_fetch(DBBuilder.META_KEY.version)
        if not stored_version or stored_version ~= DBBuilder.version then
            needs_rebuild = true
            reason = "版本号不一致或不存在"
        end

        if needs_rebuild then
            local start_time = os.clock()
            local start_memory = collectgarbage("count")
            log_rebuild("zhuyin", reason)
            zhuyin_db:empty()
            init_db_from_file(DBBuilder.preset_file_path, zhuyin_db)
            init_db_from_file(DBBuilder.user_override_path, zhuyin_db)
            zhuyin_db:meta_update(DBBuilder.META_KEY.version, DBBuilder.version)
            local end_time = os.clock()
            local end_memory = collectgarbage("count")
            local duration = end_time - start_time
            local memory_change = end_memory - start_memory
            log_rebuild("zhuyin", string.format("重建完成，耗时: %.3f秒，内存变化: %.2f KB", duration, memory_change))
        else
            log_rebuild("zhuyin", "使用现有数据库")
        end

        zhuyin_db:close()
        DBBuilder.status = "done"
    end

    local Query = {
        db = nil,
        status = "pending",
        zhuyin_dict = nil
    }

    function Query.init(env)
        if Query.status ~= "pending" then return end

        Query.db = userdb.LevelDb("lua/zhuyin")
        Query.db:open_read_only()

        Query.zhuyin_dict = ReverseLookup("wanxiang_pro")

        Query.status = "done"
    end

    function Query.get_single_char_comment(char)
        if Query.status ~= "done" then return nil end

        if Query.zhuyin_dict then
            local raw = Query.zhuyin_dict:lookup(char)
            if raw and raw ~= "" then
                local processed = raw:gsub(";[^%s]*", "")
                return processed
            end
        end

        return nil
    end

    function Query.get_multi_word_comment(text)
        if Query.status ~= "done" then return nil end

        local comment = Query.db:fetch(text)
        if comment and comment ~= "" then
            return comment
        end

        return nil
    end

    return {
        init = function()
            local config = env.engine.schema.config
            build_zhuyin_db(config)
            Query.init(env)
        end,

        fini = function()
            if Query.db and Query.status == "done" then
                Query.db:close()
            end
            Query.status = "pending"
            DBBuilder.status = "pending"
            Query.zhuyin_dict = nil
        end,

        func = function(ctx, cand)
            local is_tone_comment = ctx:get_option("pinyin")
            if not is_tone_comment then
                return cand
            end

            local char_count = select(2, cand.text:gsub("[^\128-\193]", ""))

            local genuine_cand = cand:get_genuine()
            local comment = nil

            if char_count == 1 then
                comment = Query.get_single_char_comment(genuine_cand.text)
            else
                comment = Query.get_multi_word_comment(genuine_cand.text)
            end

            if comment then
                genuine_cand.comment = comment
            end

            return cand
        end
    }
end

-- ==================== 主模块 (merged_dict) ====================
local merged_dict = {}

function merged_dict.init(env)
    -- ==================== 按顺序逐个初始化和重建数据库 ====================

    -- 1. 注音模块 (zhuyin) - 最先重建
    env.zhuyin = zhuyin_func(env)
    env.zhuyin.init()

    -- 2. 中文词库模块 (tigress_ci_dict) - 再重建
    env.tigress_ci = tigress_ci_dict
    env.tigress_ci.init(env)

    -- 3. 英文词库模块 (en_dict) - 最后重建（修复版）
    env.en_dict = en_dict_func(env)
    env.en_dict.init()

    -- ====================================================================

    env.engine_ctx = env.engine.context
end

function merged_dict.fini(env)
    -- 分别调用各自的fini
    if env.tigress_ci then env.tigress_ci.fini(env) end
    if env.en_dict then env.en_dict.fini() end
    if env.zhuyin then env.zhuyin.fini() end

    env.engine_ctx = nil
    collectgarbage()
end

function merged_dict.func(input, env)
    local ctx = env.engine_ctx
    if not ctx then
        for cand in input:iter() do
            yield(cand)
        end
        return
    end

    -- 1. 原生候选词：直接yield，同时进行注音处理（如果启用）
    local enable_pinyin = ctx:get_option("pinyin")
    for cand in input:iter() do
        if enable_pinyin then
            local processed_cand = env.zhuyin.func(ctx, cand)
            if processed_cand then
                yield(processed_cand)
            else
                yield(cand)
            end
        else
            yield(cand)
        end
    end

    -- 2. 中文词库补全
    local enable_completion = ctx:get_option("completion")
    if enable_completion and #ctx.input == 3 then
        local input_code = ctx.input:gsub("^%s+", ""):gsub("%s+$", "")
        -- 直接调用中文词库的func函数（使用yield方式）
        env.tigress_ci.func(input, env)
    end

    -- 3. 英文词库补全
    local enable_en = ctx:get_option("english_word")
    if enable_en and #ctx.input > 0 then
        local input_code = ctx.input:gsub("^%s+", ""):gsub("%s+$", "")
        local en_candidates = env.en_dict.func(ctx, input_code)
        -- 英文候选词不进行注音处理
        for _, cand in ipairs(en_candidates) do
            yield(cand)
        end
    end
end

return merged_dict
