-- gemini 2026-05-04 10:39:06

 -- ==================== 0. 引入外部依赖 ====================
local wanxiang = require("wanxiang/wanxiang")
local userdb = require("wanxiang/userdb")

-- ==================== 1. 全局常量与路径预解析 ====================
local ENTRY_SEP = string.char(1)
local USER_DATA_DIR = rime_api.get_user_data_dir()

local function find_dict_path(filename)
    local check_list = {
        USER_DATA_DIR .. "/lua/" .. filename,  -- 优先 lua 目录
        USER_DATA_DIR .. "/" .. filename       -- 次选根目录
    }
    for _, path in ipairs(check_list) do
        if wanxiang.file_exists(path) then 
            return path 
        end
    end
    return nil
end

local PATHS = {
    collision_tiger = find_dict_path("chongma_tiger.txt"),
    collision_wubi  = find_dict_path("chongma_wubi.txt"),
    tigress_ci      = find_dict_path("tiger_dicts/tigress/tigress_ci.dict.yaml") or find_dict_path("tigress_ci.dict.yaml"),
    wubici          = find_dict_path("wubici.dict.yaml"),
    en_dict         = find_dict_path("dicts/en.dict.yaml") or find_dict_path("en.dict.yaml"),
    zhuyin_word     = find_dict_path("lua/zhuyin.txt") or find_dict_path("zhuyin.txt"),
    zhuyin_zi       = find_dict_path("lua/zhuyin_zi.txt") or find_dict_path("zhuyin_zi.txt")
}

-- 全局句柄缓存
local GLOBAL_CACHE = {
    dbs = {},
    reverse_lookup = nil
}

-- ==================== 2. 数据库与通用工具 ====================
local db_pool = setmetatable({}, { __mode = "v" }) -- 弱引用缓存池

local function get_level_db(db_name)
    local key = db_name .. ".userdb"
    local db = db_pool[key]
    if not db then
        db = userdb.LevelDb(db_name)
        db:open()
        db_pool[key] = db
    end
    return db
end

local function log_rebuild(module_name, reason, duration)
    local log_dir = USER_DATA_DIR .. "/lua/data"
    local log_file_path = log_dir .. "/db_rebuild.log"
    local log_file = io.open(log_file_path, "a")
    if log_file then
        local timestamp = os.date("%Y-%m-%d %H:%M:%S")
        local log_entry = duration
            and string.format("[%s] 模块: %-15s 原因: %s 耗时: %.3f秒\n", timestamp, module_name, reason, duration)
            or string.format("[%s] 模块: %-15s 原因: %s\n", timestamp, module_name, reason)
        log_file:write(log_entry)
        log_file:close()
    end
end

local function fast_init_db(db_name, internal_version, meta_key)
    if GLOBAL_CACHE.dbs[db_name] then
        return GLOBAL_CACHE.dbs[db_name], false
    end

    local db = get_level_db(db_name)
    GLOBAL_CACHE.dbs[db_name] = db

    local key = meta_key or "version"
    local current_ver = db:meta_fetch(key)
    if current_ver ~= internal_version then
        return db, true
    end
    return db, false
end

-- ==================== 3. 重码词替换模块 (collision_dict) ====================
local collision_dict = {
    CONFIG = { 
        MAX_COMBINATIONS = 10, 
        PRIORITY_DECREMENT = 100, 
        SHOW_REPLACEMENT_COMMENT = true, 
        COMMENT_PREFIX = "💫" 
    },
    INTERNAL_VERSION = "collision_v2.1", 
    META_KEY = "db_version", 
    SOURCE_SIG_META_KEY = "source_sig", 
    db = nil, 
    initialized = false
}

function collision_dict.calc_file_signature(p)
    local f = io.open(p or "", "rb")
    if not f then return end
    local h, s, pr, m = 2166136261, 0, 16777619, 4294967296
    while true do
        local c = f:read(65536); if not c then break end
        s = s + #c; for i = 1, #c do h = ((h ~ c:byte(i)) * pr) % m end
    end
    f:close(); return string.format("%08x:%d", h, s)
end

function collision_dict.find_valid_matches(text, preedit, db)
    local codes, chars, pos, raw, matches = {}, {}, {}, {}, {}
    for s in preedit:gmatch("%S+") do codes[#codes+1] = #s end
    for p, c in utf8.codes(text) do chars[#chars+1] = utf8.char(c); pos[#pos+1] = p end
    if #chars ~= #codes then return {} end
    for i = 1, #chars do
        local word = ""
        for len = 1, 4 do
            if i+len-1 > #chars or codes[i+len-1] ~= 2 then break end
            word = word .. chars[i+len-1]
            local data = db:fetch(word)
            if data then 
                table.insert(raw, {
                    k = word, s = pos[i], si = i, ei = i+len-1, d = data, l = len, 
                    bl = (pos[i+len] or (#text+1)) - pos[i]
                }) 
            end
        end
    end
    for i, a in ipairs(raw) do
        local is_sub = false
        for j, b in ipairs(raw) do 
            if i ~= j and a.si >= b.si and a.ei <= b.ei and b.l > a.l then is_sub = true; break end 
        end
        if not is_sub and a.d ~= "" then
            local cols = {}
            for w in a.d:gmatch("[^" .. ENTRY_SEP .. "]+") do table.insert(cols, w) end
            table.insert(matches, {key = a.k, start = a.s, byte_len = a.bl, collisions = cols})
        end
    end
    return matches
end

function collision_dict.apply_replacements(text, comb, selected)
    for i = #comb, 1, -1 do 
        text = text:sub(1, comb[i].start - 1) .. selected[i] .. text:sub(comb[i].start + comb[i].byte_len) 
    end
    return text
end

function collision_dict.init(env)
    local sid = env.engine.schema.schema_id
    local path = (sid == "tiger") and PATHS.collision_tiger or (sid == "wubi" and PATHS.collision_wubi)
    if not path then return end
    
    local db, rebuild = fast_init_db("lua/collision_"..sid, collision_dict.INTERNAL_VERSION, collision_dict.META_KEY)
    collision_dict.db = db
    local sig = collision_dict.calc_file_signature(path)
    if sig and db:meta_fetch(collision_dict.SOURCE_SIG_META_KEY) ~= sig then rebuild = true end
    
    if rebuild and path then
        local t0 = os.clock()
        local map = {}
        -- 修复处 1: 避免在高版本 Lua 中修改 const 循环变量 line
        for raw_line in io.lines(path) do
            local line = raw_line:match("^%s*(.-)%s*$")
            if line ~= "" and line:sub(1,1) ~= "#" then
                local l, r = line:match("^(.-)→(.-)$")
                local lw, rw = {}, {}
                for w in (l or line):gmatch("%S+") do lw[#lw+1] = w end
                for w in (r or line):gmatch("%S+") do rw[#rw+1] = w end
                for _, s in ipairs(lw) do
                    map[s] = map[s] or {}
                    for _, t in ipairs(rw) do table.insert(map[s], t) end
                end
            end
        end
        db:empty()
        for k, v in pairs(map) do db:update(k, table.concat(v, ENTRY_SEP)) end
        db:meta_update(collision_dict.META_KEY, collision_dict.INTERNAL_VERSION)
        if sig then db:meta_update(collision_dict.SOURCE_SIG_META_KEY, sig) end
        log_rebuild("collision_dict", "重建 "..sid, os.clock()-t0)
    end
    collision_dict.initialized = (db ~= nil)
end

-- ==================== 4. 中文词库模块 (tigress_ci_dict)  ====================
local tigress_ci_dict = {
    INTERNAL_VERSION = "tigress_ci_v13_ultimate",
    META_KEY = "db_version",
    db = nil
}

-- 生成a-z序列
local function get_az_buckets()
    local buckets = {}
    for c = string.byte('a'), string.byte('z') do
        table.insert(buckets, string.char(c))
    end
    return buckets
end

function tigress_ci_dict.init(env)
    local dict_name = env.engine.schema.config:get_string("char_word/dictionary") or "tigress"
    local db_name = (dict_name == "wubici") and "lua/wubici" or "lua/tigress"
    local dict_path = (dict_name == "wubici") and PATHS.wubici or PATHS.tigress_ci

    local db, needs_rebuild = fast_init_db(db_name, tigress_ci_dict.INTERNAL_VERSION, tigress_ci_dict.META_KEY)
    tigress_ci_dict.db = db

    if needs_rebuild and dict_path then
        local start_time = os.clock()
        db:empty()
        
        local file = io.open(dict_path, "r")
        if file then
            local az_buckets = {}
            for _, ch in ipairs(get_az_buckets()) do
                az_buckets[ch] = {}
            end

            for line in file:lines() do
                if string.byte(line) ~= 35 and line ~= "" then
                    local t1 = string.find(line, "\t", 1, true)
                    if t1 then
                        local first_ch = string.sub(line, t1 + 1, t1 + 1):lower()
                        if az_buckets[first_ch] then
                            table.insert(az_buckets[first_ch], line)
                        end
                    end
                end
            end
            file:close()

            for _, ch in ipairs(get_az_buckets()) do
                local bucket_list = az_buckets[ch]
                if #bucket_list > 0 then
                    local pref_group = {}
                    
                    for _, line in ipairs(bucket_list) do
                        local text, code, weight = line:match("^([^\t]+)\t([^\t]+)\t(%d+)")
                        if text and code and weight then
                            local cl = code:lower()
                            if #cl >= 4 then
                                local pref = cl:sub(1, 3)
                                pref_group[pref] = pref_group[pref] or {}
                                table.insert(pref_group[pref], {
                                    text = text,
                                    suffix = cl:sub(4),
                                    weight = tonumber(weight),
                                    len = #cl
                                })
                            end
                        end
                    end

                    for pref, entries in pairs(pref_group) do
                        table.sort(entries, function(a, b)
                            if a.weight ~= b.weight then return a.weight > b.weight end
                            return a.len < b.len
                        end)
                        local parts = {}
                        for _, itm in ipairs(entries) do
                            table.insert(parts, itm.text .. itm.suffix)
                        end
                        db:update(pref, table.concat(parts, " "))
                    end

                    az_buckets[ch] = nil
                    pref_group = nil
                    collectgarbage("step", 300)
                end
            end

            db:meta_update(tigress_ci_dict.META_KEY, tigress_ci_dict.INTERNAL_VERSION)
            log_rebuild("tigress_ci_dict", "极速分桶流式重建", os.clock() - start_time)
            collectgarbage("collect")
        end
    end
end

function tigress_ci_dict.get_candidates(prefix)
    if not tigress_ci_dict.db or not prefix or #prefix ~= 3 then return {} end
    local data = tigress_ci_dict.db:fetch(prefix) or ""
    if data == "" then return {} end
    local res = {}
    for block in data:gmatch("%S+") do
        local t, r = block:match("^(.-)([a-z]*)$")
        if t then table.insert(res, {text = t, remaining = r}) end
    end
    return res
end

-- ==================== 5. 英文词库模块 (en_dict)  ====================
local en_dict = {
    db_name = "lua/en_dict",
    INTERNAL_VERSION = "en_v25_bucket_batch", 
    db = nil,
    depth = 4,
    max_word_length = 5
}

function en_dict.init(env)
    local db, needs_rebuild = fast_init_db(en_dict.db_name, en_dict.INTERNAL_VERSION)
    en_dict.db = db

    if needs_rebuild and PATHS.en_dict then
        local start_time = os.clock()
        db:empty()

        local file = io.open(PATHS.en_dict, "r")
        if file then
            local buckets = { {}, {}, {}, {}, {}, {}, {} }

            for line in file:lines() do
                if not line:match("^%s*#") and not line:match("^%s*$") then
                    local text, code = line:match("^([^\t]+)\t([^\t]*)")
                    if text and code and #text <= en_dict.max_word_length then
                        local code_low = code:lower()
                        local first_char = code_low:sub(1,1)

                        local b_idx = 7
                        if first_char >= 'a' and first_char <= 'd' then b_idx = 1
                        elseif first_char >= 'e' and first_char <= 'h' then b_idx = 2
                        elseif first_char >= 'i' and first_char <= 'l' then b_idx = 3
                        elseif first_char >= 'm' and first_char <= 'p' then b_idx = 4
                        elseif first_char >= 'q' and first_char <= 't' then b_idx = 5
                        elseif first_char >= 'u' and first_char <= 'x' then b_idx = 6
                        end

                        table.insert(buckets[b_idx], text .. "\t" .. code_low)
                    end
                end
            end
            file:close()

            for i = 1, 7 do
                local prefix_groups = {}
                for _, raw_str in ipairs(buckets[i]) do
                    local text, code_low = raw_str:match("^(.-)\t(.*)$")
                    if text and code_low then
                        local code_len = #code_low
                        local text_low = text:lower()

                        local type_rank = 3
                        local s_code = code_low
                        if text == code_low then
                            type_rank = 1
                            s_code = ""
                        elseif text_low == code_low then
                            type_rank = 2
                            s_code = ""
                        end
                        local s_rank = (type_rank == 1) and "" or tostring(type_rank)
                        local entry_str = text .. "\t" .. s_code .. "\t" .. s_rank

                        local start_i = math.max(1, code_len - en_dict.depth)
                        for j = start_i, code_len do
                            local prefix = code_low:sub(1, j)
                            prefix_groups[prefix] = prefix_groups[prefix] or {}
                            table.insert(prefix_groups[prefix], entry_str)
                        end
                    end
                end

                for prefix, entries in pairs(prefix_groups) do
                    db:update(prefix, table.concat(entries, ENTRY_SEP))
                end

                buckets[i] = nil
                prefix_groups = nil
                collectgarbage("step", 500)
            end
        end

        db:meta_update("version", en_dict.INTERNAL_VERSION)
        log_rebuild("en_dict", "重建完成", os.clock() - start_time)
    end
    env.max_additional_chars = en_dict.depth
end

function en_dict.func(ctx, input_code)
    if not en_dict.db or #input_code == 0 then return {} end
    local data = en_dict.db:fetch(input_code:lower()) or ""
    if data == "" then return {} end
    local limit_len = #input_code + (en_dict.depth or 4)
    local res = {}
    for entry in string.gmatch(data, "[^" .. ENTRY_SEP .. "]+") do
        local text, m_code, m_rank = entry:match("^([^\t]+)\t([^\t]*)\t?(.*)$")
        if text then
            local final_code = (m_code == "") and text:lower() or m_code
            local final_rank = (m_rank == "" or m_rank == nil) and 1 or tonumber(m_rank)
            local code_len = #final_code
            if code_len <= limit_len then
                table.insert(res, {text = text, code_len = code_len, rank = final_rank})
            end
        end
    end
    table.sort(res, function(a, b)
        if a.code_len ~= b.code_len then return a.code_len < b.code_len end
        if a.rank ~= b.rank then return a.rank < b.rank end
        local al, bl = a.text:lower(), b.text:lower()
        if al ~= bl then return al < bl end
        return a.text > b.text
    end)
    local cands = {}
    for i, v in ipairs(res) do
        table.insert(cands, Candidate("english", 0, #ctx.input, v.text, ""))
        if i >= 50 then break end
    end
    return cands
end

-- ==================== 6. 注音模块 (zhuyin) ====================
local zhuyin = {
    db_word_name = "lua/zhuyin_word",
    db_zi_name = "lua/zhuyin_zi",
    version = "zhuyin_v4", 
    db_word = nil,
    db_zi = nil,
    enum = 4
}

local function split_by_comma(str)
    local res = {}
    local start = 1
    while true do
        local pos = str:find(",", start, true)
        if not pos then
            table.insert(res, str:sub(start))
            break
        end
        table.insert(res, str:sub(start, pos - 1))
        start = pos + 1
    end
    return res
end

function zhuyin.init(env)
    zhuyin.enum = tonumber(env.engine.schema.config:get_string("enum/zhuyin")) or 4
    if zhuyin.enum > 1 then
        local db_word, rebuild_word = fast_init_db(zhuyin.db_word_name, zhuyin.version)
        zhuyin.db_word = db_word
        if rebuild_word and PATHS.zhuyin_word then
            local t0 = os.clock()
            db_word:empty()
            local f = io.open(PATHS.zhuyin_word, "r")
            if f then
                for line in f:lines() do
                    if line ~= "" and string.byte(line) ~= 35 then
                        local k, v = string.match(line, "^([^\t]+)\t([^\r\n]+)")
                        if k and v then 
                            db_word:update(k, v) 
                        end
                    end
                end
                f:close()
            end
            db_word:meta_update("version", zhuyin.version)
            log_rebuild("zhuyin_word", "极速重建", os.clock() - t0)
        end

        local db_zi, rebuild_zi = fast_init_db(zhuyin.db_zi_name, zhuyin.version)
        zhuyin.db_zi = db_zi
        if rebuild_zi and PATHS.zhuyin_zi then
            local t0 = os.clock()
            db_zi:empty()
            local f = io.open(PATHS.zhuyin_zi, "r")
            if f then
                -- 修复处 2: 避免在高版本 Lua 中修改 const 循环变量 line
                for raw_line in f:lines() do
                    local line = raw_line:match("^%s*(.-)%s*$")
                    if line ~= "" and not line:match("^#") then
                        local k, v = line:match("^([^\t]+)\t([^\t]+)")
                        if not k then k, v = line:match("^(%S+)%s+(%S+)") end
                        if k and v then db_zi:update(k, v) end
                    end
                end
                f:close()
            end
            db_zi:meta_update("version", zhuyin.version)
            log_rebuild("zhuyin_zi", "重建", os.clock() - t0)
        end
    end

    if not GLOBAL_CACHE.reverse_lookup then
        GLOBAL_CACHE.reverse_lookup = ReverseLookup("wanxiang_pro")
    end
end

function zhuyin.func(ctx, cand)
    if not ctx:get_option("pinyin") then return cand end
    local text = cand:get_genuine().text
    local clen = utf8.len(text)
    
    if clen > zhuyin.enum then return cand end

    local rev = GLOBAL_CACHE.reverse_lookup
    if not rev then return cand end

    local chars = {}
    local rev_results = {}
    local has_polyphone = false
    local all_failed = true

    for p, c in utf8.codes(text) do
        local ch = utf8.char(c)
        table.insert(chars, ch)
        local raw = rev:lookup(ch)
        local py_list = {}
        if raw and raw ~= "" then
            all_failed = false
            raw = raw:gsub(";[^%s]*", "")
            for py in raw:gmatch("%S+") do
                table.insert(py_list, py)
            end
        end
        table.insert(rev_results, py_list)
        if #py_list > 1 or #py_list == 0 then
            has_polyphone = true
        end
    end

    if all_failed then return cand end

    local final_pinyin = {}

    if not has_polyphone then
        for _, py_list in ipairs(rev_results) do
            table.insert(final_pinyin, py_list[1] or "")
        end
    else
        local word_pinyin_str = zhuyin.db_word and zhuyin.db_word:fetch(text) or ""
        
        if word_pinyin_str ~= "" then
            local vals = split_by_comma(word_pinyin_str)
            for i, ch in ipairs(chars) do
                local py = vals[i]
                if py and py ~= "" then
                    table.insert(final_pinyin, py)
                else
                    local r = rev_results[i]
                    table.insert(final_pinyin, (r and r[1]) or "")
                end
            end
        else
            for i, ch in ipairs(chars) do
                local r = rev_results[i]
                if #r > 1 or #r == 0 then
                    local zi_py = zhuyin.db_zi and zhuyin.db_zi:fetch(ch) or ""
                    if zi_py ~= "" then
                        table.insert(final_pinyin, zi_py)
                    else
                        table.insert(final_pinyin, (r and r[1]) or "")
                    end
                else
                    table.insert(final_pinyin, r[1])
                end
            end
        end
    end

    local valid_pinyin = {}
    for _, py in ipairs(final_pinyin) do
        if py ~= "" then table.insert(valid_pinyin, py) end
    end

    if #valid_pinyin > 0 then
        cand:get_genuine().comment = " " .. table.concat(valid_pinyin, " ")
    end

    return cand
end

-- ==================== 7. 主模块 ====================
local merged_dict = {}

function merged_dict.init(e)
    collision_dict.init(e); e.collision = collision_dict
    tigress_ci_dict.init(e); e.tigress_ci = tigress_ci_dict
    en_dict.init(e); e.en_dict = en_dict
    zhuyin.init(e); e.zhuyin = zhuyin
    e.engine_ctx = e.engine.context

    -- === 核心修改点：反引号消除逻辑集成 ===
    e.search_key = '`'
    e.code_pattern = '[a-z]'

    e.select_notifier = e.engine_ctx.select_notifier:connect(function(ctx)
        local input = ctx.input
        local code = input:match('^(.-)' .. e.search_key)
        if not code or #code == 0 then return end
        
        local preedit = ctx:get_preedit()
        local no_search_string = input:match('^(.-)' .. e.search_key)
        local edit = preedit.text:match('^(.-)' .. e.search_key)
        
        if edit and edit:match(e.code_pattern) then
            ctx.input = no_search_string .. e.search_key
        else
            -- 【核心同步标记】：在修改 input 触发重新翻译前，打上临时标记
            ctx:set_property("is_removing_suffix", "true")
            
            ctx.input = no_search_string
            ctx:commit()
            
            -- 清除标记
            ctx:set_property("is_removing_suffix", "false")
        end
    end)
end

function merged_dict.func(input, env)
    local ctx = env.engine_ctx; if not ctx then for c in input:iter() do yield(c) end return end

    -- === 核心修改点：拦截反引号消除触发的重译 ===
    -- 如果当前是由消除反引号触发的翻译，直接放行原输入流，跳过后续所有中文补全/英文/重码逻辑
    if ctx:get_property("is_removing_suffix") == "true" then
        for c in input:iter() do yield(c) end
        return
    end

    local s = ctx.input:gsub("%s+", ""); if #s == 0 then for c in input:iter() do yield(c) end return end
    local opt_p, opt_c, opt_e = ctx:get_option("pinyin"), ctx:get_option("completion"), ctx:get_option("english_word")
    local m_s_p, seg = false, ctx.composition:back()
    local is_rad = seg and (seg:has_tag("radical_lookup") or seg:has_tag("reverse_stroke") or seg:has_tag("yin_add_user") or seg:has_tag("rvlk1"))
    local SUBS = {"₂", "₃", "₄", "₅", "₆"}

    for cand in input:iter() do
        local pc = (opt_p and env.zhuyin) and env.zhuyin.func(ctx, cand) or cand
        local col, g = env.collision, pc:get_genuine()
        if col and col.initialized and not is_rad and (g.type=="sentence" or g.type=="phrase") and #s>=5 and not m_s_p then
            m_s_p = true
            local ms = col.find_valid_matches(g.text, g.preedit, col.db)
            if #ms > 0 then
                local cf, res, seen, ol, sm, sa = col.CONFIG, {}, {}, {}, {}, {}
                for i, m in ipairs(ms) do
                    local o, u = { m.key }, { [m.key] = true }
                    for _, a in ipairs(m.collisions) do if a and not u[a] then table.insert(o, a); u[a]=true end end
                    ol[i] = o
                end
                local function dfs(p, le)
                    if #res >= cf.MAX_COMBINATIONS or p > #ms then
                        if #sm > 0 then
                            local nt = col.apply_replacements(g.text, sm, sa)
                            if not seen[nt] then
                                seen[nt] = true
                                local chg, target = {}, {}
                                for i=1, #sm do table.insert(chg, sm[i].key .. "→" .. sa[i]); table.insert(target, sa[i]) end
                                table.insert(res, {text = nt, change = table.concat(chg, " "), short = table.concat(target, "")})
                            end
                        end
                        return
                    end
                    dfs(p + 1, le)
                    if ms[p].start >= le then
                        for i = 2, #ol[p] do
                            if #res >= cf.MAX_COMBINATIONS then break end
                            table.insert(sm, ms[p]); table.insert(sa, ol[p][i]); dfs(p + 1, ms[p].start + ms[p].byte_len); table.remove(sm); table.remove(sa)
                        end
                    end
                end
                dfs(1, -1)
                if #res > 0 then
                    local summary = ""
                    for i = 1, math.min(#res, 5) do summary = summary .. SUBS[i] .. res[i].short end
                    pc.comment = (pc.comment or "") .. summary
                end
                yield(pc)
                for i, itm in ipairs(res) do
                    local nc = Candidate(g.type, cand.start, cand._end, itm.text, (#res >= 4 and itm.change or cf.COMMENT_PREFIX))
                    nc.quality = g.quality - i * cf.PRIORITY_DECREMENT; yield(nc)
                end
            else yield(pc) end
        else yield(pc) end
    end
    if opt_c and #s == 3 and env.tigress_ci then
        local ok, l = pcall(env.tigress_ci.get_candidates, s:lower())
        if ok and l then for i, v in ipairs(l) do yield(Candidate("tigress_ci", 0, #ctx.input, v.text, "~"..v.remaining)); if i>=50 then break end end end
    end
    if opt_e and env.en_dict then
        local ok, l = pcall(env.en_dict.func, ctx, s)
        if ok and l then for _, c in ipairs(l) do yield(c) end end
    end
    collectgarbage("step", 20)
end

-- === 核心修改点：增加清理函数，防止重新部署时反复注册 notifier 导致内存泄漏 ===
function merged_dict.fini(env)
    if env.select_notifier then
        env.select_notifier:disconnect()
    end
end

return merged_dict
