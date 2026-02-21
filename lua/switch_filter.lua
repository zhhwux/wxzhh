local M = {}

function M.init(env)
    env.search_key = '`'
    env.code_pattern = '[a-z]'

    env.select_notifier = env.engine.context.select_notifier:connect(function(ctx)
        local input = ctx.input
        local code = input:match('^(.-)' .. env.search_key)
        if not code or #code == 0 then return end
        
        local preedit = ctx:get_preedit()
        local no_search_string = input:match('^(.-)' .. env.search_key)
        local edit = preedit.text:match('^(.-)' .. env.search_key)
        
        if edit and edit:match(env.code_pattern) then
            ctx.input = no_search_string .. env.search_key
        else
            ctx.input = no_search_string
            ctx:commit()
        end
    end)
end

function M.func(input, env)
    local context = env.engine.context -- 补context定义
    local input_preedit = context:get_preedit().text -- 补输入预处理文本
    local is_prefix_input = input_preedit:find("^[VRNU/;'`]")
    local has_backtick = input_preedit:find("`")
    local has_other = input_preedit:find("*") or input_preedit:find("[_'/]") or context.input:find("\\")
    local config = env.engine.schema.config
    local char_word_dict = config:get_string("char_word/dictionary")
    local yin_on = env.engine.schema.schema_id == "wanxiang_pro" and context:get_option("yin")

    -- 反查模式判断
    local is_radical_mode = false
    local seg = context.composition:back()
    if seg and (seg:has_tag("radical_lookup") or seg:has_tag("reverse_stroke") or 
                seg:has_tag("add_user_dict") or seg:has_tag("yin_add_user") or seg:has_tag("rvlk1")) then
        is_radical_mode = true
    end
    
    local cnt = 0
    local completion_cands = {}
    for cand in input:iter() do
        local text_equals_input = context.input:lower() == cand.text:lower() and #context.input == 1
              
        local cand_text = cand.text
        local cand_comment = cand.preedit.. "_" ..cand.type.. "_" ..cand.comment.. "_" ..cand.quality
        local new_cand = cand:to_shadow_candidate(
            cand.type,
            cand_text,
            cand_comment
        )

        cnt = cnt + 1  -- 逐个计数
      if context:get_option("char") and context:get_option("word") and context:get_option("sentence") and not has_backtick and not text_equals_input then
             yield(new_cand)
      else
        if is_radical_mode or has_other or cand.type == "punct" or is_prefix_input then
        --特殊候选词
             yield(new_cand)
        elseif cand.type == "time" or cand.type == "date" or cand.type == "day_summary" or cand.type == "xq" or cand.type == "oww" or cand.type == "ojq" or cand.type == "holiday_summary" or cand.type == "birthday_reminders" then
             yield(new_cand)
        elseif cnt <= 20 and utf8.len(cand.text) == 1 and cand.comment == "" and cand.type ~= "completion" then
        --虎单
          if context:get_option("char") and not has_backtick then
             yield(new_cand)
          end
        elseif cnt <= 30 and utf8.len(cand.text) > 1 and cand.comment == "" and not cand.text:find("[a-zA-Z]") then
        --虎词
          if context:get_option("word") and not has_backtick then
             yield(new_cand)
          end
        elseif (cand.type == "sentence" or (cand.type == "phrase" and utf8.len(cand.text) > 1)) and utf8.len(context.input) > 3 and not cand.comment:find(";") then
        --输入长度大于3时的虎句
          if context:get_option("sentence") and not has_backtick then
             yield(new_cand)
          end
        elseif cand.type == "phrase" and utf8.len(cand.text) == 1 and not cand.comment:find(";") then
        --虎句选字单字
          if context:get_option("sentence") and not schema_id and not has_backtick then
             yield(new_cand)
          end
        elseif cand.comment:find(";") then
        --拼音
          if yin_on or has_backtick then
             yield(new_cand)
          end
        elseif cand.text:find("[a-zA-Z]") and not text_equals_input then
             yield(new_cand)
        elseif cand.type == "completion" then
        --码表翻译器的enable_completion
          if text_equals_input then
          elseif utf8.len(context.input) == 3 then
             table.insert(completion_cands, cand)
          else
             yield(new_cand)
          end
        else
             yield(new_cand)
        end
      end
    end
        
    -- 按质量排序存储的候选项
    table.sort(completion_cands, function(a, b)
        return (a.quality or 0) > (b.quality or 0)
    end)
    
    -- 输出存储的补充候选项
    for _, cand in ipairs(completion_cands) do
        yield(cand)
    end

end

function M.fini(env)
    if env.select_notifier then
        env.select_notifier:disconnect()
    end
end

return M

