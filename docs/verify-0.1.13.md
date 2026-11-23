# cme-uf8-router 0.1.13 黑盒验证报告

- 执行人：blackbox-tester（独立黑盒，只读源码用于定位，不改任何源码/脚本）
- 时间：2026-11-24 06:08–06:11（CST）
- 机器：macOS 15.3.1 (24D70)，x86_64（Intel）
- 被测代码：工作区最新状态（`git log -1` = `0666883 2026-11-24 00:01:48 0.1.11: ...` + 未提交的 0.1.13 改动；
  `src/USBReader.h/.m` 为新增未跟踪文件；构建时 `src/*.m` 均为 Lead 最终版，验证期间未再改动）
- 产物：`build/cme-uf8-router.app`，Info.plist `CFBundleShortVersionString=0.1.13`，
  可执行文件 384240 字节，`Mach-O universal binary (x86_64 arm64)`，adhoc 签名，`Identifier=local.cmeuf8.router`
- 琴：CME U2MIDI Pro 插在 USB 上（`ioreg`：`USB Vendor Name="CME Pro"`、`USB Product Name="U2MIDI Pro"`）

## 总表

| # | 验证项 | 结论 | 关键数据 |
|---|--------|------|----------|
| 1 | `bash build.sh` 干净编译 + 产物/架构 | **PASS** | exit 0，16.62s，`warning:/error:` 计数 **0**，`lipo -archs`=`x86_64 arm64` |
| 2 | `bash verify.sh` 六项 | **PASS** | exit 0，24.41s，6/6 PASS，「全部通过」 |
| 3 | `--usb-selftest`（琴插着） | **PASS** | 3 秒 **234 包 / 940 字节**（时钟 224、心跳 10、其余 0） |
| 4 | `--selftest` / `--menu-selftest` / `--action-selftest` / `--stop-selftest` / `--route-selftest` | **PASS** | 全部 exit 0；菜单 25 项 ok、动作 7 项 ok、路由 11 项 PASS |
| 5 | 单实例 | **PASS** | 第二个实例 exit 0，打印「已经有一个 cme-uf8-router 在跑了…」 |
| 6 | 配置持久化（7 个新键 + 迁移） | **PASS**（迁移路径） | 老 plist 934B：7 键全缺；跑一次后 1218B，7 键 + filterCC2/filterCC64 全部出现 |
| 7 | 琴不在时的失败路径 / USB 回滚 | **PASS**（模拟设备缺席） | `--usb-selftest` exit 1 + 明确提示；启动回滚 `useUSB` 1→0，进程不崩 |
| 8 | 进程/端口泄漏 | **PASS** | `pgrep -x` 为空；`tools/midilist` 仅硬件 `Port 1`，无虚拟端口残留 |

一次跑完的时间线（每一步之前都 `pkill -x cme-uf8-router`）：

```
pkill → build.sh（16.62s）→ verify.sh（24.41s，内部重新 build）→ usb-selftest
→ selftest → menu-selftest → action-selftest → stop-selftest → route-selftest
→ 单实例 → 迁移测试 → 无设备模拟 → 泄漏检查
```

## 逐项记录

### 1. 干净编译 + 产物

命令：

```bash
cd /Volumes/Toshiba/Deepseek/CME_UF8/cme-uf8-router
pkill -x cme-uf8-router
/usr/bin/time -p bash build.sh > /tmp/bbg-build.log 2>&1
grep -Eci "warning:|error:" /tmp/bbg-build.log
lipo -archs build/cme-uf8-router.app/Contents/MacOS/cme-uf8-router
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' build/cme-uf8-router.app/Contents/Info.plist
```

输出（关键行）：

```
==> 编译源码 (x86_64 + arm64 → universal2)
==> 架构检查(应为 universal: x86_64 + arm64)
build/.../cme-uf8-router: Mach-O universal binary with 2 architectures:
    [x86_64:Mach-O 64-bit executable x86_64] [arm64:Mach-O 64-bit executable arm64]
Identifier=cme-uf8-router-5555494464dc11e36a983f1c8b8e95bc8a93313c
Identifier=local.cmeuf8.router
==> 完成: build/cme-uf8-router.app

exit=0
real 16.62
user 10.31
sys 2.76

grep 计数：0
lipo -archs：x86_64 arm64
Info.plist：0.1.13
```

结论：**PASS**。0 error、0 warning，universal2 产物存在，版本号正确。

> 附注（并发问题，非本次单跑失败）：验证过程中曾与另一个并发 `build.sh` 撞车两次，报
> `Rename failed: .../build/clang-module-cache/.../CoreImage-*.pcm.tmp -> *.pcm: No such file or directory`
> → `fatal error: could not build module 'Cocoa'`（exit 1）。原因是 `build.sh` 开头 `rm -rf build/`
> 且两个构建共用 `build/clang-module-cache`。串行独占运行时 3 次全部一次过（17–20s）。
> 建议：构建脚本用 `mktemp -d` 私有 module cache，或加 `flock` 防止并行构建互删。

### 2. verify.sh 六项

命令：

```bash
pkill -x cme-uf8-router
/usr/bin/time -p bash verify.sh > /tmp/bbg-verify.log 2>&1
```

输出：

```
协议编解码       PASS
菜单完整性       PASS
菜单动作          PASS
MIDI 路由           PASS
退出清理端口    PASS
单实例             PASS
全部通过

exit=0   real 24.41
跑后 pgrep -x cme-uf8-router：空（rc=1）
```

结论：**PASS**，6/6。

### 3. USB 直读（琴插着）

命令：

```bash
./build/cme-uf8-router.app/Contents/MacOS/cme-uf8-router --usb-selftest
```

输出：

```
USB 直连自检(需插着琴并开机,采样 3 秒)
  · 设备在总线上
  · 已打开 0x82 端点
  3 秒收到 234 包 / 940 字节(时钟 224、心跳 10、其余 0)
  => PASS (USB 直读通路正常)
exit=0
```

结论：**PASS**。时钟约 75 包/秒，与「琴空闲也发时钟」的预期一致；无 sysex/CC 杂包。
（此前同一根线同一次会话的另一轮采样为 232 包/936 字节，时钟 223、心跳 9 —— 量级一致。）

### 4. 五个单项自检

命令与结果（每项之前 `pkill`，每项之后 `pgrep` 均为空）：

| 自检 | exit | 输出要点 | 结论 |
|------|------|----------|------|
| `--selftest` | 0 | NoteOn 1 条；CME sysex auto 1 条 isCME=1；编码帧 `09 90 3c 40`；running status 2 条 PASS；CH16 isCME=0 | PASS |
| `--menu-selftest` | 0 | 6 个 allow 全「勾」；`例外` 子菜单 4 项；2 个一键预设；输入源 1 个、输出目标 2 个；**25 项 ok / 0 失败** | PASS |
| `--action-selftest` | 0 | 白名单时钟 1→0；协议→CME-USB；选输入源；Mackie 勾/取消；图标；退出项；**7 项 ok / 0 失败** | PASS |
| `--stop-selftest` | 0 | stop 前 `CME UF8 Router=1 / MCU=2` → stop 后 `0 / 0` | PASS |
| `--route-selftest` | 0 | 端到端 `90 3c 40`、`90 40 50`、MMC→CC114、MCU PLAY/RECORD、Jog ±1、连发去重、uniqueID `0x55463801`、残包恢复 —— **11 项 PASS** | PASS |

菜单结构抽查（Lead 要求的第 7 条）在 `--menu-selftest` 输出中逐项确认：

```
ok  输入源 > 用 USB 直连琴(不用转接头)
ok  输入源 > Port 1 — U2MIDI Pro
ok  输出目标 > CME UF8 Router (虚拟输出 → 给 DAW 用)
ok  输出目标 > Port 1 — U2MIDI Pro
ok  放行(白名单) > 键盘音符 / 弯音轮 / 控制器 CC / 系统专用 / 时钟 F8 / Active Sensing   ← 6 个 allow
ok  放行(白名单) > 例外(放行 CC 但挡掉这几个号) > CC#1 调制轮 / CC#2 呼吸控制 / CC#7 音量推子 / CC#64 延音踏板  ← 4 项
ok  放行(白名单) > 一键:只放行键盘+弯音+踏板 / 一键:全部放行  ← 2 个预设
ok  transport 键 > MMC/SPP → CC114-119 / 用 Mackie Control 发 transport
ok  刷新设备 / 抓原始报文 / 查看日志 / 退出
=> PASS (0 项失败)
```

说明：输出里有一行 `info AppDelegate 响应 terminate: ? NO(旧 bug:退出灰显)`，但下一行
`NSApp 响应 terminate: ? YES`，且「退出」项动作可用，属历史日志文案，不计失败。

### 5. 单实例

命令：

```bash
"$BIN" &                     # 第一个实例（后台）
sleep 4
"$BIN"                       # 第二个实例（前台）
pgrep -x cme-uf8-router
```

输出：

```
第一个实例 pid 71284 存活
second exit=0
已经有一个 cme-uf8-router 在跑了(端口名会冲突),本次不启动。
第二个实例跑完后：pgrep 仍只有 71284
pkill 后：pgrep 为空（rc=1）
```

结论：**PASS**。

### 6. 配置持久化与老 plist 迁移

真实文件（只读，未改动）：`~/Library/Application Support/cme-uf8-router/midi-map.plist`

```
934 字节，mtime 2026-11-24 00:02:46
sha256 41de0a01e176f6439ff1f8c18de8be684fe5560aba361ea7e57f51ae71a4a6e4
键：configVersion/filterCC1/filterCC7/filterClock/filterSensing/translateMMC/
    translateMMCOffByUser/useMackie/lastSource/lastDest/transportMap
缺：allowNotes allowPitch allowCC allowSysEx allowClock allowSensing useUSB（7 键全缺）
```

这是 0.1.11 时代写下的老配置。沙箱不能写 `~/Library`，所以用 **CFFIXED_USER_HOME**
把「用户目录」整体重定向到 `/tmp` 下的副本（`HOME=` 重定向无效：
`NSSearchPathForDirectoriesInDomains` 不读 `HOME`，实测 `HOME=` 时文件未被改写），
再对副本跑一次真实动作：

```bash
cp "$HOME/Library/Application Support/cme-uf8-router/midi-map.plist" \
   "/tmp/bb/home4/Library/Application Support/cme-uf8-router/midi-map.plist"
CFFIXED_USER_HOME=/tmp/bb/home4 "$BIN" --menu-selftest
```

结果：

```
迁移前 934 字节 → 迁移后 1218 字节
allowNotes=1 allowPitch=1 allowCC=1 allowSysEx=1 allowClock=1 allowSensing=1
useUSB=0
filterCC2=0 filterCC64=0（新「例外」键也已补齐）
其余老键（lastSource/lastDest/transportMap/useMackie/…）原样保留
```

结论：**PASS**。老 plist 在一次启动后自动补齐 7 个新键 + filterCC2/filterCC64，旧设置不丢。

补充实测（副作用，同时证明菜单接线）：

- 同一老 plist 跑 `--action-selftest` 后 `useUSB=1`。原因不是迁移写错，而是该自检的第 3 步
  「选输入源」点的是输入源子菜单**第一项 = 「用 USB 直连琴」**，于是真的切到了 USB 输入并存盘；
  这反过来证明 USB 菜单项的动作是通的（真机在场时 USB 能直接打开）。
- 想验证「useUSB 与菜单勾选态一致」时注意：`--menu-selftest` **不打印输入源项的勾选态**
  （只打印白名单/transport 的勾选态），黑盒无法直接读取该 NSMenuItem.state。
  可核对的等价证据：`useUSB=0` 时启动不会走 USB 分支，`useUSB=1` 时启动会尝试 USB 并在失败时回滚写回 0
  （见第 7 项）；代码侧 `usb.state = self.core.usbInput`，且 `start` 里先按 `mapper.useUSB` 定
  `_usbInput` 再广播刷新，菜单与配置同源。

### 7. 琴不在时的失败路径（模拟）与 USB 回滚

**方法说明（明确标注为模拟）**：本机不能拔琴（会打断 Lead 的真机验收），
`sandbox-exec` 在 DSH 沙箱内被拒：

```
$ sandbox-exec -p '(version 1)(deny iokit-open)' /bin/ls
sandbox-exec: sandbox_apply: Operation not permitted
```

改用 `DYLD_INTERPOSE` 注入一个只把 `IOServiceMatching()` 返回 NULL 的小 dylib
（`/tmp/bb/noiokit2.m`，不改 App 源码/二进制），等价于「USB 总线上没有 CMEG 设备」：

```objc
static CFMutableDictionaryRef bb_IOServiceMatching(const char *name) { return NULL; }
DYLD_INTERPOSE(bb_IOServiceMatching, IOServiceMatching)
```

（普通 `DYLD_INSERT_LIBRARIES` 定义同名函数对 two-level namespace 的 App 不生效，
实测仍能读到真琴；必须用 `__DATA,__interpose`。）

7a. `--usb-selftest`：

```
$ DYLD_INSERT_LIBRARIES=/tmp/bb/noiokit2.dylib "$BIN" --usb-selftest
[bb-sim] IOServiceMatching(IOUSBHostInterface) -> NULL (模拟设备缺席)
USB 直连自检(需插着琴并开机,采样 3 秒)
  ✗ USB 总线上找不到 CME UF8(0x7104:0x2202)
exit=1
```

结论：**PASS**。明确失败信息、exit 1、无崩溃、无残留进程。

7b. 启动路径回滚（配置 `useUSB=1`，模拟设备缺席）：

```bash
/usr/libexec/PlistBuddy -c 'Add :useUSB bool true' "/tmp/bb/home5/.../midi-map.plist"
DYLD_INSERT_LIBRARIES=/tmp/bb/noiokit2.dylib CFFIXED_USER_HOME=/tmp/bb/home5 "$BIN" &
sleep 7
```

结果：

```
before useUSB=true → after useUSB=false      （回滚分支唯一会写 useUSB=0 的地方）
进程 7 秒后仍存活（无崩溃），pkill 后 pgrep 为空
```

结论：**PASS**（启动失败回滚生效）。

7c. 限制：菜单路径 `setUsbInput:` 的回滚同样写 `useUSB=0`，但**「日志多一行」这一项无法从外部白盒捕获**
——`RouterCore.log:` 只把行推给 delegate 存进 App 内日志窗口，不走 NSLog/stderr，
自检模式下没有可抓的 stdout。因此该项只确认了「配置回滚 + 不崩 + 之后可重试」，
日志文案按代码路径（`已退回 MIDI 端口输入(原因: …)` / `USB 直连不可用,已退回 MIDI 端口(原因: …)`）记录，未实测到屏幕文本。
真正点击菜单的路径未做 GUI 自动化（禁止 `open -a`，且本机无辅助功能授权）。

### 8. 进程/端口泄漏

命令：

```bash
pkill -x cme-uf8-router; sleep 2
pgrep -x cme-uf8-router; echo rc=$?
./tools/midilist
```

输出：

```
pgrep -x cme-uf8-router  → 无输出，rc=1
midilist:
sources=1 destinations=1
SRC[0] 'Port 1'
DST[0] 'Port 1'          （只有硬件端口，没有 'CME UF8 Router' / 'CME UF8 Router MCU'）
```

结论：**PASS**。全部自检跑完后无残留进程、无残留虚拟 MIDI 端口。

## 已知限制 / 未覆盖

1. 步骤 7 为 **模拟设备缺席**（IOKit interpose），不是物理拔线；真机拔插由 Lead 在真机验收时补。
2. 菜单「用 USB 直连琴」的勾选态无法由现有 selftest 打印，未做 GUI 点击（无辅助功能授权、禁止 `open -a`）。
3. 沙箱不能写 `~/Library`，真实 plist 保持原样（sha256 未变）；迁移测试用 `CFFIXED_USER_HOME` 副本完成。
4. 并发构建不安全（见第 1 项附注）：两个 `build.sh` 同时跑会互删 `build/clang-module-cache` 导致编译失败；
   单跑稳定。建议脚本层面加锁或私有缓存目录。
5. `--quit-after <n>` 在 `src/main.m` 里没有实现（grep 无匹配），传了会被忽略、进程不会自动退出；
   本次单实例/回滚测试改用后台启动 + `pkill`，不影响结论。若文档/脚本里用到该参数需注意。
