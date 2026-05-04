local M = {}

function M.func(input, env)
    local context = env.engine.context
    local input_len = #context.input
    local input_lower = context.input:lower()

    for cand in input:iter() do
        local text_equals_input = input_len == 1 and (input_lower == cand.text:lower())
        local cand_comment = cand.comment or ""
        if cand_comment ~= "" then
          cand_comment = cand_comment:gsub("'", ""):gsub("%-", ""):gsub(",", ""):gsub("0", ""):gsub("￣", "")
        end
        local new_cand = cand:to_shadow_candidate(cand.type, cand.text, cand_comment)
        if not (cand.type == "completion" and text_equals_input) then
            yield(new_cand)
        end
    end
end

return M