-- 2026-02-19 15:51:32
local T = {prefix = "/wj"}
local regex_enabled = true
local regex_api = {
    enable  = function() regex_enabled = true end,
    disable = function() regex_enabled = false end,
    is_enabled = function() return regex_enabled end
}
local path_sep = package.config:sub(1,1)

local function startsWith(str, start) return str:sub(1, #start) == start end
local function escape_lua_pattern(s) return (s:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")) end

-- 公共函数：解析后缀数字索引
-- 返回：索引值（数字或nil）和去掉索引后的字符串
local function parse_suffix_index(input_str)
    local index_str = ""
    for i = #input_str, 1, -1 do
        local c = input_str:sub(i, i)
        if c:match("%d") then
            index_str = c .. index_str
        else
            break
        end
    end
    local has_index = #index_str > 0 and #input_str > #index_str
    local index = has_index and tonumber(index_str) or nil
    local term = has_index and input_str:sub(1, #input_str - #index_str) or input_str
    return index, term
end

local function readFileContent(path)
    local file = io.open(path, "r")
    if not file then return nil, "文件不存在" end
    local content = {}
    for line in file:lines() do table.insert(content, line) end
    file:close()
    return content
end

local function writeFileContent(path, content)
    local file = io.open(path, "w")
    if not file then return false, "无法写入文件" end
    for i, line in ipairs(content) do
        file:write(line .. (i < #content and "\n" or ""))
    end
    file:close()
    return true
end

local function path_join(...)
    local res, parts = "", {...}
    for i, part in ipairs(parts) do
        if i > 1 then 
            if res:sub(-1) ~= path_sep then res = res .. path_sep end
        end
        res = res .. part:gsub("^["..path_sep.."]", "")
    end
    return res
end

local function scan_fs(user_dir, is_dir, pattern)
    local search_filter = ""
    if pattern and pattern ~= "" then
        search_filter = path_sep == '\\' and ("*" .. pattern .. "*") or ("*" .. pattern .. "*")
    else
        search_filter = "*"
    end

    local cmd
    if path_sep == '\\' then
        cmd = string.format('dir /b /s /a%s "%s"', is_dir and "d" or "-d", path_join(user_dir, search_filter))
    else
        cmd = string.format('find "%s" -type %s -name "%s"', user_dir, is_dir and "d" or "f", search_filter)
    end

    local handle, res = io.popen(cmd), {}
    if not handle then return res end
    local prefix = escape_lua_pattern(user_dir .. path_sep)
    for path in handle:lines() do
        local rel = path:gsub(prefix, "")
        if not is_dir or rel ~= "" then table.insert(res, rel) end
    end
    handle:close()
    return res
end

-- 修改：取消全量缓存，改为按需获取
local function get_file_cache(env, first_term)
    local user_dir = rime_api.get_user_data_dir()
    return scan_fs(user_dir, false, first_term)
end

local function get_dir_cache(env, first_term)
    local user_dir = rime_api.get_user_data_dir()
    return scan_fs(user_dir, true, first_term)
end

function T.init(env)
end

local function fuzzy_search_files(search_terms, files)
    local results = {}
    for _, file in ipairs(files) do
        local lower_file, ok = file:lower(), true
        -- 这里的 search_terms[1] 已经在系统层过滤过了，这里做全量校验（包括后续关键词）
        for _, term in ipairs(search_terms) do
            if not lower_file:find(term, 1, true) then ok = false; break end
        end
        if ok then table.insert(results, file) end
    end
    return results
end

-- 公共函数：综合搜索与过滤
-- 返回：过滤后的结果列表, 去掉索引的关键词字符串, 索引值, 原始排序后的结果全集
local function search_and_filter_files(input_str, env, is_dir)
    local sel, term = parse_suffix_index(input_str)
    local st = {}
    for w in term:gmatch("%S+") do table.insert(st, w:lower()) end
    if #st == 0 then return {}, term, sel, {} end
    
    local pool = is_dir and get_dir_cache(env, st[1]) or get_file_cache(env, st[1])
    local ms = fuzzy_search_files(st, pool)
    table.sort(ms, function(a, b) return #a < #b end)
    
    local filtered = ms
    if sel and sel > 0 and sel <= #ms then
        filtered = {ms[sel]}
    end
    return filtered, term, sel, ms
end

local function ensure_directory_exists(full_dir_path)
    local cmd = path_sep == '\\' and ('if not exist "'..full_dir_path..'" mkdir "'..full_dir_path..'"') or ('mkdir -p "'..full_dir_path..'"')
    return os.execute(cmd)
end

local function unescape_string(str)
    return str:gsub("\\(.)", {n="\n", ["\\"]="\\", r="\r", t="\t"})
end

local function escape_for_display(str)
    return str:gsub("\\", "\\\\"):gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t")
end

local function fuzzy_file_search(input, seg, env)
    local total_pattern = input:match("^/wj(.*)$")
    if not total_pattern then return false end
    
    local filtered, pattern, selection_index, raw_results = search_and_filter_files(total_pattern, env, false)
    if #pattern == 0 then return false end
    
    if #raw_results == 0 then yield(Candidate(input, seg.start, seg._end, "未找到匹配文件", "")); return true end
    
    if selection_index and selection_index > 0 and selection_index <= #raw_results then
        yield(Candidate(input, seg.start, seg._end, raw_results[selection_index], "📁 文件(选择第"..selection_index.."个)"))
        return true
    end
    
    for i, file in ipairs(raw_results) do yield(Candidate(input, seg.start, seg._end, file, "📁"..i)) end
    return true
end

local function handleFileSystemRequest(input, seg, env)
    local del_path = input:match("^/wjdel\"(.-)\"?$")
    if del_path then
        local res, term, sel, raw = search_and_filter_files(del_path, env, false)
        if #term == 0 then yield(Candidate(input, seg.start, seg._end, "请输入要删除的文件关键词", "")); return true end
        
        if sel and (sel <= 0 or sel > #raw) then
            yield(Candidate(input, seg.start, seg._end, "索引无效 1-"..#raw, "")); return true
        end
        
        if #res == 0 then yield(Candidate(input, seg.start, seg._end, "未找到匹配文件: "..term, "")); return true end
        
        if input:match("^/wjdel\".+\"$") then
            local target = res[1]
            local ok, err = os.remove(path_join(rime_api.get_user_data_dir(), target))
            yield(Candidate(input, seg.start, seg._end, ok and ("删除成功: "..target) or ("删除失败: "..target.." "..(err or "")), ""))
            return true
        end
        for i, f in ipairs(res) do yield(Candidate(input, seg.start, seg._end, f, "📁"..i)) end
        return true
    end

    local create_path = input:match("^/wjnew\"(.-)\"?$")
    if create_path and not input:match("^/wjnew\".+\"$") then
        local has_slash = create_path:find("/") ~= nil
        local pre, post = create_path:match("^(.-)/(.*)$")
        pre = pre or create_path
        
        local res, term, sel = search_and_filter_files(pre, env, true)
        local sel_dir = (sel and #res > 0) and res[1] or nil
        
        if #res > 0 then
            if has_slash then
                yield(Candidate(input, seg.start, seg._end, (sel_dir or pre).."/"..(post or ""), sel_dir and "在"..sel_dir.."中创建" or "新建文件夹并创建文件"))
            else
                for i, d in ipairs(res) do yield(Candidate(input, seg.start, seg._end, d, "📂"..i)) end
                yield(Candidate(input, seg.start, seg._end, pre, "使用输入名"))
            end
        else yield(Candidate(input, seg.start, seg._end, create_path, "创建路径")) end
        return true
    end

    local create_target = input:match("^/wj\"(.*)\"$") or input:match("^/wjnew\"(.*)\"$")
    if create_target then
        local is_dir = create_target:sub(-1) == "/" or create_target:sub(-1) == "\\"
        local dir_part, file_part = create_target:match("^(.-)/(.*)$")
        local actual_dir = dir_part or create_target
        
        local res, resolved_dir, sel = search_and_filter_files(actual_dir, env, true)
        local use_input = not (sel and #res > 0)
        if not use_input then resolved_dir = res[1] end
        
        local real_p = (dir_part and file_part) and (use_input and (dir_part.."/"..file_part) or (resolved_dir.."/"..file_part)) or (use_input and create_target or resolved_dir)
        local full = path_join(rime_api.get_user_data_dir(), real_p)
        if is_dir then
            local cmd = path_sep == '\\' and ('mkdir "'..full..'"') or ('mkdir -p "'..full..'"')
            local ok = os.execute(cmd)
            yield(Candidate(input, seg.start, seg._end, ok and ("文件夹创建成功: "..real_p) or ("文件夹创建失败: "..real_p), ""))
        else
            local pdir = real_p:match("^(.*)[/\\][^/\\]*$")
            if pdir then ensure_directory_exists(path_join(rime_api.get_user_data_dir(), pdir)) end
            local f = io.open(full, "w")
            if f then f:close(); yield(Candidate(input, seg.start, seg._end, "文件创建成功: "..real_p, ""))
            else yield(Candidate(input, seg.start, seg._end, "文件创建失败: "..real_p, "")) end
        end
        return true
    end
    return false
end

local function handleReplaceRequest(input, seg, env)
    local fpath, newc = input:match("^/wj(.-)@//(.*)/$")
    if not fpath then fpath, newc = input:match("^/wj(.-)@//(.*)$") end
    if fpath then
        local ms, fterm, sel = search_and_filter_files(fpath, env, false)
        if #ms == 0 then yield(Candidate(input, seg.start, seg._end, "未找到匹配文件", "")); return true end
        if #ms ~= 1 then yield(Candidate(input, seg.start, seg._end, "匹配多个文件："..#ms, "加数字指定")); return true end
        local full = path_join(rime_api.get_user_data_dir(), ms[1])
        local content = readFileContent(full)
        if not input:match("^/wj(.-)@//(.*)/$") then
            local disp, prev = escape_for_display(newc or ""), ""
            if content and #content>0 then
                for i=1, math.min(3, #content) do prev = prev .. (i>1 and " \\n " or "") .. escape_for_display(content[i]) end
                if #content>3 then prev=prev.."..." end
            else prev = "(空文件)" end
            yield(Candidate(input, seg.start, seg._end, "将覆盖为: "..disp, "原内容: "..prev))
            return true
        end
        newc = unescape_string(newc or "")
        local lines = {}
        for l in newc:gmatch("[^\n]+") do table.insert(lines, l) end
        if #lines == 0 then table.insert(lines, "") end
        local ok, err = writeFileContent(full, lines)
        if not ok then yield(Candidate(input, seg.start, seg._end, "写入失败: "..(err or ""), "")); return true end
        yield(Candidate(input, seg.start, seg._end, "整体替换成功", (content and #content or 0).."行 → "..#lines.."行"))
        return true
    end

    local fp, k, o, n = input:match("^/wj(.-)@([^/]+)/([^/]+)/([^/]*)/$")
    if not fp then
        fp, k, o = input:match("^/wj(.-)@([^/]+)/([^/]+)//$")
        if fp then n="" else 
            fp, k, o = input:match("^/wj(.-)@([^/]+)/([^/]*)$")
            if not fp then fp, k, o, n = input:match("^/wj(.-)@([^/]+)/([^/]+)/([^/]*)$") end
        end
    end
    if not fp or not k then return false end
    
    local ms, f_term = search_and_filter_files(fp, env, false)
    local l_sel, l_term = parse_suffix_index(k)
    
    if #ms ~= 1 then yield(Candidate(input, seg.start, seg._end, #ms==0 and "未找到文件" or "匹配多个文件："..#ms, #ms==0 and "" or "加数字指定")); return true end
    local full = path_join(rime_api.get_user_data_dir(), ms[1])
    local content, err = readFileContent(full)
    if not content then yield(Candidate(input, seg.start, seg._end, "读文件失败: "..(err or ""), "")); return true end
    local matches = {}
    for i, line in ipairs(content) do if line:find(l_term, 1, true) then table.insert(matches, {line=line, idx=i}) end end
    if #matches == 0 then yield(Candidate(input, seg.start, seg._end, "无匹配关键词行", "关键词: "..l_term)); return true end
    local sel_lines = (l_sel and l_sel>0 and l_sel<=#matches) and {matches[l_sel]} or matches
    if #sel_lines ~= 1 then yield(Candidate(input, seg.start, seg._end, #sel_lines==0 and "行索引无效 1-"..#matches or "匹配"..#sel_lines.."行，请加行号", "")); return true end
    local info = sel_lines[1]
    if input:match("^/wj[^@]*@[^/]+/[^/]+/[^/]*/$") then
        local nl = info.line:gsub(o, unescape_string(n or ""), 1)
        if info.line == nl then yield(Candidate(input, seg.start, seg._end, "未找到可替换内容", "")); return true end
        content[info.idx] = nl
        local ok, err = writeFileContent(full, content)
        if not ok then yield(Candidate(input, seg.start, seg._end, "写入失败: "..(err or ""), "")); return true end
        local disp = nl:gsub("\n","\\n")
        yield(Candidate(input, seg.start, seg._end, (n=="" and "删除成功: " or "替换成功: ")..(#disp>40 and disp:sub(1,37).."..." or disp), "原行: "..info.line:sub(1,40)))
        return true
    else
        local tip = info.line
        if o and o~="" then
            tip = (#tip>20 and tip:sub(1,17).."..." or tip).." → 待替换: "..o
            if n ~= nil then
                local dn = escape_for_display(n)
                tip = tip .. (n=="" and " ➔ 删除（输/确认）" or " ➔ 新内容: " .. (#dn>20 and dn:sub(1,17).."..." or dn))
            else tip = tip.." ➔ 输入替换内容" end
        else tip = tip.." → 输入待替换内容" end
        if #matches>1 and not l_sel then tip = tip.."（共"..#matches.."行匹配，加行号）" end
        yield(Candidate(input, seg.start, seg._end, tip, "第"..info.idx.."行"))
        return true
    end
end

local function handleFileRequest(input, seg, env)
    if handleReplaceRequest(input, seg, env) then return true end
    local m_file = input:match("^/wj(.-)@/$")
    local q_file, q = input:match("^/wj(.-)@([^/]+)/?$")
    local n_file = input:match("^/wj(.-)@$")
    local target = m_file or q_file or n_file
    if not target then return false end
    
    local ms, term = search_and_filter_files(target, env, false)
    local full = path_join(rime_api.get_user_data_dir(), #ms==1 and ms[1] or term)
    local content, err = readFileContent(full)
    if not content then yield(Candidate(input, seg.start, seg._end, "读文件失败: "..(err or ""), "")); return true end
    if m_file then yield(Candidate(input, seg.start, seg._end, table.concat(content, "\n"), "全文合并")); return true end
    if q and q~="" then
        -- 使用公共函数解析后缀数字索引
        local l_sel, l_q = parse_suffix_index(q)
        local hits = {}
        for i, line in ipairs(content) do if not line:match("^%s*$") and line:find(l_q,1,true) then table.insert(hits, {line=line, n=i}) end end
        if #hits == 0 then yield(Candidate(input, seg.start, seg._end, "无匹配内容", "")); return true end
        if l_sel and l_sel>0 and l_sel<=#hits then yield(Candidate(input, seg.start, seg._end, hits[l_sel].line, "第"..hits[l_sel].n.."行(选中)"))
        else for i, d in ipairs(hits) do yield(Candidate(input, seg.start, seg._end, d.line, "("..i..")第"..d.n.."行: "..d.line:sub(1,20))) end end
        return true
    end
    for i, line in ipairs(content) do if not line:match("^%s*$") then yield(Candidate(input, seg.start, seg._end, line, "第"..i.."行")) end end
    return true
end

local function handleFileCopyMove(input, seg, env)
    if input == "/wj&" or input == "/wj+&" then
        yield(Candidate(input, seg.start, seg._end, "/wj+&源&目标& 复制", "格式"))
        yield(Candidate(input, seg.start, seg._end, "/wj&源&目标& 移动", "格式"))
        return true
    end
    if input:match("^/wj[%+]?&$") then yield(Candidate(input, seg.start, seg._end, "请输入源文件关键词", "")); return true end
    local is_move = input:sub(1,4) == "/wj&"
    local src_raw, dst_raw = input:match("^/wj[%+]?&(.-)&(.-)&$")
    if src_raw and dst_raw then
        local s_ms, s_t = search_and_filter_files(src_raw, env, false)
        if #s_ms ~= 1 then 
            yield(Candidate(input, seg.start, seg._end, #s_ms==0 and ("未找到源文件: "..s_t) or ("匹配"..#s_ms.."个源文件，请加数字"), ""))
            for i,f in ipairs(s_ms) do yield(Candidate(input, seg.start, seg._end,f,"📄"..i)) end
            return true
        end
        local d_ms, d_t = search_and_filter_files(dst_raw, env, true)
        local user, r_src = rime_api.get_user_data_dir(), s_ms[1]
        local fname = r_src:match("[^/\\]+$") or r_src
        local f_dst, t_dir, new_dir = "", "", false
        if #d_ms == 1 then f_dst, t_dir = path_join(user, d_ms[1], fname), path_join(user, d_ms[1])
        else new_dir = true; t_dir = path_join(user, d_t); if t_dir:sub(-1)~=path_sep then t_dir=t_dir..path_sep end; f_dst = path_join(t_dir, fname) end
        if new_dir then ensure_directory_exists(t_dir) end
        local cont, err = readFileContent(path_join(user, r_src))
        if not cont then yield(Candidate(input, seg.start, seg._end, "源读取失败: "..(err or ""), "")); return true end
        local ok, err = writeFileContent(f_dst, cont)
        if not ok then yield(Candidate(input, seg.start, seg._end, "写入失败: "..(err or ""), "")); return true end
        if is_move then os.remove(path_join(user, r_src)) end
        yield(Candidate(input, seg.start, seg._end, (is_move and "移动" or "复制").."成功: "..r_src.." → "..(#d_ms==1 and d_ms[1] or d_t)..(new_dir and "（已新建目录）" or ""), ""))
        return true
    end
    return false
end

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
        if not c:match("^[a-zA-Z0-9%s]$") then cur = cur..c
        else if cur~="" then blocks[cur]=true; cur="" end end
    end
    if cur~="" then blocks[cur]=true end
    return blocks
end

local function get_first_target_char(line)
    if not line or line=="" then return nil end
    local len = utf8.len and utf8.len(line) or #line
    if not len then return nil end
    for i=1,len do
        local c = utf8_char(line,i)
        if c and not c:match("^[a-zA-Z0-9%s]$") then return c end
    end
    return nil
end

function string:split(sep)
    local t = {}
    for v in self:gmatch("([^"..(sep or ":").."]+)") do table.insert(t,v) end
    return t
end

local function resolve_file_path_custom(input_path, env)
    local ms, term = search_and_filter_files(input_path, env, false)
    if #term == 0 then return nil, "请输入文件关键词" end
    if #ms ~= 1 then return nil, #ms==0 and ("未找到文件: "..term) or ("匹配"..#ms.."个文件，请加数字") end
    return ms[1]
end

local function show_file_candidates_custom(input, seg, env, term, first)
    local ms = search_and_filter_files(term, env, false)
    if #ms>0 then for i=1,#ms do yield(Candidate(input,seg.start,seg._end,ms[i],"📄"..i)) end
    else yield(Candidate(input,seg.start,seg._end,"未找到匹配文件","")) end
end

local function handleGroupOperation(input, seg, env)
    local fp = input:match("^/wj_@(.-)&$")
    if not fp then return false end
    local f, err = resolve_file_path_custom(fp, env)
    if not f then yield(Candidate(input, seg.start, seg._end, err, "")); return true end
    local user = rime_api.get_user_data_dir()
    local cont, cerr = readFileContent(path_join(user, f))
    if not cont then yield(Candidate(input, seg.start, seg._end, "读文件失败: "..(cerr or ""), "")); return true end
    local line_map, seq, c_groups, c_order, no_char = {}, {}, {}, {}, {}
    for _, line in ipairs(cont) do
        if not line_map[line] then line_map[line] = {}; table.insert(seq, line) end
        table.insert(line_map[line], line)
    end
    for _, line in ipairs(seq) do
        local group, ch = line_map[line], get_first_target_char(line)
        if ch then
            if not c_groups[ch] then c_groups[ch] = {}; table.insert(c_order, ch) end
            table.insert(c_groups[ch], group)
        else table.insert(no_char, group) end
    end
    local res, g_count = {}, 0
    for _, ch in ipairs(c_order) do
        g_count = g_count + 1
        for _, g in ipairs(c_groups[ch]) do for _, l in ipairs(g) do table.insert(res, l) end end
    end
    for _, g in ipairs(no_char) do for _, l in ipairs(g) do table.insert(res, l) end end
    local n = f:match("([^/\\]+)$") or f
    local res_p = path_join(user, f:match("^(.*)[/\\]") or "", n:gsub("%..+$", "") .. "_grouped.txt")
    local ok, werr = writeFileContent(res_p, res)
    if not ok then yield(Candidate(input, seg.start, seg._end, "写入失败: "..(werr or ""), "")); return true end
    yield(Candidate(input, seg.start, seg._end, string.format("分组完成：%d行 → %d行，按首特殊字符分%d组", #cont, #res, g_count), "结果："..res_p:gsub("^"..user..path_sep, "")))
    return true
end

local function handleDuplicateCodeOperation(input, seg, env)
    if input == "/wj_&" then
        yield(Candidate(input, seg.start, seg._end, "/wj_&文件名& 重码合并(用&拼接)", "格式")); return true
    end
    local fp = input:match("^/wj_&(.-)&$")
    if not fp then 
        local partial = input:match("^/wj_&(.*)$")
        if partial then show_file_candidates_custom(input, seg, env, partial, true); return true end
        return false 
    end
    local f, err = resolve_file_path_custom(fp, env)
    if not f then yield(Candidate(input, seg.start, seg._end, err, "")); return true end   
    local user = rime_api.get_user_data_dir()
    local cont, cerr = readFileContent(path_join(user, f))
    if not cont then yield(Candidate(input, seg.start, seg._end, "读文件失败: "..(cerr or ""), "")); return true end
    local code_map, code_order, line_counter = {}, {}, 0
    for _, line in ipairs(cont) do
        line_counter = line_counter + 1
        local clean = line:gsub("[\r\n]+$", "")        
        if not clean:match("^%s*$") and not clean:match("^#") then
            local parts = {}
            for v in clean:gmatch("[^\t]+") do table.insert(parts, v) end          
            if #parts >= 2 then
                local code, weight = parts[2], tonumber(parts[3]) or 0
                if not code_map[code] then code_map[code] = {}; table.insert(code_order, code) end
                table.insert(code_map[code], {text = clean, weight = weight, index = line_counter})
            end
        end
    end
    local res, dup_count = {}, 0
    for _, code in ipairs(code_order) do
        local group = code_map[code]
        if #group > 1 then
            table.sort(group, function(a, b) return a.weight ~= b.weight and a.weight > b.weight or a.index < b.index end)
            local sorted = {}
            for _, item in ipairs(group) do table.insert(sorted, item.text) end          
            table.insert(res, table.concat(sorted, "&")); dup_count = dup_count + 1
        end
    end   
    local n = f:match("([^/\\]+)$") or f
    local res_p = path_join(user, f:match("^(.*)[/\\]") or "", n:gsub("%..+$", "") .. "_dups.txt")
    local ok, werr = writeFileContent(res_p, res)    
    if not ok then yield(Candidate(input, seg.start, seg._end, "写入失败: "..(werr or ""), "")); return true end
    local ps = package.config:sub(1,1)
    yield(Candidate(input, seg.start, seg._end, string.format("合并完成：%d组重码", dup_count), 
        "文件："..res_p:gsub("^"..user:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%1")..ps, "")))
    return true
end

local function handleSetOperations(input, seg, env)
    local f_pat, m_pat, d_pat, g_pat = "^/wj_@(.-)@(.-)@$", "^/wj%+@(.-)@(.-)@$", "^/wj%-@(.-)@(.-)@$", "^/wj_@(.-)&$"
    if input:match(g_pat) then return handleGroupOperation(input,seg,env) end
    local op, f1, f2
    if input:match(f_pat) then op, f1, f2 = "filter", input:match(f_pat)
    elseif input:match(m_pat) then op, f1, f2 = "merge", input:match(m_pat)
    elseif input:match(d_pat) then op, f1, f2 = "dedup", input:match(d_pat)
    elseif input:match("^/wj[_%+%-]@") then
        local parts = input:sub(5):split("@")
        if #parts == 0 then yield(Candidate(input,seg.start,seg._end,"输入文件1关键词 + @",""))
        elseif #parts == 1 then show_file_candidates_custom(input,seg,env,parts[1],true)
        elseif #parts == 2 then show_file_candidates_custom(input,seg,env,parts[2],false) end
        return true
    else return false end
    local rf1, e1 = resolve_file_path_custom(f1, env)
    local rf2, e2 = resolve_file_path_custom(f2, env)
    if not rf1 or not rf2 then yield(Candidate(input,seg.start,seg._end,e1 or e2,"")); return true end
    local user = rime_api.get_user_data_dir()
    local c1, e1r = readFileContent(path_join(user, rf1))
    local c2, e2r = readFileContent(path_join(user, rf2))
    if not c1 or not c2 then yield(Candidate(input,seg.start,seg._end,"读文件失败: "..(e1r or e2r),"")); return true end
    local n1, n2 = rf1:match("([^/\\]+)$") or rf1, rf2:match("([^/\\]+)$") or rf2
    local op_map = {filter="_", merge="+", dedup="-"}
    local res_p = path_join(user, rf1:match("^(.*)[/\\]") or "", n1:gsub("%..+$","")..op_map[op]..n2:gsub("%..+$","")..".txt")
    local res, msg = {}, ""
    if op == "filter" then
        local s2 = {}
        for _, l in ipairs(c2) do for c in pairs(get_target_chars(l)) do s2[c]=true end end
        for _, l in ipairs(c1) do 
            local b, ok = get_target_chars(l), false
            for c in pairs(b) do if s2[c] then ok=true; break end end
            if ok then table.insert(res,l) end
        end
        msg = string.format("取重：%d行→%d行", #c1, #res)
    elseif op == "merge" then
        local map2 = {}
        for _, l in ipairs(c2) do
            local cl = l:gsub("[\r\n]"," ")
            for c in pairs(get_target_chars(cl)) do map2[c] = map2[c] or {}; map2[c][cl] = true end
        end
        for _, l1 in ipairs(c1) do
            local cl1, tmp = l1:gsub("[\r\n]"," "), {}
            for c in pairs(get_target_chars(cl1)) do if map2[c] then for ll in pairs(map2[c]) do tmp[ll]=true end end end
            local arr = {}
            for ll in pairs(tmp) do table.insert(arr,ll) end
            if #arr>0 then table.insert(res, cl1.."\t"..table.concat(arr,"\t")) end
        end
        msg = string.format("合并：%d+%d→%d行",#c1,#c2,#res)
    else -- dedup
        local s2 = {}
        for _, l in ipairs(c2) do for c in pairs(get_target_chars(l)) do s2[c]=true end end
        for _, l in ipairs(c1) do
            local b, has = get_target_chars(l), false
            for c in pairs(b) do if s2[c] then has=true; break end end
            if not has then table.insert(res,l) end
        end
        msg = string.format("去重：%d→%d行",#c1,#res)
    end
    local ok, werr = writeFileContent(res_p, res)
    if not ok then yield(Candidate(input,seg.start,seg._end,"写入失败: "..(werr or ""),"")); return true end
    yield(Candidate(input,seg.start,seg._end, msg, "结果："..res_p:gsub("^"..user..path_sep, "")))
    return true
end

function T.func(input, seg, env)
    local comp = env.engine.context.composition
    if comp:empty() then return end
    seg = comp:back()
    if input == "/wj" then
        local hints = {
            {"文件名@内容 检索文件内容", " "}, {"文件名2@内容3/ 选择第2个文件候选项", " "}, {"文件名@/ 合并输出整个文件", " "}, {"文件名@内容/被替换/替换/ 修改内容", " "}, {"文件名@//新内容/ 整体替换文件内容", " "}, 
            {"new\"文件夹/文件名\" 创建文件", " "}, {"del\"文件夹/文件名\" 删除文件", " "}, {"+&原文件&目标路径& 复制文件", " "}, {"&原文件&目标路径& 移动文件", " "},
            {"_@文件1@文件2@ 取重（保留共同字符行）", " "}, {"+@文件1@文件2@ 合并（拼接关联行）", " "}, {"-@文件1@文件2@ 去重（移除共同字符行）", " "},{"_@文件& 分组（按首特殊字符分组）", " "}, {"_&文件名& 重码合并", " "}
        }
        for _, h in ipairs(hints) do yield(Candidate(input, 0, 0, h[1], h[2])) end
        seg.tags.calculating = true; return
    end
    if handleSetOperations(input, seg, env) or 
       handleDuplicateCodeOperation(input, seg, env) or
       handleFileCopyMove(input, seg, env) or 
       handleFileRequest(input, seg, env) or 
       handleFileSystemRequest(input, seg, env) or 
       fuzzy_file_search(input, seg, env) then
        seg.tags.calculating = true
    end
end
return T
