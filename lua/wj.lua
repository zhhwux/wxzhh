
-- ChatGPT 2026-02-11 03:59:53
-- 功能保持 100% 不变，仅修复 Windows 卡死问题

local T = {}

T.prefix = "/wj"
local regex_enabled = true

local regex_api = {
    enable  = function() regex_enabled = true end,
    disable = function() regex_enabled = false end,
    is_enabled = function() return regex_enabled end
}

local path_sep = package.config:sub(1,1)

--====================================================
-- 通用工具
--====================================================

local function startsWith(str, start)
    return str:sub(1, #start) == start
end

local function escape_lua_pattern(s)
    return (s:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1"))
end

local function readFileContent(path)
    local file = io.open(path, "r")
    if not file then return nil, "文件不存在" end
    local content = {}
    for line in file:lines() do
        table.insert(content, line)
    end
    file:close()
    return content
end

local function writeFileContent(path, content)
    local file = io.open(path, "w")
    if not file then return false, "无法写入文件" end
    for i, line in ipairs(content) do
        file:write(line)
        if i < #content then file:write("\n") end
    end
    file:close()
    return true
end

local function path_join(...)
    local parts = {...}
    local result = ""
    for i, part in ipairs(parts) do
        if i > 1 then result = result .. path_sep end
        part = part:gsub("^["..path_sep.."]", "")
        result = result .. part
    end
    return result
end

--====================================================
-- 文件 / 目录扫描（只扫描 Rime 用户目录，一次性缓存）
--====================================================

local function scan_files(user_dir)
    local files = {}
    local cmd = path_sep == '\\'
        and string.format('dir /b /s /a-d "%s"', user_dir)
        or string.format('find "%s" -type f', user_dir)

    local handle = io.popen(cmd)
    if not handle then return files end

    local prefix = escape_lua_pattern(user_dir .. path_sep)
    for path in handle:lines() do
        local rel = path:gsub(prefix, "")
        table.insert(files, rel)
    end
    handle:close()
    return files
end

local function scan_dirs(user_dir)
    local dirs = {}
    local cmd = path_sep == '\\'
        and string.format('dir /b /s /ad "%s"', user_dir)
        or string.format('find "%s" -type d', user_dir)

    local handle = io.popen(cmd)
    if not handle then return dirs end

    local prefix = escape_lua_pattern(user_dir .. path_sep)
    for path in handle:lines() do
        local rel = path:gsub(prefix, "")
        if rel ~= "" then table.insert(dirs, rel) end
    end
    handle:close()
    return dirs
end

local function get_file_cache(env)
    if env._file_cache then return env._file_cache end
    local user_dir = rime_api.get_user_data_dir()
    env._file_cache = scan_files(user_dir)
    return env._file_cache
end

local function get_dir_cache(env)
    if env._dir_cache then return env._dir_cache end
    local user_dir = rime_api.get_user_data_dir()
    env._dir_cache = scan_dirs(user_dir)
    return env._dir_cache
end

local function invalidate_cache(env)
    env._file_cache = nil
    env._dir_cache  = nil
end

--==========================================================================
-- 模糊搜索（多关键词空格分隔）
--==========================================================================
local function fuzzy_search_files(search_terms, files)
    local results = {}
    for _, file in ipairs(files) do
        local lower_file = file:lower()
        local ok = true
        for _, term in ipairs(search_terms) do
            if not lower_file:find(term, 1, true) then
                ok = false
                break
            end
        end
        if ok then
            table.insert(results, file)
        end
    end
    return results
end

local function ensure_directory_exists(full_dir_path)
    local cmd = path_sep == '\\'
        and string.format('if not exist "%s" mkdir "%s"', full_dir_path, full_dir_path)
        or string.format('mkdir -p "%s"', full_dir_path)
    return os.execute(cmd)
end

--==========================================================================
-- 转义处理
--==========================================================================
local function unescape_string(str)
    return str:gsub("\\(.)", {
        n = "\n",
        ["\\"] = "\\",
        r = "\r",
        t = "\t"
    })
end

local function escape_for_display(str)
    return str:gsub("\\", "\\\\"):gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t")
end

--==========================================================================
-- 模糊文件搜索（候选）
--==========================================================================
local function fuzzy_file_search(input, seg, env)
    local total_pattern = input:match("^/wj(.*)$")
    if not total_pattern then return false end

    local files = get_file_cache(env)
    local search_terms = {}
    local selection_index = nil

    -- 末尾数字选索引
    local index_str = ""
    for i = #total_pattern, 1, -1 do
        local c = total_pattern:sub(i,i)
        if c:match("%d") then
            index_str = c .. index_str
        else
            break
        end
    end

    if #index_str > 0 and #total_pattern > #index_str then
        selection_index = tonumber(index_str)
        total_pattern = total_pattern:sub(1, #total_pattern - #index_str)
    end

    for term in total_pattern:gmatch("%S+") do
        if term ~= "" then
            table.insert(search_terms, term:lower())
        end
    end

    if #search_terms == 0 then return false end

    local results = fuzzy_search_files(search_terms, files)
    table.sort(results, function(a,b) return #a < #b end)

    if #results == 0 then
        yield(Candidate(input, seg.start, seg._end, "未找到匹配文件", ""))
        return true
    end

    if selection_index and selection_index > 0 and selection_index <= #results then
        yield(Candidate(input, seg.start, seg._end, results[selection_index],
            "📁 文件(选择第"..selection_index.."个)"))
        return true
    end

    for i, file in ipairs(results) do
        yield(Candidate(input, seg.start, seg._end, file, "📁"..i))
    end
    return true
end

--==========================================================================
-- 文件系统：新建 / 删除
--==========================================================================
local function handleFileSystemRequest(input, seg, env)
    -- 删除 /wjdel"..."
    local del_partial = "^/wjdel\"(.-)\"?$"
    local del_path = input:match(del_partial)
    if del_path then
        local index_str = ""
        for i = #del_path,1,-1 do
            local c = del_path:sub(i,i)
            if c:match("%d") then index_str = c..index_str else break end
        end
        local sel = nil
        local term = del_path
        if #index_str>0 and #del_path>#index_str then
            sel = tonumber(index_str)
            term = del_path:sub(1, #del_path-#index_str)
        end

        local st = {}
        for w in term:gmatch("%S+") do if w~="" then table.insert(st, w:lower()) end end
        if #st == 0 then
            yield(Candidate(input, seg.start, seg._end, "请输入要删除的文件关键词", ""))
            return true
        end

        local files = get_file_cache(env)
        local res = fuzzy_search_files(st, files)
        table.sort(res, function(a,b) return #a<#b end)

        if sel then
            if sel>0 and sel<=#res then res={res[sel]}
            else
                yield(Candidate(input, seg.start, seg._end, "索引无效 1-"..#res, ""))
                return true
            end
        end

        if #res == 0 then
            yield(Candidate(input, seg.start, seg._end, "未找到匹配文件: "..term, ""))
            return true
        end

        -- 完整命令：已输入 "
        if input:match("^/wjdel\".+\"$") then
            local target = res[1]
            local user = rime_api.get_user_data_dir()
            local full = path_join(user, target)
            local ok, err = os.remove(full)
            if ok then
                yield(Candidate(input, seg.start, seg._end, "删除成功: "..target, ""))
                env._file_cache = nil
            else
                yield(Candidate(input, seg.start, seg._end, "删除失败: "..target.." "..(err or ""), ""))
            end
            return true
        end

        for i, f in ipairs(res) do
            yield(Candidate(input, seg.start, seg._end, f, "📁"..i))
        end
        return true
    end

    -- 新建预览 /wjnew"..."
    local create_partial = "^/wjnew\"(.-)\"?$"
    local create_path = input:match(create_partial)
    if create_path and not input:match("^/wjnew\".+\"$") then
        local has_slash = create_path:find("/") ~= nil
        local pre, post = create_path:match("^(.-)/(.*)$")
        pre = pre or create_path

        local index_str = ""
        for i=#pre,1,-1 do
            local c = pre:sub(i,i)
            if c:match("%d") then index_str=c..index_str else break end
        end
        local sel = nil
        local term = pre
        if #index_str>0 and #pre>#index_str then
            sel = tonumber(index_str)
            term = pre:sub(1,#pre-#index_str)
        end

        local dirs = get_dir_cache(env)
        local st = {term:lower()}
        local res = fuzzy_search_files(st, dirs)
        table.sort(res, function(a,b) return #a<#b end)

        local sel_dir = nil
        if sel and sel>0 and sel<=#res then
            sel_dir = res[sel]
            res = {sel_dir}
        end

        if #res>0 then
            if has_slash then
                local d = sel_dir or pre
                yield(Candidate(input, seg.start, seg._end,
                    d.."/"..(post or ""),
                    sel_dir and "在"..sel_dir.."中创建" or "新建文件夹并创建文件"))
            else
                for i, d in ipairs(res) do
                    yield(Candidate(input, seg.start, seg._end, d, "📂"..i))
                end
                yield(Candidate(input, seg.start, seg._end, pre, "使用输入名"))
            end
        else
            yield(Candidate(input, seg.start, seg._end, create_path, "创建路径"))
        end
        return true
    end

    -- 完整新建命令
    local create_pat = "^/wjnew\"(.*)\"$"
    local create_target = input:match(create_pat)
    if create_target then
        local is_dir = create_target:sub(-1) == "/" or create_target:sub(-1) == "\\"
        local dir_part, file_part = create_target:match("^(.-)/(.*)$")
        local actual_dir = dir_part or create_target

        local index_str = ""
        for i=#actual_dir,1,-1 do
            local c = actual_dir:sub(i,i)
            if c:match("%d") then index_str=c..index_str else break end
        end

        local sel = nil
        local resolved_dir = nil
        local use_input = true
        if #index_str>0 and #actual_dir>#index_str then
            sel = tonumber(index_str)
            actual_dir = actual_dir:sub(1,#actual_dir-#index_str)
            local dirs = get_dir_cache(env)
            local ms = fuzzy_search_files({actual_dir:lower()}, dirs)
            table.sort(ms, function(a,b) return #a<#b end)
            if sel and sel>0 and sel<=#ms then
                resolved_dir = ms[sel]
                use_input = false
            end
        end

        local real_path
        if dir_part and file_part then
            real_path = use_input and (dir_part.."/"..file_part) or (resolved_dir.."/"..file_part)
        else
            real_path = use_input and create_target or resolved_dir
        end

        local user = rime_api.get_user_data_dir()
        local full = path_join(user, real_path)

        if is_dir then
            local cmd = path_sep == '\\'
                and string.format('mkdir "%s"', full)
                or string.format('mkdir -p "%s"', full)
            local ok = os.execute(cmd)
            if ok then
                yield(Candidate(input, seg.start, seg._end, "文件夹创建成功: "..real_path, ""))
                env._dir_cache = nil
            else
                yield(Candidate(input, seg.start, seg._end, "文件夹创建失败: "..real_path, ""))
            end
            return true
        else
            local pdir = real_path:match("^(.*)[/\\][^/\\]*$")
            if pdir then
                local full_pdir = path_join(user, pdir)
                ensure_directory_exists(full_pdir)
            end
            local f = io.open(full, "w")
            if f then
                f:close()
                yield(Candidate(input, seg.start, seg._end, "文件创建成功: "..real_path, ""))
                env._file_cache = nil
            else
                yield(Candidate(input, seg.start, seg._end, "文件创建失败: "..real_path, ""))
            end
            return true
        end
    end

    return false
end

--==========================================================================
-- 内容替换（行替换 + 全文覆盖）
--==========================================================================
local function handleReplaceRequest(input, seg, env)
    -- 整体覆盖 /wjfile@//content/
    local over_pat = "^/wj(.-)@//(.*)/$"
    local over_input = "^/wj(.-)@//(.*)$"
    local fpath, newc = input:match(over_pat)
    if not fpath then
        fpath, newc = input:match(over_input)
    end

    if fpath then
        local idx_str = ""
        for i=#fpath,1,-1 do
            local c = fpath:sub(i,i)
            if c:match("%d") then idx_str=c..idx_str else break end
        end
        local sel = nil
        if #idx_str>0 and #fpath>#idx_str then
            sel = tonumber(idx_str)
            fpath = fpath:sub(1,#fpath-#idx_str)
        end

        local files = get_file_cache(env)
        local ms = fuzzy_search_files({fpath:lower()}, files)
        table.sort(ms, function(a,b) return #a<#b end)
        if sel and sel>0 and sel<=#ms then ms={ms[sel]} end

        if #ms == 0 then
            yield(Candidate(input, seg.start, seg._end, "未找到匹配文件", ""))
            return true
        end
        if #ms ~= 1 then
            yield(Candidate(input, seg.start, seg._end, "匹配多个文件："..#ms, "加数字指定"))
            return true
        end

        local user = rime_api.get_user_data_dir()
        local full = path_join(user, ms[1])
        local content = readFileContent(full)

        -- 未输入结尾 /，预览
        if not input:match(over_pat) then
            local disp = escape_for_display(newc or "")
            local prev = ""
            if content and #content>0 then
                for i=1, math.min(3, #content) do
                    if i>1 then prev=prev.." \\n " end
                    prev=prev..escape_for_display(content[i])
                end
                if #content>3 then prev=prev.."..." end
            else
                prev = "(空文件)"
            end
            yield(Candidate(input, seg.start, seg._end, "将覆盖为: "..disp, "原内容: "..prev))
            return true
        end

        newc = unescape_string(newc or "")
        local lines = {}
        for l in newc:gmatch("[^\n]+") do table.insert(lines, l) end
        if #lines == 0 then table.insert(lines, "") end

        local ok, err = writeFileContent(full, lines)
        if not ok then
            yield(Candidate(input, seg.start, seg._end, "写入失败: "..(err or ""), ""))
            return true
        end

        local old_lines = content and #content or 0
        local new_lines = #lines
        local msg = "覆盖成功"
        if #msg > 40 then msg = msg:sub(1,37).."..." end
        yield(Candidate(input, seg.start, seg._end,
            "整体替换成功",
            old_lines.."行 → "..new_lines.."行"))
        return true
    end

    -- 行替换：/wjfile@key/old/new/
    local full_pat = "^/wj(.-)@([^/]+)/([^/]+)/([^/]*)/$"
    local p1 = "^/wj(.-)@([^/]+)/([^/]*)$"
    local p2 = "^/wj(.-)@([^/]+)/([^/]+)/([^/]*)$"
    local empty_pat = "^/wj(.-)@([^/]+)/([^/]+)//$"

    local fp, k, o, n = input:match(full_pat)
    if not fp then
        fp, k, o = input:match(empty_pat)
        if fp then n=""
        else
            fp, k, o = input:match(p1)
            if not fp then
                fp, k, o, n = input:match(p2)
            end
        end
    end
    if not fp or not k then return false end

    -- 文件索引
    local f_idx_str = ""
    for i=#fp,1,-1 do
        local c = fp:sub(i,i)
        if c:match("%d") then f_idx_str=c..f_idx_str else break end
    end
    local f_sel = nil
    if #f_idx_str>0 and #fp>#f_idx_str then
        f_sel = tonumber(f_idx_str)
        fp = fp:sub(1,#fp-#f_idx_str)
    end

    -- 行索引
    local l_idx_str = ""
    for i=#k,1,-1 do
        local c = k:sub(i,i)
        if c:match("%d") then l_idx_str=c..l_idx_str else break end
    end
    local l_sel = nil
    if #l_idx_str>0 and #k>#l_idx_str then
        l_sel = tonumber(l_idx_str)
        k = k:sub(1,#k-#l_idx_str)
    end

    local files = get_file_cache(env)
    local ms = fuzzy_search_files({fp:lower()}, files)
    table.sort(ms, function(a,b) return #a<#b end)
    if f_sel and f_sel>0 and f_sel<=#ms then ms={ms[f_sel]} end

    if #ms == 0 then
        yield(Candidate(input, seg.start, seg._end, "未找到文件", ""))
        return true
    end
    if #ms ~= 1 then
        yield(Candidate(input, seg.start, seg._end, "匹配多个文件："..#ms, "加数字指定"))
        return true
    end

    local user = rime_api.get_user_data_dir()
    local full = path_join(user, ms[1])
    local content, err = readFileContent(full)
    if not content then
        yield(Candidate(input, seg.start, seg._end, "读文件失败: "..(err or ""), ""))
        return true
    end

    local matches = {}
    for i, line in ipairs(content) do
        if line:find(k, 1, true) then
            table.insert(matches, {line=line, idx=i})
        end
    end
    if #matches == 0 then
        yield(Candidate(input, seg.start, seg._end, "无匹配关键词行", "关键词: "..k))
        return true
    end

    local sel_lines = matches
    if l_sel then
        if l_sel>0 and l_sel<=#matches then
            sel_lines = {matches[l_sel]}
        else
            yield(Candidate(input, seg.start, seg._end, "行索引无效 1-"..#matches, ""))
            return true
        end
    end
    if #sel_lines ~= 1 then
        yield(Candidate(input, seg.start, seg._end, "匹配"..#sel_lines.."行，请加行号", ""))
        return true
    end

    local info = sel_lines[1]
    local orig = info.line
    local ln = info.idx

    -- 执行替换
    if input:match("^/wj[^@]*@[^/]+/[^/]+/[^/]*/$") then
        if n then n = unescape_string(n) end
        local new_line, cnt
        if n == "" then
            new_line = orig:gsub(o, "", 1)
            cnt = orig ~= new_line and 1 or 0
        else
            new_line, cnt = orig:gsub(o, n, 1)
        end
        if cnt == 0 then
            yield(Candidate(input, seg.start, seg._end, "未找到可替换内容", ""))
            return true
        end
        content[ln] = new_line
        local ok, err = writeFileContent(full, content)
        if not ok then
            yield(Candidate(input, seg.start, seg._end, "写入失败: "..(err or ""), ""))
            return true
        end
        local tip = n == "" and "删除成功: " or "替换成功: "
        local disp = new_line:gsub("\n","\\n")
        if #disp>40 then disp=disp:sub(1,37).."..." end
        yield(Candidate(input, seg.start, seg._end,
            tip..disp,
            "原行: "..orig:sub(1,40)))
        return true
    else
        -- 输入中提示
        local tip = orig
        if o and o~="" then
            if #tip>20 then tip=tip:sub(1,17).."..." end
            tip = tip.." → 待替换: "..o
            if n ~= nil then
                local dn = escape_for_display(n)
                if n=="" then
                    tip = tip.." ➔ 删除（输/确认）"
                else
                    if #dn>20 then dn=dn:sub(1,17).."..." end
                    tip = tip.." ➔ 新内容: "..dn
                end
            else
                tip = tip.." ➔ 输入替换内容"
            end
        else
            tip = tip.." → 输入待替换内容"
        end
        if #matches>1 and not l_sel then
            tip = tip.."（共"..#matches.."行匹配，加行号）"
        end
        yield(Candidate(input, seg.start, seg._end, tip, "第"..ln.."行"))
        return true
    end
end

--==========================================================================
-- 文件内容读取 / 查询
--==========================================================================
local function handleFileRequest(input, seg, env)
    if handleReplaceRequest(input, seg, env) then return true end

    local q_pat = "^/wj(.-)@([^/]+)/?$"
    local m_pat = "^/wj(.-)@/$"
    local norm_pat = "^/wj(.-)@$"

    local m_file = input:match(m_pat)
    local q_file, q = input:match(q_pat)
    local n_file = input:match(norm_pat)

    local target = m_file or q_file or n_file
    if not target then return false end

    -- 末尾数字选文件
    local idx_str = ""
    for i=#target,1,-1 do
        local c = target:sub(i,i)
        if c:match("%d") then idx_str=c..idx_str else break end
    end
    local sel = nil
    if #idx_str>0 and #target>#idx_str then
        sel = tonumber(idx_str)
        target = target:sub(1,#target-#idx_str)
    end

    local files = get_file_cache(env)
    local st = {}
    for w in target:gmatch("%S+") do
        if w~="" then table.insert(st, w:lower()) end
    end
    local ms = fuzzy_search_files(st, files)
    table.sort(ms, function(a,b) return #a<#b end)
    if sel and sel>0 and sel<=#ms then ms={ms[sel]} end

    local real = target
    if #ms == 1 then real = ms[1] end

    local user = rime_api.get_user_data_dir()
    local full = path_join(user, real)
    local content, err = readFileContent(full)
    if not content then
        yield(Candidate(input, seg.start, seg._end, "读文件失败: "..(err or ""), ""))
        return true
    end

    -- 合并全文
    if m_file then
        local all = table.concat(content, "\n")
        yield(Candidate(input, seg.start, seg._end, all, "全文合并"))
        return true
    end

    -- 关键词查询
    if q and q~="" then
        local l_idx_str = ""
        for i=#q,1,-1 do
            local c = q:sub(i,i)
            if c:match("%d") then l_idx_str=c..l_idx_str else break end
        end
        local l_sel = nil
        if #l_idx_str>0 and #q>#l_idx_str then
            l_sel = tonumber(l_idx_str)
            q = q:sub(1,#q-#l_idx_str)
        end

        local hits = {}
        for i, line in ipairs(content) do
            if not line:match("^%s*$") and line:find(q,1,true) then
                table.insert(hits, {line=line, n=i})
            end
        end

        if #hits == 0 then
            yield(Candidate(input, seg.start, seg._end, "无匹配内容", ""))
            return true
        end

        if l_sel and l_sel>0 and l_sel<=#hits then
            local s = hits[l_sel]
            yield(Candidate(input, seg.start, seg._end, s.line, "第"..s.n.."行(选中)"))
        else
            for i, d in ipairs(hits) do
                yield(Candidate(input, seg.start, seg._end,
                    d.line,
                    "("..i..")第"..d.n.."行: "..d.line:sub(1,20)))
            end
        end
        return true
    end

    -- 普通显示所有非空行
    for i, line in ipairs(content) do
        if not line:match("^%s*$") then
            yield(Candidate(input, seg.start, seg._end, line, "第"..i.."行"))
        end
    end
    return true
end

--==========================================================================
-- 复制 / 移动
--==========================================================================
local function handleFileCopyMove(input, seg, env)
    if input == "/wj&" or input == "/wj+&" then
        yield(Candidate(input, seg.start, seg._end, "/wj+&源&目标& 复制", "格式"))
        yield(Candidate(input, seg.start, seg._end, "/wj&源&目标& 移动", "格式"))
        return true
    end
    if input:match("^/wj[%+]?&$") then
        yield(Candidate(input, seg.start, seg._end, "请输入源文件关键词", ""))
        return true
    end

    -- 完整命令
    local stage3 = "^/wj[%+]?&(.-)&(.-)&$"
    local is_move = input:sub(1,4) == "/wj&"
    local src_raw, dst_raw = input:match(stage3)
    if src_raw and dst_raw then
        local user = rime_api.get_user_data_dir()

        -- 源文件索引
        local s_idx = ""
        for i=#src_raw,1,-1 do
            local c = src_raw:sub(i,i)
            if c:match("%d") then s_idx=c..s_idx else break end
        end
        local s_sel = nil
        local s_term = src_raw
        if #s_idx>0 and #src_raw>#s_idx then
            s_sel = tonumber(s_idx)
            s_term = src_raw:sub(1,#src_raw-#s_idx)
        end

        local files = get_file_cache(env)
        local s_st = {}
        for w in s_term:gmatch("%S+") do if w~="" then table.insert(s_st, w:lower()) end end
        local s_ms = fuzzy_search_files(s_st, files)
        table.sort(s_ms, function(a,b) return #a<#b end)
        if s_sel and s_sel>0 and s_sel<=#s_ms then s_ms={s_ms[s_sel]} end

        if #s_ms == 0 then
            yield(Candidate(input, seg.start, seg._end, "未找到源文件: "..s_term, ""))
            return true
        end
        if #s_ms ~= 1 then
            yield(Candidate(input, seg.start, seg._end, "匹配"..#s_ms.."个源文件，请加数字", ""))
            for i,f in ipairs(s_ms) do yield(Candidate(input, seg.start, seg._end,f,"📄"..i)) end
            return true
        end

        local r_src = s_ms[1]
        local f_src = path_join(user, r_src)

        -- 目标索引
        local d_idx = ""
        for i=#dst_raw,1,-1 do
            local c = dst_raw:sub(i,i)
            if c:match("%d") then d_idx=c..d_idx else break end
        end
        local d_sel = nil
        local d_term = dst_raw
        if #d_idx>0 and #dst_raw>#d_idx then
            d_sel = tonumber(d_idx)
            d_term = dst_raw:sub(1,#dst_raw-#d_idx)
        end

        local dirs = get_dir_cache(env)
        local d_st = {}
        for w in d_term:gmatch("%S+") do if w~="" then table.insert(d_st, w:lower()) end end
        local d_ms = fuzzy_search_files(d_st, dirs)
        table.sort(d_ms, function(a,b) return #a<#b end)
        if d_sel and d_sel>0 and d_sel<=#d_ms then d_ms={d_ms[d_sel]} end

        local fname = r_src:match("[^/\\]+$") or r_src
        local f_dst, t_dir
        local new_dir = false

        if #d_ms == 1 then
            f_dst = path_join(user, d_ms[1], fname)
            t_dir = path_join(user, d_ms[1])
        else
            new_dir = true
            local t_dir_raw = path_join(user, d_term)
            if t_dir_raw:sub(-1)~=path_sep then t_dir_raw=t_dir_raw..path_sep end
            f_dst = path_join(t_dir_raw, fname)
            t_dir = t_dir_raw
        end

        if new_dir then ensure_directory_exists(t_dir) end

        local cont, err = readFileContent(f_src)
        if not cont then
            yield(Candidate(input, seg.start, seg._end, "源读取失败: "..(err or ""), ""))
            return true
        end

        local ok, err = writeFileContent(f_dst, cont)
        if not ok then
            yield(Candidate(input, seg.start, seg._end, "写入失败: "..(err or ""), ""))
            return true
        end

        if is_move then
            local ok, err = os.remove(f_src)
            if not ok then
                yield(Candidate(input, seg.start, seg._end, "复制成功但删除原文件失败", ""))
                return true
            end
            env._file_cache = nil
        end

        local op = is_move and "移动" or "复制"
        local t_show = #d_ms==1 and d_ms[1] or d_term
        local tip = new_dir and "（已新建目录）" or ""
        yield(Candidate(input, seg.start, seg._end,
            op.."成功: "..r_src.." → "..t_show..tip, ""))
        env._file_cache = nil
        env._dir_cache = nil
        return true
    end

    -- 阶段2：源&目标前缀
    local stage2 = "^/wj[%+]?&(.-)&(.-)$"
    local src2, dst2 = input:match(stage2)
    if src2 and dst2 then
        local dirs = get_dir_cache(env)
        local items = {}
        for _,d in ipairs(dirs) do table.insert(items, d..path_sep) end

        local st = {}
        for w in dst2:gmatch("%S+") do if w~="" then table.insert(st, w:lower()) end end
        local ms = fuzzy_search_files(st, items)
        table.sort(ms, function(a,b) return #a<#b end)

        local d_idx = ""
        for i=#dst2,1,-1 do
            local c = dst2:sub(i,i)
            if c:match("%d") then d_idx=c..d_idx else break end
        end
        local d_sel = nil
        if #d_idx>0 and #dst2>#d_idx then
            d_sel = tonumber(d_idx)
            local t = dst2:sub(1,#dst2-#d_idx)
            st = {}
            for w in t:gmatch("%S+") do if w~="" then table.insert(st,w:lower()) end end
            ms = fuzzy_search_files(st, items)
            table.sort(ms, function(a,b) return #a<#b end)
            if d_sel and d_sel>0 and d_sel<=#ms then ms={ms[d_sel]} end
        end

        if #ms>0 then
            for i,d in ipairs(ms) do yield(Candidate(input, seg.start, seg._end,d,"📂"..i)) end
        else
            yield(Candidate(input, seg.start, seg._end, "无匹配目录，将新建", ""))
        end
        return true
    end

    -- 阶段1：仅源
    local stage1 = "^/wj[%+]?&(.-)$"
    local src1 = input:match(stage1)
    if src1 then
        local files = get_file_cache(env)
        local st = {}
        for w in src1:gmatch("%S+") do if w~="" then table.insert(st,w:lower()) end end
        if #st == 0 then
            yield(Candidate(input, seg.start, seg._end, "请输入关键词", ""))
            return true
        end
        local ms = fuzzy_search_files(st, files)
        table.sort(ms, function(a,b) return #a<#b end)

        local s_idx = ""
        for i=#src1,1,-1 do
            local c = src1:sub(i,i)
            if c:match("%d") then s_idx=c..s_idx else break end
        end
        local s_sel = nil
        if #s_idx>0 and #src1>#s_idx then
            s_sel = tonumber(s_idx)
            local t = src1:sub(1,#src1-#s_idx)
            st = {}
            for w in t:gmatch("%S+") do if w~="" then table.insert(st,w:lower()) end end
            ms = fuzzy_search_files(st, files)
            table.sort(ms, function(a,b) return #a<#b end)
            if s_sel and s_sel>0 and s_sel<=#ms then ms={ms[s_sel]} end
        end

        if #ms>0 then
            for i,f in ipairs(ms) do yield(Candidate(input, seg.start, seg._end,f,"📄"..i)) end
        else
            yield(Candidate(input, seg.start, seg._end, "未找到匹配文件", ""))
        end
        return true
    end

    return false
end

--==========================================================================
-- UTF8 辅助（兼容无 utf8 库）
--==========================================================================
local function utf8_char(str, index)
    if not utf8.offset then return str:sub(index,index) end
    local sb = utf8.offset(str, index)
    if not sb then return nil end
    local eb = utf8.offset(str, index+1) or #str+1
    return str:sub(sb, eb-1)
end

local function get_target_chars(line)
    local blocks = {}
    if not line or line == "" then return blocks end
    local cur = ""
    for i=1,#line do
        local c = line:sub(i,i)
        if not c:match("^[a-zA-Z0-9%s]$") then
            cur = cur..c
        else
            if cur~="" then blocks[cur]=true cur="" end
        end
    end
    if cur~="" then blocks[cur]=true end
    return blocks
end

local function get_first_target_char(line)
    if not line or line=="" then return nil end
    if utf8.len then
        local len = utf8.len(line)
        if not len then return nil end
        for i=1,len do
            local c = utf8_char(line,i)
            if c and not c:match("^[a-zA-Z0-9%s]$") then return c end
        end
    else
        for i=1,#line do
            local c = line:sub(i,i)
            if not c:match("^[a-zA-Z0-9%s]$") then return c end
        end
    end
    return nil
end

function string:split(sep)
    sep = sep or ":"
    local t = {}
    for v in self:gmatch("([^"..sep.."]+)") do table.insert(t,v) end
    return t
end

--==========================================================================
-- 解析文件路径（带索引）
--==========================================================================
local function resolve_file_path_custom(input_path, env)
    local idx_str = ""
    for i=#input_path,1,-1 do
        local c = input_path:sub(i,i)
        if c:match("%d") then idx_str=c..idx_str else break end
    end
    local sel = nil
    local term = input_path
    if #idx_str>0 and #input_path>#idx_str then
        sel = tonumber(idx_str)
        term = input_path:sub(1,#input_path-#idx_str)
    end
    local files = get_file_cache(env)
    local st = {}
    for w in term:gmatch("%S+") do if w~="" then table.insert(st,w:lower()) end end
    if #st == 0 then return nil, "请输入文件关键词" end
    local ms = fuzzy_search_files(st, files)
    table.sort(ms, function(a,b) return #a<#b end)
    if sel and sel>0 and sel<=#ms then ms={ms[sel]} end
    if #ms == 0 then return nil, "未找到文件: "..term end
    if #ms ~= 1 then return nil, "匹配"..#ms.."个文件，请加数字" end
    return ms[1]
end

local function show_file_candidates_custom(input, seg, env, term, first)
    local files = get_file_cache(env)
    local st = {}
    for w in term:gmatch("%S+") do if w~="" then table.insert(st,w:lower()) end end
    if #st == 0 then
        for i=1,math.min(10,#files) do yield(Candidate(input,seg.start,seg._end,files[i],"📄"..i)) end
        return
    end
    local ms = fuzzy_search_files(st, files)
    table.sort(ms, function(a,b) return #a<#b end)
    local idx_str = ""
    for i=#term,1,-1 do
        local c = term:sub(i,i)
        if c:match("%d") then idx_str=c..idx_str else break end
    end
    local sel = nil
    if #idx_str>0 and #term>#idx_str then
        sel = tonumber(idx_str)
        local t = term:sub(1,#term-#idx_str)
        st = {}
        for w in t:gmatch("%S+") do if w~="" then table.insert(st,w:lower()) end end
        ms = fuzzy_search_files(st, files)
        table.sort(ms, function(a,b) return #a<#b end)
        if sel and sel>0 and sel<=#ms then ms={ms[sel]} end
    end
    if #ms>0 then
        for i=1,math.min(10,#ms) do yield(Candidate(input,seg.start,seg._end,ms[i],"📄"..i)) end
    else
        yield(Candidate(input,seg.start,seg._end,"未找到匹配文件",""))
    end
end

--==========================================================================
-- 分组 / 集合操作：取重、合并、去重、分组
--==========================================================================
local function handleGroupOperation(input, seg, env)
    local pat = "^/wj_@(.-)&$"
    local fp = input:match(pat)
    if not fp then return false end
    local f, err = resolve_file_path_custom(fp, env)
    if not f then
        yield(Candidate(input, seg.start, seg._end, err, ""))
        return true
    end
    local user = rime_api.get_user_data_dir()
    local full = path_join(user, f)
    local cont, err = readFileContent(full)
    if not cont then
        yield(Candidate(input, seg.start, seg._end, "读文件失败: "..(err or ""), ""))
        return true
    end

    -- 1) 先按「行原文」分组：相同行全部聚在一起，保留所有重复
    local line_map = {}
    local unique_line_seq = {}
    for _, line in ipairs(cont) do
        if not line_map[line] then
            line_map[line] = {}
            table.insert(unique_line_seq, line)
        end
        table.insert(line_map[line], line)
    end

    -- 2) 再按「首特殊字符」对这些行组做顶层分组
    local char_groups = {}
    local char_order = {}
    local no_char_groups = {}

    for _, line in ipairs(unique_line_seq) do
        local group = line_map[line]
        local ch = get_first_target_char(line)
        if ch then
            if not char_groups[ch] then
                char_groups[ch] = {}
                table.insert(char_order, ch)
            end
            table.insert(char_groups[ch], group)
        else
            table.insert(no_char_groups, group)
        end
    end

    -- 3) 拼接最终输出
    local result = {}
    local group_count = 0

    -- 先输出有首特殊字符的各组
    for _, ch in ipairs(char_order) do
        group_count = group_count + 1
        for _, g in ipairs(char_groups[ch]) do
            for _, l in ipairs(g) do
                table.insert(result, l)
            end
        end
    end

    -- 再输出无首特殊字符的组（同样相同行聚在一起）
    for _, g in ipairs(no_char_groups) do
        for _, l in ipairs(g) do
            table.insert(result, l)
        end
    end

    -- 写入文件
    local name = f:match("([^/\\]+)$") or f
    local newname = name:gsub("%..+$", "") .. "_grouped.txt"
    local dir = f:match("^(.*)[/\\]") or ""
    local respath = path_join(user, dir, newname)
    local ok, err = writeFileContent(respath, result)
    if not ok then
        yield(Candidate(input, seg.start, seg._end, "写入失败: "..(err or ""), ""))
        return true
    end

    local short = respath:gsub("^"..user..path_sep, "")
    yield(Candidate(input, seg.start, seg._end,
        string.format("分组完成：%d行 → %d行，按首特殊字符分%d组（相同行已聚拢）",
            #cont, #result, group_count),
        "结果："..short))
    return true
end


local function handleSetOperations(input, seg, env)
    local filter_pat = "^/wj_@(.-)@(.-)@$"
    local merge_pat  = "^/wj%+@(.-)@(.-)@$"
    local dedup_pat  = "^/wj%-@(.-)@(.-)@$"
    local group_pat  = "^/wj_@(.-)&$"

    if input:match(group_pat) then return handleGroupOperation(input,seg,env) end

    local op, f1, f2
    if input:match(filter_pat) then
        op = "filter"
        f1,f2 = input:match(filter_pat)
    elseif input:match(merge_pat) then
        op = "merge"
        f1,f2 = input:match(merge_pat)
    elseif input:match(dedup_pat) then
        op = "dedup"
        f1,f2 = input:match(dedup_pat)
    else
        if input:match("^/wj_@") or input:match("^/wj%+@") or input:match("^/wj%-@") then
            local pref = input:sub(1,4)
            local parts = input:sub(5):split("@")
            if #parts == 0 then
                yield(Candidate(input,seg.start,seg._end,"输入文件1关键词 + @",""))
                return true
            elseif #parts == 1 then
                show_file_candidates_custom(input,seg,env,parts[1],true)
                return true
            elseif #parts == 2 then
                show_file_candidates_custom(input,seg,env,parts[2],false)
                return true
            end
        end
        return false
    end

    local rf1, err1 = resolve_file_path_custom(f1, env)
    if not rf1 then
        yield(Candidate(input,seg.start,seg._end,err1,""))
        return true
    end
    local rf2, err2 = resolve_file_path_custom(f2, env)
    if not rf2 then
        yield(Candidate(input,seg.start,seg._end,err2,""))
        return true
    end

    local user = rime_api.get_user_data_dir()
    local full1 = path_join(user, rf1)
    local full2 = path_join(user, rf2)
    local c1, err1 = readFileContent(full1)
    local c2, err2 = readFileContent(full2)
    if not c1 then
        yield(Candidate(input,seg.start,seg._end,"读文件1失败: "..(err1 or ""),""))
        return true
    end
    if not c2 then
        yield(Candidate(input,seg.start,seg._end,"读文件2失败: "..(err2 or ""),""))
        return true
    end

    local n1 = rf1:match("([^/\\]+)$") or rf1
    local n2 = rf2:match("([^/\\]+)$") or rf2
    local newname
    if op == "filter" then
        newname = n1:gsub("%..+$","").."_"..n2:gsub("%..+$","")..".txt"
    elseif op == "merge" then
        newname = n1:gsub("%..+$","").."+"..n2:gsub("%..+$","")..".txt"
    else
        newname = n1:gsub("%..+$","").."-"..n2:gsub("%..+$","")..".txt"
    end

    local dir = rf1:match("^(.*)[/\\]") or ""
    local respath = path_join(user, dir, newname)
    local res = {}
    local msg = ""

    if op == "filter" then
        local set2 = {}
        for _, l in ipairs(c2) do
            local b = get_target_chars(l)
            for c in pairs(b) do set2[c]=true end
        end
        for _, l in ipairs(c1) do
            local b = get_target_chars(l)
            local ok = false
            for c in pairs(b) do if set2[c] then ok=true break end end
            if ok then table.insert(res,l) end
        end
        msg = string.format("取重：%d行→%d行", #c1, #res)

    elseif op == "merge" then
        local map2 = {}
        for _, l in ipairs(c2) do
            local cl = l:gsub("[\r\n]"," ")
            local b = get_target_chars(cl)
            for c in pairs(b) do
                if not map2[c] then map2[c]={} end
                map2[c][cl] = true
            end
        end
        local multi = 0
        local total = 0
        for _, l1 in ipairs(c1) do
            local cl1 = l1:gsub("[\r\n]"," ")
            local b = get_target_chars(cl1)
            local tmp = {}
            for c in pairs(b) do
                if map2[c] then for ll in pairs(map2[c]) do tmp[ll]=true end end
            end
            local arr = {}
            for ll in pairs(tmp) do table.insert(arr,ll) end
            local cnt = #arr
            if cnt>0 then
                total=total+cnt
                if cnt>=2 then multi=multi+1 end
                table.insert(res, cl1.."\t"..table.concat(arr,"\t"))
            end
        end
        msg = string.format("合并：%d+%d→%d行（多匹配%d）",#c1,#c2,#res,multi)

    else -- dedup
        local set2 = {}
        for _, l in ipairs(c2) do
            local b = get_target_chars(l)
            for c in pairs(b) do set2[c]=true end
        end
        for _, l in ipairs(c1) do
            local b = get_target_chars(l)
            local has = false
            if next(b) then
                for c in pairs(b) do if set2[c] then has=true break end end
            end
            if not has then table.insert(res,l) end
        end
        msg = string.format("去重：%d→%d行（移除%d）",#c1,#res,#c1-#res)
    end

    local ok, err = writeFileContent(respath, res)
    if not ok then
        yield(Candidate(input,seg.start,seg._end,"写入失败: "..(err or ""),""))
        return true
    end

    local short = respath:gsub("^"..user..path_sep, "")
    yield(Candidate(input,seg.start,seg._end, msg, "结果："..short))
    return true
end

--==========================================================================
-- 入口函数（固定你指定的初始提示）
--==========================================================================
function T.func(input, seg, env)
  local comp = env.engine.context.composition
  if comp:empty() then return end
  local seg = comp:back()

  -- 刚输入 /wj 时，显示你固定的全套提示
  if input == "/wj" then
    yield(Candidate(input, 0, 0, "文件名@内容 检索文件内容", " "))
    yield(Candidate(input, 0, 0, "文件名2@内容3/ 选择第2个文件候选项，选择第3个内容候选项", " "))
    yield(Candidate(input, 0, 0, "文件名@/ 合并输出整个文件", " "))
    yield(Candidate(input, 0, 0, "文件名@内容/被替换/替换/ 修改内容（支持\\n换行）", " "))
    yield(Candidate(input, 0, 0, "文件名@//新内容/ 整体替换文件内容（覆盖写入）", " "))
    yield(Candidate(input, 0, 0, "new\"文件夹/文件名\" 创建文件", " "))
    yield(Candidate(input, 0, 0, "del\"文件夹/文件名\" 删除文件", " "))
    yield(Candidate(input, 0, 0, "+&原文件&目标路径& 复制文件", " "))
    yield(Candidate(input, 0, 0, "&原文件&目标路径& 移动文件", " "))
    -- 集合操作提示
    yield(Candidate(input, 0, 0, "_@文件1@文件2@ 取重（保留共同字符行）", " "))
    yield(Candidate(input, 0, 0, "+@文件1@文件2@ 合并（拼接关联行）", " "))
    yield(Candidate(input, 0, 0, "-@文件1@文件2@ 去重（移除共同字符行）", " "))
    yield(Candidate(input, 0, 0, "_@文件& 分组（按首特殊字符分组）", " "))

    seg.tags.calculating = true
    return
  end

  -- 集合操作（去重/合并/分组）
  if handleSetOperations(input, seg, env) then
    seg.tags.calculating = true
    return
  end

  -- 文件复制/移动
  if handleFileCopyMove(input, seg, env) then
    seg.tags.calculating = true
    return
  end

  -- 文件内容读取/查询/替换
  if handleFileRequest(input, seg, env) then
    seg.tags.calculating = true
    return
  end

  -- 文件系统（新建/删除）
  if handleFileSystemRequest(input, seg, env) then
    seg.tags.calculating = true
    return
  end

  -- 模糊文件搜索
  if fuzzy_file_search(input, seg, env) then
    seg.tags.calculating = true
    return
  end
end

return T
