# 06 · 部署与运行

本篇说明如何让「万象虎」真正跑起来：依赖关系、目录合并、部署步骤、平台差异与排错。

---

## 1. 前置认知：这是一个「补丁包」

README 明确写道（[README.md#L62](../README.md)）：

> 更新「万象虎」核心方案，github 更新需与「rime-wanxiang-tiger-fuzhu」添加模型的方案合并方可使用。

因此本仓库**不能单独部署**。它必须与**基础工程**（rime-wanxiang-tiger-fuzhu，含万象模型、`wanxiang_pro.schema.yaml`、`rime.lua`、`wanxiang/` 等）合并。

### 缺失依赖清单（必须由基础工程补齐）

| 缺失文件/目录 | 作用 | 缺失后果 |
|---------------|------|---------|
| `wanxiang_pro.schema.yaml` | 万象拼音根方案 + 完整 engine | tiger `__include` 失败，方案无法加载 |
| `rime.lua` | 注册 `lua_*@*name` 全局组件 | 所有 `@*` 组件找不到，输入无候选 |
| `wanxiang/wanxiang.lua`、`wanxiang/userdb.lua` | 工具库 + LevelDB 封装 | `db`/`set_schema_pro`/`temporary_word` 报错 |
| `shijian`、`unicode`、`number_translator`、`super_calculator` | 时间/Unicode/金额/计算器 | 对应功能缺失 |
| `super_processor`、`super_sequence`、`super_tips`、`partial_commit`、`key_binder`(lua) | 万象超级处理器族 | 9jianhu/tigress 加载失败、调序失效 |
| `dicts/*.pro`、`zuci/*`、`tiger_dicts/*` | 万象主词库 | 拼音/整句/联想无候选 |
| 语言模型（`*.gram` 等） | 整句组句 | 整句质量下降或不可用 |

---

## 2. 目录合并映射

本仓库与基础工程合并时，通常做如下**改名/拷贝**（关键：`cn_dicts_tiger/` → `tiger_dicts/`）：

```
本仓库文件/目录             合并后位置（基础工程用户目录）
────────────────────────────────────────────────────────
default.yaml               → <Rime>/
default.custom.yaml        → <Rime>/
tiger.schema.yaml          → <Rime>/
mets.schema.yaml           → <Rime>/
xumn.schema.yaml           → <Rime>/
9jianhu.schema.yaml        → <Rime>/
tigress.schema.yaml        → <Rime>/
tiger_en.schema.yaml       → <Rime>/
tiger_lookup.schema.yaml   → <Rime>/
wanxiang_pro.custom.yaml   → <Rime>/（覆盖基础版本，注意合并其 patch）
tiger.dict.yaml            → <Rime>/
tigress.dict.yaml          → <Rime>/
tiger_en.dict.yaml         → <Rime>/
tiger_lookup.dict.yaml     → <Rime>/
wanxiang_pro.dict.yaml     → <Rime>/（覆盖基础版本）
new_symbols.yaml           → <Rime>/
wxh_algebra.yaml           → <Rime>/
lua/                       → <Rime>/lua/（与基础 lua/ 合并，勿覆盖 rime.lua）
cn_dicts_tiger/            → <Rime>/tiger_dicts/   ★改名
custom_phrase/             → <Rime>/custom_phrase/（kf.dict.yaml 等）
opencc/                    → <Rime>/opencc/（与基础 opencc 合并）
sound/                     → 同文用户目录 sound/
backgrounds/               → 同文用户目录 backgrounds/
万象虎.trime.yaml           → 同文用户目录（重命名/加入 .trime.yaml 体系）
```

> `cn_dicts_tiger/` 内部文件也引用了 `tiger_dicts/tigress/...` 路径（见 [tigress.dict.yaml](../tigress.dict.yaml)），因此**必须**改名为 `tiger_dicts/` 才能匹配。

---

## 3. 桌面端部署（小狼毫 / 鼠须管 / fcitx5-rime）

### 3.1 定位用户目录
| 平台 | 路径 |
|------|------|
| Windows（小狼毫） | `%APPDATA%\Rime`（右键托盘 → 用户文件夹） |
| macOS（鼠须管） | `~/Library/Rime` |
| Linux（fcitx5-rime） | `~/.local/share/fcitx5/rime`（ibus-rime：`~/.config/ibus/rime`） |

### 3.2 合并与部署步骤
1. 先安装**基础工程**并部署一次，确认万象方案可用；
2. 将本仓库文件按 [§2 映射](#2-目录合并映射) 合并进用户目录；
3. **重新部署**：
   - 小狼毫：托盘右键 →「重新部署」；
   - 鼠须管：菜单 →「Deploy」/ `rime_deployer`；
   - Linux：`fcitx5-remote -r` 或重启 fcitx5；
4. `Ctrl+\`` 打开方案选单，选择「万象虎」。

### 3.3 首次部署耗时
词库编译（尤其 `tiger_lookup.dict.yaml` 2.8 MB、`tigress_ci` 2.6 MB、OpenCC `hu_cf.txt` 2.8 MB）可能需要较长时间，属正常现象。

---

## 4. 移动端部署（同文输入法 Trime）

1. 同文设置 →「用户数据目录」；
2. 按 §2 映射拷贝方案、词库、`lua/`、`opencc/`、`sound/`；
3. 将 [万象虎.trime.yaml](../万象虎.trime.yaml) 放入用户目录（主题与键盘布局）；
4. 设置 →「输入法」→ 选择方案「万象虎」；
5. 设置 →「虚拟键盘」→「按键效果」→「自定义按键音」选 `abc`（字母朗读）；
6. 如需背景图，在 `backgrounds/` 放 `background.png`；
7. 点击「部署」。

> 同文的 `lua/` 位于用户目录下；Android 路径通常是 `/storage/emulated/0/rime/` 或应用私有目录，以设置页显示为准。

---

## 5. 基础工程构建（可选，开发者）

若需从基础工程源码构建：

```bash
# 克隆基础工程
git clone <rime-wanxiang-tiger-fuzhu 仓库>
# 按需合并本仓库内容后，使用 rime 插件方式构建
# librime 插件：librime-lua + librime-octagram（语言模型）
```

> 具体构建脚本与依赖以基础工程 README 为准；本仓库不含构建脚本。

---

## 6. 运行时行为说明

| 行为 | 触发 | 模块 |
|------|------|------|
| 首次启动建库 | 检测到版本/签名变化 | `db.lua`、`temporary_word.lua` |
| 4 码唯一上屏 | 虎句关、虎单/词开 | `auto_commit.lua` |
| 重复上屏历史写入文件 | iOS 退出时 | `quick_symbol_text2.lua` |
| 阅读进度落盘 | `/re` 阅读时 | `read.lua` |
| 速度统计落盘 | `/en` 结束时 | `new_statistics.lua` |
| 方案切换写文件 | `/wxh` 等 | `set_schema_pro.lua` |

---

## 7. 排错指南

| 现象 | 可能原因 | 排查 |
|------|---------|------|
| 方案列表里没有「万象虎」 | `default.yaml` 的 `schema_list` 未含，或未部署 | 检查 [default.yaml](../default.yaml#L8)，重新部署 |
| 打字无候选 / 报 Lua 错误 | 缺 `rime.lua` / `wanxiang/*`，或 `@*` 组件未注册 | 确认基础工程完整；看日志 `rime.lua` 报错 |
| tiger 方案加载失败 | 缺 `wanxiang_pro.schema.yaml` | 必须合并基础工程 |
| 拆分不显示 | `chaifen` 关闭 / 词典未编译 | `Ctrl+z` 开启；确认 `tiger_lookup` 已部署 |
| 4 码不自动上屏 | 虎句未关、或开关关闭 | `Ctrl+a` 关虎句；检查 `char_word/four_auto_commit` |
| 重码替换不生效 | `chongma_on/off` 状态、或源文件签名未变 | 检查开关；删除 `lua/collision_*` 缓存重启 |
| 注音不显示 | `pinyin` 关闭 / 缺 `zhuyin*.txt` | `Ctrl+y` 开启；确认数据文件存在 |
| 指令无效 | 当前方案是 `wanxiang_pro`（禁用）或未重新部署 | 切到 tiger；部署后再试 |
| 简词码错误 | 码表版本旧 / `enum/jianci` 不匹配 | 删除 `lua/tiger_code` 库重建；核对 `1230/1234` |
| iOS 简词丢失 | 仅内存保存 | 确认写入 `Documents/rime_user_words.lua`；检查权限 |
| 同文无法加载主题 | `万象虎.trime.yaml` 位置/命名 | 放入同文用户目录并在主题中选择 |

日志位置：
- 小狼毫：`%TEMP%\rime.weasel.*.INFO`。
- 通用：用户目录下 `*.log`；本项目另外记录 `lua/data/db_rebuild.log`。

---

## 8. 升级与迁移

1. **保留用户数据**：`custom_phrase/`（尤其 `user.txt`、`zaoci.txt`、`jianci.lua`）、`lua/read_state.txt`、`lua/input_stats.lua`、各 LevelDB 目录。
2. **`default.custom.yaml` 是你的私人配置**，升级时**不要覆盖**（README §6.22 说明它不会被更新覆盖）。
3. 升级方案文件后**重新部署**即可；LevelDB 会按版本自动重建。
4. 若方案切换指令曾改写 `*.custom.yaml`，升级前备份这些文件，升级后按需重设。

---

## 9. 版本信息

| 项 | 值 |
|----|----|
| 全局 `config_version` | `2024-08-05` |
| 仓库分支 | `main`（`github.com/zhhwux/wxzhh`） |
| 许可 / 来源 | 基于万象方案 + 虎码，遵循上游开源协议 |

---

**返回** → [Wiki 首页](README.md)
