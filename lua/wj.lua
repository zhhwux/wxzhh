local T={prefix="/wj"}
local regex_enabled=true
local regex_api={enable=function()regex_enabled=true end,disable=function()regex_enabled=false end,is_enabled=function()return regex_enabled end}
local path_sep=package.config:sub(1,1)

-- 基础辅助函数
local function startsWith(str,start)return str:sub(1,#start)==start end
local function escape_lua_pattern(s)return(s:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])","%%%1"))end
local function yield_cand(input,seg,text,comment)yield(Candidate(input,seg.start,seg._end,text,comment or""))end

-- 解析后缀数字索引
local function parse_suffix_idx(input_str)
    local index_str=""
    for i=#input_str,1,-1 do
        local c=input_str:sub(i,i)
        if c:match("%d")then index_str=c..index_str else break end
    end
    local has_index=#index_str>0 and #input_str>#index_str
    local index=has_index and tonumber(index_str)or nil
    local term=has_index and input_str:sub(1,#input_str-#index_str)or input_str
    return index,term
end

local function read_file(path)
    local file=io.open(path,"r")
    if not file then return nil,"文件不存在" end
    local content={}
    for line in file:lines()do table.insert(content,line)end
    file:close()
    return content
end

local function write_file(path,content)
    local file=io.open(path,"w")
    if not file then return false,"无法写入文件" end
    for i,line in ipairs(content)do file:write(line..(i<#content and"\n"or""))end
    file:close()
    return true
end

local function path_join(...)
    local res,parts="",{...}
    for i,part in ipairs(parts)do
        if i>1 and res:sub(-1)~=path_sep then res=res..path_sep end
        res=res..part:gsub("^["..path_sep.."]","")
    end
    return res
end

local function scan_fs(user_dir,is_dir,pattern)
    local search_filter=pattern and pattern~=""and"*"..pattern.."*"or"*"
    local cmd
    if path_sep=='\\'then
        cmd=string.format('dir /b /s /a%s "%s"',is_dir and"d"or"-d",path_join(user_dir,search_filter))
    else
        cmd=string.format('find "%s" -type %s -name "%s"',user_dir,is_dir and"d"or"f",search_filter)
    end
    local handle,res=io.popen(cmd),{}
    if not handle then return res end
    local prefix=escape_lua_pattern(user_dir..path_sep)
    for path in handle:lines()do
        local rel=path:gsub(prefix,"")
        if not is_dir or rel~=""then table.insert(res,rel)end
    end
    handle:close()
    return res
end

function T.init(env)end

local function fuzzy_search(search_terms,files)
    local results={}
    for _,file in ipairs(files)do
        local lower_file,ok=file:lower(),true
        for _,term in ipairs(search_terms)do
            if not lower_file:find(term,1,true)then ok=false;break end
        end
        if ok then table.insert(results,file)end
    end
    return results
end

-- 综合搜索与过滤
local function search_filter(input_str,env,is_dir)
    local sel,term=parse_suffix_idx(input_str)
    local st={}
    for w in term:gmatch("%S+")do table.insert(st,w:lower())end
    if #st==0 then return{},term,sel,{}end
    
    local pool=scan_fs(rime_api.get_user_data_dir(),is_dir,st[1])
    local ms=fuzzy_search(st,pool)
    table.sort(ms,function(a,b)return #a<#b end)
    
    local filtered=ms
    if sel and sel>0 and sel<=#ms then filtered={ms[sel]}end
    return filtered,term,sel,ms
end

local function ensure_dir(full_dir_path)
    local cmd=path_sep=='\\'and('if not exist "'..full_dir_path..'" mkdir "'..full_dir_path..'"')or('mkdir -p "'..full_dir_path..'"')
    return os.execute(cmd)
end

local function unescape(str)return str:gsub("\\(.)",{n="\n",["\\"]="\\",r="\r",t="\t"})end
local function escape_disp(str)return str:gsub("\\","\\\\"):gsub("\n","\\n"):gsub("\r","\\r"):gsub("\t","\\t")end

local function fuzzy_file_search(input,seg,env)
    local total_pattern=input:match("^/wj(.*)$")
    if not total_pattern then return false end
    
    local filtered,pattern,selection_index,raw_results=search_filter(total_pattern,env,false)
    if #pattern==0 then return false end
    if #raw_results==0 then yield_cand(input,seg,"未找到匹配文件");return true end
    
    if selection_index and selection_index>0 and selection_index<=#raw_results then
        yield_cand(input,seg,raw_results[selection_index],"📁 文件(选择第"..selection_index.."个)")
        return true
    end
    
    for i,file in ipairs(raw_results)do yield_cand(input,seg,file,"📁"..i)end
    return true
end

local function handle_fs(input,seg,env)
    local del_path=input:match("^/wjdel\"(.-)\"?$")
    if del_path then
        local res,term,sel,raw=search_filter(del_path,env,false)
        if #term==0 then yield_cand(input,seg,"请输入要删除的文件关键词");return true end
        if sel and(sel<=0 or sel>#raw)then yield_cand(input,seg,"索引无效 1-"..#raw);return true end
        if #res==0 then yield_cand(input,seg,"未找到匹配文件: "..term);return true end
        
        if input:match("^/wjdel\".+\"$")then
            local target=res[1]
            local ok,err=os.remove(path_join(rime_api.get_user_data_dir(),target))
            yield_cand(input,seg,ok and("删除成功: "..target)or("删除失败: "..target.." "..(err or"")))
            return true
        end
        for i,f in ipairs(res)do yield_cand(input,seg,f,"📁"..i)end
        return true
    end

    local create_path=input:match("^/wjnew\"(.-)\"?$")
    if create_path and not input:match("^/wjnew\".+\"$")then
        local has_slash=create_path:find("/")~=nil
        local pre,post=create_path:match("^(.-)/(.*)$")
        pre=pre or create_path
        
        local res,term,sel=search_filter(pre,env,true)
        local sel_dir=(sel and #res>0)and res[1]or nil
        
        if #res>0 then
            if has_slash then
                yield_cand(input,seg,(sel_dir or pre).."/"..(post or""),sel_dir and"在"..sel_dir.."中创建"or"新建文件夹并创建文件")
            else
                for i,d in ipairs(res)do yield_cand(input,seg,d,"📂"..i)end
                yield_cand(input,seg,pre,"使用输入名")
            end
        else yield_cand(input,seg,create_path,"创建路径")end
        return true
    end

    local create_target=input:match("^/wj\"(.*)\"$")or input:match("^/wjnew\"(.*)\"$")
    if create_target then
        local is_dir=create_target:sub(-1)=="/"or create_target:sub(-1)=="\\"
        local dir_part,file_part=create_target:match("^(.-)/(.*)$")
        local actual_dir=dir_part or create_target
        
        local res,resolved_dir,sel=search_filter(actual_dir,env,true)
        local use_input=not(sel and #res>0)
        if not use_input then resolved_dir=res[1]end
        
        local real_p=(dir_part and file_part)and(use_input and(dir_part.."/"..file_part)or(resolved_dir.."/"..file_part))or(use_input and create_target or resolved_dir)
        local full=path_join(rime_api.get_user_data_dir(),real_p)
        if is_dir then
            local cmd=path_sep=='\\'and('mkdir "'..full..'"')or('mkdir -p "'..full..'"')
            local ok=os.execute(cmd)
            yield_cand(input,seg,ok and("文件夹创建成功: "..real_p)or("文件夹创建失败: "..real_p))
        else
            local pdir=real_p:match("^(.*)[/\\][^/\\]*$")
            if pdir then ensure_dir(path_join(rime_api.get_user_data_dir(),pdir))end
            local f=io.open(full,"w")
            if f then f:close();yield_cand(input,seg,"文件创建成功: "..real_p)
            else yield_cand(input,seg,"文件创建失败: "..real_p)end
        end
        return true
    end
    return false
end

local function handle_replace(input,seg,env)
    local fpath,newc=input:match("^/wj(.-)@//(.*)/$")
    if not fpath then fpath,newc=input:match("^/wj(.-)@//(.*)$")end
    if fpath then
        local ms,fterm,sel=search_filter(fpath,env,false)
        if #ms==0 then yield_cand(input,seg,"未找到匹配文件");return true end
        if #ms~=1 then yield_cand(input,seg,"匹配多个文件："..#ms,"加数字指定");return true end
        local full=path_join(rime_api.get_user_data_dir(),ms[1])
        local content=read_file(full)
        if not input:match("^/wj(.-)@//(.*)/$")then
            local disp,prev=escape_disp(newc or""),""
            if content and #content>0 then
                for i=1,math.min(3,#content)do prev=prev..(i>1 and" \\n "or"")..escape_disp(content[i])end
                if #content>3 then prev=prev.."..."end
            else prev="(空文件)"end
            yield_cand(input,seg,"将覆盖为: "..disp,"原内容: "..prev)
            return true
        end
        newc=unescape(newc or"")
        local lines={}
        for l in newc:gmatch("[^\n]+")do table.insert(lines,l)end
        if #lines==0 then table.insert(lines,"")end
        local ok,err=write_file(full,lines)
        if not ok then yield_cand(input,seg,"写入失败: "..(err or""));return true end
        yield_cand(input,seg,"整体替换成功",(content and #content or 0).."行 → "..#lines.."行")
        return true
    end

    local fp,k,o,n=input:match("^/wj(.-)@([^/]+)/([^/]+)/([^/]*)/$")
    if not fp then
        fp,k,o=input:match("^/wj(.-)@([^/]+)/([^/]+)//$")
        if fp then n=""else 
            fp,k,o=input:match("^/wj(.-)@([^/]+)/([^/]*)$")
            if not fp then fp,k,o,n=input:match("^/wj(.-)@([^/]+)/([^/]+)/([^/]*)$")end
        end
    end
    if not fp or not k then return false end
    
    local ms,f_term=search_filter(fp,env,false)
    local l_sel,l_term=parse_suffix_idx(k)
    
    if #ms~=1 then yield_cand(input,seg,#ms==0 and"未找到文件"or"匹配多个文件："..#ms,#ms==0 and""or"加数字指定");return true end
    local full=path_join(rime_api.get_user_data_dir(),ms[1])
    local content,err=read_file(full)
    if not content then yield_cand(input,seg,"读文件失败: "..(err or""));return true end
    local matches={}
    for i,line in ipairs(content)do if line:find(l_term,1,true)then table.insert(matches,{line=line,idx=i})end end
    if #matches==0 then yield_cand(input,seg,"无匹配关键词行","关键词: "..l_term);return true end
    local sel_lines=(l_sel and l_sel>0 and l_sel<=#matches)and{matches[l_sel]}or matches
    if #sel_lines~=1 then yield_cand(input,seg,#sel_lines==0 and"行索引无效 1-"..#matches or"匹配"..#sel_lines.."行，请加行号");return true end
    
    local info=sel_lines[1]
    if input:match("^/wj[^@]*@[^/]+/[^/]+/[^/]*/$")then
        local nl=info.line:gsub(o,unescape(n or""),1)
        if info.line==nl then yield_cand(input,seg,"未找到可替换内容");return true end
        content[info.idx]=nl
        local ok,err=write_file(full,content)
        if not ok then yield_cand(input,seg,"写入失败: "..(err or""));return true end
        local disp=nl:gsub("\n","\\n")
        yield_cand(input,seg,(n==""and"删除成功: "or"替换成功: ")..(#disp>40 and disp:sub(1,37).."..."or disp),"原行: "..info.line:sub(1,40))
        return true
    else
        local tip=info.line
        if o and o~=""then
            tip=(#tip>20 and tip:sub(1,17).."..."or tip).." → 待替换: "..o
            if n~=nil then
                local dn=escape_disp(n)
                tip=tip..(n==""and" ➔ 删除（输/确认）"or" ➔ 新内容: "..(#dn>20 and dn:sub(1,17).."..."or dn))
            else tip=tip.." ➔ 输入替换内容"end
        else tip=tip.." → 输入待替换内容"end
        if #matches>1 and not l_sel then tip=tip.."（共"..#matches.."行匹配，加行号）"end
        yield_cand(input,seg,tip,"第"..info.idx.."行")
        return true
    end
end

local function handle_file(input,seg,env)
    if handle_replace(input,seg,env)then return true end
    local m_file=input:match("^/wj(.-)@/$")
    local q_file,q=input:match("^/wj(.-)@([^/]+)/?$")
    local n_file=input:match("^/wj(.-)@$")
    local target=m_file or q_file or n_file
    if not target then return false end
    
    local ms,term=search_filter(target,env,false)
    local full=path_join(rime_api.get_user_data_dir(),#ms==1 and ms[1]or term)
    local content,err=read_file(full)
    if not content then yield_cand(input,seg,"读文件失败: "..(err or""));return true end
    
    if m_file then yield_cand(input,seg,table.concat(content,"\n"),"全文合并");return true end
    if q and q~=""then
        local l_sel,l_q=parse_suffix_idx(q)
        local hits={}
        for i,line in ipairs(content)do if not line:match("^%s*$")and line:find(l_q,1,true)then table.insert(hits,{line=line,n=i})end end
        if #hits==0 then yield_cand(input,seg,"无匹配内容");return true end
        if l_sel and l_sel>0 and l_sel<=#hits then yield_cand(input,seg,hits[l_sel].line,"第"..hits[l_sel].n.."行(选中)")
        else for i,d in ipairs(hits)do yield_cand(input,seg,d.line,"("..i..")第"..d.n.."行: "..d.line:sub(1,20))end end
        return true
    end
    for i,line in ipairs(content)do if not line:match("^%s*$")then yield_cand(input,seg,line,"第"..i.."行")end end
    return true
end

local function handle_cp_mv(input,seg,env)
    if input=="/wj&"or input=="/wj+&"then
        yield_cand(input,seg,"/wj+&源&目标& 复制","格式")
        yield_cand(input,seg,"/wj&源&目标& 移动","格式")
        return true
    end
    if input:match("^/wj[%+]?&$")then yield_cand(input,seg,"请输入源文件关键词");return true end
    local is_move=input:sub(1,4)=="/wj&"
    local src_raw,dst_raw=input:match("^/wj[%+]?&(.-)&(.-)&$")
    if src_raw and dst_raw then
        local s_ms,s_t=search_filter(src_raw,env,false)
        if #s_ms~=1 then 
            yield_cand(input,seg,#s_ms==0 and("未找到源文件: "..s_t)or("匹配"..#s_ms.."个源文件，请加数字"))
            for i,f in ipairs(s_ms)do yield_cand(input,seg,f,"📄"..i)end
            return true
        end
        local d_ms,d_t=search_filter(dst_raw,env,true)
        local user,r_src=rime_api.get_user_data_dir(),s_ms[1]
        local fname=r_src:match("[^/\\]+$")or r_src
        local f_dst,t_dir,new_dir="","",false
        if #d_ms==1 then f_dst,t_dir=path_join(user,d_ms[1],fname),path_join(user,d_ms[1])
        else new_dir=true;t_dir=path_join(user,d_t);if t_dir:sub(-1)~=path_sep then t_dir=t_dir..path_sep end;f_dst=path_join(t_dir,fname)end
        if new_dir then ensure_dir(t_dir)end
        local cont,err=read_file(path_join(user,r_src))
        if not cont then yield_cand(input,seg,"源读取失败: "..(err or""));return true end
        local ok,err=write_file(f_dst,cont)
        if not ok then yield_cand(input,seg,"写入失败: "..(err or""));return true end
        if is_move then os.remove(path_join(user,r_src))end
        yield_cand(input,seg,(is_move and"移动"or"复制").."成功: "..r_src.." → "..(#d_ms==1 and d_ms[1]or d_t)..(new_dir and"（已新建目录）"or""))
        return true
    end
    return false
end

-- 字符串与集合辅助函数
local function utf8_char(str,index)
    if not utf8.offset then return str:sub(index,index)end
    local sb=utf8.offset(str,index)
    if not sb then return nil end
    local eb=utf8.offset(str,index+1)or #str+1
    return str:sub(sb,eb-1)
end

local function get_target_chars(line)
    local blocks={}
    if not line or line==""then return blocks end
    local cur=""
    for i=1,#line do
        local c=line:sub(i,i)
        if not c:match("^[a-zA-Z0-9%s]$")then cur=cur..c
        else if cur~=""then blocks[cur]=true;cur=""end end
    end
    if cur~=""then blocks[cur]=true end
    return blocks
end

local function get_first_char(line)
    if not line or line==""then return nil end
    local len=utf8.len and utf8.len(line)or #line
    if not len then return nil end
    for i=1,len do
        local c=utf8_char(line,i)
        if c and not c:match("^[a-zA-Z0-9%s]$")then return c end
    end
    return nil
end

function string:split(sep)
    local t={}
    for v in self:gmatch("([^"..(sep or":").."]+)")do table.insert(t,v)end
    return t
end

local function split_ws(str)
    local t={}
    for v in str:gmatch("%S+")do table.insert(t,v)end
    return t
end

local function build_line_idx(lines)
    local index={}
    for _,line in ipairs(lines)do
        if line~=""then
            local tokens=split_ws(line)
            local len=#tokens
            if len>0 then
                local first_token=tokens[1]
                if not index[first_token]then index[first_token]={}end
                table.insert(index[first_token],{tokens=tokens,len=len})
            end
        end
    end
    return index
end

local function has_seq(line_tokens,index)
    local line_len=#line_tokens
    for i=1,line_len do
        local current_token=line_tokens[i]
        local sequences=index[current_token]
        if sequences then
            for _,seq in ipairs(sequences)do
                local seq_len=seq.len
                if i+seq_len-1<=line_len then
                    local match=true
                    for j=1,seq_len do
                        if line_tokens[i+j-1]~=seq.tokens[j]then match=false;break end
                    end
                    if match then return true end
                end
            end
        end
    end
    return false
end

local function resolve_path(input_path,env)
    local ms,term=search_filter(input_path,env,false)
    if #term==0 then return nil,"请输入文件关键词"end
    if #ms~=1 then return nil,#ms==0 and("未找到文件: "..term)or("匹配"..#ms.."个文件，请加数字")end
    return ms[1]
end

local function show_candidates(input,seg,env,term)
    local ms=search_filter(term,env,false)
    if #ms>0 then for i=1,#ms do yield_cand(input,seg,ms[i],"📄"..i)end
    else yield_cand(input,seg,"未找到匹配文件")end
end

-- 提取的分组统计逻辑
local function format_group_stats(groups,label,is_tj,res,tj_res)
    if not groups or #groups==0 then return 0 end
    local total_lines=0
    local group_stats={}
    for _,g in ipairs(groups)do
        total_lines=total_lines+#g
        table.insert(group_stats,{line=g[1],count=#g})
        for _,l in ipairs(g)do table.insert(res,l)end
    end
    if is_tj then
        table.sort(group_stats,function(a,b)return a.count==b.count and a.line<b.line or a.count>b.count end)
        local circle_nums={"①","②","③","④","⑤","⑥","⑦","⑧","⑨","⑩"}
        local stat_str=label.."："..total_lines.."行"..#groups.."种"
        for i,stat in ipairs(group_stats)do
            local prefix=i<=10 and(" "..circle_nums[i])or(" "..i..". ")
            stat_str=stat_str..prefix..stat.line.." "..stat.count
        end
        table.insert(tj_res,stat_str)
    end
    return total_lines
end

local function handle_group(input,seg,env)
    local fp=input:match("^/wj_@(.-)&$")
    local is_tj=false
    if not fp then 
        fp=input:match("^/wj_tj@(.-)&$")
        if fp then is_tj=true end
    end
    if not fp then return false end
    
    local f,err=resolve_path(fp,env)
    if not f then yield_cand(input,seg,err);return true end
    local user=rime_api.get_user_data_dir()
    local cont,cerr=read_file(path_join(user,f))
    if not cont then yield_cand(input,seg,"读文件失败: "..(cerr or""));return true end
    
    local line_map,seq,c_groups,c_order,no_char={},{},{},{},{}
    for _,line in ipairs(cont)do
        if not line_map[line]then line_map[line]={};table.insert(seq,line)end
        table.insert(line_map[line],line)
    end
    for _,line in ipairs(seq)do
        local group,ch=line_map[line],get_first_char(line)
        if ch then
            if not c_groups[ch]then c_groups[ch]={};table.insert(c_order,ch)end
            table.insert(c_groups[ch],group)
        else table.insert(no_char,group)end
    end
    
    local res,tj_res,g_count={},{},0
    for _,ch in ipairs(c_order)do
        g_count=g_count+1
        format_group_stats(c_groups[ch],ch,is_tj,res,tj_res)
    end
    if #no_char>0 then format_group_stats(no_char,"无特殊字符",is_tj,res,tj_res)end
    
    local n=f:match("([^/\\]+)$")or f
    local base_name=n:gsub("%..+$","")
    local res_p=path_join(user,f:match("^(.*)[/\\]")or"",base_name.."_grouped.txt")
    local ok,werr=write_file(res_p,res)
    if not ok then yield_cand(input,seg,"写入失败: "..(werr or""));return true end
    
    local msg=string.format("分组完成：%d行 → %d行，按首特殊字符分%d组",#cont,#res,g_count)
    local result_tip="结果："..res_p:gsub("^"..escape_lua_pattern(user..path_sep),"")
    
    if is_tj then
        local tj_p=path_join(user,f:match("^(.*)[/\\]")or"","tj_"..base_name.."_grouped.txt")
        local tj_ok,tj_werr=write_file(tj_p,tj_res)
        if not tj_ok then yield_cand(input,seg,"统计写入失败: "..(tj_werr or""));return true end
        msg=msg.." (含统计)"
        result_tip="统计："..tj_p:gsub("^"..escape_lua_pattern(user..path_sep),"")
    end
    
    yield_cand(input,seg,msg,result_tip)
    return true
end

local function handle_dup(input,seg,env)
    if input=="/wj_&"then yield_cand(input,seg,"/wj_&文件名& 重码合并(用&拼接)","格式");return true end
    local fp=input:match("^/wj_&(.-)&$")
    if not fp then 
        local partial=input:match("^/wj_&(.*)$")
        if partial then show_candidates(input,seg,env,partial);return true end
        return false 
    end
    local f,err=resolve_path(fp,env)
    if not f then yield_cand(input,seg,err);return true end   
    local user=rime_api.get_user_data_dir()
    local cont,cerr=read_file(path_join(user,f))
    if not cont then yield_cand(input,seg,"读文件失败: "..(cerr or""));return true end
    
    local code_map,code_order,line_counter={},{},0
    for _,line in ipairs(cont)do
        line_counter=line_counter+1
        local clean=line:gsub("[\r\n]+$","")        
        if not clean:match("^%s*$")and not clean:match("^#")then
            local parts={}
            for v in clean:gmatch("[^\t]+")do table.insert(parts,v)end          
            if #parts>=2 then
                local code,weight=parts[2],tonumber(parts[3])or 0
                if not code_map[code]then code_map[code]={};table.insert(code_order,code)end
                table.insert(code_map[code],{text=clean,weight=weight,index=line_counter})
            end
        end
    end
    
    local res,dup_count={},0
    for _,code in ipairs(code_order)do
        local group=code_map[code]
        if #group>1 then
            table.sort(group,function(a,b)return a.weight~=b.weight and a.weight>b.weight or a.index<b.index end)
            local sorted={}
            for _,item in ipairs(group)do table.insert(sorted,item.text)end          
            table.insert(res,table.concat(sorted,"&"));dup_count=dup_count+1
        end
    end   
    
    local n=f:match("([^/\\]+)$")or f
    local res_p=path_join(user,f:match("^(.*)[/\\]")or"",n:gsub("%..+$","").."_dups.txt")
    local ok,werr=write_file(res_p,res)    
    if not ok then yield_cand(input,seg,"写入失败: "..(werr or""));return true end
    yield_cand(input,seg,string.format("合并完成：%d组重码",dup_count),"文件："..res_p:gsub("^"..escape_lua_pattern(user..path_sep),""))
    return true
end

local function handle_set_ops(input,seg,env)
    if input:match("^/wj_@(.-)&$")or input:match("^/wj_tj@(.-)&$")then return handle_group(input,seg,env)end
    
    local op_patterns={
        {"^/wj_@(.-)@(.-)@$","filter","_"},{"^/wj%+@(.-)@(.-)@$","merge","+"},
        {"^/wj%-@(.-)@(.-)@$","dedup","-"},{"^/wj%-h@(.-)@(.-)@$","line_dedup","-h"},
        {"^/wj_h@(.-)@(.-)@$","line_filter","_h"},{"^/wj%-hn@(.-)@(.-)@$","line_in_dedup","-hn"},
        {"^/wj_hn@(.-)@(.-)@$","line_in_filter","_hn"}
    }
    
    local op,f1,f2,op_char
    for _,p in ipairs(op_patterns)do
        f1,f2=input:match(p[1])
        if f1 then op,op_char=p[2],p[3];break end
    end
    
    if not op then
        if input:match("^/wj[_%+%-]h?n?@")or input:match("^/wj_tj@")then
            local clean_input=input:gsub("^/wj_[A-Za-z]*@","@"):gsub("^/wj[%+%-_]h?n?@","@")
            local parts=clean_input:split("@")
            if #parts==0 then yield_cand(input,seg,"输入文件1关键词 + @")
            elseif #parts==1 then show_candidates(input,seg,env,parts[1])
            elseif #parts==2 then show_candidates(input,seg,env,parts[2])end
            return true
        end
        return false 
    end
    
    local rf1,e1=resolve_path(f1,env)
    local rf2,e2=resolve_path(f2,env)
    if not rf1 or not rf2 then yield_cand(input,seg,e1 or e2);return true end
    
    local user=rime_api.get_user_data_dir()
    local c1,e1r=read_file(path_join(user,rf1))
    local c2,e2r=read_file(path_join(user,rf2))
    if not c1 or not c2 then yield_cand(input,seg,"读文件失败: "..(e1r or e2r));return true end
    
    local n1,n2=rf1:match("([^/\\]+)$")or rf1,rf2:match("([^/\\]+)$")or rf2
    local res_p=path_join(user,rf1:match("^(.*)[/\\]")or"",n1:gsub("%..+$","")..op_char..n2:gsub("%..+$","")..".txt")
    
    local res,msg={},""
    local is_keep=(op:match("filter")~=nil)
    
    if op=="filter"or op=="dedup"then
        local s2={}
        for _,l in ipairs(c2)do for c in pairs(get_target_chars(l))do s2[c]=true end end
        for _,l in ipairs(c1)do 
            local has=false
            for c in pairs(get_target_chars(l))do if s2[c]then has=true;break end end
            if has==is_keep then table.insert(res,l)end
        end
        msg=string.format("字%s：%d→%d行",is_keep and"取重"or"去重",#c1,#res)
    elseif op=="merge"then
        local map2={}
        for _,l in ipairs(c2)do
            local cl=l:gsub("[\r\n]"," ")
            for c in pairs(get_target_chars(cl))do map2[c]=map2[c]or{};map2[c][cl]=true end
        end
        for _,l1 in ipairs(c1)do
            local cl1,tmp=l1:gsub("[\r\n]"," "),{}
            for c in pairs(get_target_chars(cl1))do if map2[c]then for ll in pairs(map2[c])do tmp[ll]=true end end end
            local arr={}
            for ll in pairs(tmp)do table.insert(arr,ll)end
            if #arr>0 then table.insert(res,cl1.."\t"..table.concat(arr,"\t"))end
        end
        msg=string.format("合并：%d+%d→%d行",#c1,#c2,#res)
    elseif op=="line_filter"or op=="line_dedup"then
        local s2={}
        for _,l in ipairs(c2)do s2[l]=true end
        for _,l in ipairs(c1)do if (s2[l]~=nil)==is_keep then table.insert(res,l)end end
        msg=string.format("行%s：%d→%d行",is_keep and"取重"or"去重",#c1,#res)
    elseif op=="line_in_filter"or op=="line_in_dedup"then
        local index=build_line_idx(c2)
        for _,l in ipairs(c1)do
            if has_seq(split_ws(l),index)==is_keep then table.insert(res,l)end
        end
        msg=string.format("行内%s：%d→%d行",is_keep and"取重"or"去重",#c1,#res)
    end
    
    local ok,werr=write_file(res_p,res)
    if not ok then yield_cand(input,seg,"写入失败: "..(werr or""));return true end
    yield_cand(input,seg,msg,"结果："..res_p:gsub("^"..escape_lua_pattern(user..path_sep),""))
    return true
end

-- 处理 /zuci 指令
local function handle_zuci(input, seg, env)
    if input ~= "/zuci" then return false end
    local user_dir = rime_api.get_user_data_dir()
    local dicts_dir = path_join(user_dir, "dicts")
    local zuci_dir = path_join(user_dir, "zu_ci")
    ensure_dir(zuci_dir)
    local targets = { "jichu.pro.dict.yaml", "lianxiang.pro.dict.yaml", "duoyin.pro.dict.yaml", "shici.pro.dict.yaml", "diming.pro.dict.yaml" }
    local success_count = 0
    local log = {}
    for _, name in ipairs(targets) do
        local src_path = path_join(dicts_dir, name)
        local content = read_file(src_path)
        local filename = name
        if content then
            local new_content = {}
            for _, line in ipairs(content) do
                table.insert(new_content, line)
                if line:match("^%s*sort:%s*by_weight%s*$") then
                    table.insert(new_content, "columns:")
                    table.insert(new_content, "  - text")
                    table.insert(new_content, "  - weight")
                end
            end
            for i, line in ipairs(new_content) do
                if line:find("\t") then
                    line = line:gsub("\t.-\t", "\t")
                    line = line:gsub("\t%D*$", "\t")
                    new_content[i] = line
                end
            end
            local dst_path = path_join(zuci_dir, filename)
            local ok, err = write_file(dst_path, new_content)
            if ok then
                success_count = success_count + 1
                table.insert(log, filename .. " (成功)")
            else
                table.insert(log, filename .. " (写入失败)")
            end
        else
            table.insert(log, name .. " (未找到)")
        end
    end
    yield_cand(input, seg, "组词词库处理完成: " .. success_count .. "/5", "查看 zu_ci 文件夹")
    for i, msg in ipairs(log) do
        yield_cand(input, seg, msg, "文件 " .. i)
    end
    return true
end

function T.func(input,seg,env)
    local comp=env.engine.context.composition
    if comp:empty()then return end
    seg=comp:back()
    if input=="/wj"then
        local hints={
            {"文件名@内容 检索文件内容"," "},{"文件名2@内容3/ 选择第2个文件候选项"," "},{"文件名@/ 合并输出整个文件"," "},{"文件名@内容/被替换/替换/ 修改内容"," "},{"文件名@//新内容/ 整体替换文件内容"," "},
            {"new\"文件夹/文件名\" 创建文件"," "},{"del\"文件夹/文件名\" 删除文件"," "},{"+&原文件&目标路径& 复制文件"," "},{"&原文件&目标路径& 移动文件"," "},
            {"_@文件1@文件2@ 取重（保留共同字符行）"," "},{"+@文件1@文件2@ 合并（拼接关联行）"," "},{"-@文件1@文件2@ 去重（移除共同字符行）"," "},
            {"-h@文件1@文件2@ 行去重（移除完全相同行）"," "},{"_h@文件1@文件2@ 行取重（保留完全相同行）"," "},
            {"-hn@文件1@文件2@ 行内去重（移除包含文件2行的行）"," "},{"_hn@文件1@文件2@ 行内取重（保留包含文件2行的行）"," "},
            {"_@文件& 分组（按首特殊字符分组）"," "},{"_&文件名& 重码合并"," "}
        }
        for _,h in ipairs(hints)do yield_cand(input,seg,h[1],h[2])end
        seg.tags.calculating=true;return
    end
    if handle_zuci(input,seg,env)or
       handle_set_ops(input,seg,env)or 
       handle_dup(input,seg,env)or
       handle_cp_mv(input,seg,env)or 
       handle_file(input,seg,env)or 
       handle_fs(input,seg,env)or 
       fuzzy_file_search(input,seg,env)then
        seg.tags.calculating=true
    end
end

return T