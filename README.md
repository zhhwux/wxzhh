
万象虎是一个基于万象方案改造而来的rime输入方案。
虎码置顶，可分别使用开关关闭虎单、虎词、虎码整句、音码。
可用拆分滤镜和拼音滤镜开关无障碍反查。                     
它的基础 万象方案是一个可在wanxiang.schema.yaml文件更换多种音码：全拼、自然码、自然龙、小鹤双拼、搜狗双拼、微软双拼、智能ABC、紫光、国标双拼；
和多种辅助码 墨奇、鹤形、自然码、虎码首末、五笔前2、汉心码的音码方案。
内置强大词库与模型，整句输入有很高的正确率。
总的来说这个方案结合了虎码单字的高正确率、开启虎词时的更短码长、虎码两码整句的高正确率低码长且不用考虑出简让全的优势、音码整句的高正确率且不用考虑拆字的优势


注：基于万象方案改造，仓库需要与万象方案合并才能使用，可在q群反馈问题和更新完整方案
qq群 809597773
仓库地址https://github.com/zhhwux/wxzhh
万象方案地址https://github.com/amzxyz/rime_wanxiang_pinyin
相对于万象的改动有:
1.dependencies
2.开关
3.滤镜相关：tiger、拆分、拼音、常用字、u编、`或''重复上屏
4.custom_phrase相关：虎词、虎单、原码句、快符
5.tiger_sentence相关：两码句
6.音码调频
7.tips相关：上屏符号/ 默认启用手机版本
8.修改了快捷键开关Control+z开关虎单/Control+a开关虎词/Control+s开关虎句/Control+m显示拆分
9.修改了1个引导前缀：ach

更新日志:
4.5更新：修复了tiger方案‘音码候选词辅助码调序和注释显示’功能、调整了部分配置文本、跟随万象更新
4.4.10更新：设定双击'或单击`重复上屏、设置快符oe为`
4.3.23更新：设定双击'或`重复上屏、调整了o快符
4.3.21更新：添加了秃虎的快符、补充了一个词典
4.2.20更新：修复了部分/引导的快符失效的问题
4.2.1更新：恢复了万象方案虎句性能、跟随万象更新
3.31.17更新：优化了大字集关闭时因为过滤了含有生僻字的句子而导致的虎句缺失问题、默认方案改为虎（虎句优化）设置tag过滤了四码以下不完全匹配单字、并为该方案引用了万象方案配置的音码user_dict_set、设置了音码开关
3.25.1更新：新增方案 虎（纯虎 虎句优化）、设置了快捷键Control+z开关虎单/Control+a开关虎词/Control+s开关虎句/Control+m显示拆分、默认在翻译开关关闭时关闭英文候选词
3.23.3更新：修复了虎词/虎单之间的权重排序功能、移除了置顶组句开关、跟随万象更新
3.22.5更新：解决了ach自造词与`部件组字功能失效的问题、解决了㛚被划分为符号组的问题、将两码/原码句的主次选排序共存改为不共存、将虎码词典的tiger版单字改为tigress版单字、将虎字虎词开关同时开启时的字词顺序由 字在词前 调整为词典内部权重顺序、新增u编开关、更换快符〔〕为[]、跟随万象跟新：新增预测功能开关
3.17.8更新：跟随万象更新：新增了tips开关功能、默认 基本的6码3字不调频、常用字滤镜补充 诶
3.5.21更新：将句词单的输出顺序调整为单词句、将快符ov\划为符号组、跟随万象更新
3.1.21更新：将一简词的输出顺序放在了一简字之后
2.28.4更新：
改造整句词典，为两码整句添加了加码纠错能力、优化了两码句/原码句开关，解决了相同码长时切换首选无效的问题、新增了一简词开关、跟随万象更新
2.24.7更新：
改良整句词典实现两码整句，与含有常规字词的原码整句共存，根据开关状态决定排序、
缩减常用字过滤字集为8105、
跟随万象更新
2.23.4更新：因为万象原本的字符集过滤lua不过滤句中生僻字，为了避免对虎码整句的影响，换成了core2022
2.23.2更新：为虎词添加了简词、相对调低了24个同权重码词条权重、分离了虎码整句，为整句词典添加了二码单字、更随万象更新
2.22.2更新：更换 custom_phrase/user_dict的txt为custom_phrase/dictionary的dict.yaml，解决了txt无法根据同权重词条上下顺序排序的问题、删除了两个ox快符、更随万象今晚更新
2.20.18更新：解决了某些候选字错误的被归类为符号组的问题
2.20.4更新：修复了加入虎码整句后 虎单虎词异常置顶 不让位于双拼词的问题
2.19.24更新：修复了加入虎码整句后 无法使用符号上屏的问题
2.19.23更新：新增了虎码整句功能
2.18.23更新：将虎单、虎词开关同时开启时 虎词的顺序放在了虎单之前
2.18.21更新：将其它形码单字词典加了词，从方案移到了群文件、更随万象更新
2.18.14更新：继续简化了lua逻辑、更随万象更新
2.17.23更新：解决了快符被开关关闭的问题，简化了lua逻辑
2.17.21更新：调整了滤镜顺序，更随万象今日更新
2.17.1更新：新增了置顶组句开关、更随万象更新
2.16.15更新，默认开启了音码调频，略微调整了快符，简化了custom.yaml，更随万象今日更新
2.14.15更新，新增了虎词和虎词开关
