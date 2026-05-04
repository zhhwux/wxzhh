local wanxiang = require("wanxiang/wanxiang")

-- 文件复制函数
local function copy_file(src, dest)
    local fi = io.open(src, "r")
    if not fi then 
        return false 
    end
    local content = fi:read("*a")
    fi:close()

    local fo = io.open(dest, "w")
    if not fo then 
        return false 
    end
    fo:write(content)
    fo:close()
    return true
end

-- 检查文件是否存在
local function file_exists(path)
    local f = io.open(path, "r")
    if f then
        f:close()
        return true
    end
    return false
end

-- 替换方案函数
local function replace_schema(file_path, target_schema)
    local f = io.open(file_path, "r")
    if not f then 
        return false 
    end
    local content = f:read("*a")
    f:close()

    -- 根据文件名决定替换模式
    if file_path:find("wanxiang_reverse") then
        content = content:gsub("([%s]*__include:%s*wanxiang_algebra:/reverse/)%S+", "%1" .. target_schema)
    elseif file_path:find("wanxiang_mixedcode") then
        content = content:gsub("([%s]*__patch:%s*wanxiang_algebra:/mixed/)%S+", "%1" .. target_schema)
    elseif file_path:find("wanxiang_english") then
        content = content:gsub("([%s]*__patch:%s*wanxiang_algebra:/english/)%S+", "%1" .. target_schema)
    elseif file_path:find("wanxiang%.custom") or file_path:find("wanxiang_pro%.custom") then
        content = content:gsub("([%s%-]*wanxiang_algebra:/pro/)%S+",  "%1" .. target_schema, 1)
        content = content:gsub("([%s%-]*wanxiang_algebra:/base/)%S+", "%1" .. target_schema, 1)
    end

    f = io.open(file_path, "w")
    if not f then 
        return false 
    end
    f:write(content)
    f:close()
    return true
end

-- translator 主函数
local function translator(input, seg, env)
    local schema_id = env.engine.schema.schema_id
    
    -- 如果方案本身是 wanxiang_pro，则禁用一切指令
    if schema_id == "wanxiang_pro" then
        return
    end

    local user_dir = rime_api.get_user_data_dir()

    -- ================= 新指令逻辑 ================= --
    local new_base_cmds = {
        ["/wxh"] = "万象虎",
        ["/mets"] = "虎码二三整句",
        ["/xumn"] = "虎码原码整句",
        ["/kjzb"] = "九键虎",
        ["/wxwb"] = "万象五笔"
    }

    local new_mid_cmds = {
        ["/shiba"] = "18jian",
        ["/shiwu"] = "15jian",
        ["/shisi"] = "14jian"
    }

    -- 动态获取默认基础指令（仅在找不到已有基础指令时回退用）
    local schema_to_rule = {
        tiger = "万象虎",
        mets = "虎码二三整句",
        xumn = "虎码原码整句",
        wubi = "万象五笔"
    }

    if new_base_cmds[input] or new_mid_cmds[input] then
        local target_file = user_dir .. "/" .. schema_id .. ".custom.yaml"
        local marker = "##########################以上格式受指令初始化控制，最好保持格式不变，如果发生变更请不要使用指令修改相关数据#####################################"
        
        -- 1. 先读取原有文件内容
        local old_content = ""
        if file_exists(target_file) then
            local f = io.open(target_file, "r")
            if f then
                old_content = f:read("*a")
                f:close()
            end
        end

        -- 2. 查找分隔符，提取头部受控区域的内容
        local start_idx, end_idx = string.find(old_content, marker, 1, true)
        local head_part = ""
        if start_idx then
            head_part = string.sub(old_content, 1, start_idx - 1)
        else
            head_part = old_content
        end

        -- 3. 构造新的头部 YAML 内容
        local yaml_head = "patch:\n" ..
                          "  speller/algebra:\n" ..
                          "    __patch:\n"
        
        local current_base = "" -- 用于记录当前最终使用的基础指令

        if new_base_cmds[input] then
            -- 【基础指令】：直接覆盖，只写入新的基础指令和通配符（重置中间指令为空）
            current_base = new_base_cmds[input]
            yaml_head = yaml_head .. "      - wxh_algebra:" .. current_base .. "\n"
            yaml_head = yaml_head .. "      - wxh_algebra:/通配符\n"
        elseif new_mid_cmds[input] then
            -- 【中间指令】：需要保留当前已有的基础指令
            current_base = schema_to_rule[schema_id] or "万象虎"
            
            -- 遍历头部所有 wxh_algebra:xxx 的规则
            for rule in string.gmatch(head_part, "wxh_algebra:([^%s\r\n]+)") do
                -- 只要不是通配符，也不是中间指令，那就是我们要保留的基础指令
                if rule ~= "/通配符" and rule ~= "18jian" and rule ~= "15jian" and rule ~= "14jian" then
                    current_base = rule
                    break -- 找到第一个匹配的基础指令就停止
                end
            end

            -- 写入：保留的基础指令 -> 新的中间指令 -> 通配符
            yaml_head = yaml_head .. "      - wxh_algebra:" .. current_base .. "\n"
            yaml_head = yaml_head .. "      - wxh_algebra:" .. new_mid_cmds[input] .. "\n"
            yaml_head = yaml_head .. "      - wxh_algebra:/通配符\n"
        end
        
        -- ★ 新增：如果当前基础指令是"虎码原码整句"，则追加相关配置
        if current_base == "虎码原码整句" then
            yaml_head = yaml_head .. "  speller/delimiter: \" _\"\n"
            yaml_head = yaml_head .. "  speller/alphabet: zyxwvutsrqponmlkjihgfedcbaZYXWVUTSRQPONMLKJIHGFEDCBA7890_;*/'[]\n"
        end

        -- 加上分隔符
        yaml_head = yaml_head .. marker

        -- 4. 拼接最终内容
        local final_content = ""
        if start_idx then
            -- 如果存在分隔符，只替换分隔符及其之前的内容，保留之后的内容
            final_content = yaml_head .. string.sub(old_content, end_idx + 1)
        else
            -- 如果不存在分隔符，将新内容放置于文件最开头，并保留原内容
            if old_content ~= "" and not string.match(old_content, "^%s*$") then
                -- 移除原内容开头的多余空白，避免产生多余空行
                old_content = string.gsub(old_content, "^%s+", "")
                final_content = yaml_head .. "\n" .. old_content
            else
                final_content = yaml_head .. "\n"
            end
        end
        
        -- 5. 写入文件
        local f = io.open(target_file, "w")
        if f then
            f:write(final_content)
            f:close()
            yield(Candidate("switch", seg.start, seg._end, "已更新 " .. schema_id .. ".custom.yaml，请手动重新部署", ""))
        else
            yield(Candidate("switch", seg.start, seg._end, "更新文件失败", ""))
        end
        return
    end
    -- ============================================== --

    -- 处理直接辅助/间接辅助切换 (统一只处理 wanxiang_pro)
    if input == "/zjf" or input == "/jjf" then
        local target_aux = (input == "/zjf") and "直接辅助" or "间接辅助"
        local paths = {
            user_dir .. "/wanxiang_pro.custom.yaml",
        }

        local total_hits, touched = 0, 0
        for _, p in ipairs(paths) do
            if file_exists(p) then
                local f = io.open(p, "r")
                local content = f:read("*a")
                f:close()

                local n1, n2 = 0, 0
                content, n1 = content:gsub("(%-+%s*wanxiang_algebra:/pro/)直接辅助(%s*#?.*)", "%1" .. target_aux .. "%2")
                content, n2 = content:gsub("(%-+%s*wanxiang_algebra:/pro/)间接辅助(%s*#?.*)", "%1" .. target_aux .. "%2")
                local n = n1 + n2

                if n > 0 then
                    local w = io.open(p, "w")
                    if w then w:write(content); w:close() end
                    total_hits = total_hits + n
                    touched = touched + 1
                end
            end
        end

        local msg = (total_hits > 0)
            and ("已切换到〔" .. target_aux .. "〕，请重新部署")
            or  "未找到可切换的条目"
        yield(Candidate("switch", seg.start, seg._end, msg, ""))
        return
    end

    -- 方案映射表
    local schema_map = {
        ["/flypy"] = "小鹤双拼",
        ["/mspy"] = "微软双拼",
        ["/zrm"] = "自然码",
        ["/sogou"] = "搜狗双拼",
        ["/znabc"] = "智能ABC",
        ["/ziguang"] = "紫光双拼",
        ["/pyjj"] = "拼音加加",
        ["/gbpy"] = "国标双拼",
        ["/lxsq"] = "乱序17",
        ["/zrlong"] = "自然龙",
        ["/hxlong"] = "汉心龙",
        ["/pinyin"] = "全拼",
        ["/wxsp"] = "万象双拼",
    }

    local target_schema = schema_map[input]
    if target_schema then
        local shared_dir = rime_api.get_shared_data_dir()

        -- 统一只处理 wanxiang_pro
        local pro_file = user_dir .. "/wanxiang_pro.custom.yaml"
        local custom_file_exists = file_exists(pro_file)

        local files = {
            "wanxiang_mixedcode.custom.yaml",
            "wanxiang_reverse.custom.yaml",
            "wanxiang_english.custom.yaml"
        }

        local fourth_file = "wanxiang_pro.custom.yaml"
        table.insert(files, fourth_file)

        for _, name in ipairs(files) do
            -- 1. 优先尝试从 系统目录/custom/ 下寻找
            local src = shared_dir .. "/custom/" .. name
            
            -- 2. 如果系统目录没有，尝试从 用户目录/custom/ 下寻找（作为后备）
            if not file_exists(src) then
                src = user_dir .. "/custom/" .. name
            end
            
            local dest = user_dir .. "/" .. name

            if name == fourth_file and custom_file_exists then
                -- 根目录自定义文件已存在，不复制，但依然修改内容
                replace_schema(dest, target_schema)
            else
                -- 其他文件: 只有当源文件存在时才复制
                if file_exists(src) then
                    if copy_file(src, dest) then
                        replace_schema(dest, target_schema)
                    end
                end
            end
        end

        -- 返回提示候选
        local location_tip = "系统"
        if custom_file_exists then
            yield(Candidate("switch", seg.start, seg._end, "检测到已有配置，已切换到〔" .. target_schema .. "〕，请手动重新部署", ""))
        else
            yield(Candidate("switch", seg.start, seg._end, "已从"..location_tip.."目录复制并切换到〔" .. target_schema .. "〕，请手动重新部署", ""))
        end
    end
end
return translator
