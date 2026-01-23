local wanxiang = require('wanxiang')
local userdb = require("lib/userdb")
local zhuyin = {}

-- 数据库构建模块：整合原 zhuyin.lua 的核心功能
local DBBuilder = {
    disabled_types = {},
    preset_file_path = wanxiang.get_filename_with_fallback("lua/data/PYPhrases.txt"),
    user_override_path = rime_api.get_user_data_dir() .. "/lua/data/user_py.txt",
    status = "pending"
}

-- 元数据 Key
DBBuilder.META_KEY = {
    version = "wanxiang_version",
    disabled_types = "disabled_types_fingerprint",
}

---判断某个类型是否被禁用
function DBBuilder.is_disabled(tip)
    local type = tip:match("^(..-):") or tip:match("^(..-)：")
    if not type then return false end
    return DBBuilder.disabled_types[type] == true
end

---从文件加载数据到 DB
function DBBuilder.init_db_from_file(path, db)
    local file = io.open(path, "r")
    if not file then return end

    for line in file:lines() do
        -- 格式：值 [tab] 键
        local value, key = line:match("([^\t]+)\t([^\t]+)")
        if key and value and not DBBuilder.is_disabled(value) then
            db:update(key, value)
        end
    end
    file:close()
end

function DBBuilder.ensure_dir_exist(dir)
    local sep = package.config:sub(1, 1)
    dir = dir:gsub([["]], [[\"]])
    if sep == "/" then
        os.execute('mkdir -p "' .. dir .. '" 2>/dev/null')
    end
end

---初始化数据库构建逻辑
function DBBuilder.build_zhuyin_db(config)
    if DBBuilder.status ~= "pending" then return end
    
    -- 1. 确保目录存在
    local dist = rime_api.get_distribution_code_name() or ""
    if dist ~= "hamster" and dist ~= "hamster3" and dist ~= "Weasel" then
        local user_lua_dir = rime_api.get_user_data_dir() .. "/lua"
        DBBuilder.ensure_dir_exist(user_lua_dir .. "/data")
    end

    -- 2. 创建或打开数据库（使用 zhuyin 数据库）
    local zhuyin_db = userdb.LevelDb("lua/zhuyin")
    zhuyin_db:open()
    
    -- 3. 读取 disabled_types 配置
    local disabled_keys = {}
    local disabled_types_list = config:get_list("zhuyin/disabled_types")
    if disabled_types_list then
        for i = 1, disabled_types_list.size do
            local item = disabled_types_list:get_value_at(i - 1)
            if item and #item.value > 0 then
                DBBuilder.disabled_types[item.value] = true
                table.insert(disabled_keys, item.value)
            end
        end
    end
    table.sort(disabled_keys)
    local current_disabled_fingerprint = table.concat(disabled_keys, "|")

    -- 4. 检查是否需要重建
    local needs_rebuild = false
    local db_ver = zhuyin_db:meta_fetch(DBBuilder.META_KEY.version)
    if db_ver ~= wanxiang.version then
        needs_rebuild = true
    end

    if not needs_rebuild then
        local db_fingerprint = zhuyin_db:meta_fetch(DBBuilder.META_KEY.disabled_types) or ""
        if db_fingerprint ~= current_disabled_fingerprint then
            needs_rebuild = true
        end
    end

    -- 5. 执行重建
    if needs_rebuild then
        zhuyin_db:empty()
        DBBuilder.init_db_from_file(DBBuilder.preset_file_path, zhuyin_db)
        DBBuilder.init_db_from_file(DBBuilder.user_override_path, zhuyin_db)
        
        zhuyin_db:meta_update(DBBuilder.META_KEY.version, wanxiang.version)
        zhuyin_db:meta_update(DBBuilder.META_KEY.disabled_types, current_disabled_fingerprint)
    end
    
    -- 6. 关闭数据库（后续CR模块会以只读模式打开）
    zhuyin_db:close()
    
    DBBuilder.status = "done"
end

-- CR模块：复用zhuyin.userdb
local CR = {
    style = '{comment}',
    db = nil,  -- 延迟初始化
    status = "pending"
}

-- CR初始化：加载配置+打开数据库
function CR.init(env)
    if CR.status ~= "pending" then return end
    CR.style = env.settings.PYPhrases_type or '{comment}'
    CR.db = userdb.LevelDb("lua/zhuyin")
    CR.db:open_read_only()
    CR.status = "done"
end

-- CR查询：从zhuyin.userdb读取注释
function CR.get_comment(cand)
    if CR.status ~= "done" or not cand or not cand.text or cand.text == "" then
        return nil
    end
    local comment = CR.db:fetch(cand.text)
    if not comment or comment == "" then return nil end
    local left, right = CR.style:match("^(.-)comment(.-)$")
    return left and (left .. comment .. right) or comment
end

-- ZY注音模块
local ZY = {}
function ZY.init(env)
    env.zhuyin_dict = ReverseLookup("wanxiang_pro")
end

function ZY.fini(env)
    env.zhuyin_dict = nil
    collectgarbage()
end

local function process_existing_comment(comment)
    if not comment or comment == "" then return comment end
    local processed = comment:gsub(";[^' ]*[' ]", " ")
    local last_semicolon = processed:find(";[^;]*$")
    if last_semicolon then processed = processed:sub(1, last_semicolon - 1) end
    return processed:gsub("%s+", " "):gsub("^%s*(.-)%s*$", "%1")
end

local function process_annotation(raw, is_single_char)
    if not raw or raw == "" then return raw end
    if is_single_char then
        return raw:gsub(";[^%s]*", "")
    end
    return raw:match("^([^;]*)") or raw
end

function ZY.run(cand, env, mode)
    local dict = env.zhuyin_dict
    if not dict or #cand.text == 0 then return nil end
    
    local char_count = select(2, cand.text:gsub("[^\128-\193]", ""))
    local raw_comment = _RIME_RAW_CAND_COMMENT and _RIME_RAW_CAND_COMMENT[cand.text] or nil
    
    if mode == "char" then
        if char_count == 1 then
            if raw_comment and raw_comment:find(";") then
                return process_existing_comment(raw_comment)
            else
                local raw = dict:lookup(cand.text)
                return process_annotation(raw, true)
            end
        end
        return nil
    else
        if raw_comment and raw_comment:find(";") then
            return process_existing_comment(raw_comment)
        elseif char_count == 1 then
            local raw = dict:lookup(cand.text)
            return process_annotation(raw, true)
        elseif char_count > 1 then
            local parts, has_annotation = {}, false
            for char in cand.text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
                local raw = dict:lookup(char)
                local part = process_annotation(raw, false) or char
                table.insert(parts, part)
                if part ~= char then has_annotation = true end
            end
            return has_annotation and table.concat(parts, " ") or nil
        end
    end
    return nil
end

-- 主模块初始化：现在包含数据库构建
function zhuyin.init(env)
    -- 1. 获取配置
    local config = env.engine.schema.config
    env.settings = {
        pinyin_switch = config:get_bool("super_comment/pinyin") or true,
        auto_delimiter = config:get_string('speller/delimiter'):sub(1,1) or " ",
        PYPhrases_type = config:get_string("super_comment/corrector_type") or "{comment}"
    }
    env.zhuyin_mode = config:get_string("enum/zhuyin") or "all"
    
    -- 2. 构建数据库（如果需要）
    DBBuilder.build_zhuyin_db(config)
    
    -- 3. 初始化ZY注音字典
    ZY.init(env)
    
    -- 4. 按需初始化CR模块
    if env.zhuyin_mode == "all" or env.zhuyin_mode == "word" then
        CR.init(env)
    end
end

-- 主模块销毁
function zhuyin.fini(env)
    ZY.fini(env)
    if CR.db and CR.status == "done" then
        CR.db:close()
    end
    CR.status = "pending"
    DBBuilder.status = "pending"  -- 重置构建状态
    collectgarbage()
end

-- 主处理函数
function zhuyin.func(input, env)
    local is_tone_comment = env.engine.context:get_option("pinyin")
    for cand in input:iter() do
        if is_tone_comment then
            local genuine_cand = cand:get_genuine()
            local zy_comment = nil
            
            if env.zhuyin_mode == "all" then
                local cr_comment = CR.get_comment(genuine_cand)
                if cr_comment and cr_comment ~= "" then
                    genuine_cand.comment = cr_comment
                else
                    zy_comment = ZY.run(genuine_cand, env, "all")
                    if zy_comment then
                        genuine_cand.comment = zy_comment
                    end
                end
            elseif env.zhuyin_mode == "char" then
                zy_comment = ZY.run(genuine_cand, env, "char")
                if zy_comment then
                    genuine_cand.comment = zy_comment
                end
            elseif env.zhuyin_mode == "word" then
                local char_count = select(2, genuine_cand.text:gsub("[^\128-\193]", ""))
                if char_count == 1 then
                    zy_comment = ZY.run(genuine_cand, env, "char")
                    if zy_comment then
                        genuine_cand.comment = zy_comment
                    end
                else
                    local cr_comment = CR.get_comment(genuine_cand)
                    if cr_comment and cr_comment ~= "" then
                        genuine_cand.comment = cr_comment
                    end
                end
            end
        end
        yield(cand)
    end
end

return zhuyin