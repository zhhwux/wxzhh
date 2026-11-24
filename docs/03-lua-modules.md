# 03 · Lua 模块与关键函数

本仓库的 Lua 扩展位于 [lua/](../lua)。按在 Rime 管线中的**挂载类型**可分为三类：

| 类型 | 挂载写法 | 入口约定 |
|------|---------|---------|
| **processor** | `lua_processor@*name` | `function(key_event, env)` 或 `{init, func, fini}` |
| **translator** | `lua_translator@*name` | `function(input, seg, env)` |
| **filter** | `lua_filter@*name` | `function(input, env)` 或 `{init, func, fini}` |

> `*` 表示组件名来自基础工程 `rime.lua` 的全局注册；本仓库只提供实现文件。个别模块直接 `return function(...)`（如 `switch_translator`、`set_schema_pro`），另一些 `return M`（含 `init/func/fini`）。

模块速览：

| 模块 | 类型 | 主要职责 | 行数 |
|------|------|---------|------|
| [quick_symbol_text2](#1-quick_symbol_text2lua--重复上屏) | processor | 重复上屏 / 快符引导 | 186 |
| [switch_translator](#2-switch_translatorlua--多翻译器聚合) | translator | 聚合多来源候选 | 169 |
| [set_schema_pro](#3-set_schema_prolua--方案切换指令) | translator | 斜杠指令改方案/双拼类型 | 296 |
| [wj](#4-wjlua--文件检索与管理) | translator | `/wj` 文件管理系统 | 710 |
| [chaifen](#5-chaifenlua--拆分注释) | filter | 候选拆分注释 | 152 |
| [db](#6-dblua--重码简词英文注音聚合过滤器) | filter | 重码/简词/英文/注音 | 697 |
| [temporary_word](#7-temporary_wordlua--临时简词与造词) | filter | 4 码临时简词、造词 | 398 |
| [auto_commit](#8-auto_commitlua--4码自动上屏) | filter | 4 码唯一上屏 / 5 码顶屏 | 187 |
| [read](#9-readlua--阅读功能) | filter | `/re` 阅读模式 | 463 |
| [unicode_display](#10-unicode_displaylua--unicode-显示) | filter | U+ 编码注释 | 61 |
| [switch_filter](#11-switch_filterlua--注释清洗与去冗余) | filter | 清洗注释、去冗余候选 | 20 |
| [common_filter](#12-common_filterlua--字符集过滤) | filter | 字符集过滤（辅助） | 102 |
| [yin](#13-yinlua--拼音候选生成辅助) | translator | 包装拼音翻译器（辅助） | 46 |
| [new_statistics](#14-new_statisticslua--输入速度统计) | translator | `/st` `/en` 速度统计 | 173 |
| [tiger_code_table](#15-码表数据模块) | data | 字→虎码 | 8501 |
| [wubi_code_table](#15-码表数据模块) | data | 字→五笔 | 8109 |

---

## 公共概念：`env` 与环境对象

Rime Lua 组件的 `env` 是一个跨调用持久化的表，常用于缓存。常用字段：

| 字段 | 含义 |
|------|------|
| `env.engine` | 引擎对象；`env.engine.context` 为输入上下文 |
| `env.engine.schema.schema_id` / `.config` | 当前方案 id / 配置读取器 |
| `env.engine.context.input` | 当前输入串 |
| `env.engine.context:get_option(name)` | 读取开关状态 |
| `env.engine.context.composition:back()` | 当前段（可 `.tags`） |
| `env.engine.context.commit_notifier` / `select_notifier` / `update_notifier` | 事件订阅 |
| `env.engine:commit_text(t)` | 直接上屏 |

---

## 1. quick_symbol_text2.lua —— 重复上屏

- **类型**：processor（`{init, fini, func}`），挂在 **processors 最前**（`@before0`）。
- **作用**：维护最近 **100 条**上屏历史，实现「重复上屏」「合并输出历史」「清空历史」，并处理 `;;` → 中文分号。

### 关键函数

| 函数 | 说明 |
|------|------|
| `is_ios_device()` | 判断是否 iOS（`HOME` 含 `/var/mobile/`） |
| `init(env)` | 读取 `recognizer/patterns/quick_text`；构建触发键 `trigger_list`（默认 `''`）；连接 `commit_notifier` 记录历史，连接 `update_notifier` 处理指令 |
| `processor(key_event, env)` | 输入长度为 2（或匹配触发键长度）时返回 `true` 拦截 |
| `fini(env)` | 断连通知器；iOS 下保存历史到文件 |

### 触发规则（update_notifier 内）
| 输入 | 行为 |
|------|------|
| `/spql` | 清空全部历史 |
| `;;` | 若 `quick_text` 未配置为 `;;`，上屏「；」 |
| `'`` `（双符号 `'``） | 合并上屏全部历史 |
| `''` 或自定义触发 | 上屏最近一条 |

### 持久化
- **iOS**：写入 `$HOME/Documents/rime_history.txt`（环形 100 条）。
- **其它平台**：模块级内存表 `commit_history`（进程内有效）。

### 相关配置
- `recognizer/patterns/quick_text`（可选，自定义触发键）
- 快捷重复键 `historySJ/historyDM/historyDM3`（在 `wanxiang_pro.custom.yaml`）

---

## 2. switch_translator.lua —— 多翻译器聚合

- **类型**：translator，返回 `function(input, seg, env)`，挂在 `translators @before1`。
- **作用**：把 `char_word / yin_engine / sentence / wx_english` 四类翻译器**统一封装**，按开关与方案 id 决定是否启用、输出多少候选、候选类型与优先级。

### 数据驱动结构 `sources`
每个 source 定义：`name / option / type / max_candidates / priority / min_input_length / filter / candidate_filter / candidate_config`。

| source | 触发开关 | 翻译器 | 优先级 | 关键条件 |
|--------|---------|--------|-------|---------|
| `char_word` | `char`(单字) / `word`(词) | table_translator | 300 | 按字数过滤 |
| `yin_engine` | `yin` | script_translator | -1 | 非 wanxiang_pro |
| `sentence` | `sentence` | script_translator | 50 | 方案=wanxiang_pro 或输入≥8；最短长度 4 |
| `wx_english` | `english_word` | table_translator | 300 | 非 wanxiang_pro |

### 关键函数
| 函数 | 说明 |
|------|------|
| `get_translator(env, source)` | 用 `Component.Translator(env.engine,"", full_name)` 创建并缓存翻译器 |
| `should_enable_source(...)` | 统一判断开关、最小长度、方案过滤 |
| `create_candidate(...)` | 复制候选为指定 `type/start/end`，设置 `quality = priority - index`、`comment`、`preedit` |
| `lua_translator(input, seg, env)` | 主循环：遍历 sources，`translation:iter()` 逐个 yield |

> 设计要点：通过 `candidate_config` 的 `dynamic_end` 让候选的结束位置跟随输入长度；用 `use_native_type` 决定是否保留原候选类型。

---

## 3. set_schema_pro.lua —— 方案切换指令

- **类型**：translator，返回 `function(input, seg, env)`，挂 `translators @before6`。
- **作用**：把斜杠指令解析为**改写 `*.custom.yaml` 文件**的操作（部署后生效），实现「整句规则切换」「键位映射切换」「双拼类型切换」「辅助码类型切换」。

### 依赖
`require("wanxiang/wanxiang")`（外部基础工程）。

### 指令表

**A. 整句规则 / 键位（改写 `<schema_id>.custom.yaml`）**
| 指令 | 目标 |
|------|------|
| `/wxh` `/mets` `/xumn` `/kjzb` `/wxwb` | 万象虎 / 二三整句 / 原码整句 / 九键虎 / 万象五笔 |
| `/shiba` `/shiwu` `/shisi` | 18 / 15 / 14 键映射 |

**B. 辅助码类型（改写 `wanxiang_pro.custom.yaml`）**
| 指令 | 目标 |
|------|------|
| `/zjf` | 直接辅助 |
| `/jjf` | 间接辅助 |

**C. 双拼类型（改写 `wanxiang_pro.custom.yaml` 等 4 个文件）**
| 指令 | 方案 |
|------|------|
| `/flypy` `/mspy` `/zrm` `/sogou` `/znabc` `/ziguang` `/pyjj` `/gbpy` `/lxsq` `/zrlong` `/hxlong` `/pinyin` `/wxsp` | 小鹤/微软/自然码/搜狗/智能ABC/紫光/拼音加加/国标/乱序17/自然龙/汉心龙/全拼/万象双拼 |

### 关键函数
| 函数 | 说明 |
|------|------|
| `copy_file(src,dest)` / `file_exists(path)` | 文件工具 |
| `replace_schema(file_path, target)` | 按文件名与正则替换 `wanxiang_algebra:/xxx/…` 中的方案名 |
| `translator(input, seg, env)` | 主逻辑：识别指令 → 读取旧文件 → 构造新的 YAML 头部（受 `marker` 分隔）→ 写回 → yield 提示候选 |

### 关键机制：受控区与 marker
文件里那条 `##########################以上格式受指令初始化控制…##########` 是**受控区边界**：脚本只重写 marker **之前**的头部，marker 之后的用户自定义内容原样保留。若用户改动了头部格式导致 marker 丢失，脚本会把新头部插入文件最前并保留原内容。

### 特殊分支
- 若当前方案就是 `wanxiang_pro`，**禁用一切指令**（第 66 行）。
- 若基础规则是「虎码原码整句 / 二三整句 / 九键虎」，还会同步写入 `speller/delimiter`、`speller/alphabet`、`sentence/prism`。

---

## 4. wj.lua —— 文件检索与管理

- **类型**：translator（`{init, func}`），返回 `T`，挂 `translators +`，前缀 `/wj`。
- **作用**：一个「输入法内的文件管理器」，用斜杠语法完成**检索 / 读取 / 替换 / 删除 / 新建 / 复制 / 移动 / 集合运算 / 分组 / 重码合并 / 组词库处理**。

### 关键函数
| 函数 | 说明 |
|------|------|
| `parse_suffix_idx` | 解析末尾数字（用于「选第 N 个」） |
| `scan_fs(user_dir, is_dir, pattern)` | 用 `find`/`dir` via `io.popen` 扫描用户目录 |
| `search_filter(input_str, env, is_dir)` | 空格分词模糊匹配 + 可选序号选择 |
| `handle_file` | `文件名@关键词` 检索行；`文件名@/` 整体；`@//新/` 整体替换 |
| `handle_fs` | `/wjnew"…"` 新建、`/wjdel"…"` 删除 |
| `handle_replace` | `文件名@旧/新/`、`文件名@旧/新/gi` 行内替换 |
| `handle_cp_mv` | `&源&目标&` 移动、`+&源&目标&` 复制 |
| `handle_set_ops` | `_@ / +@ / -@ / -h@ / _h@ / -hn@ / _hn@` 集合运算 |
| `handle_group` / `handle_dup` | `_@文件&` 分组、`_&文件&` 重码合并 |
| `handle_zuci` | `/zuci` 批量处理词库（加 `columns`、清洗列） |
| `T.func` | 总入口，按顺序尝试各 handler，命中后设 `seg.tags.calculating=true` |

### 全部语法（`func` 内 hints）
| 语法 | 功能 |
|------|------|
| `文件名@内容` | 检索文件内容 |
| `文件名2@内容3/` | 选择第 2 个文件、第 3 个匹配 |
| `文件名@/` | 合并输出整个文件 |
| `文件名@旧/新/` | 行内替换 |
| `文件名@//新内容/` | 整体覆盖 |
| `new"目录/文件"` / `del"目录/文件"` | 新建 / 删除 |
| `+&源&目标&` / `&源&目标&` | 复制 / 移动 |
| `_@f1@f2@` / `+@f1@f2@` / `-@f1@f2@` | 取重 / 合并 / 去重（按字符） |
| `-h@` / `_h@` | 行去重 / 行取重 |
| `-hn@` / `_hn@` | 行内去重 / 行内取重 |
| `_@文件&` | 按首特殊字符分组 |
| `_&文件名&` | 重码合并 |
| `/zuci` | 组词词库处理 |

> 该模块重度使用 `io.popen`：**Windows 与类 Unix 的命令分支不同**（`path_sep=='\\'` 判断）。

---

## 5. chaifen.lua —— 拆分注释

- **类型**：filter，暴露 `{CF, ZH, func=ZH.func, clear_char_cache}`，挂 `filters`。
- **作用**：为候选词附加「部首拆分」注释，例如 `好 → 女子`。按方案缓存，性能敏感。

### 两级缓存
```lua
global_cache[schema_id] = { dict, mode, char_cache, display_mode }
```
- `dict`：`ReverseLookup("tiger_lookup")`（五笔方案用 `wubi_lookup`）；
- `char_cache`：单字 → 拆分结果缓存；
- `display_mode`：读 `enum/chaifen`（`char` 只拆单字 / `all` 全拆）。

### 关键函数
| 函数 | 说明 |
|------|------|
| `CF.init(env)` | 按方案初始化缓存（复用，避免重复加载词典） |
| `process_single_char(cache, char)` | 单字查表 + 缓存 |
| `CF.run(cand, env)` | 单字直接返回拆分；多字在 `all` 模式下逐字拼接 |
| `ZH.init(env)` | 判断是否启用：① `chaifen` 开关 ② 处于反查 tag（`yin_add_user/rvlk1/rvlk2`）③ 输入含 `` ` ``/`*` 且不以 `ZVRNU/;` 开头 |
| `ZH.func(input, env)` | 启用则写 `cand:get_genuine().comment`，否则透传 |
| `CF.clear_char_cache(schema_id)` | 手动清缓存（词典更新后） |

---

## 6. db.lua —— 重码/简词/英文/注音聚合过滤器

- **类型**：filter（`{init, func, fini}`），返回 `merged_dict`，挂 `filters @before6`。这是**最复杂**的模块，内聚四个子库。

### 依赖
`require("wanxiang/wanxiang")`、`require("wanxiang/userdb")`。

### 6.1 四个子模块

| 子模块 | 数据源 | 职责 |
|--------|--------|------|
| `collision_dict` | `chongma_tiger.txt` / `chongma_wubi.txt` | 重码词替换（把句中错词替换为更合理的词），DFS 生成最多 10 种组合 |
| `tigress_ci_dict` | `tiger_dicts/tigress/tigress_ci.dict.yaml` | 3 码简词补全（按前 3 码分桶） |
| `en_dict` | `dicts/en.dict.yaml` | 英文/中英词检索（按首字母分 7 桶，前缀索引） |
| `zhuyin` | `lua/zhuyin.txt`、`zhuyin_zi.txt` + `ReverseLookup("wanxiang_pro")` | 注音注释（`pinyin` 开关开启时） |

### 6.2 版本化 LevelDB 缓存
所有子库都通过 `userdb.LevelDb` 建库，并用 `fast_init_db(name, internal_version, meta_key)`：
- 当 `db:meta_fetch(version) != internal_version` 时**重建**；
- `collision_dict` 还计算**源文件签名**（`calc_file_signature`，FNV 哈希 + 字节数），源文件变化即重建；
- 重建耗时写入 `lua/data/db_rebuild.log`（`log_rebuild`）。

### 6.3 关键函数

| 函数 | 说明 |
|------|------|
| `find_dict_path(filename)` | 在 `用户目录/lua/`、`用户目录/` 查找数据文件 |
| `get_level_db(db_name)` | 弱引用池缓存 LevelDB 句柄 |
| `collision_dict.init/calc_file_signature/find_valid_matches/apply_replacements` | 重码替换全流程 |
| `tigress_ci_dict.init/get_candidates(prefix)` | 3 码简词 |
| `en_dict.init/func(ctx, input_code)` | 英文检索，返回 Candidate 列表（≤50） |
| `zhuyin.init/func(ctx, cand)` | 多音字注音，写 `comment` |
| `merged_dict.init(e)` | 依次初始化四库，并连接 `select_notifier`（处理 `` ` `` 后缀搜索） |
| `merged_dict.func(input, env)` | 主过滤：先注音 → 重码替换 → 追加 3 码简词 → 追加英文 |

### 6.4 重码替换算法（collision）
1. 句子的 preedit 按空格切分得到各字编码长度，只有**每字 2 码**才参与；
2. 在词库中匹配 1–4 长度的词，剔被子词包含的项；
3. 对每个匹配项枚举其重码候选，`dfs` 生成替换组合（上限 `MAX_COMBINATIONS=10`）；
4. 用 `apply_replacements` 生成新句，`quality = 原质量 - i*100` 降权；
5. 依 `chongma_off`/`tishi_off` 开关决定是否替换/加提示。

---

## 7. temporary_word.lua —— 临时简词与造词

- **类型**：filter（`{init, func, fini}`），返回 `M`，挂 `filters @before7`。
- **作用**：实现「4 码临时简词」「文件简词」「永久简词」「选字造词」的存储与检索。

### 依赖
`safe_require("wanxiang/userdb")`（可选，缺失时降级）。

### 核心概念
- **码表**：启动时把 `tiger_code_table.lua` / `wubi_code_table.lua` 灌入 LevelDB（`lua/tiger_code` / `lua/wubi_code`），用 `code_table:fetch(char)` 取字码。
- **造词取码**（`get_tiger_code`）：
  - 2 字：各取前 2 码；
  - 3 字：前两字各 1 码 + 末字 2 码；
  - ≥4 字：前 3 字各 1 码 +（`1234` 模式取第 4 字 / 否则取最后一字）1 码；
  - 由 `enum/jianci` 控制（`1230` / `1234`）。

### 存储位置
| 数据 | 路径 |
|------|------|
| 永久简词 | `custom_phrase/jianci.lua`（iOS：`$HOME/Documents/rime_user_words.lua`） |
| 文件简词源 | `custom_phrase/user.txt` |

### 关键函数
| 函数 | 说明 |
|------|------|
| `Utils.get_path/save_lua_table/utf8_sub/trim_invalid_chars` | 路径、序列化、UTF-8 工具 |
| `CodeTableDB.init(env, mode)` | 码表入库（版本 `1.0`） |
| `get_tiger_code(env, word)` | 按规则生成词码 |
| `M.build_reverse_index` | 建立「码 → 词」反查索引（按时间排序） |
| `M.init` | 读配置、建码表、加载永久库、处理 `user.txt`、订阅 `commit_notifier` |
| `M.process_user_txt(env, load, allow_create)` | 解析 `user.txt`（支持 `word`/`word\tcode`/`word\tcode\tweight`），缺失编码自动补全 |
| `M.update_history` | 上屏后记录；4 码上屏时更新永久简词并落盘 |
| `M.func` | 指令处理 + 按编码聚合「临时 / 永久⭐ / 文件📁」三类候选 |
| `M.fini` | 断连、关闭库 |

### 指令
| 指令 | 作用 |
|------|------|
| `/jcql` | 清空简词 |
| `/wjjc` | 加载/生成文件简词编码（不产出候选） |
| `/zyj` | 文件简词 → 永久简词 |
| `/zwj` | 永久简词 → 导出到文件 |

---

## 8. auto_commit.lua —— 4 码自动上屏

- **类型**：filter（`{init, func, fini}`），返回 `M`，挂 `filters`。
- **作用**：在「虎单/虎词开关打开且虎句关闭」时，实现三种自动行为。

### 配置（`char_word/*`）
```yaml
four_auto_commit: true    # 4码唯一自动上屏
four_auto_clear: false    # 4码空码自动清屏
five_commit_four: true    # 5码顶屏
```

### 逻辑（`M.func`）
1. **短路**：`sentence` 开启 / 方案是 `wanxiang_pro` / 处于反查 tag → 直接透传。
2. 收集候选并统计 `table/user_table` 数量 `candidate_count`。
3. 输入 4 码：
   - `candidate_count==1 && four_auto_commit` → 上屏并清空；
   - `candidate_count==0 && four_auto_clear` → 清屏；
   - 否则记录首候选到 `env.tiger_four`（供 5 码顶屏）。
4. 输入 5 码且 `five_commit_four` 且前缀匹配 → 顶屏首候选，并用 `letter_map_*` 生成下一字候选：
   - `letter_map_tiger`（虎单）/ `letter_map_tigress`（虎词）/ `letter_map_wubi_one|two`（五笔）。

> 这是典型的「**用 filter 干预上屏**」技巧：直接调用 `env.engine:commit_text()` 并 `context:clear()`。

---

## 9. read.lua —— 阅读功能

- **类型**：filter（`{init, func, fini}`），返回 `M`，挂 `filters`。
- **作用**：把 `custom_phrase/read.txt` 当作「书」，按行/按标点分段逐段输出，实现边打字边阅读。

### 文件与状态
| 文件 | 作用 |
|------|------|
| `custom_phrase/read.txt` | 待阅读文本 |
| `lua/read_state.txt` | 保存「全局已读行号」 |

### 双层缓存（`FORCE_CONFIG`）
- `line_cache`：每次缓存 1000 行；
- `segment_cache`：当前行按中英文标点切分的片段；
- `global_line_index`：已读总行数（持久化）。

### 关键函数
| 函数 | 说明 |
|------|------|
| `M.save_read_state` / `load_read_state` | 进度存取（UTF-8，65001） |
| `read_lines_by_skip(path, skip, take)` | 跳过已读、批量读行 |
| `parse_line_segments(line)` | 按 `，、。；,;？！?!：:…` 切分 |
| `M.load_read_txt` | 加载缓存，处理文件缺失/空/读完等状态 |
| `M.get_current_candidate` / `next_candidate` | 取当前/下一段 |
| `handle_switch_commands` | `/re` 开启；单独 `/` 或含 `/` 关闭 |
| `M.func` | 阅读模式下输出首候选（正文）与空候选（占位） |

---

## 10. unicode_display.lua —— Unicode 显示

- **类型**：filter，返回 `function(input, env)`，挂 `filters`。
- **作用**：`udpf_switch` 开启时，给单字候选注释追加 `[U+xxxx]`。
- 关键：`C2U(char)` 用 `utf8.codepoint` → `%x`；只处理 `utf8.len==1` 的候选。

---

## 11. switch_filter.lua —— 注释清洗与去冗余

- **类型**：filter（`return M`，`func(input, env)`），挂 `filters`。
- **作用**：
  1. 去掉候选注释中的格式字符 `' - , 0 ￣`；
  2. 输入长度为 1 且候选是 `completion` 且文本等于输入时，**丢弃**该冗余候选。

---

## 12. common_filter.lua —— 字符集过滤

- **类型**：filter（`{init, fini, func}` + 工具函数），返回 `charsfilter`。
- **说明**：本仓库的 `*.yaml` **未直接引用**它（字符集过滤实际由基础工程的 `charset_filter` 承担）。保留作为「常用字/生僻字过滤」的独立实现参考。
- 关键函数：`IsChineseCharacter`（覆盖 CJK 基本区及扩展 A–I、兼容区、私用区等）、`InCharset`、`IsReverseLookup`（反查时不过滤）。

---

## 13. yin.lua —— 拼音候选生成辅助

- **类型**：translator，返回 `function(input, seg, env)`。
- **说明**：用 `Component.Translator(env.engine,"","script_translator@yin_engine")` 包装拼音翻译器，产出带 `🎼` 注释的候选（上限 20）。当前虎系通过 `switch_translator` 的 `yin_engine` source 实现同样能力，本文件为**独立/备用实现**，未在仓库 yaml 中直接挂载。

---

## 14. new_statistics.lua —— 输入速度统计

- **类型**：translator（`{init, func}`，`return {init, func}`）。
- **作用**：`/st` 开始、`/en` 结束，生成「输入条数/总字数/平均速度/最快一分钟」报告；结果持久化到 `lua/input_stats.lua`。
- 关键：`format_custom_summary(temp_stats)` 生成报告；`ctx.commit_notifier` 累加统计；排除 `※◉` 开头的系统文本。

---

## 15. 码表数据模块

| 文件 | 结构 | 用途 |
|------|------|------|
| [tiger_code_table.lua](../lua/tiger_code_table.lua) | `local tiger_code_table = {["啊"]="dtzk", ...}` 约 8498 条 | `temporary_word` 生成简词码 |
| [wubi_code_table.lua](../lua/wubi_code_table.lua) | 同上，五笔编码 | 五笔版本造词 |

这两个文件是**纯数据**，启动时由 `temporary_word.lua` 的 `CodeTableDB.init` 灌入 LevelDB。

---

## 16. 模块与配置的耦合速查

| Lua 读取的配置键 | 使用模块 |
|------------------|---------|
| `char_word/dictionary` | chaifen、temporary_word、db、auto_commit |
| `enum/chaifen` | chaifen |
| `enum/jianci` | temporary_word |
| `enum/zhuyin` | db（zhuyin） |
| `char_word/four_auto_commit|four_auto_clear|five_commit_four` | auto_commit |
| `recognizer/patterns/quick_text` | quick_symbol_text2 |
| `char_word/dictionary`（wubici 判定） | 多模块切换五笔/虎码数据源 |

---

**下一篇** → [04 · 词库与数据资产](04-dictionary-data.md)
