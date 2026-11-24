# 05 · 功能与指令速查

本篇汇总**面向使用者**的功能：开关、快捷键、斜杠指令、引导前缀。内容依据仓库配置与 README 整理，可作为日常使用与排障手册。

---

## 1. 推荐使用习惯

1. **万象虎**：2–4 任意码「虎句」+ 虎单/词，穿插交替上屏；
2. **万象拼音**：双拼整句 + 虎单穿插；
3. **虎码二三整句**：虎句/单/词交替（1–2 根字 2 码，3–4 根字 3 码）；
4. **虎码原码整句**：最短首选编码，1 码字后加 `'`，分词符为 `_`；
5. **九键虎**：九宫格定位码整句。

---

## 2. 功能开关（switches）

开关既可在**方案选单**（`Ctrl+\``）里切换，也可用快捷键：

| 快捷键 | 开关 | 状态 |
|--------|------|------|
| `Control+a` | `sentence` 虎句 | 关 / 虎句 |
| `Control+s` | `word` 虎词 | 关 / 虎词 |
| `Control+d` | `char` 虎单 | 关 / 虎单 |
| `Control+z` | `chaifen` 拆分 | 隐 / 拆 |
| `Control+y` | `pinyin` 注音 | 字 / pīn |
| `Control+m` | `english_word` 中英 | 中 / 英 |
| `Control+q` | `yin` 音码 | 关 / 音码 |
| `Control+r` | `completion` 提示 | 关 / 提示 |
| `Control+Shift+3` | `ascii_punct` 中英标点 | ¥ / $ |
| `Control+Shift+4` | `traditionalization` 简繁 | 简 / 繁 |
| `Control+Shift+1` | 在最近两方案间切换 | — |

> 虎单 / 虎词 / 虎句三者可任意组合；「虎句关 + 虎单/词开」时触发 `auto_commit.lua` 的 4 码自动上屏 / 5 码顶屏逻辑。

---

## 3. 输入方式与引导前缀

| 引导 | 含义 | 实现位置 |
|------|------|---------|
| 直接编码 | 虎码字/词/句 | `tiger` translator |
| `'前缀` | 拼音反查 / 拼音造词 | `yin_add_user` |
| `` `后缀 `` | 拼音反查 | `yin_add_user` |
| `` `前缀 `` | 虎码自造词（addle 造词） | `add_user_dict` |
| `;前缀` | 快符（`;q`→`：` 等） | `custom_phrase/kf.dict.yaml` |
| `o前缀` | 快符（部分） | punctuator/快符 |
| `*` | 通配符（任意编码位替代） | speller algebra `derive` |
| `/前缀` | 斜杠指令 / 符号 / 功能 | 各 translator |
| `'` `'``（双击单引号） | 重复上屏 | `quick_symbol_text2` /
 `historyDM` |
| `z` / `[` / `]` | 重复上屏（手机/电脑/电脑3） | `historySJ/DM/DM3` |
| `V前缀` | 计算器 | `super_calculator` |
| `N前缀` | 数字转日期大写 | `number_translator` |
| `R前缀` | 数字转金额大写 | `number_translator` |
| `U前缀` | Unicode 编码转文字 | `unicode` |
| `\后缀` | 成对符号包裹 | punctor/万象 |

---

## 4. 斜杠指令总表

### 4.1 方案与键位切换（`set_schema_pro.lua`）
| 指令 | 效果 |
|------|------|
| `/wxh` | 万象虎整句规则 |
| `/mets` | 虎码二三整句规则 |
| `/xumn` | 虎码原码整句规则 |
| `/kjzb` | 九键虎整句规则 |
| `/wxwb` | 万象五笔整句规则 |
| `/shiba` `/shiwu` `/shisi` | 18 / 15 / 14 键位映射（需配合主题） |
| `/zjf` `/jjf` | 直接辅助 / 间接辅助 |
| `/flypy` | 小鹤双拼 |
| `/mspy` | 微软双拼 |
| `/zrm` | 自然码 |
| `/sogou` | 搜狗双拼 |
| `/znabc` | 智能ABC |
| `/ziguang` | 紫光双拼 |
| `/pyjj` | 拼音加加 |
| `/gbpy` | 国标双拼 |
| `/lxsq` | 乱序17 |
| `/zrlong` | 自然龙 |
| `/hxlong` | 汉心龙 |
| `/pinyin` | 全拼 |
| `/wxsp` | 万象双拼 |

> 这些指令会改写 `*.custom.yaml`，**必须重新部署**后生效；在 `wanxiang_pro` 方案内指令被禁用。

### 4.2 造词与简词（`temporary_word.lua`）
| 指令 | 效果 |
|------|------|
| `/wjjc` | 为 `user.txt` 中无编码的词生成编码（不产出候选） |
| `/zyj` | 文件简词 → 永久简词（固定在次选） |
| `/zwj` | 永久简词 → 导出到文件 |
| `/jcql` | 清空全部简词 |

### 4.3 上屏历史（`quick_symbol_text2.lua`）
| 输入 | 效果 |
|------|------|
| `''` | 上屏最近一条 |
| `'`` ` | 合并上屏最近 100 条 |
| `/spql` | 清空上屏历史 |

### 4.4 阅读（`read.lua`）
| 输入 | 效果 |
|------|------|
| `/re` | 开始阅读 `custom_phrase/read.txt` |
| `/` | 关闭阅读（阅读模式中） |

### 4.5 速度统计（`new_statistics.lua`）
| 输入 | 效果 |
|------|------|
| `/st` + 空格确认 | 开始临时统计 |
| `/en` | 结束并输出报告 |

### 4.6 文件管理（`wj.lua`，`/wj` 前缀）
| 语法 | 功能 |
|------|------|
| `/wj` | 显示帮助 |
| `文件名@内容` | 检索文件内容 |
| `文件名@/` | 合并输出整个文件 |
| `文件名@旧/新/` | 行内替换 |
| `文件名@//新内容/` | 整体覆盖 |
| `new"目录/文件"` | 新建文件/文件夹 |
| `del"目录/文件"` | 删除文件 |
| `+&源&目标&` | 复制 |
| `&源&目标&` | 移动 |
| `_@f1@f2@` | 取重（保留共同字符行） |
| `+@f1@f2@` | 合并（拼接关联行） |
| `-@f1@f2@` | 去重（移除共同字符行） |
| `-h@f1@f2@` / `_h@f1@f2@` | 行去重 / 行取重 |
| `-hn@f1@f2@` / `_hn@f1@f2@` | 行内去重 / 行内取重 |
| `_@文件&` | 按首特殊字符分组 |
| `_&文件名&` | 重码合并 |
| `/zuci` | 组词词库处理 |

---

## 5. 虎码造词体系

| 方式 | 操作 | 存储 |
|------|------|------|
| 选字造词 | 逐字选词（默认自动，`add_user_dict/enable_auto_phrase` 可关） | `custom_phrase/zaoci.txt`（部署后） |
| 4 码临时简词 | 最近上屏过一段文本后，用 4 码打出它 | 内存 → 确认后永久化 |
| 永久简词 | 临时简词上屏后被永久保存 | `custom_phrase/jianci.lua` |
| 文件简词 | `user.txt` 每行一条，部署/`/wjjc` 生成编码 | `custom_phrase/user.txt` |
| 置顶词典 | `custom_phrase/user.txt`，不参与组句，受虎词开关控制 | `custom_phrase/user.txt` |

`user.txt` 支持格式：
```
文本
文本<TAB>编码
文本<TAB>编码<TAB>权重
文本<TAB>权重
```
无编码行会在加载时自动补全虎码。

---

## 6. 候选词手动调序

选中候选后：
| 快捷键 | 动作 |
|--------|------|
| `Ctrl+j` | 向左移动 |
| `Ctrl+k` | 向右移动 |
| `Ctrl+p` | 置顶 |
| `Ctrl+l` | 清除调序信息 |

> 由基础工程的 `super_sequence` 处理器 / 过滤器实现（本仓库未含）。

---

## 7. 快捷输入（万象原生）

| 编码 | 输出 |
|------|------|
| `osj` 或 `/sj` | 当前时间 |
| `orq` 或 `/rq` | 日期 |
| `V…` | 计算器 |
| `R1234.5` | 金额大写 |
| `N…` | 日期大写 |
| `U4e00` | Unicode 汉字 |
| `/(符号名)` | 符号候选 |
| `7890` | 1234 声调（音码用，轻声归 4） |

> 这些多由基础工程的 `shijian / number_translator / super_calculator / unicode` 提供。

---

## 8. 五笔版本差异

当 `char_word/dictionary: wubici` 时，多个模块自动切换到五笔数据源：

| 模块 | 虎码 | 五笔 |
|------|------|------|
| chaifen | `tiger_lookup` | `wubi_lookup` |
| db（collision） | `chongma_tiger.txt` | `chongma_wubi.txt` |
| db（tigress_ci） | `lua/tigress` | `lua/wubici` |
| temporary_word | `tiger_code_table` | `wubi_code_table` |

---

## 9. 常见组合示例

| 目标 | 操作 |
|------|------|
| 纯虎单打字 | `Ctrl+s` 关虎词、`Ctrl+a` 关虎句、`Ctrl+d` 开虎单 |
| 拼音整句 | 切到「万象拼音」方案，双拼整句 |
| 忘记拆分 | 用 `*` 替代不确定的码位 |
| 拼音反查虎码 | 输入 `'pinyin` 或 `pinyin`` ` |
| 打不出长句回改 | 开 `Control+r` completion 提示，或分句上屏 |
| 生成个人词库 | 编辑 `custom_phrase/user.txt` → 部署 / `/wjjc` → `/zyj` |
| 阅读中查文件 | `/re` 后逐段输出，`/` 退出 |

---

**下一篇** → [06 · 部署与运行](06-deployment.md)
