# cme-uf8-router 独立代码审计（只读）

- 审计对象：`/Volumes/Toshiba/Deepseek/CME_UF8/cme-uf8-router/src/`（main.m / AppDelegate.h,m / RouterCore.h,m / MIDIMapper.h,m / CMEMIDIProtocol.h,m，共 1849 行），另读了 build.sh、README.md、使用说明.txt 作行为对照。
- 审计方式：逐行通读 + 跨文件追踪调用路径。**未改任何 src 文件、未构建 App、未运行任何可执行文件、未操作 MIDI 端口（没跑 tools/midilist、mculisten）**。
- 唯一一次编译相关动作：对 `src/RouterCore.m` 跑过 `clang -fsyntax-only`（只做语法确认，**不产生任何产物**，无 .o/无 .app），目的是核实「回调函数先用后声明是否真的编译不过」；结论是能编译（只有 1 条 nonnull 警告），所以该项不列 bug。`/tmp/auditprobe` 是独立小样，未碰项目目录。
- 严重度定义：**致命** = 必崩/核心功能整体失效；**高** = 常见场景下功能错误或资源失控；**中** = 特定场景错误、可绕过、或证据链不完整但风险明确；**低** = 洁癖/健壮性/可维护性。
- 计数：致命 2、高 7、中 13、低 10，共 32 条。

---

## 一、致命

### A1【致命】MIDI 回调线程 / 通知线程直接改共享状态，并调用 AppKit 与 MIDI API
- 位置：`src/RouterCore.m:195-206`（notify proc 里 `[core refreshDevices]`）、`src/RouterCore.m:70-74`（`removeAllObjects`）、`src/RouterCore.m:120-124`、`src/RouterCore.m:405,413`（回调线程里 `MIDIPortDisconnectSource/ConnectSource`）、`src/AppDelegate.m:171,195`（主线程 for-in 遍历同一批数组）、`src/AppDelegate.m:465-469`（作者自己加了「非主线程就转发」的补丁）。
- 现象/后果：
  1. 热插拔瞬间（或任意 `kMIDIMsgSetupChanged`），通知线程执行 `refreshDevices` 的 `removeAllObjects`/`addObject`，主线程同时 `rebuildSourceMenu` 的 `for (NSString *name in self.core.sourceNames)` → `__NSArrayM mutated while being enumerated` 抛 NSGenericException，App 直接崩；`_sourceIndex`/`_destIndex` 同样是「一边 `removeAllObjects` 一边 `objectForKey:`」，属于未定义行为，可能 EXC_BAD_ACCESS。
  2. `refreshDevices` 里调 `reconnectInputForSelected` → 在 **MIDINotification 回调内部** 调 `MIDIPortDisconnectSource`/`MIDIPortConnectSource`。CoreMIDI 规定通知回调里不要改 MIDI 图状态，这是「点菜单卡死」的同族死锁路径（MIDIServer 内部持锁回调你，你再回头调它）。
  3. `midiReadProc` 线程（`src/RouterCore.m:208-212`）里 `handleIncoming` 会读 `_destIndex`、调 `delegate`（`src/RouterCore.m:420`），`sendToMCUSource` 还会 `[self log:]`；`log` 的实现在 MIDI 线程读 `_logView`（`src/AppDelegate.m:472`），日志窗口开/关与回调竞争。
- 根因：`_midiQueue`（`src/RouterCore.m:21,42`）建了**从未使用**；没有锁、没有主线程约束；`routerDidRefreshDevices` 的 main-thread 补丁只救了「UI 更新」这一半，数组和字典的写入已经发生在通知线程上了。
- 最小修法：notify proc 里**只**置一个 `@atomic BOOL _needsRefresh` 并 `dispatch_async(dispatch_get_main_queue(), ...)`，把 `refreshDevices` 整体搬回主线程；`midiNotifyProc` 内绝不调任何 `MIDI*` API。`handleIncoming` 只做「解码 + 发送」，发送所需的目标改成不可变快照（`MIDIEndpointRef`，见 B2）或让整个 `handleIncoming` 在 `_midiQueue` 上跑、与主线程状态用 `dispatch_sync` 交换。加 `_stopping` 标志，`stop()` 先置位再 dispose，回调看到就立即返回。

### A2【致命】跨包 sysex 缓冲无上限，且「少一个 F7」会永久吞掉后续所有 MIDI
- 位置：`src/RouterCore.m:238-260`（`decodePacket`）、`src/RouterCore.m:240`（每包都把旧缓冲拼进去）、`src/RouterCore.m:251-256`（不完整就回存）、`src/RouterCore.m:27`；配合 `src/CMEMIDIProtocol.m:153-163`（`parseRawByteStream` 的 sysex 分支「读到包尾就返回，不要求 F7」）。
- 现象/后果：设备发出一条 F0 开头的 sysex 但 F7 丢失（拔线、驱动丢字节、U2MIDI Pro 拆包异常）后，`_sysexBuf` 永久非空。之后**每一包正常 Note/CC 都会被拼到 F0 后面**，`parseRawByteStream` 把它们全当 sysex 数据吃到结尾，返回 `[F0 ... 0x40]`，末字节不是 F7 → 又回存进 `_sysexBuf`。结果：**琴从此一个音符都不响**，且缓冲每包都变长、每包都要重新解析整个缓冲（O(n²) CPU + 持续涨内存），运行在实时 MIDI 线程上。用户侧的表现正是「刚才还好好的，突然不响了，重启才好」。
- 根因：没有上限、没有超时、没有「遇到新的状态字节就丢弃残包」的清理规则，且 `decodeBytes` 是「全量重解析」而不是「只解析新增字节」。
- 最小修法：(1) `_sysexBuf.length > 65536` 直接清空；(2) 新包首字节若 `>= 0x80 && != 0xF7`（非实时）且缓冲里没有 F7 → 先丢弃缓冲再拼；(3) 记录 `_sysexBufTime`，>1s 未续上就清空；(4) 拼包后只对「新增段」做一次状态机推进（把 parser 改成增量对象），避免 O(n²)。

---

## 二、高

### B1【高】`start` 半途失败会泄漏 client + 虚拟端口，且 `stop` 因 `_running==NO` 直接 return，无法自愈
- 位置：`src/RouterCore.m:139-156`（MIDIClientCreate / MIDISourceCreate / MIDIInputPortCreate / MIDIOutputPortCreate 逐个 early-return）、`src/RouterCore.m:156`（`_running = YES` 在最后）、`src/RouterCore.m:182-183`（`if (!_running) return;`）。
- 现象/后果：`MIDIInputPortCreate` 或 `MIDIOutputPortCreate` 失败（系统 MIDI 半死、端口数耗尽）时，client 和 "CME UF8 Router" 虚拟源已经建好、`_running` 仍是 NO → 函数返回；`applicationWillTerminate`（`src/AppDelegate.m:56`）调 `stop` 会被第 183 行挡回，**端口和 client 永久泄漏到进程结束**，Logic 里留下一个没人喂数据的「CME UF8 Router」。再点「刷新设备」也不会重建（`start` 也不重入），用户只能重启 App。若用户手动再触发一次 start，会再 `MIDIClientCreate` 一次并覆盖 `_client`，而 `_virtualSource` 因 `if (!_virtualSource)` 不复建 → 虚拟源挂在**已被覆盖、再也不会 dispose 的旧 client** 上。
- 根因：资源获取与状态标记没有绑定，失败路径没有统一 cleanup。
- 最小修法：把 `_running = YES` 提前到 client 创建成功之后、并把四条失败分支都改成 `[self stop]`（或抽 `- (void)teardownAll` 无条件执行，不判断 `_running`）；`stop` 改为「按句柄逐个撤」，不要用 `_running` 当门闸。

### B2【高】输入/输出目标用「枚举序号」寻址，热插拔后会把音符发到错误的设备
- 位置：`src/RouterCore.m:83,98`（`_sourceIndex/unique = @(i)`）、`src/RouterCore.m:385`（每次发送 `MIDIGetDestination(idx)`）、`src/RouterCore.m:407-411`（`MIDIGetSource(idx)`）。
- 现象/后果：`_destIndex` 存的是 `refreshDevices` 那一刻 `MIDIGetDestination(i)` 的**数组下标**。拔掉/插入任意 MIDI 设备后，系统枚举顺序变化，而下标要到下一次 `refreshDevices` 才更新。中间这段时间（热插拔通知到达前、或通知被 A1 的竞态吃掉时）按「输出目标 = 第 3 个」发 Note，会落到**另一台合成器**上；拔掉设备后 `MIDIGetDestination(idx)` 返回 0，则**静默丢弃**（`src/RouterCore.m:386`）。输入侧同理，重连可能接到别的源上。此外显示名里带设备名（`src/RouterCore.m:64-66`）+ 同名加 ` (2)`（`src/RouterCore.m:128-134`），跨重启时后缀可能换人，`lastSource` 恢复就指错设备。
- 根因：把「显示名 → 序号」当稳定标识；CoreMIDI 里稳定标识是 `MIDIEndpointRef` + `kMIDIPropertyUniqueID`。
- 最小修法：字典值改存 `@(MIDIEndpointGetUniqueID(ep))`，发送/连接时用 `MIDIGetSource/Destination` 全量扫一遍按 uniqueID 找，或直接缓存 `MIDIEndpointRef` 并在 `refreshDevices` 时重解析（缓存 Ref 拔插后失效，需校验 `MIDIObjectGetIntegerProperty` 仍然存在）。

### B3【高】恢复 `lastSource/lastDest` 之后没有通知界面 → 输入/输出勾选态与实际不符（上次事故的残留半修）
- 位置：`src/RouterCore.m:157`（`refreshDevices` 先跑，已 `[self.delegate routerDidRefreshDevices:self]`）、`src/RouterCore.m:160-168`（之后直接写 `_selectedSourceName/_selectedDestName` ivar，**没有再通知**）、`src/AppDelegate.m:45-49`（start 之后只重建了协议/过滤器/transport 三张子菜单，**没重建输入源/输出目标**）。
- 现象/后果：重启 App 后，`refreshDevices` 先把「输出目标」自动设成虚拟口并刷新菜单（勾在虚拟口），随后第 165-168 行把 `_selectedDestName` 改成上次记住的硬件口，但菜单不再刷新 → **菜单里勾着 A，实际发往 B**。输入源同理：多设备时 `refreshDevices` 阶段无选中（全不勾），第 161 行恢复后仍全不勾，用户以为没接上。只有当 `_mapper.useMackie` 为真时，第 169 行的 `setUseMackieTransport:` 会顺带再 `refreshDevices`（`src/RouterCore.m:339`）而「碰巧」修好——默认（MCU 关）路径必现。
- 根因：状态恢复写在「已经广播过刷新」之后，且 UI 侧补刷只覆盖了三张菜单。
- 最小修法：把恢复逻辑挪到 `start` 的第一次 `refreshDevices` **之前**（先读 `_mapper.lastSource/lastDest` 塞进去），或在 `start` 末尾补一次 `[self.delegate routerDidRefreshDevices:self]`；`AppDelegate` 侧在 `applicationDidFinishLaunching` 里补 `rebuildSourceMenu`/`rebuildDestMenu`（更稳的是让 delegate 回调统一重建五张菜单）。顺手加日志：恢复失败（名字不在了）要打印，别静默。

### B4【高】`captureRaw` 在 MIDI 实时回调线程里同步写盘，且日志无上限、无开关
- 位置：`src/RouterCore.m:266`（每个 CoreMIDI 包**无条件**调）、`src/RouterCore.m:215-235`（每次都 `NSDateFormatter` 分配 + `NSString` 拼 hex + `writeData:` 同步落盘）、`src/RouterCore.m:217-227`（static 句柄，永不关闭、无轮转）。
- 现象/后果：演奏时每一包（含 F8 时钟、弯音、触后）都在 CoreMIDI 的高优先级线程上做一次磁盘 I/O 和多次对象分配 —— 这是典型会造成 MIDI 抖动/掉音的写法；`raw-capture.log` 无上限增长（长时间挂机可到 GB），且**把用户弹的全部音符持久化**（隐私）。`@try/@catch`（`src/RouterCore.m:234`）会把写失败静默吞掉，磁盘满后每包都抛一次异常。
- 根因：调试抓包代码直接留在热路径上，且没有开关/大小上限。
- 最小修法：默认关闭，改成菜单项「原始报文抓包」+ 内存环形缓冲，或至少 `dispatch_async` 到串行后台队列写、单文件 8MB 轮转、去掉 `NSDateFormatter`（用 `gettimeofday` 拼数字）。

### B5【高】标准流解码的 running status 分支有移位错误：丢音符 / 音高错乱
- 位置：`src/CMEMIDIProtocol.m:128-145`（`b` 已 `buf[i++]` 取出，分支里却用 `buf[i]`、`buf[i+1]` 组消息）。
- 现象/后果：输入 `90 3C 40 44 50`（第二个音用 running status）→ 第一个音正确；读到 `0x44` 时 `i` 已指向 `0x50`，`i+1 < len` 为假 → **第二个音直接丢**。输入 `90 3C 40 44 50 45 60` → 会输出 `90 50 45`（音高 0x50、力度 0x45，全错）再吞掉 `60`。标准流（DIN/串联）设备几乎一定用 running status，这是「一排音里漏音、音不对」的确定性来源。默认 Auto 模式在非 CME 数据上也走这条路径（`src/CMEMIDIProtocol.m:116`）。
- 根因：当前字节 `b` 就是 running-status 消息的第一个数据字节，但代码把它当已消费、去读后面的字节；另外 `i + 1 < len` 少算了当前字节。
- 最小修法：
  ```objc
  // b 是首数据字节，还需 1 个（2 字节消息）或 2 个（3 字节消息）
  if (runningStatus >= 0xC0 && runningStatus <= 0xDF) {
      // 2 字节消息只需要 b 一个数据字节
      out << {runningStatus, b};
  } else {
      if (i < len) { out << {runningStatus, b, buf[i]}; i++; }
  }
  ```
  并把 running status 状态提升到跨包（成员变量/解析器实例），否则被 CoreMIDI 拆包的 running-status 消息仍会丢。

### B6【高】没有任何单实例防护：双开即「每个音符发两遍」+ 配置文件互相覆盖
- 位置：`src/main.m:55-68`（直接 `[app run]`，无检查）、`src/AppDelegate.m:41-50`（无 `NSRunningApplication`/lockfile 检查）、`src/RouterCore.m:143,290`（同名虚拟端口照建不误）、`src/MIDIMapper.m:204-219`（整个字典 `writeToFile:atomically:` 覆盖写）。
- 现象/后果：双击两次 App（或开机项 + 手动启动）→ CoreMIDI 允许两个同名虚拟源，DAW 里看到两个 "CME UF8 Router"；两个实例都连同一台琴 → **每个键发两次**（重复音符/双触发 transport）；两个实例各建一对 "CME UF8 Router MCU" → Logic 里两个控制表面抢同一份按键；两个实例的 `saveConfig` 都是「读旧值改一项再整文件写」，A 改过滤器、B 改 lastSource，**后写的把先写的覆盖掉**（用户表现为「设置老是自己变回去」）。`--reset-config` 与运行中的实例也会互相踩。
- 根因：无进程级互斥；配置写入无合并/无文件锁。
- 最小修法：`applicationDidFinishLaunching` 最前面判 `[[NSRunningApplication runningApplicationsWithBundleIdentifier:@"local.cmeuf8.router"] count] > 1`（排除自己）就 `NSApp terminate:`；同时 `open(~/Library/Application Support/cme-uf8-router/.lock, O_CREAT|O_EXCL)` 兜底（`--selftest` 系列不进这条路）。配置写用 `NSFileCoordinator` 或至少写前重读合并。

### B7【高】MCU 250ms 去重语义错误：快速二击被吞 / 长按每 250ms 又触发一次
- 位置：`src/RouterCore.m:353-361`（`if (vel != 0 && note == _lastMCUNote && now - _lastMCUNoteTime < 0.25) return;`）。
- 现象/后果：`mcuMessagesFor:` 对每个 transport 事件返回「按下 0x7F + 松开 0x00」两条（`src/MIDIMapper.m:112-114`），也就是每次按键 DAW 都收到完整的 press+release。于是：
  1. 250ms 内的第二次同键按下，其「按下」被丢、但「松开」照发（`src/RouterCore.m:359` 只挡 vel!=0）→ **第二次按键无效**（连按两下 FF 只前进一次，双击 PLAY 只播一次）。
  2. 按住走带键时琴会连发同一报文（代码注释 `src/RouterCore.m:352` 自己说了），去重只把频率降到 4Hz：每 250ms 又发一对 press+release → 在 Logic 里等于每 250ms 点一次 PLAY/STOP，**按住 PLAY 会播放/停止来回跳**。
- 根因：去重窗口按「时间」猜按键边沿，而 MMC 本身没有 key-up 事件；「自己补的 off」和「设备自动重复」在同一个入口里无法区分。
- 最小修法：维护 `_mcuHeldNote` 状态机而不是时间窗：同一 note 的重复消息在「没有收到过任何不同 transport 事件」期间一律忽略（静默 500ms 或换键才解除）；同时把「去重」从 `sendToMCUSource`（发送层）上移到 `handleIncoming` 的「事件层」，让「按下/松开」成对生成一次即可。用 4c 场景补一条自检：连发 3 条 MMC Play，应只产生 1 对 MCU 报文。

---

## 三、中

### C1【中】MMC `Record Exit (0x07)` 被当成 STOP
- 位置：`src/MIDIMapper.m:56`（`case 0x07: key = 5; // STOP`），MCU 侧 `src/MIDIMapper.m:108` 同样落到 0x5D。
- 现象：琴结束录音时发的 0x07 会输出 STOP。若琴在每次 REC 后补一条 Record Exit（部分固件如此），用户按一次 REC 会在 DAW 里先录音再停住。
- 修法：0x07 映射成「无动作」（`key = 0`）或单独定义为「REC 的松开」；若现场实测琴只发 0x06 不发 0x07，则保留但加注释与自检锁死行为。

### C2【中】MMC→CC 翻译只发 127、从不发 0，DAW 里「第二次按」可能不触发
- 位置：`src/MIDIMapper.m:136-140`（`out = {0xB0, cc, 0x7F}` 单条），对比 MCU 路径已经改成「127 + 0」成对（`src/MIDIMapper.m:112-114`）。
- 现象：这是**默认推荐模式**（translateMMC=YES、MCU 关）。很多 DAW/插件对 CC 按钮是「值变化才触发」，连续两次都是 127 等于没变化 → 第二次按不动；另一些按「≥64 触发」则正常。和已修过的「MCU 卡按下态」是同一类问题，只是还没轮到 CC 路径。
- 修法：与 MCU 路径对齐，返回 `@[ {0xB0,cc,0x7F}, {0xB0,cc,0x00} ]`（先验证目标 DAW 是否把短脉冲当两次触发，Logic 的 Controller Assignments 可在自检里人工确认一次）。

### C3【中】旧版配置迁移路径会顺手清掉 `lastSource/lastDest`
- 位置：`src/MIDIMapper.m:179-185`（`configVersion != 1` 时 `_translateMMC = YES; [self saveConfig]; return;`）。`saveConfig`（`src/MIDIMapper.m:214-215`）只在 `_lastSource/_lastDest` 非 nil 时写字段，而此处还没加载它们 → 旧文件里的输入/输出记忆被抹掉。
- 现象：从 ≤0.1.4 升级后第一次启动，「重启记住输入输出」失效一次，正好会被误判成「持久化没修好」。
- 修法：迁移分支里先照常解析 `lastSource/lastDest`/`transportMap`（抽一个 `-parseDict:`），只把 `translateMMC` 强制为 YES，再 `saveConfig`。

### C4【中】Auto 模式把「通道 16 的状态字节」误判为 CME 帧
- 位置：`src/CMEMIDIProtocol.m:109-117`（`if ((bytes[i] & 0x0F) == 0x0F) looksCME = YES`）。
- 现象：任何低半字节为 `0xF` 的状态字节都命中：`0x9F`（CH16 Note On）、`0xBF`（CH16 CC）、`0x8F/0xAF/0xCF/0xDF/0xEF`。只要包长 ≥4 且 4 字节对齐处出现这些字节，整包就按 CME 变长帧解析 → 输出一串孤立数据字节，音符/CC 全乱。默认 Auto 模式下，接一台 CH16 的设备就会中招。
- 修法：判定条件收紧为「`bytes[i] == 0x0F` 且 `bytes[i+1]` 是合法 CME 头（0xF0/0xF2/0xF8-0xFF）」，并至少连续命中 2 帧才算 CME；或改用 `mode` 由用户在菜单显式指定（现在菜单已有）。

### C5【中】自己的 MCU 源没有从输入源列表里排除，可以选中形成回环
- 位置：`src/RouterCore.m:79`（只跳过 `_virtualSource`）、`src/RouterCore.m:86-90`（MCU 源 `_mcuSource` 未处理）。
- 现象：勾了 MCU 后，输入源菜单里会多出 "CME UF8 Router MCU"；选中它 → 自己发给 DAW 的 MCU 按键又从输入回到 `handleIncoming` → 再发一遍（自激/重复触发），且 `refreshDevices` 的「只有一个源时自动选上」（`src/RouterCore.m:104-107`）在只剩自己时会把输入源自动设成自己。
- 修法：`src/RouterCore.m:79` 的条件扩成 `if (ep == _virtualSource || ep == _mcuSource) continue;`；`ensureMCUEndpoints` 成功后补一次 `refreshDevices`（现在依赖调用方）。

### C6【中】CoreMIDI 返回码大面积未检查（部分地方查了，部分没查，不一致）
- 位置：未检查——`src/RouterCore.m:178`（`MIDIPortConnectSource`，`connectInput`）、`src/RouterCore.m:405`（Disconnect）、`src/RouterCore.m:411`（Connect，选了源但连接失败时仍打「输入源: xxx」日志 `src/RouterCore.m:412`）、`src/RouterCore.m:387`（`MIDISend`）、`src/RouterCore.m:365,381`（`MIDIReceived`）、`src/RouterCore.m:322,374`（`MIDIPacketListAdd`）、`src/RouterCore.m:147-148,292-293,302-303`（`MIDIObjectSetStringProperty`）；已检查——`src/RouterCore.m:139-155,290,300,364`。
- 现象：「菜单显示已连接/已发送，实际没通」且日志是**成功文案**，排障时会被误导（正是之前「菜单全空但看不出来」那类问题的变种）。`MIDIPacketListAdd` 失败（见 C7）则消息静默消失。
- 修法：抽一个 `- (BOOL)check:(OSStatus)st what:(NSString *)what`，失败就 `[self log:...失败 %d]` 并在 UI 上把该项标灰；连接成功后**再**打成功日志。

### C7【中】发送用的 `MIDIPacketList` 是栈上单体结构，>256 字节的 sysex 会被静默丢弃
- 位置：`src/RouterCore.m:362-364`（`MIDIPacketList pktlist;` + `MIDIPacketListAdd(..., sizeof(pktlist), ...)`，返回值在 364 检查了但在 `src/RouterCore.m:374` 没检查）、`src/RouterCore.m:320-322`。
- 现象：`MIDIPacket` 内建 data 只有 256 字节，`sizeof(MIDIPacketList)` 只够一个包。转发长 sysex（设备 dump、GM Reset 之外的厂商 bulk）时 Add 返回 NULL → 整条被丢，且 374 行不看返回值，连日志都没有。
- 修法：按 `msg.length` 用 `malloc(sizeof(MIDIPacketList) + msg.length)` 动态分配（或 `MIDIPacketListAdd` 失败时 fallback 分段发）；374 行补返回值检查 + 日志。

### C8【中】日志窗口没有历史缓冲：打开前的所有日志直接丢失，且跨线程读 `_logView`
- 位置：`src/AppDelegate.m:471-479`（`if (_logView)` 才存，否则丢弃）、`src/AppDelegate.m:291-307`（窗口首次打开才创建 `_logView`）、`src/AppDelegate.m:472`（在 MIDI 线程读 `_logView`）。
- 现象：启动失败、端口创建失败这些**最需要看的日志**都发生在用户点「查看日志」之前，打开窗口是空的；出问题时只能靠猜。日志 textStorage 也只增不减。
- 修法：AppDelegate 里加 `NSMutableArray<NSString *> *_logLines`（主线程访问，`didLog` 里先同步进队列再刷 UI，最多保留 2000 行）；窗口创建时回填；`_logView` 的判空也搬到主线程。

### C9【中】`stop()` 与回调线程之间没有屏障，dispose 期间回调可能还在跑
- 位置：`src/RouterCore.m:182-191`（先 dispose `_inputPort`，再 MCU 端点、虚拟源、client）、`src/RouterCore.m:311-314`、`src/AppDelegate.m:54-61`（willTerminate 里同步调用）。
- 现象：`MIDIPortDispose`/`MIDIClientDispose` 不保证返回时回调已结束；若此刻 `midiReadProc` 正在 `sendToSelectedDest` 里 `MIDISend(_outputPort,...)`，就是在用一个已 dispose 的 port（未定义行为/返回 kMIDIInvalidPort 被忽略）；`stop` 期间若有 `kMIDIMsgSetupChanged` 到达，`refreshDevices` 会重入并把菜单重建到「已撤掉的端口」上。
- 修法：`stop()` 先 `_stopping = YES`（atomic），回调开头判断即 return；dispose 前 `dispatch_sync(_midiQueue, ^{})` 把在途回调排空（需要 A1 的队列化一起做）；`MIDIPortDisconnectSource` 后再 dispose。

### C10【中】协议模式不持久化，重启后悄悄回到「自动」
- 位置：`src/AppDelegate.m:234-238`（`selectProto:` 只改 `core.protocolMode`）、`src/MIDIMapper.m:204-219`（`saveConfig` 无该字段）。使用说明第 39 行把协议模式当菜单功能向用户展示。
- 现象：需要强制「标准流」的用户每次重启都要重选；`--quit-after` 自检看不出问题，因为自检不跨越重启。
- 修法：`protocolMode` 存进 plist（`d[@"protocolMode"]`），`RouterCore.start` 里从 mapper 恢复，菜单重建已经在 `applicationDidFinishLaunching` 做了。

### C11【中】`_menu.delegate = nil` + `statusItem.menu` 让状态行/勾选态在「打开菜单那一刻」不刷新
- 位置：`src/AppDelegate.m:75`（delegate 置 nil）、`src/AppDelegate.m:115`（`_statusItem.menu = _menu`）、`src/AppDelegate.m:150-153`（`statusClicked:` 设计上负责刷新状态行，但状态栏一旦挂了 menu 就只弹菜单、**不再发 action**）。
- 现象：`statusClicked:` 是死代码；状态行 `● 输入 → 输出` 与按钮标题只在 `updateStatusRow` 被显式调用的时刻更新（菜单动作/refresh 委托），热插拔导致的自动选中、以及 B3 的恢复都不会即时反映到「你打开菜单看到的第一行」。逻辑上正确的兜底是 `menuNeedsUpdate:`。
- 修法：`_menu.delegate = self`，实现 `- (void)menuNeedsUpdate:(NSMenu *)menu { [self updateStatusRow]; [self rebuildSourceMenu]; [self rebuildDestMenu]; [self rebuildTransportMenu]; [self rebuildFilterMenu]; [self rebuildProtoMenu]; }`（或 `menuWillOpen:` 里做）；删掉 `statusClicked:` 或改成 `button.action` 可用时的刷新入口。

### C12【中】选择恢复只看「显示名还在不在」，失败时静默且无回退说明
- 位置：`src/RouterCore.m:160-164`（`[_sourceNames containsObject:_mapper.lastSource]`）、`src/RouterCore.m:165-168`（dest 同理）、`src/RouterCore.m:102-103`（刷新时失效直接置 nil，不写 mapper 也不提示）。
- 现象：设备改名（"Port 1 — U2MIDI Pro" → 换 USB 口后设备名变化）、同名设备序号互换（` (2)` 后缀，见 B2）时，恢复静默失败 → 用户看到「上次明明选了 U2MIDI，这次没选上」，与「持久化没生效」无法区分。`lastSource` 也不会被清掉，下次继续失败。
- 修法：恢复失败时 `[self log:@"上次的输入源 %@ 已不在列表，回退到默认"]`；并在 `start` 结束后把实际生效的选择写回 mapper（现在 B3 的路径写完 ivar 就完事）。

### C13【中】`saveConfig` 写失败静默；目录创建失败也静默；双实例互相覆盖（与 B6 相关）
- 位置：`src/MIDIMapper.m:219`（`[d writeToFile:... atomically:YES]` 返回值丢弃）、`src/MIDIMapper.m:172`（`createDirectoryAtPath:...error:NULL`）。
- 现象：只读目录/磁盘满/权限问题时，用户改的过滤器、MCU 开关「看起来生效了」但重启就没了，且没有任何提示。
- 修法：检查返回值，失败 `NSLog` + 在菜单里显示一行「配置保存失败」；目录创建失败直接返回 nil 并让调用方跳过写（避免对 nil 路径 `writeToFile:` 抛异常，见 D7）。

---

## 四、低

### D1【低】`_midiQueue` 死代码
`src/RouterCore.m:21,42` 建了串行队列从未使用。要么按 A1 用它，要么删掉——留着会让后来人以为「已经做了串行化」。

### D2【低】`connectInput` 死代码且语义危险
`src/RouterCore.m:173-180`：把所有系统 MIDI 源全部连接（`MIDIPortConnectSource` 循环、错误不查），与 `src/RouterCore.m:158` 注释「只连接选中的源」直接矛盾。当前无人调用，但一旦有人「顺手」调用就会把其他设备混进来。

### D3【低】`idx == -2` 是死分支
`src/RouterCore.m:375-378`：`_destIndex` 只会写入 `i` 和 `-1`（`src/RouterCore.m:89,98`），`-2`（指向 MCU 源）永远不会出现，代码与意图不符。

### D4【低】`--route-selftest` 里有占位调用与多处 early-return 泄漏
`src/RouterCore.m:447`：`MIDISourceCreate(client, CFSTR("x"), NULL)` 在 `client` 还是 0 时调用（注释说「占位避免未用告警」，实际是无意义调用 + nonnull 警告）；`src/RouterCore.m:453,457` 失败时只 `return` 不 dispose `client`；`src/RouterCore.m:465` 只 dispose client，留下 `testSrc/testDst`。自检还会在用户系统上真实创建 "CME UF8 Router" 与 MCU 端口（`src/RouterCore.m:459-460`），跑自检时 Logic 可能看到端口闪现。

### D5【低】`applicationWillTerminate` 里 `exit(0)` 既无 watchdog、也救不了崩溃/强杀路径
`src/AppDelegate.m:54-61`：注释说要「保证点退出就退出」，但真正可能卡住的是 `[self.core stop]` 本身（见 C9），`exit(0)` 是在它返回**之后**才执行——stop 卡住时这行永远到不了。另外崩溃、SIGKILL、注销强退都不走 `applicationWillTerminate`（不过那种情况下 CoreMIDI 会随进程退出收走客户端端口，主要影响是 Logic 侧的半死设备缓存）。建议：`stop` 加超时/异步 + `dispatch_after(1s, exit)` 兜底；并把「端口已撤」的日志挪到 `stop` 之前打印，避免日志丢失误导。

### D6【低】枚举日志的计数把「自己的两个端口」算进去了
`src/RouterCore.m:120-121` 用的是 `MIDIGetNumberOfSources/Destinations()` 的原始值（含 `_virtualSource`、`_mcuSource`/`_mcuDest`），但列表里已经把它们剔除（`src/RouterCore.m:79,94`），日志会显示「3 个输入源」而菜单只有 1 个，排障时容易误判。

### D7【低】`configPath` 在极端情况下返回 nil，随后 `writeToFile:` 会抛异常
`src/MIDIMapper.m:167-173`：`paths.firstObject` 为 nil 时 `stringByAppendingPathComponent:` 返回 nil，`src/MIDIMapper.m:219` 拿 nil 当路径写会抛 `NSInvalidArgumentException`（不是「静默失败」而是崩溃）。加 `if (!dir) return nil;` + 调用方判空。

### D8【低】raw-capture 无开关/无轮转/含用户演奏内容（隐私）
见 B4 的修法；单独列出是因为即使 B4 改成异步，仍需「默认关 + 8MB 轮转 + 菜单可见开关」。

### D9【低】MCU 端口创建失败后 `useMackieTransport` 仍为 YES，transport 静默丢失并刷日志
`src/RouterCore.m:326-332` 不检查 `ensureMCUEndpoints` 的结果就置 YES；`src/RouterCore.m:351` 每来一个 transport 键打一条「MCU 端口不存在,transport 键丢弃」。菜单勾着、功能没有、日志刷屏。修法：`ensureMCUEndpoints` 返回 BOOL，失败则回滚 `_useMackieTransport = NO` 并提示。

### D10【低】菜单重建有重复/冗余路径，动作里重建正在展开的菜单
`src/AppDelegate.m:284-289`：`refresh:` 调 `core refreshDevices`（内部已经通过 delegate 重建了源/目标菜单）后又 `rebuildSourceMenu/rebuildDestMenu`，一次点击重建两遍；`src/AppDelegate.m:268-280` 在菜单动作里重建**正在显示**的 submenu。功能上目前没坏（菜单是独立 NSMenu 对象），但会让「点一下勾不动」这类历史问题更难排查，建议只保留一条重建路径（delegate 那条）。

---

## 五、复查过的「已修复项」（确认无残留，供 Lead 放心）
- `teardownMCUEndpoints` 已无自我调用：`src/RouterCore.m:311-314` 只 dispose 两个句柄，`stop`（`src/RouterCore.m:186`）与 `setUseMackieTransport:NO`（`src/RouterCore.m:335`）调用它都不会回到自身。
- core 懒加载存在：`src/AppDelegate.m:36-39`，菜单构建（`src/AppDelegate.m:116-120`）与 `applicationDidFinishLaunching`（`src/AppDelegate.m:42-44`）都不再出现 `_core` 恒 nil。
- `stop` 的 dispose 顺序正确：input/output port → MCU 端点 → 虚拟源 → client（`src/RouterCore.m:184-188`），符合 CoreMIDI 要求。
- 「松开」不再被去重吞掉：`src/RouterCore.m:359` 只对 `vel != 0` 去重；MCU 路径改成按下/松开成对（`src/MIDIMapper.m:112-114`）——但时间窗语义仍有问题，见 B7。
- 菜单在 start 之后的补刷确实加了（`src/AppDelegate.m:45-49`），只是漏了输入源/输出目标两张，见 B3。
- `applicationWillTerminate` 确实会调 `stop`（`src/AppDelegate.m:56`），端口撤除路径存在（风险点见 C9/D5）。

---

## 六、必须先修的 5 条（按顺序）
1. **A1 线程/回调纪律**：notify/read 回调不碰共享数组、不在 MIDI 回调里调 `MIDIPort*`，全部投递主线程 —— 这是唯一会**崩溃/卡死**的类别，且其它修复都建立在它之上（`src/RouterCore.m:195-206,70-74,405-413`）。
2. **A2 sysex 缓冲设上限 + 残包清理**：一次丢 F7 就会「整机不响」，用户只能重启（`src/RouterCore.m:238-260`）。
3. **B1 start 失败走完整 teardown**：否则端口泄漏 + App 看似在跑其实没路由，还无法自愈（`src/RouterCore.m:139-156,182-183`）。
4. **B2 用 endpoint/uniqueID 而不是枚举序号**：热插拔后音符会发到别的设备上，属于「静默错投」（`src/RouterCore.m:385,407-411`）。
5. **B3 restore 后补一次 delegate 刷新**：这是上次「菜单勾选与真实状态不一致」事故**尚未修完**的那一半，默认路径（MCU 关）必现（`src/RouterCore.m:160-168` + `src/AppDelegate.m:47-49`）。

> 若按「对演奏的影响」而非「崩溃风险」排序，B4（实时线程写盘）、B7（MCU 去重导致连按失效/长按乱触发）应插到第 4、5 位；B3 属于显示问题，可紧随其后。
