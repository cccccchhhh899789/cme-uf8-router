# 0.1.13 文档一致性核对（可直接当 checklist）

- 核对对象：`使用说明.txt`、`README.md`、`docs/known-pitfalls.md`、`docs/audit.md`、`docs/fixes-0.1.7.md`、`../复刻实现与排错.md`、`../../交接单.md`
- 代码基准：`src/AppDelegate.m`（602 行）、`src/MIDIMapper.h/.m`、`src/RouterCore.m`（1184 行）、`src/USBReader.m`、`src/main.m`、`build.sh`、`make-dmg.sh`
- 方式：只读 grep/read + `ls` 验证路径；**未运行 App、未跑自检、未碰 MIDI 端口**（Lead 与另一位同事在并行实测）
- 版本基准：源码/构建脚本=`0.1.13`；本报告行号以 2026-11-24 当前工作区为准（src 有未提交改动，行号可能再漂）

**问题计数：35 条**（高 12 / 中 13 / 低 10）。其中「代码已变、文档仍说旧行为」的实质错误 18 条，版本/路径类 11 条，历史文档保鲜 6 条。

---

## 一、高优先级：会直接把用户带错（先改这些）

| # | 位置 | 文档现在怎么说 | 代码事实（证据） | 应改成 |
|---|---|---|---|---|
| H1 | `使用说明.txt:42-43` | 「过滤器 > 勾选 = 丢弃该类消息。默认全不勾(原样直通)，只有遇到故障消息才需要勾」 | 0.1.13 已改白名单：菜单名=`放行(白名单)`（`src/AppDelegate.m:107`）；六项`勾选 = 放行`（`src/AppDelegate.m:302,310-324`）；默认 `allowNotes/Pitch/CC/SysEx=YES`、`allowClock/Sensing=NO`（`src/MIDIMapper.m:20-25`） | 改为「放行(白名单) > 勾选 = 放行，不勾 = 丢弃。默认放行 音符/弯音/CC/sysex，丢弃 时钟 F8 与 Active Sensing」；删掉「默认全不勾」 |
| H2 | `使用说明.txt:125-127` | 「USB 直连会多出 77 条/秒的时钟…有些 DAW 会把这股时钟当成速度…烦的话菜单【过滤器】勾上「过滤 时钟/实时消息」」 | 菜单名和项名都已不存在（`src/AppDelegate.m:107,315`）；默认 `allowClock=NO`，时钟根本不进 DAW（`src/MIDIMapper.m:24,51,171-173`）。77/s 只是 App 收到的量 | 改为「琴仍发 77 条/秒时钟，但默认白名单已丢弃，DAW 不会看到；若某个 DAW 明确需要时钟，才到【放行(白名单)】勾『时钟 F8』」 |
| H3 | `使用说明.txt:84-85` | MCU 对应关系写 `FF→0x5C REW→0x5B RTZ→0x36(F1)` | 0.1.12 起 FF/REW/RTZ 不再发按键，改发 Jog 轮：`B0 3C 41`（左/REW/RTZ）、`B0 3C 01`（右/FF）（`src/MIDIMapper.m:129-142`）。只有 STOP/PLAY/REC 仍是 Note（`0x5D/0x5E/0x5F`） | 改成三行 Jog 说明；删掉 `0x5C/0x5B/0x36` 和「RTZ→F1」；保留 PLAY/STOP/REC 的 Note 号 |
| H4 | `使用说明.txt:209-210` | 「当年原厂驱动能分成 CC115/CC116，是因为它走 UF8 自己的 USB 口 + CME 私有帧(帧里带按键 ID)」；「现在两个键都发 MCU 的 REWIND」 | 该「帧里带按键 ID」说法已被 2026-11-24 实测推翻（`../复刻实现与排错.md:21-27`：反编译 `_CMEParseUSBMIDIInputWithDriver` + USB 两轮六键逐字节相同）；现在两键都发 Jog 逆时针，不是 REWIND（`src/MIDIMapper.m:138-139`） | 改为「原厂驱动也分不开；5-pin 与 USB 上都相同。现在 `|<<`/`<<` 都发 Jog 逆时针一格」 |
| H5 | `使用说明.txt:128-129` | 「真被占了，菜单里会显示『打开 USB 接口失败』，把那个网页关掉再切一次即可」 | ①错误只在日志里：`USB 直连失败: …`（`src/RouterCore.m:658-659`），菜单项标题不会变；②失败后 `usbInput` 已置 YES，**再点同一项不会重试**（`src/AppDelegate.m:234-235` + `src/RouterCore.m:672-673` 提前 return） | 改为「到【查看日志】看『USB 直连失败: 打开 USB 接口失败…』；关掉占用网页后，先选任意一个 MIDI 端口（退出 USB 模式），再选回『用 USB 直连琴』才会重开；或重启 App」 |
| H6 | `使用说明.txt:40` | 协议模式只写「自动识别 / CME-USB / 标准流」 | USB 输入时三档全部 `enabled = !locked`，并多一行「USB 直连:固定按 CME 帧解码(下面三档不生效)」（`src/AppDelegate.m:268-288`） | 补一句「走 USB 直连时这三档会置灰，固定按 CME 帧解码（琴的 USB 口是混合格式）」 |
| H7 | `使用说明.txt:34-45` | 【菜单说明】仍是旧结构：没有 USB 首项、没有白名单六项/两个预设、没有 transport 键与抓包项 | 实际菜单：输入源首项是「用 USB 直连琴(不用转接头)/(未检测到琴)」（`src/AppDelegate.m:199-207`）；放行(白名单)六项+两个预设（`:310-331`）；另有「transport 键」「抓原始报文(排错用)」（`:111,119`） | 按代码重写这一节：输入源首项=USB；放行(白名单)六项+两项一键预设；补 transport 键、抓原始报文 |
| H8 | `README.md:27` | 「过滤器：CC#1 调制轮、CC#7 音量、时钟、Active Sensing 可单独丢弃」 | 同上，已改白名单六项（`src/MIDIMapper.m:20-25`、`src/AppDelegate.m:310-316`）；CC1/CC7 只是白名单之外的旧开关 | 改为「放行白名单：音符/弯音/CC/sysex/时钟/Active Sensing，勾选=放行；默认丢时钟与心跳」 |
| H9 | `README.md:84` | 「两个都发 MCU REWIND」 | 0.1.12 起都发 Jog 逆时针（`src/MIDIMapper.m:138-139`） | 改为「两个都发 Jog 逆时针一格（`B0 3C 41`），不是 REWIND」 |
| H10 | `README.md:86` | 「MCU 按键本身就是 Note On（CH1 的 91–95）」 | 91–95 里只剩 STOP(93)/PLAY(94)/REC(95)；REW(91)/FF(92) 已改 Jog CC（`src/MIDIMapper.m:129-152`） | 改为「STOP/PLAY/REC 是 Note On CH1（0x5D/0x5E/0x5F）；前后走带是 Jog CC」 |
| H11 | `README.md:123` | 「按键为 Note On CH1，按下 vel 0x7F、松开 0x00，必须成对发送」 | 只对 PLAY/STOP/REC 成立；FF/REW/RTZ 返回单条 `B0 3C xx`，没有按下/松开（`src/MIDIMapper.m:135-142`） | 加限定「STOP/PLAY/REC 成对；前后走带是单条 Jog CC，无配对」 |
| H12 | `交接单.md:117` | 标题「**CME UF8 Router 0.1.12**」；正文按 0.1.12 描述；末尾称「本地 `release/` 同样只留最新版三件套」 | 当前源码/构建=`0.1.13`（`build.sh:75,85`）；`release/` 实际同时有 v0.1.12 目录+dmg+zip 与 v0.1.13 目录+zip，**没有 0.1.13.dmg** | 改标题与描述为 0.1.13，补 USB 直连/白名单/协议置灰/两个预设；`release/` 三件套说法与现状二选一：补 0.1.13.dmg 并清走 v0.1.12，或改文档说明 |

---

## 二、中优先级：版本号、路径、功能描述不完整

| # | 位置 | 问题 | 应改成 |
|---|---|---|---|
| M1 | `README.md`（无版本行） | 通篇没有 `0.1.13` 版本号（只有 `:24` 提到 0.1.13 的功能），与任务要求的「五处一致」不符 | 顶部加「版本 0.1.13」或 badge；与 `使用说明.txt:4` 对齐 |
| M2 | `README.md:88` | 「仅支持 macOS（10.13+）」 | `build.sh:80-81` 写 `LSMinimumSystemVersion=11.0`，构建产物也是 11.0（PlistBuddy 实测）。改「macOS 11.0+」或把构建值改回 10.13（二选一，需 Lead 定） |
| M3 | `make-dmg.sh:3` | 头注释「产物:release/cme-uf8-router-v0.1.0.dmg」 | 改成 `${VERSION}` 的说明或直接写 0.1.13；实际变量 `:9` 已是 0.1.13 |
| M4 | `../复刻实现与排错.md:3` | 「对象：…（v0.1.7，2026-11-23）」 | 改 v0.1.13；或改成「当前版本 0.1.13，下文按专题保留历史版本标记」 |
| M5 | `../复刻实现与排错.md:49-55` | MCU 输出表仍写 `\|<<`→`90 5B`、`>>`→`90 5C` | 改成 Jog：`\|<<`/`<<`→`B0 3C 41`，`>>`→`B0 3C 01`；REC/STOP/PLAY 行保留 |
| M6 | `../复刻实现与排错.md:81` | 「本版两个都当 REWIND；回到开头用 Logic Return」 | 改为「本版两个都发 Jog 逆时针一格」，并保留 Return 建议 |
| M7 | `../复刻实现与排错.md:127` | 「原始报文抓取（常开）」 | 0.1.7 起默认关 + 菜单开关 + 8MB 轮转（`src/RouterCore.h:37`、`src/AppDelegate.m:353-361`），改成「默认关，排障时在菜单勾『抓原始报文』」 |
| M8 | `../复刻实现与排错.md:130-140` | 版本线停在 **0.1.6**，交付物指向 `release/cme-uf8-router-v0.1.6/` | 补 0.1.7–0.1.13（Jog/延迟松开/USB 直连/白名单/协议置灰），交付物改 v0.1.13 |
| M9 | `release/` | 缺 `cme-uf8-router-v0.1.13.dmg`；仍有 v0.1.12 的目录/dmg/zip 与 `使用说明-v0.1.12.txt` | 跑 `bash make-dmg.sh` 后清旧版；`交接单.md:117` 的「只留最新三件套」才成立。**未执行构建，仅报告** |
| M10 | `../复刻实现与排错.md:125` | 工具表列 `mmctest`，但 `tools/` 只有 `mmctest.m`，没有可执行文件（midilist/mculisten/mcuinject 都有） | 补编译产物，或注明「需先 clang 编译 mmctest.m」 |
| M11 | `make-dmg.sh:20` | 回退分支引用 `使用说明模板.txt`，项目里不存在该文件 | 删掉该分支或补模板文件 |
| M12 | `使用说明.txt:249-258` | 自检参数清单漏了 `--stop-selftest`（`src/main.m:35,89` 有）；`:256` 仍写「真点菜单项(过滤器/…)」 | 补 `--stop-selftest`；把「过滤器」改成「放行(白名单)」 |
| M13 | `src/AppDelegate.m:326,335-342`（文档/菜单文案） | 菜单写「一键:只放行键盘+弯音+踏板(最干净)」，实现却把 `allowSysEx=YES`（走带键 MMC 必需） | 文档如实写「键盘+弯音+CC(含踏板)+sysex（走带键需要）」，或改菜单名；需 Lead 定，**不要只改一边** |

---

## 三、低优先级：历史文档保鲜（不必重写正文，加横幅/注记即可）

| # | 位置 | 问题 | 建议 |
|---|---|---|---|
| L1 | `docs/known-pitfalls.md:3` | 「源码快照：RouterCore.m 736 行、AppDelegate.m 481 行」；现为 1184/602 行 | 加「行号与状态为 0.1.7 修复前快照」横幅 |
| L2 | `docs/known-pitfalls.md:193-212` | §六「现状」表把 P01/P02/P03/P04/P10/P15/P16 都标「踩了」，这些已在 0.1.7 修复（`docs/fixes-0.1.7.md`） | 表头加「截至 0.1.7 修复前」；或逐行加「0.1.7 已修」 |
| L3 | `docs/known-pitfalls.md:216-227` | §七「如果只能先修三件事」三件均已完成 | 加一句「已被 0.1.7 采纳，保留作方法论」 |
| L4 | `docs/audit.md:2-4` | 审计对象写「共 1849 行」，行号引用均为当时快照 | 顶部加「历史审计快照，行号会漂；修复结果见 fixes-0.1.7.md」 |
| L5 | `使用说明.txt:175` | 0.1.7 变更日志「(过滤器/协议模式同理)」 | 历史段落可保留；若怕混读，改成「(放行白名单/协议模式同理)」 |
| L6 | `使用说明.txt:233` | 0.1.2 变更日志「过滤器默认为『全不勾』(直通)」 | 是历史记录；建议加「(0.1.13 已改为白名单，见上)」避免误读 |
| L7 | `使用说明.txt:246` | 0.1.5「恢复默认(过滤器全关、MMC→CC 开)」 | 同上，加「当前默认已改为白名单前四项放行」 |
| L8 | `使用说明.txt:118` | 只写「用 USB 直连琴(不用转接头)」 | 补「未检测到琴时该项显示『(未检测到琴)』且不可点」 |
| L9 | `使用说明.txt:17` | 首次启动「选【输入源】= 键盘进 Mac 的口」 | 补「没有转接头就选第一项『用 USB 直连琴』」 |
| L10 | `release/v0.1.13/README.txt:42,127`、`release/使用说明-v0.1.13.txt:42,127` | 发布包里的说明是 `使用说明.txt` 的旧副本，H1/H2 同样存在 | 修完 `使用说明.txt` 后重新打包，否则 0.1.13 安装包里仍是错说明 |

---

## 四、代码注释与文档口径不一致（供 Lead 决定是否动 src，本报告不改）

| # | 位置 | 现状 | 建议 |
|---|---|---|---|
| C1 | `src/MIDIMapper.m:6` | 「过滤默认:全部关闭(原样直通)。需要丢弃故障消息时在菜单里勾选」 | 与 `:18-25` 白名单默认矛盾；改成「白名单默认放行前四项，时钟/心跳默认丢」 |
| C2 | `src/MIDIMapper.h:6` | 「过滤器(CC1/CC7/时钟/ActiveSensing)可开关」 | 与 `:13-20` 白名单说明并存，删旧句 |
| C3 | `src/MIDIMapper.h:40-42` | 「Mackie Control 输出…返回 @[按下(vel 0x7F), 松开(vel 0x00)]」 | 现在 FF/REW/RTZ 返回单条 Jog CC，注释会误导 |
| C4 | `src/main.m:49` | `--reset-config` 注释「过滤器全关、MMC→CC 翻译开」 | 重置后实际是白名单默认（`MIDIMapper.m:18-30`）；改注释与 `:53-55` 的打印项（可顺带打印 allow*） |

---

## 五、版本号一致性矩阵（任务第 5 项）

| 位置 | 当前值 | 判定 |
|---|---|---|
| `build.sh:75`（CFBundleShortVersionString） | `0.1.13` | ✅ |
| `build.sh:85`（NSHumanReadableCopyright） | `cme-uf8-router 0.1.13` | ✅ |
| `make-dmg.sh:9`（VERSION） | `0.1.13` | ✅ |
| `make-dmg.sh:3`（头注释） | `v0.1.0` | ❌ 见 M3 |
| `使用说明.txt:4` | `0.1.13` | ✅ |
| `README.md` | 无版本行 | ❌ 见 M1 |
| `交接单.md:117` | `0.1.12` | ❌ 见 H12 |
| `build/…/Info.plist`（实测） | `0.1.13` | ✅ |
| `release/v0.1.13/…/Info.plist`（实测） | `0.1.13` | ✅ |
| `../复刻实现与排错.md:3` | `v0.1.7` | ❌ 见 M4 |

---

## 六、文档引用路径存在性核验（任务第 6 项）

| 引用路径 | 出处 | 结果 |
|---|---|---|
| `/Volumes/Toshiba/Deepseek/CME_UF8/复刻规格书.md`（§3） | `使用说明.txt:56` | ✅ 存在，§3「功能映射表」存在 |
| `resources/cme-wordmark.png` | `使用说明.txt:163` | ✅ |
| `tools/makeicons.m` | `使用说明.txt:167`、`README.md:61` | ✅ |
| `resources/menubar.png`、`resources/AppIcon.icns` | `README.md:60` | ✅ |
| `docs/fixes-0.1.7.md` / `docs/audit.md` / `docs/known-pitfalls.md` | `README.md:79` | ✅ 三份都在 |
| `docs/preview/` | `交接单.md:117` | ✅ 目录存在（app-icon-512.png 等） |
| `CME_UF8/复刻实现与排错.md` | `交接单.md:117` | ✅ |
| `CME_UF8/cme-uf8-router/使用说明.txt` | `交接单.md:117` | ✅ |
| `tools/mcuinject` | `交接单.md:157` | ✅（含二进制+m） |
| `tools/midilist`、`tools/mculisten` | `../复刻实现与排错.md:123-124` | ✅ 二进制存在 |
| `tools/mmctest` | `../复刻实现与排错.md:125` | ❌ 只有 `mmctest.m`，无二进制（M10） |
| `release/cme-uf8-router-v0.1.6/` | `../复刻实现与排错.md:140` | ❌ 不存在（现有 v0.1.12、v0.1.13） |
| `release/cme-uf8-router-v0.1.13.dmg` | 由 `使用说明` 安装节与 `交接单.md:117`「三件套」隐含 | ❌ 不存在（只有 v0.1.12.dmg） |
| `使用说明模板.txt` | `make-dmg.sh:20` | ❌ 不存在（M11） |
| `~/Library/Application Support/cme-uf8-router/midi-map.plist` | `使用说明.txt:57` | ✅ 运行时路径，`src/MIDIMapper.m:217-230` 生成 |
| `~/Library/Application Support/cme-uf8-router/raw-capture.log` | `使用说明.txt:197`、`../复刻实现与排错.md:127` | ✅ 运行时路径（`src/RouterCore.m:358+`） |

---

## 七、USB 直连一节逐条对照（任务第 3 项）

| 文档说法 | 代码核验 | 结论 |
|---|---|---|
| 不需要转接头、直接读 0x82 端点 | `src/USBReader.m:9-13,75`；`src/AppDelegate.m:195-207` | ✅ 一致 |
| 琴的 USB 口报假 CDC，macOS 不挂 MIDI 驱动 | `../复刻实现与排错.md:29-32`；`src/RouterCore.m:268-269` | ✅ 一致 |
| 走带行为与 5-pin 完全一样、Jog 方案照旧 | `src/RouterCore.m:632-643` 用 `CMEMIDIProtocolModeCME` 解码后走同一 `dispatchMessage`；`src/MIDIMapper.m:129-142` | ✅ 一致 |
| 时钟 77 条/秒、心跳 4 条/秒 | `src/MIDIMapper.m:18-19`、`src/AppDelegate.m:315` | ✅ 数字一致；但默认已被白名单丢弃（H2） |
| 被 Chrome WebUSB 抢占、报「打开 USB 接口失败」 | `src/USBReader.m:68-71`；`src/RouterCore.m:658-659` | ⚠️ 现象对，展示位置与重试办法错（H5） |
| 选完生效、配置记住、下次启动仍是 USB | `src/RouterCore.m:280-290,672-681`；`src/MIDIMapper.m:269,297` | ✅ 一致 |
| 协议模式在 USB 下置灰 | `src/AppDelegate.m:268-288` | ❌ 文档未写（H6） |

---

## 八、给 Lead 的修改顺序建议

1. 先改 H1/H2/H5（同一段用户会照着操作，错得最危险）。
2. 再改 H3/H4/H9/H10/H11（0.1.12 的 Jog 结论没有同步到使用说明和 README）。
3. 然后 H6/H7/M13（USB 置灰、白名单/preset 说明、preset 名称与实现对齐）。
4. 版本/路径类 H12/M1–M4/M8–M11 一起收（改完 `使用说明.txt` 再重新打 0.1.13.dmg）。
5. 历史文档 L1–L4 只加横幅，不改历史结论。
6. C1–C4 是源码注释，按「本轮只写 docs」的约束未动，需 Lead 决定是否另派。
