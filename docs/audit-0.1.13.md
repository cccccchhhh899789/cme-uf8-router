# 0.1.13 代码审计（USB 直读 + 白名单 + 输入方式切换）

- 审计对象：`src/USBReader.h/.m`（新增）、`src/RouterCore.h/.m`、`src/MIDIMapper.h/.m`、
  `src/AppDelegate.m`、`src/main.m`、`src/CMEMIDIProtocol.m`（被 USB 路径复用）、`build.sh`
- 方式：**只读**。通读上述文件 + `git diff HEAD -- src/`（HEAD=`0666883` 0.1.11，未提交改动为本轮 0.1.13）。
  **未运行 App、未跑任何自检、未碰 MIDI/IOKit 设备**（Lead 在并行实测）。
- 基线：2026-11-24 06:04（工作区在审计期间仍被并行修改过一次，行号按当时文件；
  `RouterCore.m` sha1 `4a046d55…`、`MIDIMapper.m` `97e96f05…`、`AppDelegate.m` `0292fbe3…`、
  `USBReader.m` `995d3be9…`、`main.m` `d6ccfb25…`、`CMEMIDIProtocol.m` `b2657736…`）。
- 严重级别沿用 `docs/audit.md`：
  致命 = 必崩 / 核心功能整体失效；高 = 常见场景功能错误或资源失控；中 = 特定场景错误、可绕过；
  低 = 健壮性 / 洁癖 / 以后会踩。
- 纯代码审计；文档一致性问题见 `docs/docs-check-0.1.13.md`，本文不重复。

**结论：未发现致命级。高 2 条、中 6 条、低 6 条。**

---

## 一、高

### H1 切到 USB 后 CoreMIDI 源仍会被重新连上 → 同一台琴双份输入

**位置**
- `src/RouterCore.m:226`（`refreshDevices` 末尾**无条件** `[self reconnectInputForSelected]`）
- `src/RouterCore.m:204-207`（只有一个源时自动选中）
- `src/RouterCore.m:288-291`（启动恢复 USB 时只置 `_usbInput = YES` + `startUSBInput`，不 `disconnectAllSources`）
- `src/RouterCore.m:701-704`（`reconnectInputForSelected` 完全不看 `_usbInput`）

**触发**
1. **启动**：上次用过 USB（`useUSB=YES` 已存盘）→ `start` 先在 `:284` 调 `refreshDevices`：
   此时 `_usbInput` 还是 NO、CoreMIDI 里只有 U2MIDI Pro 一个源 → `:204-207` 自动选中、`:226` 连上；
   然后 `:288-291` 才开 USB，**没有断开刚连上的 CoreMIDI 源**。
2. **运行中**：USB 模式下任何 `kMIDIMsgSetupChanged`（插拔任意 MIDI 设备、Logic 打开/新建虚拟端口、
   App 自己建/撤 MCU 端口）→ `midiNotifyProc` 投递 `refreshDevices`（`:333-349`）→ `:226` 又把
   U2MIDI Pro 连回来。`setUsbInput:` 里的 `disconnectAllSources`（`:683`）只保证切换那一瞬间干净。

**后果**
- 5-pin 与 USB 是同一份数据（`../复刻实现与排错.md:32-35`），两条路径都进 `dispatchMessage`：
  音符/CC 全部双份；非 MCU 模式下走带 CC 双份；MCU 模式下配对键会被 `mcuEventShouldEmitKey`
  的 0.4s 去重掩盖，但 **Jog（非成对）仍双份**（`:494-496`）。
- 两条路径并发访问同一份无锁状态：`_sysexBuf`（`RouterCore.m:414-454`）与 `_mapper` 的
  `_lastSPP`（`MIDIMapper.m:93-104`）→ 数据竞争（NSMutableData 边拼边改），可能串包或崩。
- 日志会显示「输入源: U2MIDI Pro」，但菜单勾的是 USB，排障时更迷惑。

**修法**
1. `reconnectInputForSelected` 开头加 `if (_usbInput) return;`（`:702`）；
2. `start` 里把 `_usbInput = _mapper.useUSB` 提到 `refreshDevices` **之前**，或 USB 分支先
   `disconnectAllSources`（`_usbInput` 置位后），顺序：断源 → 开 USB；
3. 可选：USB 模式下不做「唯一源自动选中」与「输入源: …」日志，避免状态自相矛盾。

---

### H2 拔插后 USB 输入无法恢复，且菜单再点也没有反应

**位置**
- `src/USBReader.m:54-83`（只 `openDevice` 一次；`_iface` 已存在就直接 YES；无 close/重枚举）
- `src/USBReader.m:101-127`（失败只 `usleep` 重试**同一个**已失效 pipe，无 `interestHandler`、
  无 termination 通知、无重新 `copyServiceForCME`）
- `src/RouterCore.m:648-658`（`startUSBInput` 不判断 reader 是否真的在跑）
- `src/RouterCore.m:677-678`（`if (_usbInput == on) return;` → 已经勾着时再点 USB 被直接吞掉）
- `src/AppDelegate.m:206`（`usb.enabled = present || usbOn` → 拔掉后 `present=NO` 但 `usbOn=YES`，仍可点）

**触发**：USB 线拔掉再插、琴断电再开、接口接触不良（任何 read 失败）。

**后果**
- 旧 pipe/iface 永远失效，`readLoop` 每秒一次 `errorHandler` → 「USB 读取中断」日志刷屏；
- `_usbInput` 保持 YES、菜单项保持勾选，再点同一项被早退吞掉 → **无法从菜单恢复**；
  用户必须「先选任意 MIDI 端口，再选回 USB」或重启 App（这条已写进 docs-check H5 的文档修法，
  代码侧根因在这里）；
- 期间没有任何输入，用户以为琴/App 坏了。

**修法**
- `errorHandler` 计数：连续 N 次失败后回主线程做 `stop` → `close`（`closeWithOptions:`）→ 重新
  `copyServiceForCME`/`openDevice`/`start`，成功后重置计数；或改用 IOUSBHost 的 interest/termination 通知；
- 把 `setUsbInput:` 早退改成 `if (_usbInput == on && _usb && _usb.isRunning) return;`，
  让「勾着但没在跑」时允许重试（配套把失败原因显示到菜单项标题/tooltip）；
- 重试失败时只记一次日志，不要每秒刷。

---

## 二、中

### M1 启动路径不校验 USB 打开失败、不回滚（与菜单路径不一致）

**位置**：`src/RouterCore.m:288-291`（`[self startUSBInput];` 忽略返回值）；
对比 `src/RouterCore.m:684-692`（菜单路径已做失败回滚）。

**触发**：`useUSB=YES` 已存盘，但启动时琴没插/没开机/被 WebUSB 占着。

**后果**：`_usbInput` 仍是 YES、`useUSB` 仍是 YES，状态行显示「USB直连」，实际没有 USB 输入；
如果 `refreshDevices` 已连上 CoreMIDI 源则仍能收到（掩盖问题），否则完全没输入；每次启动重复失败。
菜单路径会回滚，启动路径不会，两种入口行为不一致，以后很难查。

**修法**：启动分支复用同样的回滚（`_usbInput=NO; _mapper.useUSB=NO; saveConfig; reconnect`，
并把 `_lastUSBError` 带到状态行/菜单）。若希望「失败也记住 USB 选择」，则至少让状态行显示
「USB直连(打开失败)」而不是装作正常。

---

### M2 stop 不等 USB 读线程退出、不关闭接口，与端口 dispose 竞争

**位置**
- `src/USBReader.m:97-99`（`stop` 只 `_running = NO`，不 abort、不 join、不清 `_thread`）
- `src/RouterCore.m:671-675`（`stopUSBInput` 立即 `_usb = nil`）
- `src/RouterCore.m:318-324`（随后 dispose `_inputPort/_outputPort/_mcuSource/…`）
- `src/RouterCore.m:603-606`（`sendToMCUSource:` 不检查 `_stopping`）
- `src/RouterCore.m:506-509`（80ms 延迟块也直接访问 `_mcuSource`）

**触发**：退出 App、或 USB→MIDI 端口切换的瞬间，琴正好有包（琴空闲也持续发 F8/FE，概率不低）。

**后果**
- 在途 `sendIORequestWithData:` 最长再阻塞 1s；主线程不等它就开始 dispose。读线程若已越过
  `handleUSBPacket` 的 `:635` 检查，会对着已 dispose 的 endpoint/port 调 `CMESendToEndpoint/Port`
  → UAF 崩溃（退出时崩通常被 `exit(0)` 掩盖，但模式切换时是真崩）；
- `_usb = nil` 后 reader 被读线程 retain，接口要等线程退出才释放。**快速 USB→MIDI→USB**
  时旧接口可能还开着，新的 `openDevice` 若因独占打不开，会误报「另一个程序(Chrome)占着」——
  实际占着的是自己（接口是否互斥打开取决于 IOUSBHost，此条需真机验证，但 1s 窗口确实存在）。

**修法**：`stop` 里先 `[_pipeIn abortWithOption:IOUSBHostAbortOptionSynchronous error:&e]`
（或 `abortWithError:`）让在途请求立刻返回，再等 `readLoop` 退出（信号量/`NSThread` join）后
才释放接口；Reader 增加显式 `close`（`closeWithOptions:`）并在 `stopUSBInput` 调用；
`sendToMCUSource:` 增加 `_stopping` 判断；或把「发送 + dispose」都放到同一条串行队列。

---

### M3 CME 模式不支持跨包续帧（只续 sysex），短包会丢字节/错位

**位置**
- `src/CMEMIDIProtocol.m:50`（`while (remaining >= 4)`：尾部 1-3 字节直接丢弃）
- `src/CMEMIDIProtocol.m:47-89`（解析器本身无跨调用状态；sysex 之外的 `sourceLen` 固定 4）
- `src/RouterCore.m:445-449`（`decodePacket` 只把「首字节 F0 且末字节非 F7」的残包回存）
- `src/RouterCore.m:641-643`（USB 路径固定 `mode:CMEMIDIProtocolModeCME`）
- `src/RouterCore.m:631-633`（注释称 USB 的 MMC 会被拆成两个 4 字节记录）

**触发**：USB 短包长度不是 4 的整数倍（`USBReader.h:18` 自己写明「也可能是短包」），
或 64 字节传输边界切断一条记录。Linux 的 `snd_usbmidi_cme_input` 是逐字节状态机，
天生支持跨 URB；本实现是「整包批量解析」，没有等价能力。

**后果**
- 切断处 1-3 字节被静默丢弃，下一包从数据字节开始被当成 CIN 解析
  （`parseStandardPackets` 不做状态字校验，`CMEMIDIProtocol.m:29-44`）→ 向 DAW 发垃圾短消息；
- 若切断的是 0x0F sysex：首包回存 `F0…`，续包把裸 `F0` 拼到新包前再交给 `parseCMEPackets`，
  `head=0xF0` 不满足 `(head&0x0F)==0x0F` → 走 `parseStandardPackets` 且 `cin=0`（长度 0）
  → **整条 sysex 丢失**。USB 上丢的是走带 MMC/SPP。
- 另外 `:631-633` 的注释与事实不符：被拆成两个 4 字节记录的是 **U2MIDI Pro/5-pin 路径**
  （`../复刻实现与排错.md:37`），USB 的 CME sysex 是「整条一包」（`../复刻规格书.md:30`）。
  注释会让后人误以为 USB 也需要 sysex 跨包拼接，掩盖真正缺的是「普通/未消费字节」的续接。

**修法**：在 `decodePacket` 层保存「本包未被消费的尾部字节」（不只是 sysex），下一包前置再解析；
或把 `parseCMEPackets` 改成返回 consumed 偏移的流式接口；CME 分支增加「裸 F0 开头的续包按 sysex
拼接」；同时修正 `:631-633` 注释。若实测确认设备永远按 4 字节/记录边界发包，也建议在 Reader 里
断言并记录（`transferred % 4 != 0` 时告警），别静默丢。

---

### M4 白名单与走带/翻译的语义漏洞（三个方向不一致）

**位置**
- `src/RouterCore.m:490-515`：`useMackie=YES` 时 transport 在 RouterCore 就被拦走直发 MCU，
  `MIDIMapper` 白名单完全不参与；
- `src/MIDIMapper.m:177-191`：`translateMMC=YES`（默认）时 MMC/SPP 翻成 CC114-119，
  只受 `_allowCC` 管（:182），`_allowSysEx=NO` 拦不住；只有 `translateMMC=NO` 时才在 :180 受 `allowSysEx` 管；
- `src/MIDIMapper.m:106-110,181`：`allowClock=NO` 不拦 FA/FB/FC，它们被翻成 CC119/118；
- `src/AppDelegate.m:305,314,315`：菜单写「白名单:没勾的东西一律进不了 DAW」「系统专用(sysex / MMC / SPP)」。

**触发/后果**（都是用户按菜单文案操作后的真实结果）
1. `allowNotes=NO`（想彻底静音音符）+ MCU transport 开 → 走带仍发 Note On/Off 到 MCU 口；
   `allowCC=NO` → Jog 仍发 `B0 3C xx`。菜单承诺与行为不符。
2. 取消勾选「系统专用」→ 走带 MMC 仍以 CC114-119 进 DAW（在 `allowCC=YES` 时）。反过来，
   取消勾选「控制器 CC」→ 走带键突然全没了（translate 路径被 :182 丢掉），用户预期只是推子/踏板。
3. 取消勾选「时钟」→ FA/FB/FC 仍以 CC 形式出去（若 allowCC 开着）。

**修法**（需 Lead 先定语义，再改代码/文案二选一）
- 建议语义：白名单按「**源事件类别**」判——MMC/SPP 先看 `allowSysEx`，FA/FB/FC 先看 `allowClock`，
  通过后再决定翻译成 CC（此时 `allowCC` 是否二次门控要写清）；
- MCU 路径单独定义：要么在 `dispatchMessage` 里按 `allowNotes`（Note 对）判定，要么在菜单明确
  「走带键不受乐器白名单影响，独立开关是 transport 键」；
- 至少把 :305 的「一律」改成准确描述。

---

### M5 老 `filterCC1/CC7/Clock/Sensing` 成了无 UI 的隐藏过滤器

**位置**
- `src/MIDIMapper.m:266-269`（`loadConfig` 仍读入四个旧键）
- `src/MIDIMapper.m:170-172,200-201`（仍参与丢弃）
- `src/AppDelegate.m:363-381`（`toggleFilter:` 里四个 `filter*` 分支已无菜单项能触发，成死代码）

**触发**：0.1.12 用户曾勾过「过滤 时钟/ActiveSensing/CC#1/CC#7」，升级后 plist 保留
`filterClock=YES` 等；新菜单已没有这四项。

**后果**：菜单显示「时钟」= 勾选（放行），实际 `_filterClock` 仍把时钟丢掉；「放行 CC」勾着，
CC#1/#7 仍被丢。UI 上无法关掉这些旧过滤器，只能删 plist。白名单承诺被旧状态污染，
且非常难查（没有任何日志）。

**修法**：迁移时把 `filter*` 归并进新语义（`filterClock`→`allowClock=NO` 后清零；
`filterSensing`→`allowSensing=NO`；`filterCC1/7` 无对应项，可忽略并写日志），
或干脆删除旧键读取；`toggleFilter:` 里的旧分支一并删掉，避免以后误以为可用。

---

### M6 `runActionSelfTest` 第 3 步点到了 USB 首项：测试失效 + 改用户配置 + 占 USB 口

**位置**：`src/AppDelegate.m:527-536`（`firstObject`）；行为链 `selectUSBInput:`（`:234-239`）→
`setUsbInput:YES`（`RouterCore.m:677-692`）。

**触发**：跑 `--action-selftest`（`main.m:78-82`，此模式会先抢单实例锁，但仍会读用户真实 plist、
写 `useUSB=YES`）。

**后果**
- 第 3 步本意「点第一项输入源」，现在第一项是「用 USB 直连琴」：调用的是 `selectUSBInput:`，
  `selectedSourceName` 不会变成 `sourceNames.firstObject` → 断言 FAIL；即使恰好 PASS 也没测到选源；
- 副作用：打开 USB 接口（与真机/运行中 App 抢 IOUSBHost）、把 `useUSB=YES` 写进用户的
  `midi-map.plist`，自检跑完用户的输入方式被改了；若琴未插，还会走失败回滚路径，测试结果失真。

**修法**：按 `representedObject == nil` 或标题前缀跳过 USB 项，或直接 `d.core.selectedSourceName = …`；
自检结束恢复 `useUSB` 原值；USB 分支另写一个「预期打开失败也不算 FAIL」的独立用例。

---

## 三、低

### L1 0 长度包无退避；复用同一块 `NSMutableData`

**位置**：`src/USBReader.m:102,120`。设备按规格「空闲不停发 0 长度包」
（`../复刻规格书.md:35`），`transferred == 0` 时 `continue` 立即重新提交，没有 `usleep`。
若 ZLP 速率高，QoS 为 UserInteractive 的读线程会以 USB 往返速度空转（CPU 占用需真机确认）。
另：`buf` 只分配一次，`sendIORequestWithData:` 头文件只承诺 `bytesTransferred` 是输出，
未承诺不改 `data.length`；若某版 SDK 回写为实际字节数，短包后请求长度会越来越小，ZLP 后变 0
并永久空转（这是「万一」的防御点，无法从当前头文件确认）。

**修法**：每轮 `[buf setLength:CME_READ_LEN]`（或每次新建）；`transferred == 0` 时 `usleep(1000)`；
连续 0 包计数并定期告警；实测空闲 CPU，若确实满核则升级为高。

### L2 `USBMIDIReader.isRunning` 永远是 NO

**位置**：`src/USBReader.h:32`、`src/USBReader.m:19,87-95`。显式 ivar 叫 `_running`，
属性会自动合成 `_isRunning`，两者不共享存储 → `RouterCore.m:658` 的守卫永远放行。
目前靠 `USBMIDIReader.start` 内的 `if (_running) return;` 兜住，逻辑侥幸正确，但公开 API 撒谎。
**修法**：实现 `- (BOOL)isRunning { return _running; }`（或把 ivar 改名 `_isRunning`）。

### L3 `messageAllowed:` 的归类与不可达分支

**位置**：`src/MIDIMapper.m:51-59`。
- `st >= 0xF8` 先命中，`:52` 的 `if (st == 0xFE) return _allowSensing;` **不可达**
  （单字节 FE 现被 `processMessage:168-170` 提前拦下，所以暂无实际错，但语义不完整）；
- `0xC0` Program Change、`0xD0/0xA0` Aftertouch、`0xF1/F3/F4/F5/F6/F7` 全落到 `allowCC`。
  菜单文案是「控制器 CC(推子/旋钮/踏板)」，取消它却会连带丢 Program Change/触后；
  `0xF4/F5/F7` 是未定义/孤立字节，当 CC 放行没有意义；
- `parseCMEPackets` 会把孤立的 `F7` 当 1 字节消息输出（`CMEMIDIProtocol.m:75-76`），最终落到 `allowCC`。
**修法**：FE 判断放到 `>=0xF8` 前；给 PC/Aftertouch 单独归类或改文案；未定义系统字节直接丢。

### L4 `runUSBSelfTest` 统计竞争 + `--usb-selftest` 不抢单实例锁

**位置**：`src/RouterCore.m` 的 `runUSBSelfTest`（`stop` 后无锁 printf `__block` 统计量；
`stop` 不等线程，≤1s 内仍可能在 block 里写 `sample`/计数）；`src/main.m:29-37,83-88`
（`--usb-selftest` 不在 `needsMIDIPorts` 里，不取锁）。`sleep(3)` 还阻塞主线程。
**后果**：读数偏小/字符串边读边改（理论上可崩）；与运行中的 App 抢同一接口时只报「打开失败」，
容易被误判为设备坏，而不是「先退 App」。
**修法**：`stop` 后等线程真正退出（信号量）或读统计时用同一把锁；`--usb-selftest` 检测
`/tmp/cme-uf8-router.lock` 并提示「先退出 App」；用信号量替代 `sleep`。

### L5 状态行与 `lastUSBError` 未进 UI

**位置**：`src/AppDelegate.m:176-182`（USB 模式仍按 `protocolMode` 显示「自动」，
而菜单写「USB 直连:固定按 CME 帧解码」）；`src/RouterCore.h:34` 注释说 `lastUSBError` 是
「菜单/日志用」，实际只在日志（`RouterCore.m:661-662`），菜单/状态行没有反馈。
**修法**：USB 模式下状态行显示 `[CME 固定]`；USB 菜单项在 `lastUSBError` 非空时加
「(上次失败: …)」或 tooltip。

### L6 `--reset-config` 输出仍是旧键名

**位置**：`src/main.m:56-58`。只打印 `filterCC1/CC7/Clock/Sensing`，看不到 `allow*` 与 `useUSB`
（重置后六项 allow 全 YES、useUSB=NO），与菜单新语义脱节。
**修法**：改打六个 `allow*` + `useUSB`（顺带 `translateMMC`）。

---

## 四、已核对并确认没有问题的点

- `build.sh:15-24` 已把 `src/USBReader.m` 加入 SRCS、`IOUSBHost` 加入 FRAMEWORKS；两个 arch 都会链；
  `LSMinimumSystemVersion=11.0` 覆盖 IOUSBHost（10.15+）。
- CoreMIDI 回调纪律：`midiNotifyProc` 只 `dispatch_async` 主线程（`RouterCore.m:333-349`），
  `midiReadProc` 只读 `_stopping` 后转发（`:351-356`），没有在通知回调里改 MIDI 图。
- sysex 残包的历史教训没有回归：1.0s stale 清理与 65536 字节硬上限仍在（`RouterCore.m:430,452`）；
  但只对「首字节 F0」的残包生效（普通/CME 帧的续接见 M3）。
- MCU 按下/松开成对 + 80ms 延迟松开仍在（`RouterCore.m:497-513`），延迟队列是独立串行队列
  `_mcuQueue`，不会被主线程菜单阻塞；Jog 单条无配对，符合 0.1.12 的结论。
- `decodePacket:length:` 保留原签名、内部委托 `mode:` 版本（`RouterCore.m:409-411`），
  DIN 路径行为未变；USB 路径显式 `CME`，不依赖 Auto 猜测。
- `disconnectAllSources` 先断后连、避免重复 `MIDIPortConnectSource`（`:701-719`），逻辑本身正确，
  缺的只是 USB 守卫（H1）。
- 配置迁移：老 plist 无 `allow*` 时保留 init 默认（当前六项全 YES，**与 0.1.12 直通等价**，
  除 M5 的旧 filter* 外），`needsMigration` 会补写新键（`MIDIMapper.m:264,289`）；
  `if (d[key])` 对 `@NO` 也成立，读取方式正确。
- `presetAllowAll:` / `presetCleanFilter:` 只改 allow* + saveConfig + rebuild，没有额外副作用；
  `presetCleanFilter` 标题与实现（含 allowSysEx）不符已由 docs-check M13 记录，代码侧不重复。

---

## 五、建议修复顺序

1. **H1**（双份输入）：一行守卫 + 启动顺序，风险最高、改动最小。
2. **H2 / M2**（USB 生命周期）：重开/拔插恢复 + stop 等线程、显式关接口，这两条一起改。
3. **M1 / M6**（启动回滚、自检点错项）：小的状态一致性问题，顺手做。
4. **M5**（隐藏过滤器）：影响升级用户，迁移逻辑改完要写测试（可只读验证 plist 解析）。
5. **M3**（跨包续帧）：改动最大，需真机抓一次 `transferred % 4 != 0` 的样本再定方案。
6. **M4**（白名单 × 走带语义）：先定语义再改代码/文案。
7. L1–L6 按闲时处理。

---

## 六、与其它文档的关系

- `docs/docs-check-0.1.13.md` 是**文档一致性**审计（35 条）。其中 H1/H2 引用的
  「默认 allowClock/allowSensing=NO、默认丢时钟与心跳」在 2026-11-24 06:01 之后已不成立：
  当前 `MIDIMapper.m:20-25` 六项默认全 YES（注释写明「= 和 0.1.12 行为一致」）。
  改文档前请以当前代码为准，否则会把正确的默认值改错。
- `docs/audit.md` 是 0.1.7 之前的历史审计，其严重度定义沿用；A1/A2/B1-B7 已修，不在本文重复。
