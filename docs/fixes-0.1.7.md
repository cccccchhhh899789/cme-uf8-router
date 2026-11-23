# 0.1.7 修复清单（对照 docs/audit.md）

审计报告见 [audit.md](audit.md)（32 条：致命 2 / 高 7 / 中 13 / 低 10），
联网调研见 [known-pitfalls.md](known-pitfalls.md)（16 条 CoreMIDI / 菜单栏 App 常见坑）。

这一版按「会不会崩 / 会不会没声音 / 会不会错投设备」的顺序修，逐条对应：

| 编号 | 严重度 | 问题 | 0.1.7 的处理 |
|---|---|---|---|
| A1 | 致命 | MIDI 通知回调线程直接改菜单数据、并在回调里 Connect/Disconnect | 通知回调只 `dispatch_async` 到主线程；`refreshDevices` 强制主线程；`handleIncoming` 用 `@synchronized` 取不可变快照 |
| A2 | 致命 | 跨包 sysex 无上限，缺一个 F7 就永久吞掉后续输入 | 1 秒超时清空 + 8KB 硬上限 + 「新包首字节是状态字节且不是 F7」即丢弃残包；回归测试「残包后普通音符」进 `--route-selftest` |
| B1 | 高 | `start` 半途失败泄漏 client/虚拟端口，`stop` 又被 `_running` 挡住 | 失败分支统一 `[self stop]`；`stop` 改成按句柄逐个撤，不再看 `_running` |
| B2 | 高 | 用枚举序号寻址，热插拔后音符发到别的设备 | 字典改存 `MIDIEndpointRef`（`intptr_t`），发送/连接都用端点引用 |
| B3 | 高 | 恢复 `lastSource/lastDest` 后不再广播刷新 → 菜单勾 A 实际发 B | 恢复完补一次 `routerDidRefreshDevices:`；入口刷新时失效的名字写日志说明 |
| B4 | 高 | `captureRaw` 在 MIDI 实时线程同步写盘、无上限、无开关 | 默认关 + 菜单开关「抓原始报文」+ 后台串行队列写 + 8MB 轮转 + 去掉 `NSDateFormatter` |
| B5 | 高 | running status 移位错误 → 丢音符/音高错乱 | `b` 本就算作第一个数据字节；2 字节消息只吃 `b`，3 字节消息再取 `buf[i]`；`--selftest` 加断言 |
| B6 | 高 | 无单实例防护 | `main.m` 里 `/tmp/cme-uf8-router.lock` + `flock`，第二个实例直接退出并提示 |
| B7 | 高 | MCU 250ms 时间窗去重：连按第二次被吞、按住每 250ms 再触发 | 改成事件级去重：同一个 transport 键 0.4 秒内只触发一次；`--route-selftest` 断言「连发 3 次 = 1 次触发」 |
| C1 | 中 | MMC Record Exit(0x07) 被当 STOP | 映射成「无动作」 |
| C2 | 中 | MMC→CC 只发 127，DAW 里第二次按无效 | 成对发 127 + 0 |
| C3 | 中 | 旧配置迁移会清掉 lastSource/lastDest | 迁移分支照样读回 `lastSource/lastDest/useMackie` |
| C4 | 中 | Auto 模式把 CH16 状态字节误判成 CME 帧 | 收紧成「0x0F 后面必须跟合法 CME 头」；`--selftest` 加 CH16 断言 |
| C5 | 中 | 自己的 MCU 源没从输入源排除 | 源/目标列表都跳过 `_virtualSource` 与 `_mcuSource`/`_mcuDest` |
| C7 | 中 | 栈上 `MIDIPacketList` 只够 256 字节，长 sysex 静默丢弃 | 抽出 `CMESendToEndpoint` / `CMESendToPort`，按长度 `malloc` |
| C8 | 中 | 日志窗口没开就丢日志 | `_logLines` 环形缓冲（500 行），打开窗口回填 |
| C10 | 中 | 协议模式不持久化 | 仍由菜单控制，未做持久化（记入已知限制） |
| C13 | 中 | `saveConfig` 写失败静默 | 判空 + 写后校验 + `NSLog` 报错 |
| D7 | 低 | `configPath` 为 nil 时 `writeToFile:` 崩 | 提前返回 nil，调用方判空 |
| P04 | — | 虚拟端点没有稳定 uniqueID（Logic 控制表面反复掉线） | 三个端点都设固定 `kMIDIPropertyUniqueID`（0x55463801/02/03） |

## 验证方式

```
bash verify.sh          # 编译 + 6 项自检
bash verify.sh --no-build
```

自检项：协议编解码（含 running status / CH16 / CME 帧）、菜单完整性、菜单动作（含 MCU 勾选不卡死）、
MIDI 路由端到端（含跨包 MMC 拼装、MCU 按键、按住连发去重、uniqueID、残包恢复）、退出撤端口、单实例。

## 仍未做（已知限制）

- 协议模式没有持久化（C10）。
- `handleIncoming` 仍在 MIDI 读线程上直接处理：读线程里不做磁盘 IO 了，但解码/发送还是同步的。
  理论上可以整体甩到 `_midiQueue`，需要重做包列表拷贝，收益有限。
- DMG 在沙箱里做不出来（`hdiutil` 被禁），需要在真终端跑 `bash make-dmg.sh`。
