# 04 · 词库与数据资产

本篇说明仓库中所有「数据类」文件：词典、码表、OpenCC、重码表、注音、符号、主题、音效。它们决定了「编码 ↔ 文字」的映射，是翻译器与滤镜的底层数据。

---

## 1. 数据资产总表

| 资产 | 路径 | 大小 | 用途 | 使用者 |
|------|------|------|------|--------|
| 主词库 | [tiger.dict.yaml](../tiger.dict.yaml) | 1 KB | 聚合虎码字表 + 简词 + 万象 zuci | `translator` (tiger) |
| 官虎字词 | [tigress.dict.yaml](../tigress.dict.yaml) | 1.4 MB | 字/词方案词典，带 encoder | `char_word`、tigress |
| 8105 字表 | [cn_dicts_tiger/8105.dict.yaml](../cn_dicts_tiger/8105.dict.yaml) | 146 KB | 8105 通用字 + 重码标记 | 被 tiger.dict 引用 |
| 简词库 | [cn_dicts_tiger/tigress_ci.dict.yaml](../cn_dicts_tiger/tigress_ci.dict.yaml) | 1.1 MB | `/` 引导句中简词 | tiger.dict |
| 简词库(详细) | [cn_dicts_tiger/tigress/tigress_ci.dict.yaml](../cn_dicts_tiger/tigress/tigress_ci.dict.yaml) | 2.6 MB | 同上，含 encoder | tigress.dict |
| 简易简词 | [cn_dicts_tiger/tigress/tigress_simp_ci.dict.yaml](../cn_dicts_tiger/tigress/tigress_simp_ci.dict.yaml) | 60 KB | 精简简词 | tigress.dict |
| 作者词 | [cn_dicts_tiger/tigress/author.dict.yaml](../cn_dicts_tiger/tigress/author.dict.yaml) | 164 B | 个人词 | tigress.dict |
| 拆字反查库 | [tiger_lookup.dict.yaml](../tiger_lookup.dict.yaml) | 2.8 MB | 字 → 〔部首拆分·编码〕 | `chaifen` |
| 中英混合 | [tiger_en.dict.yaml](../tiger_en.dict.yaml) | 18 KB | 中英混排词 | `tiger_en` |
| 拼音词库 | [wanxiang_pro.dict.yaml](../wanxiang_pro.dict.yaml) | 1 KB | 聚合万象拼音词库 | `yin_engine`、`wanxiang_pro` |
| 快符 | [custom_phrase/kf.dict.yaml](../custom_phrase/kf.dict.yaml) | 2 KB | `;x` 快符 | tigress.dict |
| 符号表 | [new_symbols.yaml](../new_symbols.yaml) | 30 KB | 全类符号 | punctuator |
| 拼写片段 | [wxh_algebra.yaml](../wxh_algebra.yaml) | 7 KB | 可复用 algebra | 指令写入 |
| 重码替换 | [lua/chongma_tiger.txt](../lua/chongma_tiger.txt) / `chongma_wubi.txt` | — | 重码词 → 更优词 | `db` |
| 注音词库 | [lua/zhuyin.txt](../lua/zhuyin.txt) | — | 词 → 拼音串 | `db`(zhuyin) |
| 注音字库 | [lua/zhuyin_zi.txt](../lua/zhuyin_zi.txt) | — | 字 → 拼音 | `db`(zhuyin) |
| 虎码码表 | [lua/tiger_code_table.lua](../lua/tiger_code_table.lua) | 8501 行 | 字 → 虎码 | `temporary_word` |
| 五笔码表 | [lua/wubi_code_table.lua](../lua/wubi_code_table.lua) | 8109 行 | 字 → 五笔 | `temporary_word` |
| 拼音 OpenCC | [opencc/pinyin.json](../opencc/pinyin.json) | 368 B | 汉字 → 拼音显示 | 9jianhu/simplifier |
| 虎拆 OpenCC | [opencc/hu_cf.json](../opencc/hu_cf.json) | 235 B | 虎码拆分转换 | 拆分显示 |
| 拼音字典 | [opencc/PYCharacters.txt](../opencc/PYCharacters.txt)、`PYPhrases.txt` | 0.7/1.0 MB | 拼音 OpenCC 词表 | pinyin.json |
| 虎拆字典 | [opencc/hu_cf.txt](../opencc/hu_cf.txt) | 2.8 MB | 拆分转换词表 | hu_cf.json |
| 同文主题 | [万象虎.trime.yaml](../万象虎.trime.yaml) | 196 KB | Trime 主题 + 键盘 | 同文输入法 |
| 按键音 | [sound/abc.sound.yaml](../sound/abc.sound.yaml) + `sound/字母/*.mp3` | 648 KB | 字母朗读按键音 | 同文 |
| 背景占位 | [backgrounds/放入"background.png"…txt](../backgrounds) | — | 主题背景说明 | 主题 |

---

## 2. Rime 词典格式要点

`*.dict.yaml` 的通用头部：

```yaml
---
name: <词库名>            # 必须与引用它的字典名一致
version: "x.y"
sort: by_weight           # 或 original
use_preset_vocabulary: false
columns: [ text, code, weight ]   # 可选：自定义列序
encoder: { rules: [...] }          # 可选：按公式自动生成编码
import_tables: [ 其他词库 ]         # 可选：聚合
...
# 词条：文字 \t 编码 \t 权重
```

### 2.1 `tiger.dict.yaml`（主词库，聚合）
```yaml
import_tables:
  - tiger_dicts/8105       # 字表
  - tiger_dicts/tigress_ci # /引导的句中简词
  - zuci/ext               # 扩展词库
  - zuci/moegirl           # 萌娘词库
  - zuci/jichu.pro         # 基础词库 2-3 字
  - zuci/lianxiang.pro     # 联想词库 5 字以上
  - zuci/duoyin.pro        # 多音兼容
  - zuci/shici.pro         # 诗词
  - zuci/diming.pro        # 地名
```
> 注意：`tiger_dicts/*`、`zuci/*` 大多**不在本仓库**，来自基础工程。本仓库提供 `cn_dicts_tiger/`，合并时映射为 `tiger_dicts/`（见 [06](06-deployment.md)）。

### 2.2 `tigress.dict.yaml`（官虎字词，带 encoder）
```yaml
columns: [ text, weight, code, stem ]
encoder:
  rules:
    - { length_equal: 2, formula: "AaAbBaBb" }
    - { length_equal: 3, formula: "AaBaCaCb" }
    - { length_in_range: [4, 10], formula: "AaBaCaZa" }
import_tables:
  - tiger_dicts/tigress/tigress_ci
  - tiger_dicts/tigress/tigress_simp_ci   # 行首加 # 可关闭简词
  - tiger_dicts/tigress/author
  - custom_phrase/kf                       # 快符
```
- `encoder.formula` 是 Rime 的**编码公式**：`A`=第 1 字、`B`=第 2 字…，小写=取该字编码的对应码位。例如 2 字词 `AaAbBaBb` = 两字各取前 2 码；3 字词 `AaBaCaCb` = 前两字各 1 码 + 末字 2 码；4–10 字 `AaBaCaZa` = 首三字各 1 码 + 末字 1 码。这与 `temporary_word.lua` 的 `get_tiger_code` 规则一致。
- `stem`（词干）用于让 `prism` 生成不同整句方案（`wxh/mets/xumn/9jianhu`）的编码投影。

### 2.3 `8105.dict.yaml`（字表 + 重码标记）
```yaml
#重码
的	￣u'	10359470
为	￣i'	1195466
...
```
- 编码前的 `￣` 标记表示**该字存在重码**（同名不同字共码）。
- `tiger.schema.yaml` 的 algebra `xform/[-￣]//` 会把它去掉；`switch_filter.lua` 也会清理注释中的 `￣`。

### 2.4 `tiger_lookup.dict.yaml`（拆字反查）
```yaml
sort: original
的	〔白勹丶·unid〕
是	〔日𤴓·ots〕
```
格式：`字 \t 〔部首拆分·编码〕`。被 `chaifen.lua` 通过 `ReverseLookup("tiger_lookup")` 查询，用于候选的拆分注释。

### 2.5 `wanxiang_pro.dict.yaml`（拼音，聚合外部）
```yaml
import_tables:
  - dicts/zi.pro
  - dicts/jichu.pro
  - dicts/lianxiang.pro
  - dicts/cuoyin.pro
  - dicts/duoyin.pro
  - dicts/shici.pro
  - dicts/diming.pro
  - zuci/ext
  - zuci/moegirl
```
均为**外部基础工程**词库。本仓库只提供聚合声明。

### 2.6 `custom_phrase/kf.dict.yaml`（快符）
```yaml
columns: [ text, code, weight ]
多行头 ...
：“	;q
？	;w
（	;e
```
即输入 `;q` 上屏 `：`，`:w` → `？` 等。`;` 引导的编码在 `speller.auto_select_pattern: ^;\w+` 下**候选唯一自动上屏**。

---

## 3. 重码替换表 `chongma_*.txt`

[chongma_tiger.txt](../lua/chongma_tiger.txt) 由 `db.lua` 的 `collision_dict` 解析：

```
来源词→目标词1 目标词2
```

| 行 | 含义 |
|----|------|
| `您→你` | 把「您」替换为「你」 |
| `在 存` | 「在」与「存」互为重码（空格分隔，仅登记） |
| `如何存→如何在` | 词组替换 |
| `鲸鱼鳝鱼鲜鱼鲜鱼鲑鱼` | 多个同码词并列 |

解析逻辑：按 `→` 切左右，左侧每个词登记为 key，右侧每个词加入候选，最终以 `\x01` 分隔存入 LevelDB，供「重码替换」 DFS 使用。

---

## 4. 注音数据

| 文件 | 格式 | 例句 |
|------|------|------|
| [lua/zhuyin.txt](../lua/zhuyin.txt) | `词\t拼音1,拼音2,…` | `阿斗\tā,dǒu` |
| [lua/zhuyin_zi.txt](../lua/zhuyin_zi.txt) | `字\t拼音` | `阿\tā` |

`db.lua` 的 `zhuyin` 子模块用途：
1. 优先用 `ReverseLookup("wanxiang_pro")` 查单字拼音；
2. 多音字时用 `zhuyin.txt`（词级）或 `zhuyin_zi.txt`（字级）消歧；
3. 结果写入候选 `comment`（`pinyin` 开关开启时）。

`enum/zhuyin`（默认 4）控制最多为几字候选显示注音。

---

## 5. 码表 `tiger_code_table.lua` / `wubi_code_table.lua`

```lua
local tiger_code_table = {
    ["啊"] = "dtzk",
    ["阿"] = "tzk",
    ...
}
return tiger_code_table
```

- 约 8498（虎）/ 8100+（五笔）条「单字 → 全码」。
- 启动时由 `temporary_word.lua` 的 `CodeTableDB.init` 加载进 LevelDB（`lua/tiger_code`、`lua/wubi_code`），带 `code_table_version=1.0`，版本不符则重建。
- 用途：为「文件简词 / 永久简词」自动生成 4 码编码。

---

## 6. OpenCC 转换配置

### 6.1 `opencc/pinyin.json`（拼音显示）
```json
{
  "name": "pinyin",
  "segmentation": { "type": "mmseg", "dict": { "type": "text", "file": "PYPhrases.txt" } },
  "conversion_chain": [{
    "dict": { "type": "group", "dicts": [
      { "type": "text", "file": "PYPhrases.txt" },
      { "type": "text", "file": "PYCharacters.txt" }
    ]}
  }]
}
```
- 用 `PYPhrases.txt`（词组优先）+ `PYCharacters.txt`（单字兜底）把汉字转拼音，供「注音滤镜 / 拼音滤镜」显示。
- 在 `9jianhu.schema.yaml` 的 `simplifier@pinyin` 与各方案 `pinyin` 开关中使用。

### 6.2 `opencc/hu_cf.json`（虎拆转换）
```json
{ "name": "hu_cf", "conversion_chain": [{ "dict": { "type": "text", "file": "hu_cf.txt" } }] }
```
- 用 `hu_cf.txt`（2.8 MB）做虎码拆分相关转换（如把码转部首字形）。

---

## 7. 符号表 `new_symbols.yaml`

源自 Rime 官方 `symbols.yaml`，定义 `symbol_table`：

```yaml
symbol_table:
  full_shape:
    ',' : { commit: ， }
    '<' : [ 《, 〈, «, ‹ ]
    '''' : { pair: [ '‘', '’' ] }
    ...
  half_shape:
    ...
```
- `punctuator.__include: new_symbols:/symbol_table` 引入后，输入对应符号键会产出「候选符号列表」（如按 `<` 出现《〈«‹）。
- `pair` 表示成对符号（如引号自动配对）。
- 也被识别器 `punct: "^/([0-9]|10|[A-Za-z]+)$"` 用于「斜杠 + 名称」调取符号。

---

## 8. 拼写运算片段 `wxh_algebra.yaml`

集中定义具名 algebra 块，供 `set_schema_pro.lua` 在改写 `*.custom.yaml` 时引用（`wxh_algebra:/块名`）。详见 [02 · §10](02-schemas.md#10-wxh_algebrayaml--可复用拼写片段)。核心块：

| 块名 | 关键内容 |
|------|---------|
| `万象虎` | `derive/^(\w)(\w),(\w)(\w)$/...` 双拼辅助码展开 |
| `虎码二三整句` | `xform/[,-0]//`、`xform/￣.*$//` |
| `虎码原码整句` | `xform/[,￣0]//`、`xform/-.*$//` |
| `九键虎` | 完整 T9 映射 |
| `万象五笔` | 万能 z、双拼展开 |
| `通配符` | `*` 派生 |
| `18jian/15jian/14jian` | `xlit` 键位压缩 |
| `9jian` | 拼音九宫格数字映射（含 `\U` 大写转换） |

---

## 9. 主题与音效（同文 / Trime）

### 9.1 `万象虎.trime.yaml`
同文输入法（Trime）的 **style / preset_keyboards / preset_color_schemes / preset_keys** 配置，约 196 KB，包含：
- 高度集中控制区（`conf.default_height`、`compact_height` 等）；
- 26 键、9 键、18/15/14 键等**多种键盘布局**；
- 多套配色方案（含「简纯-」主题的「简明」配色）；
- `preset_keys`：回车、中英切换、符号、方向等行为绑定；
- 背景图支持：在 `backgrounds/` 放 `background.png` 即生效。

> 该文件只对**同文输入法**生效；桌面端 Rime 使用各自皮肤的 `*.custom.yaml`，本仓库未包含。

### 9.2 `sound/`
```
sound/abc.sound.yaml        # 列出音效文件顺序
sound/字母/字母A.mp3 … 字母Z.mp3
sound/字母/哒1.mp3
```
配合同文「虚拟键盘 → 按键效果 → 自定义按键音 → 选择 abc」使用，实现**字母朗读**按键音（见 [sound/自定义按键音.txt](../sound/自定义按键音.txt)）。

---

## 10. 数据放置位置（运行时）

Rime 部署后，词典会编译为 `*.bin`。本仓库涉及的**运行时数据/缓存**（多在用户目录）：

| 路径 | 生成者 | 说明 |
|------|--------|------|
| `custom_phrase/zaoci.txt` | Rime 用户词典 | 选字造词结果 |
| `custom_phrase/user.txt` | 用户手填 / `temporary_word` | 置顶/文件简词源 |
| `custom_phrase/jianci.lua`（iOS `rime_user_words.lua`） | `temporary_word` | 永久简词 |
| `custom_phrase/read.txt` | 用户 | 阅读文本 |
| `lua/read_state.txt` | `read.lua` | 阅读进度 |
| `lua/input_stats.lua` | `new_statistics.lua` | 速度统计 |
| `lua/data/db_rebuild.log` | `db.lua` | 建库日志 |
| LevelDB 目录（`lua/tiger_code`、`lua/wubi_code`、`lua/collision_*`、`lua/tigress`、`lua/en_dict`、`lua/zhuyin_*`） | `db.lua` / `temporary_word.lua` | 各类缓存库 |

---

**下一篇** → [05 · 功能与指令速查](05-features-and-commands.md)
