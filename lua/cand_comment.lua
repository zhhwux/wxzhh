-- 用于获取并传递原始候选词注释的模块
local cand_comment = {}

-- 全局变量存储原始注释，避免与其他模块冲突
_RIME_RAW_CAND_COMMENT = _RIME_RAW_CAND_COMMENT or {}

function cand_comment.init(env)
    -- 初始化工作
end

function cand_comment.func(input, env)
    for cand in input:iter() do
        -- 存储原始注释到全局变量（使用候选词文本作为键，应对可能的重复）
        _RIME_RAW_CAND_COMMENT[cand.text] = cand.comment
        yield(cand)
    end
end

return cand_comment
