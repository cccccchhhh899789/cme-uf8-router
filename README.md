# cme-uf8-router

把 2005 年的 **CME UF8** 主键盘接到现代 Mac 上，并把琴上的 6 个走带键翻成 **Mackie Control**（MCU）消息，让 Logic Pro 用内置控制表面即插即用。

> 非官方项目，与 CME 无关联。CME / UF8 是 CME 的商标。

---

## 为什么需要它

CME UF8 的原厂驱动是 2005 年的 **PowerPC** 代码（`UF-MIDI-USB-Driver.plugin`），在 Apple Silicon / 现代 macOS 上完全跑不起来，琴因此只是一台"能弹但走带键没用"的键盘。

这个 App 在 Mac 侧重做了当年驱动的翻译层：

```
UF8 ──5-pin DIN──> USB-MIDI 接口 ──> cme-uf8-router ──┬──> CME UF8 Router       （音符/CC/弯音 → DAW 乐器轨）
                                                       └──> CME UF8 Router MCU   （走带键 → DAW 控制表面）
```

## 功能

- 菜单栏常驻（无 Dock 图标），按需创建虚拟 MIDI 端口
- 三档协议解码：标准 USB-MIDI / CME 私有帧（0x0F 前置）/ 自动识别
- 走带键翻译：MMC、SPP、实时消息 → 可选 **Mackie Control** 或原厂 CC114–119
- 跨包 SysEx 拼装（不少 USB-MIDI 接口会把一条 MMC 拆成两包）
- 过滤器：CC#1 调制轮、CC#7 音量、时钟、Active Sensing 可单独丢弃
- 原始报文抓取，方便自己排查
- 输入源 / 输出目标 / 各项开关全部持久化

## 安装

1. 从 [Releases](../../releases) 下载最新 `.dmg`
2. 双击打开，把 `cme-uf8-router.app` 拖进 `/Applications`
3. **首次启动要右键 → 打开**（本 App 为 ad-hoc 签名、未做 Apple 公证，直接双击会被 Gatekeeper 拦）
4. 菜单栏出现 `UF8:` 图标即启动成功

> 也可以在终端里解除隔离：`xattr -dr com.apple.quarantine /Applications/cme-uf8-router.app`

## 配置

App 菜单（点击菜单栏图标）：

| 菜单项 | 选什么 |
|---|---|
| 输入源 | 你的 USB-MIDI 接口（如 `Port 1 — U2MIDI Pro`） |
| 输出目标 | `CME UF8 Router (虚拟输出 → 给 DAW 用)` |
| transport 键 | 勾选「用 Mackie Control 发 transport」 |

DAW 侧（以 Logic Pro 为例）：

| 位置 | 选择 |
|---|---|
| 音轨 MIDI 输入 | `CME UF8 Router` |
| 控制表面设定 → 安装 → **Mackie Control** | 输入 + 输出都选 `CME UF8 Router MCU` |
| 设置 → MIDI → 输入 | **取消勾选** `CME UF8 Router MCU`（否则乐器轨会跟着弹响，见下） |

## 自检

```bash
bash verify.sh          # 编译 + 6 项自检（协议 / 菜单 / 动作 / 路由 / 退出撤端口 / 单实例）
bash verify.sh --no-build
```

0.1.7 做过一轮独立代码审计（32 条）与 CoreMIDI 坑调研，修复清单见
[docs/fixes-0.1.7.md](docs/fixes-0.1.7.md)，原始报告见 [docs/audit.md](docs/audit.md)、
[docs/known-pitfalls.md](docs/known-pitfalls.md)。

## 已知限制（都是硬件/协议层面的，非 bug）

- **最左两个键（`\|<<` 和 `<<`）发的完全一样**：都是 `F2 00 00`。5-pin DIN 上不带按键 ID，电脑侧无法区分；两个都发 MCU REWIND。"回到开头"用 DAW 自己的 Return 键。
  （原厂驱动能分开，是因为它走 UF8 自己的 USB 口 + CME 私有帧，帧里带按键 ID。）
- **按下走带键会"弹响"乐器**：MCU 按键本身就是 Note On（CH1 的 91–95），乐器轨和控制表面读同一股数据。按上表的「设置 → MIDI → 输入」取消勾选即可。
- **控制表面显示离线**：0.1.7 起三个虚拟端点都使用固定 `kMIDIPropertyUniqueID`，Logic 控制表面不会再因为「重启后换了身份」而掉线；若仍显示离线，通常是 App 正在升级、端口短暂消失，重开一次即可。
- 仅支持 macOS（10.13+），双架构 `x86_64 + arm64`。

## 自己编译

需要 Xcode Command Line Tools：

```bash
bash build.sh          # 编译 universal2 + ad-hoc 签名 + 跑协议层自检
bash make-dmg.sh       # 打 DMG（需要能创建磁盘映像的正常终端）
```

自检：

```bash
./build/cme-uf8-router.app/Contents/MacOS/cme-uf8-router --selftest        # 协议编解码
./build/cme-uf8-router.app/Contents/MacOS/cme-uf8-router --menu-selftest   # 菜单项完整性
./build/cme-uf8-router.app/Contents/MacOS/cme-uf8-router --action-selftest # 点菜单真的改状态
./build/cme-uf8-router.app/Contents/MacOS/cme-uf8-router --route-selftest  # 端到端 MIDI 路由
```

> 跑路由自检前先 `pkill -f cme-uf8-router.app/Contents/MacOS`，否则真实键盘数据会串进探针。

## 协议笔记

| 琴键 | 琴实际发的 | 说明 |
|---|---|---|
| `\|<<` / `<<` | `F2 00 00` | Song Position Pointer = 0 |
| `>>` | `F2 10/20/30 00` | SPP 递增 |
| `●` | `F0 7F 00 06 06 F7` | MMC Record Strobe |
| `■` | `FC` | 实时 Stop |
| `▶` | `FA` | 实时 Start |

- 琴发的是**标准 MIDI**，`CC114–119` 是原厂驱动在电脑侧做的翻译，不是琴的输出。
- 2006 年 readme 的映射：`RTZ→115 REW→116 FF→117 REC→114 STOP→118 PLAY→119`，推子 `M.VOLUME → CC#7 CH1`。
- CME 私有帧（`0x0F` 前置 + 一包多消息）只在 UF8 自己的 USB 口出现，参考 Linux 内核 `sound/usb/midi.c` 的 `snd_usbmidi_cme_input`。
- MCU：`F0 00 00 66 14` 头，宿主唤醒 `… 00 F7`，设备应答 `… 01 F7`（Device Ready）；按键为 Note On CH1，按下 vel `0x7F`、松开 `0x00`，**必须成对发送**。

## 许可

MIT，见 [LICENSE](LICENSE)。
