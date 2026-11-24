# 02 · 方案（Schema）配置详解

本篇逐个说明仓库中的「方案定义文件」与「补丁文件」，解释每个字段的作用。所有行号以当前仓库为准。

文件清单：

| 文件 | 类型 | 作用 |
|------|------|------|
| [default.yaml](../default.yaml) | 全局默认 | 方案清单、菜单、中西文切换、识别器、快捷键 |
| [default.custom.yaml](../default.custom.yaml) | 全局补丁 | 调整启用方案 |
| [tiger.schema.yaml](../tiger.schema.yaml) | 方案 | **万象虎**（默认主方案） |
| [wanxiang_pro.custom.yaml](../wanxiang_pro.custom.yaml) | 方案补丁 | 虎系引擎管线追加（关键） |
| [mets.schema.yaml](../mets.schema.yaml) | 方案 | 虎码二三整句 |
| [xumn.schema.yaml](../xumn.schema.yaml) | 方案 | 虎码原码整句 |
| [9jianhu.schema.yaml](../9jianhu.schema.yaml) | 方案 | 九键虎（自带完整 engine） |
| [tigress.schema.yaml](../tigress.schema.yaml) | 方案 | 官虎字词（纯字词） |
| [tiger_en.schema.yaml](../tiger_en.schema.yaml) | 方案 | 虎码中英混合翻译器 |
| [tiger_lookup.schema.yaml](../tiger_lookup.schema.yaml) | 方案 | 反查拆分注释（仅词库，无 engine） |
| [wxh_algebra.yaml](../wxh_algebra.yaml) | 片段 | 可复用的拼写运算代码块 |
| [new_symbols.yaml](../new_symbols.yaml) | 数据 | 全类符号表 |

---

## 1. default.yaml —— 全局默认

这是 Rime 的**顶层全局配置**，所有方案共享。

### 1.1 方案清单
```yaml
config_version: '2024-08-05'
schema_list:
  - schema: tiger        # 虎码2-4任意码整句（默认）
  - schema: wanxiang_pro # 拼音方案
  - schema: mets         # 虎码23整句
  - schema: xumn         # 虎码原码整句
  - schema: 9jianhu      # 9键虎
```
`config_version` 必须**大于**共享目录同名文件的版本，本文件的修改才会生效。

### 1.2 菜单与选单
```yaml
menu:
  page_size: 6            # 每页 6 个候选（7890 用作声调）
switcher:
  caption: 「方案选单」
  hotkeys: [Control+grave]   # Ctrl+` 呼出
  save_options: [ ascii_punct, traditionalization, s2t, ... ]  # 需跨会话记忆的开关
  fold_options: true
```
- `save_options` 列出了「方案选单里切换后会记住」的开关，这些开关**不能**设 `reset`。

### 1.3 中西文切换（ascii_composer）
```yaml
ascii_composer:
  good_old_caps_lock: true
  switch_key:
    Caps_Lock: clear
    Shift_L: commit_code   # 半途按 Shift 先上屏编码再切英文
    Shift_R: commit_code
    Control_L/R: noop
```

### 1.4 识别器（recognizer）
全局识别 `email`、`url`、`underscore` 等模式，命中后该段不上屏（交由对应 tag 处理）。各方案可 `import_preset: default` 继承并追加自己的 pattern。

### 1.5 全局快捷键（key_binder）
- `[` / `]`：以词定字（上屏当前词句首/末字）。
- `Alt+←/→`：移动输入光标。
- `-` / `=`：上下翻页。
- `Control+Shift+1`：在最近两个方案间切换。
- `Control+Shift+3`：中英标点；`Control+Shift+4`：简繁。
- 小键盘 `KP_*` 映射到主键盘（便于金额大写等）。

---

## 2. tiger.schema.yaml —— 万象虎（主方案）

```yaml
__include: wanxiang_pro.schema.yaml:/
```
第一行即「继承万象拼音全部配置」，随后只写虎码差异。

### 2.1 方案元信息
```yaml
schema:
  schema_id: tiger
  name: 万象虎
  dependencies: [ tiger_en, tiger_lookup, tigress ]
```
`dependencies` 让词库 / 反查能在部署时一并编译，供 `lua` 的 `ReverseLookup` 使用。

### 2.2 开关（switches）
用户可切换的功能状态，是整套交互的核心：

| name | states | 含义 |
|------|--------|------|
| `english_word` | 中 / 英 | 中英单词候选 |
| `chaifen` | 隐 / 拆 | 拆分滤镜 |
| `pinyin` | 字 / pīn | 拼音滤镜（注音） |
| `charset_filter` | 全 / 常 | 常用字过滤（reset:1 默认开） |
| `sentence` | 关 / 虎句 | 虎码整句（reset:1） |
| `word` | 关 / 虎词 | 虎词（reset:1） |
| `char` | 关 / 虎单 | 虎单（reset:1） |
| `yin` | 关 / 音码 | 拼音混输 |
| `completion` | 关 / 提示 | 3 码 completion |
| `super_tips` | off / tips | 万象超级提示 |
| `chongma_on/off` `tishi_off` | 重码开/关/提示关 | 重码替换三态 |
| `tone_display` | 关 / 句pīn | 整句注音 |
| `comment_off/fuzhu_hint` | 注关 / 辅开 | 拼音辅助码滤镜 |
| `chaifen_switch` | 拆分关 / 开 | 候选实时拆分提醒 |
| `ascii_punct` | ¥ / $ | 中英标点 |
| `full_shape` | 半角 / 全角 | 全半角 |
| `s2s/s2t/s2hk/s2tw` | 简/通繁/港繁/臺繁 | 简繁转换 |
| `emoji` | 🙃 / 😄 | emoji |
| `udpf_switch` | 关 / U编 | Unicode 显示 |
| `chinese_english` | 关 / 翻译 | 中英翻译 |

### 2.3 翻译器与词库参数

```yaml
translator:            # 整句翻译器
  dictionary: tiger
  prism: wxh
  enable_user_dict: false      # 关闭自动调频
  enable_completion: false
  initial_quality: 99

yin_engine:            # 拼音混输引擎
  dictionary: wanxiang_pro

user_dict_set:         # 「虎码造词」使用词汇入口
  dictionary: tiger
  prism: wxh
  initial_quality: 0
  core_word_length: 4          # 按段学词 + 相邻段拼接
  max_word_length: 7
  enable_user_dict: true
  user_dict: custom_phrase/zaoci
  db_class: tabledb

add_user_dict:         # 「虎码造词」制造词汇入口
  user_dict: custom_phrase/zaoci

tiger_en:              # 中英混合表
  dictionary: tiger_en
  db_class: stabledb
  initial_quality: 2

char_word:             # 虎单/虎词（官虎字词）
  dictionary: tigress
  user_dict: custom_phrase/user
  db_class: stabledb
  initial_quality: 9999        # 置顶
  four_auto_commit: true       # 4码唯一自动上屏
  four_auto_clear: false       # 4码空码自动清屏
  five_commit_four: true       # 5码顶屏

enum:
  chaifen: all                 # char|all 只显示单字拆分|完全拆分
  jianci: 1230                 # 1230|1234 四字以上造词取码规则
```

> 注意 `custom_phrase`、`chengyu`、`wanxiang_english`、`wanxiang_mixedcode` 被**显式清空**（`dictionary: ""`），表示虎码方案不启用这些翻译器，避免与拼音冲突。

### 2.4 拼写与分词（speller）
```yaml
speller:
  alphabet: zyxwvutsrqponmlkjihgfedcbaZYXWVUTSRQPONMLKJIHGFEDCBA7890;*/\[]
  initials: ...;\[\]          # 仅作始码的键（排除 ` 使单个反引号可上屏）
  delimiter: " '"             # 空格分隔 + 单引号手动分词
  auto_select: true
  auto_select_pattern: ^;\w+  # ; 引导的唯一候选自动上屏
  algebra:                    # 拼写运算（编码变换规则）
    - xform/[-￣]//                    # 去掉重码标记
    - derive/^(\w)(\w),(\w)(\w)$/$1$2/   # 纯双拼
    - derive/.../$1$2$3/                 # 双拼+1位辅助码
    - derive/.../$1$2$3$4/               # 双拼+2位辅助码
    - derive/[a-z](.*)/*$1/              # 通配符 * 派生
    ...
```
`algebra` 是 Rime 的**拼写运算 DSL**：`xform` 转换、`derive` 派生、`xlit` 字符替换、`abbrev` 简写……这里主要用于：
1. 清洗编码中的重码标记 `￣`、`-`；
2. 把「双拼+辅助码」的逗号结构展开成多种合法编码；
3. 用 `*` 生成通配符编码（忘记拆分时可用）。

---

## 3. wanxiang_pro.custom.yaml —— 虎系管线追加（关键）

这是**理解万象虎如何扩展引擎**的核心文件。它通过 `patch:` 对 `wanxiang_pro` 追加工件。

### 3.1 拼写运算补丁
```yaml
patch:
  speller/algebra:
    __patch:
      - wanxiang_algebra:/pro/小鹤双拼   # 默认双拼类型
      - wanxiang_algebra:/pro/直接辅助    # 辅助码类型
```
这两项引用基础工程的 `wanxiang_algebra`，是「运行时可被 `/flypy`、`/zrm` 等指令改写」的对象（见 `set_schema_pro.lua`）。文件里那条长注释 `##########以上格式受指令初始化控制##########` 是 `set_schema_pro.lua` 改写文件时的分隔标记，**不要随意改动**。

### 3.2 引擎组件追加
见 [01-整体架构 §3.1](01-architecture.md#31-虎系方案tiger--mets--xumn--9jianhu)。它在 `processors / segmentors / translators / filters` 四个阶段插入虎码所需组件。

### 3.3 其它补丁
```yaml
punctuator:
  digit_separators: ":,."
  __include: new_symbols:/symbol_table   # 引入全类符号
  half_shape/+: { ';': [：, ；] }         # 半角分号映射

recognizer/patterns/+:
  yin_add_user: "^[A-Za-z']*`$|^'[A-Za-z']*$"   # 拼音反查
  add_user_dict: "^`[A-Za-z']*$"                # 虎码自造词
  semicolon: ";;"
  wj: "^/wj.*$"                                 # 文件管理

key_binder/bindings/+:   # 虎码专属快捷键
  - { accept: semicolon, send: 2, when: has_menu }          # 分号次选
  - { accept: "Control+m", toggle: english_word }           # 中英
  - { accept: "Control+q", toggle: yin }                    # 音码
  - { accept: "Control+y", toggle: pinyin }                 # 注音
  - { accept: "Control+z", toggle: chaifen }                # 拆分
  - { accept: "Control+r", toggle: completion }             # 提示
  - { accept: "Control+a", toggle: sentence }               # 虎句
  - { accept: "Control+s", toggle: word }                   # 虎词
  - { accept: "Control+d", toggle: char }                   # 虎单

historySJ: { input: z, size: 3, initial_quality: 99 }       # 重复上屏（手机）
historyDM: { input: "[", size: 99, initial_quality: 0 }     # 重复上屏（电脑）
historyDM3: { input: "]", size: 99, initial_quality: 0 }

add_user_dict:   # 虎码造词：` 前缀
  prefix: "`"
  tips: "〔虎〕"
  user_dict: zc
  enable_auto_phrase: true

yin_add_user:    # 拼音反查：' 前缀 或 ` 后缀
  prefix: "'"
  suffix: "`"
  tips: "〔音〕"
  enable_auto_phrase: true

sentence:        # 虎句
  dictionary: tiger
  prism: wxh
  user_dict: custom_phrase/zaoci
  db_class: stabledb
  enable_sentence: true
  initial_quality: 99
  comment_format:
    - xform/~[A-Za-z]*//   # 去掉内部拼音标记
```

---

## 4. mets.schema.yaml —— 虎码二三整句

```yaml
__include: tiger.schema:/
schema: { schema_id: mets, name: 虎码二三整句 }

translator:  { dictionary: tiger, prism: mets, ... }
add_user_dict: { prism: mets }
user_dict_set: { prism: mets }
sentence:      { prism: mets }

speller:
  algebra:
    - xform/[,-0]//      # 去掉重码标记与辅助码
    - xform/￣.*$//
    - derive/[a-z](.*)/*$1/ ...   # 通配符
```
**核心差异**：`prism: mets` + 专门的 algebra。编码规则为「1–2 根字 2 码，3–n 根字 3 码」（见文件首行注释），通过不同的 prism（码表投影）实现，词库仍是 `tiger`。

---

## 5. xumn.schema.yaml —— 虎码原码整句

```yaml
__include: tiger.schema:/
schema: { schema_id: xumn, name: 虎码原码整句 }

speller:
  alphabet: ...7890_;*/\'[]   # 增加 _ 与 '
  delimiter: " _"              # 分词符改为下划线
  algebra:
    - xform/[,￣0]//
    - xform/-.*$//
    - derive/...                # 通配符
```
**核心差异**：编码规则「最短首选编码，1 码字后加 `'` 后缀」，分词符 `_`，prism `xumn`。

---

## 6. 9jianhu.schema.yaml —— 九键虎

与其它虎系方案不同，它**自带完整 `engine`**（不继承万象管线），并重写了开关（去掉虎句/虎词/音码等，只保留拆分、拼音、中英、全角、U编）。

### 6.1 九键拼写运算（重点）
`speller/algebra` 分两段：

1. **无重码的九键方案**：把 26 键编码映射到 9 个键位（T9），并用 `xform`/`derive` 区分「选择位」与「编码位」，保证任意码长都有候选；
2. **适配九键布局**：把 `[abc]→a`、`[def]→d` … `[qw]→q`，使**字母键盘与九键键盘可同时使用**（`derive` 兼容原键盘）。

```yaml
- xform/[abc]/a/
- xform/[def]/d/
...
- xform/[qw]/q/     # 与传统九宫格不同：1 键映射到 q/w
- derive/[a-z](.*)/*$1/   # 通配符
```
拼音滤镜使用 `opencc/pinyin.json`，`show_in_comment: true`。

### 6.2 引擎组件
见 [01 §3.2](01-architecture.md#32-九键虎9jianhu)。

---

## 7. tigress.schema.yaml —— 官虎字词

纯字词方案（`enable_sentence: false`），`initial_quality: 9999`。自带完整 engine，并在 `translators` 中挂载：
- `set_schema_pro`（/zrm 等拼音类型切换）
- `shijian`（时间日期）、`unicode`、`super_calculator`
- `yin_add_user`（音码造词）
- `historyDM / DM3 / SJ`（重复上屏）

`recognizer` 中 `import_preset: default` 继承全局，并追加 `punct`、`yin_add_user`、`calculator(^V)`、`unicode(^U)` 等。

`speller` 中 `auto_clear: max_length`、`max_code_length: 4`，`auto_select_pattern: ^;\w+|^\w{4}$`（可加四码上屏）。

---

## 8. tiger_en.schema.yaml —— 中英混合翻译器

`table_translator` 专用方案，词库 `tiger_en`。`speller/algebra` 通过 `__include: 虎` + `__patch: AZtoaz` 定义：
- `虎`：剥离拼音声调、处理 `ü/ue` 等；
- `AZtoaz`：派生大小写（`derive/A/a/` … `derive/Z/z/`）。

被 `tiger` 通过 `table_translator@tiger_en` 引用为「中英混合词」来源。

---

## 9. tiger_lookup.schema.yaml —— 拆分反查

结构极简，只有：
```yaml
schema: { schema_id: tiger_lookup, name: 反查拆分注释滤镜 }
translator: { dictionary: tiger_lookup }
```
它**没有 engine**，仅用于让 `tiger_lookup.dict.yaml` 参与部署编译，从而被 `chaifen.lua` 的 `ReverseLookup("tiger_lookup")` 查询（字 → 部首拆分）。

---

## 10. wxh_algebra.yaml —— 可复用拼写片段

集中定义若干**具名拼写运算块**，供 `set_schema_pro.lua` 写入 `*.custom.yaml` 时引用：

| 块名 | 作用 |
|------|------|
| `万象虎` | 双拼 + 辅助码的逗号展开 |
| `虎码二三整句` | 去 `,-0` / `￣` |
| `虎码原码整句` | 去 `,￣0` / `-` |
| `九键虎` | 完整九键映射（与 9jianhu.schema 一致） |
| `万象五笔` | 五笔兼容 + 万能 z |
| `通配符` | `*` 派生规则 |
| `18jian/15jian/14jian` | 键位压缩（`xlit` 重映射） |
| `9jian` | 拼音九宫格数字映射 |

这些块正是「`/shiba`、`/shiwu`、`/shisi` 按键映射切换指令」和「`/wxh`、`/mets`、`/xumn`、`/kjzb` 整句规则切换指令」写入文件时引用的目标。

---

## 11. default.custom.yaml —— 全局补丁

```yaml
patch:
  schema_list:
    - {schema: tiger}
    - {schema: wanxiang_pro}
    - {schema: mets}
    - {schema: xumn}
    #- {schema: 9jianhu}   # 默认未启用九键
```
用户可通过取消注释来启用/禁用方案。它是**用户可自由修改而不被更新覆盖**的口子（README 6.22 有说明）。

---

**下一篇** → [03 · Lua 模块与关键函数](03-lua-modules.md)
