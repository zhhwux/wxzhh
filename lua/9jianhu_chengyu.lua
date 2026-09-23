--[[
9jianhu_chengyu.lua
九键虎（9jianhu）渐进式四字成语与高频四字词动态流打滤镜

兼容特性：
1. 兼容移动端 Trime / 小企鹅 / 同文 键盘的 9 个字母编码（q, a, d, g, j, m, p, t, x）与 PC 数字键盘（1-9）；
2. 4 击自然流打：输入 4 码（如 tggm 或 8446）直接高频置顶“按部就班”；
3. 5 击精准收窄：输入第 5 码（首字位置 a 或 2）精确收窄；
4. 6 击或带分词符（'）、斜杠（/）时静默让行，彻底避免干扰原有原码整句和分词逻辑；
5. 双重载入保障：优先从 TSV 文件流式解析；若遇 Android Scoped Storage 限制，自动降级为 require 模块载入，确保 Trime/小企鹅 100% 可用。
--]]

local M = {}

-- 全局词典单例缓存
local words_cache = nil

-- 查找词表文件路径（多路径兼容 Android Trime / Linux Fcitx5 / macOS Squirrel）
local function find_words_file()
    local search_paths = {}
    
    local user_dir = rime_api and rime_api.get_user_data_dir and rime_api.get_user_data_dir()
    if user_dir then
        table.insert(search_paths, user_dir .. "/lua/data/9jianhu_words.tsv")
        table.insert(search_paths, user_dir .. "/data/9jianhu_words.tsv")
        table.insert(search_paths, user_dir .. "/9jianhu_words.tsv")
    end
    
    -- Android Trime 常见外部存储路径
    table.insert(search_paths, "/sdcard/rime/lua/data/9jianhu_words.tsv")
    table.insert(search_paths, "/sdcard/rime/9jianhu_words.tsv")
    table.insert(search_paths, "/storage/emulated/0/rime/lua/data/9jianhu_words.tsv")
    table.insert(search_paths, "/storage/emulated/0/rime/9jianhu_words.tsv")
    
    -- 相对路径
    table.insert(search_paths, "lua/data/9jianhu_words.tsv")
    table.insert(search_paths, "data/9jianhu_words.tsv")
    table.insert(search_paths, "9jianhu_words.tsv")

    for _, path in ipairs(search_paths) do
        local f = io.open(path, "r")
        if f then
            f:close()
            return path
        end
    end
    return nil
end

-- 加载词表到内存
local function load_words_cache()
    if words_cache then return words_cache end
    words_cache = {}

    -- 策略 1：文件解析
    local file_path = find_words_file()
    if file_path then
        local f = io.open(file_path, "r")
        if f then
            for line in f:lines() do
                local tab = line:find("\t")
                if tab then
                    local code = line:sub(1, tab - 1)
                    local words_str = line:sub(tab + 1)
                    local words = {}
                    for w in words_str:gmatch("%S+") do
                        table.insert(words, w)
                    end
                    words_cache[code] = words
                end
            end
            f:close()
            return words_cache
        end
    end

    -- 策略 2：require 降级（针对 Android 沙盒文件系统权限限制）
    local ok, data = pcall(require, "data.9jianhu_words_data")
    if ok and data then
        words_cache = data
        return words_cache
    end

    local ok2, data2 = pcall(require, "9jianhu_words_data")
    if ok2 and data2 then
        words_cache = data2
        return words_cache
    end

    return words_cache
end

function M.init(env)
    load_words_cache()
end

function M.func(input, env)
    local context = env.engine.context
    local input_str = context.input
    local input_len = #input_str

    -- 支持九键的 9 个字母 [qadgjmptx] 或纯数字 [1-9] (3 击超高频、4 击流打、5 击收窄)
    local matched_words = nil
    if (input_len >= 3 and input_len <= 5) and 
       (input_str:match("^[qadgjmptx]+$") or input_str:match("^[1-9]+$")) then
        local cache = load_words_cache()
        matched_words = cache and cache[input_str]
    end

    -- 检查是否处于反查或特殊模式
    if matched_words and context.composition and not context.composition:empty() then
        local seg = context.composition:back()
        if seg and (seg:has_tag("radical_lookup") or seg:has_tag("reverse_stroke") or 
                    seg:has_tag("punct") or seg:has_tag("shijian")) then
            matched_words = nil
        end
    end

    local yielded_texts = {}

    if input_len == 3 and matched_words then
        -- 3 击模式：先让出原生第 1 候选（高频单字神圣不可侵犯），再插入高频三字词
        local first_cand = nil
        local has_yielded_first = false
        for cand in input:iter() do
            if not has_yielded_first then
                yield(cand)
                yielded_texts[cand.text] = true
                has_yielded_first = true
                -- 插入 3 码超高频三字词（作为第 2、3 候选，一击即点）
                for i, word in ipairs(matched_words) do
                    if i > 2 then break end
                    if not yielded_texts[word] then
                        local word_cand = Candidate("phrase", 0, input_len, word, "")
                        word_cand.quality = 90 - i
                        yield(word_cand)
                        yielded_texts[word] = true
                    end
                end
            else
                if not cand.text or not yielded_texts[cand.text] then
                    yield(cand)
                end
            end
        end
        return
    end

    -- 5 击模式：精准单字尊享保护
    -- 若原生首候选为精准单字（如“呢”），优先置顶，成语/流打词作为后续扩展紧随其后
    if input_len == 5 and matched_words then
        local first_cand = nil
        local has_checked_first = false
        local single_char_cand = nil

        for cand in input:iter() do
            if not has_checked_first then
                has_checked_first = true
                local text = cand.text
                local is_single = false
                if text and #text > 0 then
                    if utf8 and utf8.len then
                        local ok, l = pcall(utf8.len, text)
                        if ok and l then is_single = (l == 1) end
                    else
                        local b = string.byte(text, 1)
                        local char_len = 1
                        if b >= 0xF0 then char_len = 4
                        elseif b >= 0xE0 then char_len = 3
                        elseif b >= 0xC0 then char_len = 2
                        end
                        is_single = (#text == char_len)
                    end
                end

                if is_single then
                    -- 原生首选是单字：单字第 1 候选置顶！
                    yield(cand)
                    yielded_texts[cand.text] = true
                    -- 紧随其后注入流打词/成语（第 2~5 位）
                    for i, word in ipairs(matched_words) do
                        if i > 5 then break end
                        if not yielded_texts[word] then
                            local word_cand = Candidate("phrase", 0, input_len, word, "")
                            word_cand.quality = 90 - i
                            yield(word_cand)
                            yielded_texts[word] = true
                        end
                    end
                else
                    -- 原生首选不是单字（如多字词）：成语置顶
                    for i, word in ipairs(matched_words) do
                        if i > 5 then break end
                        local word_cand = Candidate("phrase", 0, input_len, word, "")
                        word_cand.quality = 1000 - i
                        yield(word_cand)
                        yielded_texts[word] = true
                    end
                    if not yielded_texts[cand.text] then
                        yield(cand)
                        yielded_texts[cand.text] = true
                    end
                end
            else
                if not cand.text or not yielded_texts[cand.text] then
                    yield(cand)
                end
            end
        end
        return
    end

    -- 4 击及其他模式：强置顶注入流打二字词、三字词、成语
    if matched_words then
        for i, word in ipairs(matched_words) do
            if i > 5 then break end
            local cand = Candidate("phrase", 0, input_len, word, "")
            cand.quality = 1000 - i
            yield(cand)
            yielded_texts[word] = true
        end
    end

    -- 正常输出后续原有候选，过滤重复项
    for cand in input:iter() do
        if not cand.text or not yielded_texts[cand.text] then
            yield(cand)
        end
    end
end

function M.fini(env)
end

return M
