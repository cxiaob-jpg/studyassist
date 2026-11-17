# 学习助理（StudyAssist）

给 **小学到高中** 孩子用的 **KOReader 插件**：在 Kindle 墨水屏上练语文、数学、英语、物理、化学、生物、历史、地理，还能背古诗、默单词。
默认离线、无广告、无账号，学习记录只保存在本机；只有家长主动配置并使用的 AI 出题和检查更新会联网。

> **打开 KOReader 就能练，一轮 10 题，约 5–10 分钟。** 不收集数据，不要求登录，也不需要手机 App 陪跑。

> 本项目基于原作者 **[AvenGeeker](https://github.com/AvenGeeker)** 的开源项目 [KidLearn](https://github.com/AvenGeeker/kidlearn) 二次开发，署名与改动说明见[原项目与致谢](#原项目与致谢)。

## 目录

- [功能](#功能)
- [学科与年级覆盖](#学科与年级覆盖)
- [安装](#安装)
- [在线更新](#在线更新可选联网)
- [使用](#使用)
- [背诵与单词](#背诵与单词)
- [出题与练习规则](#出题与练习规则)
- [知识点学习（课标知识图谱）](#知识点学习课标知识图谱)
- [积分、连续学习与奖章](#积分连续学习与奖章)
- [每日总结与抽卡](#每日总结与抽卡)
- [AI 错题变种](#ai-错题变种可选联网)
- [数据存储](#数据存储)
- [内容维护：题库与背诵卡](#内容维护题库与背诵卡)
- [开发与测试](#开发与测试)
- [代码结构](#代码结构)
- [已知限制与常见问题](#已知限制与常见问题)
- [参与贡献](#参与贡献)
- [原项目与致谢](#原项目与致谢)
- [许可](#许可)

---

## 功能

- **今日挑战**：点进去先按当前年级列出所有已收录学科（二级菜单），选学科后再挑单元（三级菜单），每轮 10 题；第一行的「全部学科混合」则直接跨学科抽 10 题。
- **8 学科练习**：语文、数学、英语、物理、化学、生物、历史、地理；按年级/学期/教材单元出题，每次 10 题。
- **背诵**：古诗接龙、古诗作者、英语词义、英语短语四类卡片，共 1310 张，按册分装。
- **英语单词默写**：显示中文，键盘输入英文；还能把课外遇到的词加进「我的单词库」，一起默写。
- **知识点学习（课标图谱）**：8 学科 3036 个知识点 / 11492 道题，按单元浏览、学习卡片先学后练、全册综合。
- **自适应诊断**：选一个知识点，答错沿先修边回溯找薄弱根因，生成学习路径；掌握度持久保存。
- **自适应难度**：每个「学科 + 年级」独立记录水平，按最近 10 次首次作答的正确率自动升降。
- **即时反馈**：答对给星星，答错可再试一次，也可以直接看答案和解析。
- **激励系统**：星星积分、连对奖励、连续学习天数、50 枚奖章（翻页奖章墙）、错题本与错题复习。
- **每日总结与抽卡**：每累计首答 20 题得 1 次抽卡机会，从 48 张卡池里智能抽卡，优先补没收集过的卡。
- **AI 错题变种（可选联网）**：配置 OpenAI、DeepSeek、通义千问、Kimi、智谱、豆包、Gemini、Claude、硅基流动、OpenRouter、Ollama 或自定义 OpenAI 兼容服务，从错题生成同知识点变种题；单题 3 道、批量最多 10 道，生成后先给家长预览。
- **家长设置**：省份、年级、学期、语文/数学教材、每日目标（5/10/15/20 题）、答错是否可重试、AI 服务、重置进度。

墨水屏适配：单窗口内切换页面，不做动画，按钮和字号按屏幕缩放，避免频繁整屏刷新。

---

## 学科与年级覆盖

静态题库共 **12719 题**（91 册），知识点题另计 **11492 道**（3036 个知识点）。小学数学在运行时程序生成，题量无限。

| 学科 | 年级 | 教材版本 | 静态题量 | 知识点 |
| --- | --- | --- | --- | --- |
| 语文 | 1–9 | 统编 | 4612（30 册） | 683 |
| 数学 | 1–12 | 人教 / 北师大 / 苏教 / 苏教（2024新教材，四上）/ 青岛 / 沪教 + 初中 / 高中 | 2087（11 册，小学部分程序生成） | 859 |
| 英语 | 3–12 | 人教 PEP / 人教初中 / 人教高中 | 3164（19 册） | 791 |
| 物理 | 8–12 | 人教 | 1236（10 册） | 305 |
| 化学 | 9–12 | 人教 | 584（7 册） | 141 |
| 生物 | 7–8 | 人教 | 264（4 册） | 66 |
| 历史 | 7–9 | 统编 | 536（6 册） | 133 |
| 地理 | 7–8 | 人教 | 236（4 册） | 58 |

当前年级没有的学科会显示「本学习阶段暂无某学科」，并提示覆盖范围，可在设置里切换年级。省份目录共 32 个，用于推荐常用教材版本，家长仍可手动覆盖。

---

## 安装

> 🤖 **不会越狱 / 没装过 KOReader？想让 AI 一步步帮你装？**
> 见 [《用 AI 助手把学习助理装进 Kindle（保姆级 · AI 可执行教程）》](docs/AI_INSTALL_GUIDE.md)：
> 把整份文档发给你的 AI（ChatGPT / Claude / Kimi / DeepSeek 等），它会带你完成越狱、安装 KOReader、安装本插件，
> 还能把你的 AI API 配置直接生成并推送到 Kindle，免去在墨水屏上手填 Key。

### Kindle

> 本仓库根目录就是插件本体。克隆或下载后，把整个仓库目录重命名为 `studyassist.koplugin` 再复制；也可以直接用打包脚本生成安装包。

1. 用 USB 连接 Kindle。
2. 把 **整个** `studyassist.koplugin` 文件夹复制到：

   ```text
   /Volumes/Kindle/koreader/plugins/studyassist.koplugin/
   ```

   最终必须存在：

   ```text
   /Volumes/Kindle/koreader/plugins/studyassist.koplugin/main.lua
   ```

3. 安全弹出 Kindle，重启 KOReader。
4. 主菜单 → **更多工具** → **学习助理**。

也可以使用打包脚本生成的 `install/studyassist/studyassist.koplugin.zip`，解压后得到同名文件夹，放到上面的位置即可。

### 升级

覆盖 `studyassist.koplugin` 文件夹不会影响学习记录：记录在 `koreader/settings/studyassist.lua`；自定义单词在 `studyassist_words.lua`；使用过 AI 出题时，变种题库在 `studyassist_ai_bank.json`。

不想每次用 USB 拷贝？插件内置了[在线更新](#在线更新可选联网)，可在「设置 → 检查更新」里直接从 GitHub Release 升级，学习记录同样不受影响。

### 开机自动进入（可选）

给 KOReader 的启动脚本设置环境变量即可，任选一个：

```bash
export STUDYASSIST_AUTOSTART=1     # 推荐
export KIDLEARN_AUTOSTART=1        # 旧配置名，仍兼容
```

设置后启动 KOReader 约 1 秒会自动打开学习助理。

### 绑定快捷键（可选）

插件注册了 Dispatcher 动作：

- 动作 ID：`studyassist_open`
- 事件：`StudyAssistOpen`

可以在 KOReader 的「手势管理 / 快捷键」里绑定它，一键打开。

---

## 在线更新（可选联网）

插件内置了从 GitHub Release 自更新的能力，省去每次用 USB 把文件夹拷到 Kindle 的麻烦。这是继 AI 出题之后第二个**可选联网**功能：**默认手动触发，不后台轮询、不收集任何数据**。

### 怎么用

1. 打开「设置」，可以看到「当前版本：vX.Y.Z」。
2. 点「检查更新」：插件请求 GitHub 最新 Release 并比对版本号。已是最新会提示「已是最新版本」；有新版本则弹确认框，点「升级」后开始下载 `studyassist.koplugin.zip`。
3. 下载时会显示**进度条**（已下载 / 总大小和百分比）。下载**不设超时**：网络慢或暂时卡住只会停在当前进度，不会报错，什么时候继续由网络决定；不想等了随时点「取消下载」即可，取消不影响任何学习记录，也不会留下临时文件。下载完成后自动解压并替换插件程序。
4. 升级完成后提示重启 KOReader 生效（Lua 模块有缓存，必须重启）。点「重启」即可；选「稍后」则下次启动生效。

也可以在设置里打开「启动时自动检查更新」（**默认关闭**）。打开后，每次进入插件且设备已联网时静默检查一次，只有发现新版本才弹确认框；离线时不打扰、不会主动要求开 WiFi。

### 历史数据零影响（重要）

**升级只替换插件程序，绝不动你的学习记录。** 星星、连续打卡、每日统计、错题本、自适应等级、知识点掌握度、奖章和设置都在 `koreader/settings/studyassist.lua`，自定义单词在 `studyassist_words.lua`，AI 变种题库在 `studyassist_ai_bank.json`——这些都在插件目录**之外**。更新器的写入范围严格限定在插件目录和两个临时目录，从不读写 settings；升级失败会自动回滚到旧版本。无论成功、失败还是回滚，学习记录都逐字节不变（有专门的单元测试验证）。

### 发布约定（给维护者）

- 版本号唯一来源是 `_meta.lua` 的 `version`（如 `1.12.0`）。
- 在 GitHub 发 Release：tag 用 `vX.Y.Z`，附件名严格为 `studyassist.koplugin.zip`（用 `tools/studyassist/package_plugin.sh` 生成，包内顶层是 `studyassist.koplugin/`）。
- 插件用 `https://api.github.com/repos/cxiaob-jpg/studyassist/releases/latest` 检查，只认稳定版（不含 draft/prerelease）。
- 想验证更新流程：发一个比当前更高的 tag（如当前 1.12.0，发 v1.12.1）。

### 注意

- **开发版安装会被拒绝**：用 `test_plugin.sh` 链接进 KOReader 的符号链接安装属于开发版，更新器会提示手动更新，避免覆盖你的工作区。
- **网络**：直连 GitHub。国内访问可能较慢或不稳定：下载不设超时、带进度条，慢就慢慢等，随时可点「取消下载」；检查更新失败可重试。可在存档 `settings.update_api_url` 自定义检查接口地址（附件下载地址取自该接口返回，镜像需相应重写）。
- 首次使用前仓库需至少有一个已发布的 Release。

---

## 使用

首页顶部是学习总览（总星星、连续学习天数、今日进度、奖章数），下面是入口：

| 入口 | 说明 |
| --- | --- |
| 今日挑战·10题 | 二级菜单：按年级列出所有可用学科 + 「全部学科混合」；选学科后进入三级菜单挑单元，每轮 10 题 |
| 背诵 | 古诗接龙 / 古诗作者 / 英语词义 / 英语短语 / 英语单词默写 / 我的单词库 |
| 学科按钮（8 个） | 语文、数学、英语、物理、化学、生物、历史、地理；点进去选单元或综合练习，每次 10 题 |
| 拓展挑战 | 小学数学菜单内的专项入口：从数感、推理、几何、数据等素养题里抽 10 题，同轮不重复 |
| 知识点学习 | 选学科 → 按单元浏览知识点、学习卡片、知识点练习、全册综合、自适应诊断 |
| 错题本 | 查看错题、重做单题、复习全部错题、AI 强化、AI 题库 |
| 奖章墙 | 50 枚奖章，每页 10 枚翻页查看，已获得 / 未解锁及进度 |
| 抽卡 / 今日总结 | 每累计 20 题得 1 次抽卡机会，每次智能抽 1 张卡（优先新卡）；按钮显示「抽卡（X/20）」或「可抽 N 次」 |
| 集卡册 | 按等级查看已收集卡片，点卡片看详情；未收集显示卡背与「？？？」 |
| 设置 | 省份、年级、学期、语文教材、数学教材、每日目标、重试开关、AI 出题、重置进度、关于 |

今日挑战的三级结构：**首页 · 今日挑战 → 学科（二级）→ 单元（三级）→ 10 题**。二级菜单顶部是「全部学科混合（10 题）」，下面按当前年级只列出真正有题库的学科（例如低年级不会出现物理、化学），并标出每个学科的单元数；页面底部会写明本学习阶段暂缺哪些学科。

答题流程：选择答案（或数字键盘输入）→ 点「确认答案」→ 立即判题 → 查看解析 → 继续下一题。
答错时如果开启了重试，可以「再试一次」；也可以「看答案」，此时显示正确答案和解析。

---

## 背诵与单词

背诵是纯闪卡循环：不判题、不给星星、不进错题本，只看和记。

| 类型 | 玩法 | 卡片数 |
| --- | --- | --- |
| 古诗接龙 | 看上一句，背下一句 | 157 |
| 古诗作者 | 看篇名，背作者 | 173 |
| 英语词义 | 看英文单词，想中文意思 | 692 |
| 英语短语 | 看英文短语，想中文意思 | 288 |

- 卡片按学科、年级、学期分装，只出现当前学习阶段的内容；换年级后自动切换。
- **英语单词默写**：显示中文，用 KOReader 键盘输入英文；判分忽略大小写和首尾标点。
- **我的单词库**：把课外遇到的词记下来，和课本词一起默写。添加时填英文单词和中文意思；**中文可以留空**，留空的词能查看和删除，但不参与默写（Kindle 没有中文输入法，这是正常用法）。
- 重复添加同一个单词会覆盖中文意思，不会产生重复条目。
- 单词库保存在插件目录之外（`koreader/settings/studyassist_words.lua`），升级插件不会丢。

---

## 出题与练习规则

| 模式 | 题量 | 组成 |
| --- | --- | --- |
| 今日挑战（全部学科混合） | 10 | 当前年级所有可用学科轮换抽取，同一轮不重复 |
| 今日挑战（指定学科） | 10 | 三级菜单选单元后出题，与「学科练习」同规则 |
| 学科练习 | 10 | 指定单元，或按当前年级的单元轮换（综合练习） |
| 错题复习 | ≤10 | 按最久未复习优先，最多 10 题 |
| AI 强化 | ≤10 | 取最久未复习的 5 道错题，每题 AI 生成 2 道变种；每次重新生成 |
| 知识点练习 | 1–4 | 单个知识点的全部题目，按难度升序 |
| 全册综合 | 10 | 当前年级/册按单元轮换抽知识点题，难度随自适应等级 |
| 知识点诊断 | ≤12 | 目标知识点 + 先修回溯；连对 2 题判掌握，答错补基础确认题 |
| 背诵 | — | 闪卡，不判题 |

小学数学（1–6 年级）由程序生成，题量无限；初中、高中数学走静态题库。

### 难度

- 每道题难度为 1–3；静态题库固定标注，数学小学部分由生成器按难度出题。
- 每个「学科 + 年级」有独立的 `adaptive.level`（1–3），初始为 2；切换年级不会串难度。
- 每 10 次**首次作答**结算一次：正确率 ≥ 90% 升一级，≤ 50% 降一级。
- 按当前等级抽题的概率：

  | 等级 | 难度 1 | 难度 2 | 难度 3 |
  | --- | --- | --- | --- |
  | 1 | 70% | 30% | 0% |
  | 2 | 30% | 50% | 20% |
  | 3 | 10% | 40% | 50% |

### 去重

最近答过的 30 道题会记录在 `recent_ids`，抽题时优先避开；题库不够时才允许重复。

---

## 知识点学习（课标知识图谱）

从开源项目 [cn-math-taxonomy](https://github.com/xiaoyang111222/cn-math-taxonomy) 同步的知识图谱与题库（**CC BY-NC 4.0**：署名、非商业使用；数据文件头记录了来源 commit）：

| 学科 | 知识点 | 题目 | 覆盖年级 |
| --- | --- | --- | --- |
| 数学 | 859 | 3254 | 1–12 |
| 英语 | 791 | 3164 | 3–12 |
| 语文 | 683 | 2732 | 1–9 |
| 物理 | 305 | 1063 | 8–12 |
| 化学 | 141 | 378 | 9–12 |
| 历史 | 133 | 497 | 7–9 |
| 生物 | 66 | 216 | 7–8 |
| 地理 | 58 | 188 | 7–8 |

首页「知识点学习」→ 选学科 → 按当前年级/学期浏览：

- **知识点列表**：按教材单元分组，显示掌握状态（★已掌握 ●学习中 ▲薄弱，无标记 = 未学）；顶部「全册综合（10 题）」按单元轮换抽题，难度随自适应等级。
- **学习卡片（先学后练）**：知识点描述、掌握标准、例题与参考答案；列出直接先修知识点（hard 在前），可点击跳转先学基础；「开始练习（N 题）」按难度升序练该点全部题目（1–4 题）。
- **自适应诊断**：选一个目标知识点，引擎先出提高题；连对 2 题判「掌握」（并推断其先修已掌握）；答错补一道基础确认题——确认对判「不稳」，确认错判「薄弱」并沿先修边回溯（hard 优先，深度 ≤3，总题量 ≤12）。结果页给出掌握/不稳/薄弱清单和「学习路径」（薄弱根因在前），可一键去学第一个薄弱点。
- **掌握度存档**：练习与诊断结果写入 `studyassist.lua` 的 `knowledge` 字段。单点练习首答全对 → 已掌握、全错 → 薄弱、其余 → 学习中；全册综合里每个知识点至少 2 题才升级掌握。诊断是测评：不给星星、不进错题本、不影响自适应等级与连续天数。

细节约定：

- 知识点模式**不受教材版本设置限制**，标注「课标知识点 · 人教/统编参考」；年级/学期沿用设置页。
- 数学数值题支持整数、小数、分数答案：小数/分数题的数字键盘会增加「.」「/」键，分数判分接受等价小数（如 1/2 = 0.5）。
- 知识点练习的计分、错题本、奖章规则与普通练习完全一致。

### 同步与维护

```bash
# 从本地 cn-math-taxonomy 检出重新生成 data/knowledge/
python3 tools/studyassist/sync_taxonomy.py --source ~/GitHub/cn-math-taxonomy
# 校验生成物
python3 tools/studyassist/validate_knowledge.py
# 检查生成物是否与源一致（提交前）
python3 tools/studyassist/sync_taxonomy.py --check
```

`data/knowledge/` 全部是生成产物，**不要手改**；源仓库更新后重跑同步脚本覆盖。

---

## 积分、连续学习与奖章

### 星星

| 场景 | 星星 |
| --- | --- |
| 首次答对 | +10 |
| 第二次答对 | +5 |
| 连对 3 题（首次答对） | 额外 +5 |
| 连对 5 题 | 额外 +10 |
| 连对 10 题 | 额外 +20 |
| 完成一轮 | +10 |
| 单轮 10 题全部首次答对 | 额外 +20 |
| 当天第一轮 | 额外 +10 |
| 错题复习首次答对 | +5 |
| 错题复习第二次答对 | +2 |

错题复习不参与连对奖励，也没有「完成一轮 / 满分 / 当天首轮」奖励。

### 连续学习

- 当天首次作答累计达到 **5 题**，记为一个学习日（答错也算）。
- 连续的自然日累加；断一天从 1 重新开始。
- 历史最长连续天数会保留，用于奖章判定。

### 奖章（50 枚）

奖章墙每页 10 枚（2×5），用「上一页 / 下一页」翻页；首页按钮显示 `奖章墙（x/50）`。

| 线 | 奖章与条件（目标递进） |
| --- | --- |
| 单科入门 | 初次闯关（完成第一轮）、小试牛刀（答对 20）、百题达人（答对 100）、满分王（单轮全对）、三日坚持（连续 3 天）、一周之星（连续 7 天）、识字小博士（语文答对 50）、口算小能手（数学答对 50）、单词小达人（英语答对 50）、物理小牛顿（物理答对 50）、历史小通鉴（历史答对 50）、十连对（连对 10）、错题克星（掌握 5 道错题） |
| 星星 | 星光闪闪 500 → 星星收藏家 2000 → 星空大师 5000 → 传奇星主 10000 |
| 答对 | 答题小勇士 300 → 知识小达人 600 → 千题学者 1000 → 学霸之星 2000 |
| 轮次 | 勤学不倦 30 → 百轮勇士 100 |
| 连续学习 | 半月恒心 14 → 月度之星 30 → 双月坚持 60 → 百日传奇 100 |
| 单科进阶 | 识字小硕士（语文 150）、语文小学者（语文 300）、口算小硕士（数学 150）、数学小学者（数学 300） |
| 连对 | 十五连对 15 → 二十连对 20 |
| 满分轮 | 满分常客 5 → 满分传奇 10 |
| 错题掌握 | 错题清道夫 15 → 错题终结者 30 |
| 拓展挑战轮次 | 拓展新手 1 → 拓展爱好者 5 → 拓展小达人 15 → 拓展高手 30 → 拓展大师 60 → 拓展传奇 100 |
| 拓展挑战答对 | 思维萌芽 10 → 思维小火花 50 → 思维小火焰 150 → 思维小太阳 300 |
| 知识点掌握 | 知识点小收藏 10 → 知识点小达人 30 → 知识点小博士 60 |
| 集卡 | 稀有卡新手（首张 S 及以上）、集卡小行家（15 种）、传说收藏家（首张 SSS） |

挑战计数从 v1.3.2 起累积，不追溯旧版本的历史轮次。

### 错题本

- 首次答错时把整道题快照存入错题本（含题干、选项、答案、解析）。
- 错题最多保留 200 道，超出时淘汰最久未复习的。
- 对错题本里的题，首次作答答对累计 2 次即视为「掌握」，移出错题本（普通练习和错题复习都算）。
- 因为存的是快照，之后修改题库不会改变已存在的错题。
- 错题详情可点「AI 出 3 道变种」；错题本可点「AI 强化」批量生成。生成结果先进入「家长预览」，确认后再练。
- AI 变种答错会作为普通错题进入错题本；答对不推进原错题的掌握进度。
- 所有生成结果长期保存在独立 AI 题库，可按组删除或清空；清空 AI 题库不会删除错题本。

---

## 每日总结与抽卡

首页「抽卡 / 今日总结」入口。**抽卡按累计题量解锁：每累计首答 20 题获得 1 次抽卡机会，每次智能抽 1 张卡，不限每日次数**。首页按钮与总结页都会实时显示「抽卡进度 X/20 · 可抽 N 次」；机会不足时点击会提示还差几题。错题复习的首答不计入抽卡题量，避免靠重做旧题刷抽卡。

1. **评分（本地公式，0–100）**：目标完成 30 分 + 首答正确率 30 分 + 轮次 15 分 + 拓展挑战 10 分 + 知识点练习 5 分 + 连续学习 10 分 + 收藏力量 10 分。≥90 超赞、75–89 很棒、60–74 不错、<60 继续加油。
2. **总结文案**：配置了 AI 时，把当天聚合统计发给 AI，生成 80–200 字总结和每张卡片的祝福语；未配置或请求失败时使用离线模板总结，卡片照常抽取。
3. **抽卡**：分数决定各等级权重，先随机等级，再在该等级里优先挑一张没收集过的卡。

   **累计幸运**：每累计答题 100 道 +1 点，每累计完成拓展题 25 道 +1 点，合计封顶 +20 点，全部加到 SS 权重上；解锁挑战奖章后，每 2 点幸运再给 SSS 增加 1 点权重。

   **SSS 为拓展挑战专属**：只有解锁了挑战奖章才会进入卡池（10 枚满配、评分 100、幸运 20 时约占总权重 25%）。

   整个卡池集齐后才会抽到重复卡，重复卡只累计数量。

- 卡池固定 48 张：R×12、RR×10、S×8、SS×10、SSS×8（动物 + 学习主题，SS/SSS 为神话瑞兽）。卡面为灰度插画（`data/cards/`，缺图时自动降级为纯文字格）。
- 「集卡册」按 SSS→R 分组展示全部卡片：已收集显示卡面缩略图与数量，点开看详情；未收集显示卡背与「？？？」，不可点击。
- 抽卡机会来自累计首答（每 20 题 1 次，错题复习不计）；抽卡结果先写入存档，再请求 AI，断网或 AI 失败不丢卡。

---

## AI 错题变种（可选联网）

AI 出题未配置时不可用；家长在「设置 → AI 出题」里配置 API Key 和模型后即可使用。调用时只发送当前选中的错题快照（题干、选项、答案、解析、年级/单元/难度），不会发送孩子姓名或设备信息。

支持多个服务配置并选择一个当前服务：

| 预设 | 协议 | 默认接口 |
| --- | --- | --- |
| OpenAI | OpenAI 兼容 | `https://api.openai.com/v1` |
| DeepSeek | OpenAI 兼容 | `https://api.deepseek.com/v1` |
| 通义千问 | OpenAI 兼容 | `https://dashscope.aliyuncs.com/compatible-mode/v1` |
| Kimi | OpenAI 兼容 | `https://api.moonshot.cn/v1` |
| 智谱 GLM | OpenAI 兼容 | `https://open.bigmodel.cn/api/paas/v4` |
| 豆包/火山方舟 | OpenAI 兼容 | `https://ark.cn-beijing.volces.com/api/v3` |
| Google Gemini | Gemini 原生 | `https://generativelanguage.googleapis.com/v1beta` |
| Anthropic Claude | Anthropic 原生 | `https://api.anthropic.com/v1` |
| 硅基流动 | OpenAI 兼容 | `https://api.siliconflow.cn/v1` |
| OpenRouter | OpenAI 兼容 | `https://openrouter.ai/api/v1` |
| Ollama（局域网） | OpenAI 兼容 | 家长填写，例如 `http://<电脑IP>:11434/v1` |
| 自定义 | OpenAI 兼容 | 家长填写 |

- 每个配置只需要选预设、填 API Key 和模型；自定义服务还需要填接口地址。
- 「测试连接」会发送一条极短请求，可能消耗少量 token。
- API Key 明文保存在 `koreader/settings/studyassist.lua`，设置页只显示末 4 位。KOReader 没有系统钥匙串，请使用低额度 Key，并避免在共用设备上保存。
- 公网服务请使用 `https://`；自定义 `http://` 只建议在可信局域网（如 Ollama）使用。
- AI 生成内容不保证完全正确；预览页会显示答案和解析，请家长检查后再让孩子练习。
- 生成结果会做结构校验（题量、四个不重复选项、答案 1–4、解析、阅读材料），但无法自动验证所有学科答案，仍需家长预览。
- 批量模式取最久未复习的 5 道错题，每题 2 道，最多 10 道；每次批量都会新建一组。

### 用配置文件免手填（推荐）

如果不想在 Kindle 上逐项输入 API Key 和模型，可以在电脑上准备：

```text
koreader/settings/studyassist_ai_config.json
```

Kindle 用 USB 连接后通常就是：

```text
/Volumes/Kindle/koreader/settings/studyassist_ai_config.json
```

最小配置示例（`preset`、`api_key`、`model` 必填；`base_url` 可省略，省略时用预设默认地址）：

```json
{
  "preset": "deepseek",
  "base_url": "https://api.deepseek.com/v1",
  "api_key": "sk-你的Key",
  "model": "deepseek-chat"
}
```

`preset` 可用值：`openai`、`deepseek`、`qwen`、`kimi`、`zhipu`、`doubao`、`gemini`、`claude`、`siliconflow`、`openrouter`、`ollama`、`custom`。使用第三方中转或自定义 OpenAI 兼容地址时，写 `"preset": "custom"` 并填写 `base_url`。

仓库里有一份模板：[`tools/studyassist/studyassist_ai_config.example.json`](tools/studyassist/studyassist_ai_config.example.json)。复制为 `studyassist_ai_config.json`、改好三个值，再推到上面的路径即可。**不要把填好 Key 的文件提交到 Git。**

也可以用脚本生成并直接推送到 Kindle（Kindle 挂载点通常是 `/Volumes/Kindle`）：

```bash
python3 tools/studyassist/make_ai_config.py \
  --preset deepseek \
  --api-key sk-你的Key \
  --model deepseek-chat \
  --mount /Volumes/Kindle
```

不加 `--mount` 时只生成当前目录下的 `studyassist_ai_config.json`；自定义接口地址用 `--base-url`，自定义显示名用 `--name`，预设用 `--preset custom`。

配置规则：

- 放入文件后重启 KOReader，插件会读入文件并在「设置 → AI 出题」显示「当前 AI 配置来自 …」。
- 文件内容变化后重启会重新导入；导入会**替换**插件里现有的 AI 服务列表，请把要保留的服务都写进同一个文件。
- 导入成功后可继续在插件里临时修改；只要文件内容不再变化，重启不会把临时修改改回去。删除配置文件并重启后，导入记录会清除，之后以插件内设置为准。
- 文件是 JSON，不能写注释；API Key 和 `studyassist.lua` 一样是明文，请给 Key 设置低额度，并避免放在共用设备或公开仓库。
- 多个服务可以写成数组，并指定当前服务：

```json
{
  "active_id": "aip-2",
  "profiles": [
    { "id": "aip-1", "preset": "deepseek", "api_key": "sk-aaa", "model": "deepseek-chat" },
    { "id": "aip-2", "preset": "qwen", "api_key": "sk-bbb", "model": "qwen-plus" }
  ]
}
```

---

## 数据存储

进度文件：

```text
koreader/settings/studyassist.lua
```

自定义单词：

```text
koreader/settings/studyassist_words.lua
```

可选 AI 配置（推到设置目录后自动导入）：

```text
koreader/settings/studyassist_ai_config.json
```

可选 AI 题库（只有使用过 AI 出题才会生成）：

```text
koreader/settings/studyassist_ai_bank.json
```

Kindle 上通常对应 `/mnt/us/koreader/settings/`。`studyassist.lua` 是 KOReader `LuaSettings` 序列化的 Lua 表，主要字段：

| 字段 | 内容 |
| --- | --- |
| `schema_version` | 存档版本，当前为 5 |
| `total` | 总星星、答题数、正确数、轮数、满分轮数、最高连对、掌握错题数、拓展挑战轮数、拓展挑战答题数、拓展挑战答对数 |
| `by_subject` | 8 学科各自的答题数与正确数 |
| `streak` | 当前连续天数、历史最长、最后学习日 |
| `daily` | 按日期统计的答题数、正确数、星星、轮数，以及学科细分、玩法轮数、知识点练习记录、每日总结报告（`report`）；保留 90 天 |
| `wrong` | 错题快照，最多 200 条 |
| `badges` | 已解锁奖章及时间戳 |
| `adaptive_by_grade` | 各「学科 + 年级」的难度等级与最近 10 次统计 |
| `settings` | 省份、年级、学期、语文教材、数学教材、每日目标、重试开关、AI 服务配置 |
| `recent_ids` | 最近 30 道题 ID |
| `knowledge` | 各学科知识点掌握度（learning/mastered/weak）、首答计数、最近学习时间 |
| `cards` | 永久卡片收藏：每张卡的数量、首次/最近获得时间、名称与等级快照；不随 90 天清理删除 |
| `draw` | 抽卡进度 `progress`、可用机会 `credits`、累计抽卡次数 `draws`、一次性迁移标记 `seeded` |

- **备份 / 换机**：复制 `studyassist.lua`；如需保留自定义单词，再复制 `studyassist_words.lua`；如需保留 AI 变种题，再复制 `studyassist_ai_bank.json`。
- **升级快照（v5）**：从旧版本升级后第一次写入前，插件会把原始存档完整复制为 `studyassist.lua.pre-v5.bak`（一次性、永不覆盖）。迁移只新增字段，不改动既有星星、奖章、错题、知识点等任何数据。KOReader 自身还会滚动保留 `studyassist.lua.old` 作为日常写入备份。
- **重置进度**：设置 → 重置学习进度。只清空星星、打卡、奖章、错题、知识点掌握度、卡片收藏和挑战计数，保留省份、年级、学期、教材、每日目标、重试开关、AI 服务配置和 AI 题库。自定义单词也不受影响。
- 存档结构变化时必须在 `core/progress.lua` 的 `normalize()` 里做兼容处理，见 [`AGENTS.md`](AGENTS.md)。

---

## 内容维护：题库与背诵卡

所有题库、知识点、背诵卡都是脚本生成的 JSON，插件只读 JSON，**不要手改 `data/` 下的生成产物**。

```text
tools/studyassist/
├── build_bank.py           # 小学语文题库（源数据 + 生成逻辑）
├── build_junior.py         # 初中 8 科题库（从 cn-math-taxonomy 抽取）
├── build_from_taxonomy.py  # 按教材单元生成静态题库
├── build_catalog.py        # 省份 / 年级 / 教材 / 单元目录
├── build_knowledge_all.py  # 8 学科知识点 + 知识点题库
├── build_recite.py         # 背诵卡（古诗接龙 / 作者 / 词义 / 短语）
├── sync_taxonomy.py        # 从 cn-math-taxonomy 同步知识图谱
├── validate_bank.py        # 单册题库校验
├── validate_banks.py       # 全部题库校验
├── validate_catalog.py     # 目录与知识点映射校验
├── validate_knowledge.py   # 知识点题库校验
├── export_review.py        # 导出家长抽查清单
└── package_plugin.sh       # 打包安装 zip
```

常用命令：

```bash
# 重新生成目录
python3 tools/studyassist/build_catalog.py
# 重新生成小学语文题库
python3 tools/studyassist/build_bank.py
# 重新生成初中题库
python3 tools/studyassist/build_junior.py
# 重新生成知识点与背诵卡
python3 tools/studyassist/build_knowledge_all.py
python3 tools/studyassist/build_recite.py
# 全量校验
python3 tools/studyassist/validate_banks.py
python3 tools/studyassist/validate_catalog.py
python3 tools/studyassist/validate_knowledge.py
# 导出家长抽查清单（每单元默认 5 题）
python3 tools/studyassist/export_review.py
```

> 生成拼音需要 `pypinyin`：`pip install -r tools/studyassist/requirements.txt`。

`export_review.py` 输出到 `install/studyassist/review/`（该目录被 `.gitignore` 忽略，不随仓库提交）。

### 题目字段

```json
{
  "id": "zh2u-u1-001",
  "unit": "u1",
  "type": "pinyin_to_char",
  "skill": "pinyin",
  "difficulty": 1,
  "answer_mode": "choice",
  "stem": "“kē”对应的汉字是？提示：可以组成“蝌蚪”。",
  "options": ["蝌", "跳", "蚪", "池"],
  "answer": 1,
  "explain": "“蝌”读 kē，可以组词“蝌蚪”。"
}
```

| 字段 | 必填 | 说明 |
| --- | --- | --- |
| `id` | 是 | 全局唯一 |
| `unit` | 是 | 必须是 `data/catalog.json` 中该年级/学期的单元 ID |
| `type` | 是 | 题型标识，如 `pinyin_to_char`、`word_choice`、`reading`、`choice` |
| `skill` | 是 | 展示用技能标签 |
| `difficulty` | 是 | 1–3 |
| `answer_mode` | 是 | `choice` 或 `number` |
| `stem` | 是 | 题干 |
| `passage` | 阅读题必填 | 共用短文 |
| `options` | 选择题必填 | 恰好 4 个，互不重复、非空 |
| `answer` | 是 | 选择题为正确选项序号 1–4；数字题为数值 |
| `explain` | 是 | 解析，至少 4 个字符 |

### 校验脚本会检查什么

- `schema_version`、`subject`、`grade`、`semester` 正确；
- ID 全局唯一，单元存在于目录；
- 选项恰好 4 个且互不重复，答案在 1–4；
- 同一单元内题干不重复，解析不为空；
- 阅读题必须有 `passage`；
- 知识点题库的题目都能对应到 `topics` 里的知识点。

---

## 开发与测试

### 前置条件

- 准备一份 KOReader 源码检出，并能构建模拟器（见 [KOReader Building](https://github.com/koreader/koreader/blob/master/doc/Building.md)）。默认使用 `~/GitHub/koreader`，其他位置用 `KOREADER_DIR=/path/to/koreader` 指定。
- 初始化 KOReader 子模块：

  ```bash
  cd "${KOREADER_DIR:-$HOME/GitHub/koreader}"
  git submodule update --init --recursive
  ./kodev build
  ```

- macOS 建议用 Homebrew 安装 `bash`、`gnu-getopt`、`coreutils`、`make`、`findutils`。

### 运行模拟器

在仓库根目录执行：

```bash
tools/studyassist/run_emulator.command
```

脚本会把本仓库链接到 `${KOREADER_DIR:-$HOME/GitHub/koreader}/plugins/studyassist.koplugin`，设置 `STUDYASSIST_AUTOSTART=1`，然后启动 KOReader。启动后约 1 秒会自动打开插件。

### 单元测试

测试源码在 `spec/unit/studyassist_*.lua`。`test_plugin.sh` 会临时把本仓库和测试链接进 KOReader，再通过 `front` 套件运行：

```bash
# 跑全部插件测试
tools/studyassist/test_plugin.sh

# 只跑一个
tools/studyassist/test_plugin.sh studyassist_session

# 复用已有构建，跳过重新编译
KODEV_REUSE_BUILD=1 tools/studyassist/test_plugin.sh studyassist_session
```

| 测试 | 覆盖内容 |
| --- | --- |
| `studyassist_bank` | 题库加载、单元覆盖、阅读短文、旧接口兼容 |
| `studyassist_catalog` | 省份/年级/教材目录、推荐教材、知识点生成校验 |
| `studyassist_mathgen` | 多版本 × 多年级单元生成校验、拓展题 |
| `studyassist_progress` | 积分、连对、连续天数、分年级自适应、错题掌握、存档兼容、迁移零丢失 |
| `studyassist_session` | 满分一轮、今日挑战跨学科、跨年级/教材、错题复习、重试与奖励 |
| `studyassist_ui` | 首页 / 学科菜单 / 背诵 / 设置 / 奖章翻页 / 错题本 / AI 设置与预览 / 每日总结 / 集卡册 / 更新对话框 |
| `studyassist_ai` | 厂商协议、请求构建、响应解析、变种校验、AI 题库 |
| `studyassist_knowledge` | 知识点分册/图谱加载、选项与分数判分、缓存 |
| `studyassist_diagnose` | 掌握/不稳/薄弱判定、先修回溯顺序、题量与深度上限 |
| `studyassist_cards` | 卡池完整性、收藏力量与评分加成、等级权重、智能单抽、离线兜底 |
| `studyassist_update` | 版本比较、Release 解析、路径净化、增量下载、升级回滚与数据零影响 |

### 打包

```bash
tools/studyassist/package_plugin.sh
# 输出：install/studyassist/studyassist.koplugin.zip
```

发 GitHub Release 时：tag 用 `vX.Y.Z`（与 `_meta.lua` 的 `version` 对应），把 `studyassist.koplugin.zip` 作为同名附件上传，插件的[在线更新](#在线更新可选联网)即可识别。

---

## 代码结构

```text
.
├── _meta.lua              # 插件名、描述与版本号（version 为更新比对唯一来源）
├── main.lua               # 入口：菜单注册、Dispatcher 动作、开机自动打开
├── core/
│   ├── catalog.lua        # 省份/年级/教材/单元目录读取
│   ├── bank.lua           # 静态题库加载、校验、缓存、按单元/难度抽题
│   ├── knowledge.lua      # 课标知识点分册/先修图谱加载、分数/小数判分
│   ├── diagnose.lua       # 自适应诊断引擎（先修回溯、掌握/不稳/薄弱、学习路径）
│   ├── recite.lua         # 背诵卡加载与分类
│   ├── words.lua          # 自定义单词库（增删、默写出题）
│   ├── session.lua        # 会话构建（今日挑战/学科/错题/AI）、判题、连对、结算
│   ├── progress.lua       # 本地存档、每日统计、连续天数、分年级自适应、错题本
│   ├── badges.lua         # 50 枚奖章的定义与解锁判断
│   ├── cards.lua          # 48 张固定卡池、智能单抽权重、收藏统计
│   ├── report.lua         # 每日评分公式、总结提示词与校验、离线兜底
│   ├── mathgen.lua        # 小学数学题与拓展题的程序生成器
│   ├── ai_config.lua      # AI 厂商预设、服务配置、Key 校验
│   ├── ai_http.lua        # LuaSocket/LuaSec + Turbo 的 HTTPS POST 传输
│   ├── ai_client.lua      # OpenAI / Anthropic / Gemini 请求与响应
│   ├── ai_variant.lua     # 变种提示词、严格 JSON 校验、题目标准化
│   ├── ai_bank.lua        # 独立 AI 变种题库 JSON 存储
│   ├── update.lua         # GitHub Release 在线自更新（可选联网，历史数据零影响）
│   └── update_http.lua    # 更新下载引擎：非阻塞分片下载，进度回调、可取消
├── ui/
│   ├── mainview.lua       # 单窗口状态机：首页/学科/答题/背诵/单词/总结/错题/AI/奖章/集卡册/设置
│   ├── update_dialog.lua  # 更新下载进度对话框（进度条 + 取消按钮）
│   └── widgets.lua        # 按钮、卡片、标签、进度条等墨水屏小组件
├── data/
│   ├── catalog.json       # 省份/年级/教材/单元目录
│   ├── chinese/ english/ math/ physics/ chemistry/ biology/ history/ geography/
│   │                      # 各科静态题库（生成产物）
│   ├── knowledge/         # 8 学科知识点题库 + 先修图谱（sync_taxonomy.py 生成）
│   ├── recite/            # 背诵卡（build_recite.py 生成）
│   └── cards/             # 卡面插画（灰度 PNG，勿手改）
├── tools/studyassist/     # 题库构建、校验、抽查导出、打包、测试、模拟器启动
├── spec/unit/studyassist_*.lua  # 插件单元测试
├── AGENTS.md              # 开发协作规范
└── README.md
```

一次答题的调用链：

```text
main.lua → ui/mainview.lua（状态机）
              ├── core/catalog.lua  读取省份/年级/教材/单元
              ├── core/session.lua  构建题目、判题、连对
              ├── core/bank.lua     静态题库读取与抽取
              ├── core/knowledge.lua 知识点题读取与判分
              ├── core/diagnose.lua 知识点诊断
              ├── core/recite.lua / core/words.lua  背诵与单词默写
              ├── core/mathgen.lua  小学数学题生成
              ├── core/progress.lua 记分、存档、错题、自适应
              ├── core/ai_*.lua     可选 AI 配置、请求、变种校验与题库
              ├── core/badges.lua   轮次结束时结算奖章
              └── core/report.lua + core/cards.lua  每日总结、评分与抽卡
```

---

## 已知限制与常见问题

**菜单里找不到插件？**
确认文件夹名以 `.koplugin` 结尾、`main.lua` 在文件夹根部，然后重启 KOReader。改名或换版本后必须重启，KOReader 不会热加载插件。

**从旧版 kidlearn 升级上来，记录会丢吗？**
不会，但要手动迁移一次：把 `koreader/settings/` 下的 `kidlearn.lua`、`kidlearn_words.lua`、`kidlearn_ai_bank.json`、`kidlearn_ai_config.json` 分别改名为 `studyassist.lua`、`studyassist_words.lua`、`studyassist_ai_bank.json`、`studyassist_ai_config.json`。

**中文或拼音显示成方块？**
确认没有删除 `koreader/fonts`；插件依赖 KOReader 的 CJK 字体回退。

**进度没有保存？**
检查 `koreader/settings/` 是否可写。

**想重新开始？**
设置 → 重置学习进度。只清空星星、打卡、奖章、错题、知识点掌握度、卡片收藏和挑战计数；省份、年级、学期、教材、每日目标、重试开关、AI 服务配置、AI 题库和自定义单词都会保留。

**为什么抽不到 SSS 卡？**
SSS 是拓展挑战专属：先完成拓展挑战解锁挑战奖章，SSS 才会进入卡池；挑战奖章越多、当天评分越高概率越大。

**能多设备同步吗？**
不能。除家长主动使用的 AI 出题和检查更新外，插件是单机离线的；没有账号、云同步或统计上报。换设备需要手动复制 `studyassist.lua`，需要保留单词时再复制 `studyassist_words.lua`。

**AI 出题失败怎么办？**
先检查 Wi-Fi、API Key、模型名称和接口地址；用配置文件部署时，确认文件在 `koreader/settings/studyassist_ai_config.json` 且是合法 JSON，改完文件后重启 KOReader。401 通常是 Key 无效，404 通常是模型或接口不存在，429 通常是请求太频繁或额度不足。

**AI 生成的题一定正确吗？**
不保证。生成后会做结构校验，但学科答案仍需家长在「家长预览」里检查。AI 出题会消耗服务商 token。

**多教材的单元名一定和纸质课本完全一样吗？**
目录按公开教材目录整理，不同地区、不同年份的印次可能有少量差异。发现不一致时改 `tools/studyassist/build_catalog.py` 后重新生成。

**为什么有些年级点进去显示「本学习阶段暂无某学科」？**
该学科的题库还未覆盖这个年级（例如生物只有 7–8 年级、地理只有 7–8 年级）。提示里会写明覆盖范围，切换到有内容的年级即可。

**改了 `data/*.json` 但界面没变化？**
`core/bank.lua` 有内存缓存，重启 KOReader；另外确认改的是构建脚本，不是只改了生成结果。

---

## 参与贡献

- Bug / 设备兼容问题：请附上 KOReader 版本、设备型号、复现步骤和相关日志。
- 修改代码或题库前，先读 [`AGENTS.md`](AGENTS.md)；题库 JSON 是生成产物，不要直接手改。
- 提交前至少运行插件单测：

  ```bash
  tools/studyassist/test_plugin.sh
  ```

- 用户可见行为变化时同步更新本 README；新增内容应保持适龄、离线优先和墨水屏友好。

---

## 原项目与致谢

本项目的**原作者是 [AvenGeeker](https://github.com/AvenGeeker)**，原始项目为 **KidLearn（小小学习家）**：

| | 链接 |
|---|---|
| 原作者 | <https://github.com/AvenGeeker> |
| 原项目仓库 | <https://github.com/AvenGeeker/kidlearn> |
| 原项目 Releases | <https://github.com/AvenGeeker/kidlearn/releases> |
| 原项目 Issues | <https://github.com/AvenGeeker/kidlearn/issues> |

「学习助理」是在原作者 KidLearn 的基础上二次开发而来，沿用了它的整体架构与大量代码：KOReader 插件框架与主视图状态机、题库/知识点 JSON 结构、奖章、抽卡、错题本、每日总结等机制，以及全部内容构建脚本的基础。没有原项目，就不会有这个版本。本版的主要改动是：

- 更名为「学习助理（StudyAssist）」，内部标识统一为 `studyassist`，更新源改为本仓库
- 学科从小学语文、数学扩展到小初高 8 科（语文/数学/英语/物理/化学/生物/历史/地理）
- 新增「今日挑战」（每次 10 题跨学科混合）与「背诵」（古诗接龙/作者/词义/短语，1310 张卡）
- 新增英语单词默写与自定义词库（`settings/studyassist_words.lua`）
- 首页与二级菜单布局针对 600×800 墨水屏重排，子页仅保留首页右上角关闭按钮

如果本项目对你有帮助，也请给原项目点一个 **Star**，这是对原作者最直接的支持。

---

## 许可

插件代码跟随 KOReader 仓库的 **AGPL** 许可（上游 [AvenGeeker/KidLearn](https://github.com/AvenGeeker/kidlearn) 亦为此声明），并保留原作者署名与源码出处（见[原项目与致谢](#原项目与致谢)）；再分发或修改时请同样保留该署名。
题目内容为原创或使用公版古诗/名句，不复制教材长课文。
`data/knowledge/` 下的知识图谱与题目改编自 [cn-math-taxonomy](https://github.com/xiaoyang111222/cn-math-taxonomy)，采用 **CC BY-NC 4.0**（署名、非商业使用）；商业使用需另行取得源项目授权。
