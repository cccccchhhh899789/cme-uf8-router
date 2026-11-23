# CoreMIDI + 菜单栏 App 已知坑（外部证据 + 对本项目的对照）

> 写于 2026-11-23 22:15。本文只做**静态阅读 + 公开资料核查**：未运行 App、未创建/销毁任何 MIDI 端口、未跑 `tools/` 下任何工具。
> 对照用的源码快照：`src/RouterCore.m` 736 行、`src/AppDelegate.m` 481 行、`src/main.m` 87 行（当时 `git status` 显示 src 正被并行修改，**行号会漂移，请按函数名搜**）。
> 代码级逐条审计（32 条，含严重度分级）另见 [audit.md](audit.md)；本文补的是「外部权威依据 + 为什么会反复出这类问题」。

---

## 先给结论

这个项目的 bug 密集，不是因为 CoreMIDI 难用，而是因为它同时踩了**三个系统性缺失**，每一个都会不断生出新 bug：

1. **线程边界没有画清**。CoreMIDI 的回调在三种不同的线程上（读线程 / 建 client 的那个 runloop 线程 / 主线程），项目里三处都在改同一批可变状态，靠事后 `dispatch_async` 打补丁。
2. **没有「身份」概念**。端口、设备全按**名字**和**枚举下标**记，而热插拔会同时改变这两样；宿主（Logic）却按 **uniqueID** 认设备。两边对不上，就表现为「重启后离线」「选错了口」。
3. **失败是静默的**。CoreMIDI 几乎每个 API 都返回 `OSStatus`，但 UI 只有一行日志，日志窗口没开时连日志都丢。用户唯一能观测的只有「有没有声音」，于是每个小故障都变成一次「又出 bug 了」。

外加一类**不是 bug 的 bug**（设备固件/宿主路由的既有限制），见文末。

---

## 一、线程模型

### P01 在 `MIDIReadProc` 里做文件 I/O、发 MIDI、碰 UI

- **现象**：弹一会儿琴偶发丢音；插拔设备瞬间卡顿；`Note On` 有、`Note Off` 没到，音一直挂着；严重时宿主（Logic）一起卡。
- **原因**：读回调跑在 CoreMIDI 自己开的**高优先级接收线程**上（Apple 原文："The CoreMIDI framework will create a high-priority receive thread on your client's behalf, and from that thread, your MIDIReadProc will be called"）。在这个线程里 `createDirectory`、`NSDateFormatter` 分配、写盘，都是毫秒级阻塞；CoreMIDI 的接收队列有限，接收线程一慢，后续 packet 就丢。同一线程里再调 `MIDIReceived`/`MIDISend` 还会叠加锁竞争。
- **正确做法**：回调里只 `memcpy` 出一份 packet 数据，`dispatch_async` 到自己的串行队列；解析、落盘、发 MIDI、更新 UI 全在队列上。原则是**宁可丢日志，不能丢 MIDI**。
- **置信度**：高（Apple 原文明确 + 代码可见）
- **来源**：[MIDIInputPortCreate](<https://developer.apple.com/documentation/coremidi/midiinputportcreate(_:_:_:_:_:)>)（Discussion）、[MIDIServices.h 的 MIDIReadProc 段](https://github.com/phracker/MacOSX-SDKs/blob/master/MacOSX10.9.sdk/System/Library/Frameworks/CoreMIDI.framework/Versions/A/Headers/MIDIServices.h)
- **本项目**：`src/RouterCore.m` 的 `midiReadProc`（:229-233）直接调 `handleIncoming`，后者（:283-305）逐包 `captureRaw`（:236-256，`static NSFileHandle` + 每包新建 `NSDateFormatter` + `writeData`）再 `MIDIReceived`/`MIDISend`。**踩了。**

### P02 以为 `MIDINotifyProc` 在后台线程，并在里面重入 CoreMIDI

- **现象**：插拔设备瞬间 UI 卡一下、正在弹的音丢几个；频繁插拔后要重启 App 才恢复；偶发挂音。
- **原因**：通知回调**不在专用线程**——Apple 原文："It is called on the runloop (thread) on which `MIDIClientCreate` was first called."，本项目就是**主线程**。于是：(a) 在通知里做全量枚举 + 断开/重连所有源，会直接卡主线程；(b) 一次物理插拔通常连发多条通知（`kMIDIMsgSetupChanged` 加 `ObjectAdded`/`ObjectRemoved`），每条都从头再来一遍；(c) 在通知回调里改 MIDI 图连接（`MIDIPortConnectSource`/`DisconnectSource`）属于重入，容易撞上 MIDIServer 内部的锁。
- **正确做法**：通知里**只置一个脏标记**（原子变量 / `dispatch_source`），异步合并后在主线程做一次 refresh；`ObjectAdded` 按端点增量连接（Chromium 就是这么做的），不要「全部断开再重连」。
- **置信度**：高（线程归属有原文；「卡顿/丢音」是从代码路径推出的高置信结论）
- **来源**：[MIDIServices.h 的 MIDINotifyProc 段](https://github.com/phracker/MacOSX-SDKs/blob/master/MacOSX10.9.sdk/System/Library/Frameworks/CoreMIDI.framework/Versions/A/Headers/MIDIServices.h)、[Chromium midi_manager_mac.cc](https://chromium.googlesource.com/chromium/src/media/+/refs/heads/main/midi/midi_manager_mac.cc)
- **本项目**：`midiNotifyProc`（:216-227）对三种通知都直接 `[core refreshDevices]`；`refreshDevices` 末尾（:144）调 `reconnectInputForSelected`，而它（:420-433）先对**所有** source `MIDIPortDisconnectSource` 再连选中项——**断开与重连之间到达的 `Note Off` 就丢了**，这是「弹着弹着音挂着」的直接机理。**踩了。**

### P03 队列/锁建了但没用（假线程安全）

- **现象**：代码看起来是「回调甩队列」的架构，实际仍然裸奔；后来改的人以为安全，越改越乱。
- **原因**：`_midiQueue` 创建后**全文没有一处使用**（死代码），而 `_sourceNames`/`_destNames`/`_destIndex` 被通知线程写、主线程读。
- **正确做法**：要么真用队列并把共享状态收敛到该队列（所有读写都在队列上），要么用不可变快照 + 原子替换；**删掉不用的队列**，否则它是误导。
- **置信度**：高（代码可见）
- **来源**：[MIDIServices.h MIDIReadProc 段](https://github.com/phracker/MacOSX-SDKs/blob/master/MacOSX10.9.sdk/System/Library/Frameworks/CoreMIDI.framework/Versions/A/Headers/MIDIServices.h) 关于 synchronization 的提示
- **本项目**：`src/RouterCore.m:63` 创建 `_midiQueue`，`handleIncoming` 从未 dispatch 进去；`AppDelegate.m:471-480` 的 `didLog` 也在回调线程里读 `_logView`。**踩了。**

---

## 二、身份与生命周期

### P04 虚拟端点不设 `uniqueID`（本项目最贵的坑）

- **现象**：Logic 里控制表面第一次配好，重启 App 或重启 Mac 后显示 **offline**，必须回 `控制表面 → 设置` 重新选一遍输入/输出；有时列表里出现重复的 "CME UF8 Router"。
- **原因**：虚拟端点的 `uniqueID` 由系统在**每次创建时**分配，宿主把控制表面绑定在 uniqueID 上，新 ID 就被当成「另一个设备」。Apple 原文给了正面建议："After creating a virtual source, it's a good idea to assign it the same unique ID it had the last time your application created it. (Although you should be prepared for this to fail in the unlikely event of a collision.) This will permit other clients to retain persistent references to your virtual source more easily."
- **正确做法**：创建后 `MIDIObjectSetIntegerProperty(ep, kMIDIPropertyUniqueID, 固定值)`；设置失败（冲突）就读回系统分配的实际 ID 并持久化，下次沿用。source 和 destination 都要设。
- **置信度**：高（Apple 原文明确建议）
- **来源**：[MIDIServices.h 的 MIDISourceCreate / MIDIDestinationCreate / kMIDIPropertyUniqueID 段](https://github.com/phracker/MacOSX-SDKs/blob/master/MacOSX10.9.sdk/System/Library/Frameworks/CoreMIDI.framework/Versions/A/Headers/MIDIServices.h)
- **补充：进程被强杀后端点会怎样**。client 一旦销毁（正常退出或进程死亡被 MIDIServer 回收），它创建的虚拟端点随之消失，不会永久残留——所以「残留」通常不是端口本身，而是**宿主里那份指向旧 `uniqueID` 的控制表面配置**：设备没了，配置还在，重新建出来的设备 ID 又不同，于是显示 offline。这也是为什么修 P04 比修退出流程更能解决「重启后要重配」。
- **本项目**：全 src **没有任何** `kMIDIPropertyUniqueID`（grep 0 命中）；`MIDISourceCreate`/`MIDIDestinationCreate` 之后只设了 Manufacturer/Model（`RouterCore.m:167-169`、`:313-314`、`:323-324`）。README 自述的「重启后控制表面可能离线」就是这条的临床表现。**踩了，且这是根因级。**

### P05 按名字/枚举下标记住设备

- **现象**：同名设备两个时选错；插拔后消息发到了别的端口；「恢复上次选择」恢复到一个已经不存在或已变成另一个设备的口。
- **原因**：`MIDIGetSource`/`MIDIGetDestination` 的索引**没有任何稳定性承诺**（文档只写「0…count-1，越界返回 NULL」）；`kMIDIPropertyName` 明确不保证唯一（Apple 建议重名时前置设备名）。唯一稳定标识是 `uniqueID`。
- **正确做法**：枚举时一并取 `uniqueID`，配置里存 `uniqueID`（名字只做显示与兜底）；发送前用 `MIDIObjectFindByUniqueID` 重新解析端点，解析不到就**明确报错让用户重选**，不要静默失败。
- **置信度**：高
- **来源**：[MIDIGetSource](<https://developer.apple.com/documentation/coremidi/midigetsource(_:_:)>)（只有 index 语义，无稳定性承诺）、[MIDIServices.h 的 kMIDIPropertyName 段](https://github.com/phracker/MacOSX-SDKs/blob/master/MacOSX10.9.sdk/System/Library/Frameworks/CoreMIDI.framework/Versions/A/Headers/MIDIServices.h)
- **本项目**：`MIDIMapper` 持久化 `lastSource`/`lastDest` 字符串；`sendToSelectedDest`（:389-410）每次都用枚举时记下的下标重新 `MIDIGetDestination(idx)`。**踩了。**

### P06 反复 `MIDIClientCreate` / `MIDIClientDispose`

- **现象**：反复「停止 → 启动」或反复开关 MCU 后，端口建不出来，必须重启 App；历史项目里直接崩溃。
- **原因**：SuperCollider 的实测结论——"once we've called `MIDIClientDispose`, we can't call `MIDIClientCreate` again"，作者一天撞十几次 crash，最后改成**不销毁 client**、跨库重编译复用。
- **正确做法**：client 全生命周期只建一次；停服务只断连接、停路由，不销毁 client；确需销毁时，先确保没有在途回调（见 P01 的队列化）。
- **正确顺序**：① 先 `MIDIPortDispose` 输入/输出端口（等于掐断回调来源）→ ② 再 `MIDIEndpointDispose` 自己创建的虚拟端点 → ③ 最后 `MIDIClientDispose`。端口其实也可以不手动 dispose——Chromium 的注释是 "Do not need to dispose midi_input_ and midi_output_ explicitly. CoreMIDI automatically disposes them on the client disposal."，两种写法都行，**关键是 client 最后**。已知死锁来源只有两类：在通知回调里改 MIDI 图（P02），以及 dispose 时仍有回调在跑、回调里又调 CoreMIDI。
- **置信度**：中（2014 年的旧系统报告，现代 macOS 未必复现；但风险方向一致，且本项目确实在反复建销）
- **来源**：[supercollider #1147 "Topic/coremidi crash fix"](https://github.com/supercollider/supercollider/pull/1147)
- **本项目**：`stop`（:203-212）完整销毁 client；MCU 开关反复 `ensureMCUEndpoints`/`teardownMCUEndpoints`（:308-335）创建/销毁同名端点。**部分踩。**

### P07 自己创建的虚拟端口又连回自己的输入（自激环）

- **现象**：一开 MCU 就疯狂刷消息、CPU 飙高；日志里同一条 `F0 00 00 66 14 01 F7` 无限重复；Logic 里按键乱跳。
- **原因**：本进程既是 "CME UF8 Router MCU" 这个 source 的**生产者**（`MIDIReceived`），又可能把它当输入源连上自己的 input port；消息绕一圈回到自己，形成环。
- **正确做法**：枚举输入源时排除**本进程创建的全部端点**（不只是主 source，还有 MCU source）；更稳的是用 `connRefCon` 标记来源，在回调里丢弃来自自己的包。
- **置信度**：高（代码 + 机理）；是否已被触发取决于用户会不会选到它 → 标「潜在」
- **来源**：[MIDIServices.h 的 MIDIReceived 段](https://github.com/phracker/MacOSX-SDKs/blob/master/MacOSX10.9.sdk/System/Library/Frameworks/CoreMIDI.framework/Versions/A/Headers/MIDIServices.h)、[Chromium 用 connRefCon 标识来源](https://chromium.googlesource.com/chromium/src/media/+/refs/heads/main/midi/midi_manager_mac.cc)
- **本项目**：`refreshDevices` 只过滤了 `_virtualSource`（`:100`），**没有过滤 `_mcuSource`**；`connectInput`（:194-201）一个都不过滤，且 `connRefCon` 传 `NULL`（:199）——但 `:157` 的注释却写着「选中的源/目标在端点上设置 refcon，回调里通过它取回」，实现和注释对不上。**潜在踩。**

---

## 三、数据与协议

### P08 把 `MIDIPacketList` 当数组索引 / 忽略 ARM 对齐

- **现象**：Apple Silicon 上偶发 `EXC_BAD_ACCESS` 或读到垃圾字节，Intel 上却正常。
- **原因**：packet 是变长的，Apple 原文："the packets in the list, while defined as an array, may not be accessed as an array"；且 "On Intel and PowerPC, MIDIPacket is unaligned. On ARM, MIDIPacket must be 4-byte aligned."。
- **正确做法**：遍历**永远**用 `MIDIPacketNext`；自己拼 list 用 `MIDIPacketListAdd`，缓冲区用 `union`/`malloc` 保证对齐；单条 list ≤ 65536 字节，大 sysex 必须分包。
- **置信度**：高
- **来源**：[MIDIServices.h 的 MIDIPacketList / MIDIPacketListAdd 段](https://github.com/phracker/MacOSX-SDKs/blob/master/MacOSX10.9.sdk/System/Library/Frameworks/CoreMIDI.framework/Versions/A/Headers/MIDIServices.h)
- **本项目**：`handleIncoming` 用了 `MIDIPacketNext`（这点是对的）；list 都是栈上结构体，天然对齐。**没踩**，但值得留在清单里防止以后改坏。

### P09 虚拟源里 `MIDIReceived` 的时间戳填 0

- **现象**：虚拟端口发出的消息偶尔「提前/延后」，或和不按键的时间对不上；不同宿主表现不一致。
- **原因**：`MIDIReceived` 与 `MIDISend` 的语义不同——Apple 原文："Unlike MIDISend(), a timestamp of 0 is not equivalent to \"now\"; the driver or virtual source is responsible for putting proper timestamps in the packets."。`MIDIPacket.timeStamp` 注释里的 "Zero means 'now'" 是对接收侧 packet 说的，**不能**直接套到 `MIDIReceived`。
- **正确做法**：用 `mach_absolute_time()`（或 `AudioGetCurrentHostTime()`）填每包时间戳；至少不要假定 0 会当成「现在」。
- **顺带记住分工**：`MIDIReceived` 只用于**自己创建的虚拟 source**（把消息发布给所有连上来的客户端）；`MIDISend` 用于**向别人的 destination** 发（这时 0 才等于「现在」）。两个 API 不能互换。
- **置信度**：高（文档原文）；具体表现受宿主实现影响，现象层标中
- **来源**：[MIDIReceived](<https://developer.apple.com/documentation/coremidi/midireceived(_:_:)>)（Discussion）、[MIDIServices.h 的 MIDIPacket.timeStamp 注释](https://github.com/phracker/MacOSX-SDKs/blob/master/MacOSX10.9.sdk/System/Library/Frameworks/CoreMIDI.framework/Versions/A/Headers/MIDIServices.h)
- **本项目**：所有 `MIDIPacketListAdd` 的时间参数都是 `0`（:343、:385、:395 等 10 处）。**踩了。**

### P10 sysex 拼包无上限、无超时

- **现象**：某次干扰/拔线之后琴**突然彻底不响**，重启 App 才好；内存缓慢上涨、CPU 升高。
- **原因**：`_sysexBuf` 只增不减；一条没有 `F7` 结尾的残包会让之后**所有**正常消息都被当成 sysex 续包吞掉，而且每来一包都全量重解析（O(n²)）。Apple 对 list 有 65536 字节上限，对「残包」没有魔法。
- **正确做法**：长度上限（如 64KB）+ 超时（1s 内没续上就清空）+ 「遇到非实时状态字节且缓冲里没有 F7 就丢弃残包」；解析改成增量推进。
- **置信度**：高（代码可见）；「彻底不响」是从代码推出的高置信结论
- **来源**：[MIDIServices.h MIDIPacketListAdd 段](https://github.com/phracker/MacOSX-SDKs/blob/master/MacOSX10.9.sdk/System/Library/Frameworks/CoreMIDI.framework/Versions/A/Headers/MIDIServices.h)、[audit.md A2](audit.md)
- **本项目**：`decodePacket`（:259-281）。**踩了。**

### P11 Note On/Off 配对与去抖

- **现象**：挂音（一直响）；或者快速连按时丢音。
- **原因**：任何「过滤 / 去抖 / 丢包」只要可能丢掉 `Note Off`，就会挂音。常驻的菜单栏 App 尤其糟——用户连「重启 App」这个动作都找不到。
- **正确做法**：去抖只作用于 `Note On`（velocity > 0），`Note Off`（velocity = 0）**永远放行**；停止、退出、换端口时，对已知按下的音符主动补发 `Note Off`（panic）。
- **置信度**：高
- **来源**：[Logic Pro Help：Mackie 模式按键就是 note messages，会触发乐器](https://www.logicprohelp.com/forums/topic/154194-problem-w-ni-maschine-mikro-mk3-as-midi-controller/)（说明这类设备为什么天然容易制造挂音）
- **本项目**：`sendToMCUSource`（:371-387）的 250ms 去抖已经做到「`vel == 0` 必发」，**这点是对的**；缺的是退出/换端口时的 panic。**部分踩。**

---

## 四、菜单栏 App（LSUIElement）特有

### P12 agent App 不出现在「强制退出」列表

- **现象**：用户找不到 App、以为它没启动或关不掉，只能重启 Mac；这是「怎么这么多 bug」观感的重要来源。
- **原因**：`LSUIElement = 1` 的 agent App 不进 Dock、不进 `Cmd+Tab`，**也不进强制退出窗口**。同类项目维护者的原话："keeps it out of the Dock and app switcher. On macOS, that agent-app model also means it does not appear as a normal application in the Force Quit window."，剩下的退出途径只有「菜单里的 Quit、活动监视器、命令行 kill」。
- **正确做法**：菜单里放**显眼**的「退出」；提供「重启服务」和自启开关；窗口/日志要能被找到。
- **置信度**：高
- **来源**：[CodexBar #1333](https://github.com/steipete/CodexBar/issues/1333)、[LSUIElement 文档](https://developer.apple.com/documentation/bundleresources/information-property-list/lsuielement)
- **本项目**：`LSUIElement=true`；菜单有「退出」（此前踩过 target 写错导致灰显）；没有「重启服务」。**部分踩。**

### P13 终止流程：`applicationWillTerminate:` 不是必然会跑

- **现象**：点退出偶发没反应；退出后配置没保存；强制退出后下次启动状态不对。
- **原因**：所有终止请求（Quit、注销、关机）都先走 `applicationShouldTerminate:`；返回 `NSTerminateLater` 后必须在 2 分钟内回 `replyToApplicationShouldTerminate:`，否则超时；`applicationWillTerminate:` 只在「即将结束执行」时调用，**强杀/崩溃不保证**。
- **正确做法**：收尾（停路由、写配置、panic）放在 `applicationShouldTerminate:`，返回 `NSTerminateNow`；`willTerminate` 只做尽力而为的事；必要时用 `atexit`/`SIGTERM` 兜底。
- **置信度**：高
- **来源**：[Apple《Graceful Application Termination》（归档）](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/AppArchitecture/Tasks/GracefulAppTermination.html)
- **本项目**：`applicationShouldTerminate:` 已显式返回 `NSTerminateNow`（`AppDelegate.m:64-66`），`applicationWillTerminate:` 里 `[core stop]` 之后直接 `exit(0)`（:54-61，注释说明是为了绕开 `MIDIClientDispose` 拖慢退出）。**已缓解**，但 `exit(0)` 属于「用强杀换秒退」，值得在文档里对用户说明。

### P14 `activateIgnoringOtherApps:` 弹窗不可靠（且已弃用）

- **现象**：点「查看日志」窗口出来了但被别的 App 盖住；或者偶尔才在最前。
- **原因**：Apple 原文："there may be a time lag before the app activates—you shouldn't assume the app will be active immediately after sending this message."；macOS 27 起已弃用，改为 `activate()`。
- **正确做法**：`makeKeyAndOrderFront:` + `[NSApp activate]`（必要时先 `setActivationPolicy:NSApplicationActivationPolicyAccessory` 再切回）；窗口层级设 floating。
- **置信度**：高（文档）；特定系统版本上的表现标中
- **来源**：[NSApplication activate(ignoringOtherApps:)](<https://developer.apple.com/documentation/appkit/nsapplication/activate(ignoringotherapps:)>)
- **本项目**：`showLog:`（`AppDelegate.m:291-306`）用了它。**踩了（轻微）。**

### P15 没有单实例保护

- **现象**：两个实例同时跑，系统里出现两条同名虚拟端口，Logic 收到双份消息，或其中一个静默失败。
- **原因**：默认没有单实例约束。`LSMultipleInstancesProhibited` 的官方措辞是 "more than one **user** can launch the app simultaneously"——语义偏「多用户」，对「同一用户双开」是否完全生效需要实测，**不能只靠它**。
- **正确做法**：启动时用 `NSRunningApplication runningApplicationsWithBundleIdentifier:` 找同 bundle id 的其他实例，激活它然后自己退出；再用 `flock` 一个锁文件兜底。
- **置信度**：中（该键对同用户双开的实际效果未实测；双实例的后果是高置信推断）
- **来源**：[LSMultipleInstancesProhibited 文档](https://developer.apple.com/documentation/bundleresources/information-property-list/lsmultipleinstancesprohibited)
- **本项目**：Info.plist 无该键，`main.m` 无检查。**没防。**

### P16 失败不可见（可观测性）

- **现象**：用户只看到「没反应」；日志窗口没开时日志全丢；每次故障都要靠猜 → 体感上就是「到处是 bug」。
- **原因**：`didLog` 只在 `_logView` **已存在**时追加，窗口没开直接丢弃；端口创建失败、选源失败都只是 `log` 一行，没有 UI 提示。
- **正确做法**：内存里保留最近 N 条环形日志，窗口打开时回填；菜单栏标题/图标区分「未选输入 / 已连接 / 错误」；关键错误发系统通知。
- **置信度**：高（代码可见）
- **来源**：源码本身 + [audit.md](audit.md)
- **本项目**：`AppDelegate.m:471-480`。**踩了。**

---

## 五、为什么这类项目「bug 特别多」——把上面归一下类

- **线程类（P01–P03）**：CoreMIDI 把线程模型摊给了调用方，而且三个回调在三个不同线程上。只要没有「状态归谁所有」的明确约定，每加一个功能就会多一条竞态。
- **身份类（P04–P07）**：系统给端点的唯一标识是 `uniqueID`，而人的直觉是「名字 + 排第几个」。所有热插拔相关的怪现象几乎都能追到这一条。
- **生命周期类（P06、P13、P15）**：常驻进程没有「关闭窗口」这个自然终点，退出路径一乱，端口残留、配置没存、双实例全来了。
- **观测类（P16、P12）**：没有可见 UI 的 App，故障只能靠音频判断；日志再一丢，等于闭眼调试。

---

## 六、对照本项目：哪些踩了，哪些还没

| 坑 | 现状 | 证据（按函数名搜，行号会漂移） |
|---|---|---|
| P01 读回调里做重活 | **踩了** | `midiReadProc` → `handleIncoming` → `captureRaw` 写盘 |
| P02 通知里全量重建 + 断连重连 | **踩了** | `midiNotifyProc` 三种通知都 `refreshDevices`；`reconnectInputForSelected` 先全断再连 |
| P03 假线程安全 | **踩了** | `_midiQueue` 创建后零使用 |
| P04 无 `uniqueID` | **踩了（根因）** | 全项目 grep 0 命中 |
| P05 按名字/下标选设备 | **踩了** | `_destIndex` + `lastSource`/`lastDest` 字符串 |
| P06 反复建销 client/端点 | **部分** | `stop` 销毁 client；MCU 开关反复建销端点 |
| P07 自激环 | **潜在** | 只过滤 `_virtualSource`，未过滤 `_mcuSource`；`connectInput` 不过滤 |
| P08 packet 数组/对齐 | **没踩** | 用了 `MIDIPacketNext` |
| P09 时间戳 0 | **踩了** | 10 处 `MIDIPacketListAdd(..., 0, ...)` |
| P10 sysex 无上限 | **踩了** | `decodePacket` 的 `_sysexBuf` |
| P11 Note 配对 | **部分** | 去抖对 `vel==0` 放行（对）；缺 panic |
| P12 不进强制退出 | **部分** | 有「退出」菜单，无「重启服务」 |
| P13 终止流程 | **已缓解** | `applicationShouldTerminate:` 返回 Now + `willTerminate` 里 `exit(0)` |
| P14 activate 弹窗 | **踩了（轻微）** | `showLog:` 用 `activateIgnoringOtherApps:` |
| P15 单实例 | **没防** | Info.plist 无键，`main.m` 无检查 |
| P16 日志丢弃 | **踩了** | `didLog` 无窗口时不缓存 |

---

## 七、如果只能先修三件事

1. **给两个虚拟端点设稳定 `uniqueID`**（P04）。
   一次改动，直接消灭「重启后 Logic 控制表面离线」这个最高频的用户抱怨；也是宿主能「记住」这个设备的唯一办法。改动量小、风险低、收益最大。

2. **把 `handleIncoming` 真正甩到 `_midiQueue`，`captureRaw` 移出读回调**（P01 + P03）。
   读线程只做 `memcpy` + `dispatch_async`；日志改环形缓冲、异步落盘。这一条同时治「丢音」「卡顿」「挂音」三类症状，也是后面所有并发修改的前提。

3. **通知回调里不再断连重连**（P02），顺手给 sysex 加上限（P10）。
   `midiNotifyProc` 只置脏标记，合并后异步 refresh；`ObjectAdded` 增量连接；`reconnectInputForSelected` 加 debounce，且只在「选中的源真的变了」时才动。sysex 上限是几行代码，但能防住「突然彻底不响、只能重启」这种最吓人的故障。

> 第 1 条治「用户每次都要重配」，第 2 条治「用着用着丢音」，第 3 条治「插拔后就坏」。三条互不冲突，可以并行改。

---

## 八、不是 bug 的 bug（预期管理，写进使用说明比改代码有用）

- **UF8 最左两个按键发出完全相同的字节**（`F2 00 00`）：设备固件层面就没区分，软件无法还原，只能文档说明或让用户在 Logic 里重映射。
- **MCU 按键是 Note On，会让乐器轨弹响**：Mackie 协议本来就是 Note 消息；Logic 的「Any」端口选择会把控制消息路由给乐器。正确做法是在 Logic 的 MIDI 输入设置里取消勾选 MCU 端口，而不是改 App。参考 [des99 的解释](https://www.logicprohelp.com/forums/topic/154194-problem-w-ni-maschine-mikro-mk3-as-midi-controller/)。
- **Logic 的控制表面是绑在「MIDI 端口」上的**："When you choose a MIDI input (port) from the pop-up menu in the Control Surfaces > Setup… dialog, all assignments that use the same input are changed accordingly."（[jimamsden](https://jimamsden.wordpress.com/2017/12/28/creating-logic-pro-x-controller-assignments/)）。所以「重启后要重选端口」不是 Logic 的 bug，而是 P04 的临床表现；Apple 官方手册 [Logic Pro 9 Control Surfaces Support](<https://help.apple.com/logicpro/mac/9.1.6/en/logicpro/controlsurfacessupport/Logic%20Pro%209%20Control%20Surfaces%20Support%20(en).pdf>) 里有完整的控制表面设置流程。

---

## 参考来源

- Apple：[MIDIInputPortCreate](<https://developer.apple.com/documentation/coremidi/midiinputportcreate(_:_:_:_:_:)>) · [MIDIReceived](<https://developer.apple.com/documentation/coremidi/midireceived(_:_:)>) · [MIDIGetSource](<https://developer.apple.com/documentation/coremidi/midigetsource(_:_:)>) · [NSApplication activate(ignoringOtherApps:)](<https://developer.apple.com/documentation/appkit/nsapplication/activate(ignoringotherapps:)>) · [LSUIElement](https://developer.apple.com/documentation/bundleresources/information-property-list/lsuielement) · [LSMultipleInstancesProhibited](https://developer.apple.com/documentation/bundleresources/information-property-list/lsmultipleinstancesprohibited) · [Graceful Application Termination（归档）](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/AppArchitecture/Tasks/GracefulAppTermination.html)
- Apple 头文件原文（`MIDIServices.h`，经 MacOSX-SDKs 镜像）：<https://github.com/phracker/MacOSX-SDKs/blob/master/MacOSX10.9.sdk/System/Library/Frameworks/CoreMIDI.framework/Versions/A/Headers/MIDIServices.h>
- Chromium：<https://chromium.googlesource.com/chromium/src/media/+/refs/heads/main/midi/midi_manager_mac.cc>
- SuperCollider：<https://github.com/supercollider/supercollider/pull/1147>
- CodexBar（LSUIElement 与强制退出）：<https://github.com/steipete/CodexBar/issues/1333>
- Logic 控制表面绑定端口：<https://jimamsden.wordpress.com/2017/12/28/creating-logic-pro-x-controller-assignments/>
- Logic 官方手册（控制表面）：<https://help.apple.com/logicpro/mac/9.1.6/en/logicpro/controlsurfacessupport/Logic%20Pro%209%20Control%20Surfaces%20Support%20(en).pdf>
- Mackie 模式按键发 Note 会触发乐器：<https://www.logicprohelp.com/forums/topic/154194-problem-w-ni-maschine-mikro-mk3-as-midi-controller/>
