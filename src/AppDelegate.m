// AppDelegate.m — 菜单栏 App 主体
//
// 菜单结构:
//   [状态行: ● 输入源名 → 输出目标名]
//   ——
//   输入源 > (子菜单,单选,列出所有系统 MIDI 源)
//   输出目标 > (子菜单,单选,列出所有系统 MIDI 目标)
//   协议模式 > 自动识别 / CME-USB / 标准流
//   ——
//   放行(白名单) > 键盘音符 / 弯音 / CC / sysex / 时钟 / ActiveSensing(勾选 = 放行)
//   ——
//   刷新设备
//   查看日志(面板)
//   退出

#import "AppDelegate.h"
#import "CMEMIDIProtocol.h"
#import "USBReader.h"
#import <objc/runtime.h>

@implementation AppDelegate {
    NSStatusItem *_statusItem;
    RouterCore *_core;
    NSMenu *_menu;
    NSMenuItem *_statusItem_row;
    NSMenuItem *_srcItem;
    NSMenuItem *_dstItem;
    NSMenuItem *_protoItem;
    NSMenuItem *_filterItem;
    NSMenuItem *_transportItem;
    NSMenuItem *_logItem;
    NSTextView *_logView;
    NSWindow *_logWindow;
    NSMutableArray<NSString *> *_logLines;   // 日志环形缓冲(最多 500 行)
}

// core 懒创建:之前 main.m 里从没给 delegate 建过 core,导致菜单永远空
- (RouterCore *)core {
    if (!_core) _core = [[RouterCore alloc] init];
    return _core;
}

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
    self.core.delegate = self;      // 之前漏了这行:MIDI 热插拔/日志回调都不会来
    [self setupStatusBar];
    [self.core start];
    // 菜单是在 core 启动前建的,那时 useMackieTransport/配置还没恢复,
    // 勾选态会显示成「没勾」但功能其实在跑 —— 启动完再刷一次以真实状态为准
    [self rebuildProtoMenu];
    [self rebuildFilterMenu];
    [self rebuildTransportMenu];
}

// 退出前把虚拟口/端口都撤干净,免得系统里留下挂在已经不在的 App 上的 MIDI 端口
// (不撤的话 Logic 那边会看到一个半死的设备,得等 MIDIServer 超时才收走)
- (void)applicationWillTerminate:(NSNotification *)notification {
    printf("[quit] 撤虚拟端口/MCU 端口\n"); fflush(stdout);
    [self.core stop];
    fflush(stdout);
    // MIDIClientDispose 在某些情况下会等 MIDIServer 回话而拖延退出;
    // 端口已经撤完了,这里直接结束进程,保证「点退出就退出」
    exit(0);
}

// 明确允许退出(默认就是 Now,写出来是为了防止哪天加了窗口后逻辑变化)
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    return NSTerminateNow;
}

- (void)setupStatusBar {
    _statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    // 菜单栏图标:模板图(纯黑剪影),系统会按深浅色自动反色。找不到资源时退回文字
    NSImage *barIcon = [NSImage imageNamed:@"menubar"];
    if (barIcon) {
        barIcon.template = YES;
        barIcon.size = NSMakeSize(18, 18);
        _statusItem.button.image = barIcon;
        _statusItem.button.imagePosition = NSImageOnly;
        _statusItem.button.toolTip = @"cme-uf8-router";
    } else {
        _statusItem.button.title = @"UF8";
    }
    _statusItem.button.target = self;
    _statusItem.button.action = @selector(statusClicked:);

    _menu = [[NSMenu alloc] init];
    _menu.delegate = nil;

    // 状态行
    _statusItem_row = [[NSMenuItem alloc] initWithTitle:@"未选择输入/输出" action:nil keyEquivalent:@""];
    _statusItem_row.enabled = NO;
    [_menu addItem:_statusItem_row];
    [_menu addItem:[NSMenuItem separatorItem]];

    // 输入源
    _srcItem = [[NSMenuItem alloc] initWithTitle:@"输入源" action:nil keyEquivalent:@""];
    [_menu addItem:_srcItem];
    // 输出目标
    _dstItem = [[NSMenuItem alloc] initWithTitle:@"输出目标" action:nil keyEquivalent:@""];
    [_menu addItem:_dstItem];
    // 协议模式
    _protoItem = [[NSMenuItem alloc] initWithTitle:@"协议模式" action:nil keyEquivalent:@""];
    [_menu addItem:_protoItem];
    [_menu addItem:[NSMenuItem separatorItem]];

    // 放行(白名单) —— 内部变量名仍叫 _filterItem,免得全文件改一遍
    _filterItem = [[NSMenuItem alloc] initWithTitle:@"放行(白名单)" action:nil keyEquivalent:@""];
    [_menu addItem:_filterItem];

    // transport 键翻译(MMC/SPP -> CC),Logic 里能直接学习
    _transportItem = [[NSMenuItem alloc] initWithTitle:@"transport 键" action:nil keyEquivalent:@""];
    [_menu addItem:_transportItem];
    [_menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *refresh = [[NSMenuItem alloc] initWithTitle:@"刷新设备" action:@selector(refresh:) keyEquivalent:@"r"];
    refresh.target = self;
    [_menu addItem:refresh];

    NSMenuItem *capture = [[NSMenuItem alloc] initWithTitle:@"抓原始报文(排错用)" action:@selector(toggleCapture:) keyEquivalent:@""];
    capture.target = self;
    capture.state = self.core.captureRawEnabled ? NSControlStateValueOn : NSControlStateValueOff;
    [_menu addItem:capture];

    NSMenuItem *log = [[NSMenuItem alloc] initWithTitle:@"查看日志" action:@selector(showLog:) keyEquivalent:@"l"];
    log.target = self;
    [_menu addItem:log];

    NSMenuItem *quit = [[NSMenuItem alloc] initWithTitle:@"退出" action:@selector(terminate:) keyEquivalent:@"q"];
    quit.target = NSApp;   // NSApp 实现了 terminate:(不是 AppDelegate)
    [_menu addItem:quit];

    _statusItem.menu = _menu;
    [self rebuildSourceMenu];
    [self rebuildDestMenu];
    [self rebuildProtoMenu];
    [self rebuildFilterMenu];
    [self rebuildTransportMenu];
}

// ---------- transport 键翻译 ----------
- (void)rebuildTransportMenu {
    NSMenu *sub = [[NSMenu alloc] init];
    NSMenuItem *legend = [[NSMenuItem alloc] initWithTitle:@"琴发的是 MMC/SPP(不是 CC),三选一,互斥" action:nil keyEquivalent:@""];
    legend.enabled = NO;
    [sub addItem:legend];
    [sub addItem:[NSMenuItem separatorItem]];

    BOOL mackie = self.core.useMackieTransport;
    BOOL ccMode = self.core.mapper.translateMMC;

    // 三选一:单选语义,避免「两个都勾但只有一个生效」那种骗人状态
    NSMenuItem *a = [[NSMenuItem alloc] initWithTitle:@"用 Mackie Control 发 transport(推荐,Logic 装 Mackie Control 表面)"
                                               action:@selector(selectTransportMode:) keyEquivalent:@""];
    a.target = self; a.representedObject = @"modeMackie";
    a.state = (mackie && !ccMode) ? NSControlStateValueOn : NSControlStateValueOff;   // Mackie 优先
    [sub addItem:a];
    NSMenuItem *aNote = [[NSMenuItem alloc] initWithTitle:@"  走带从「CME UF8 Router MCU」口出去,弹奏照旧走虚拟输出" action:nil keyEquivalent:@""];
    aNote.enabled = NO;
    [sub addItem:aNote];

    NSMenuItem *b = [[NSMenuItem alloc] initWithTitle:@"翻成 CC114-119(CC#114-119 那项要放行)"
                                               action:@selector(selectTransportMode:) keyEquivalent:@""];
    b.target = self; b.representedObject = @"modeCC";
    b.state = (ccMode && !mackie) ? NSControlStateValueOn : NSControlStateValueOff;
    [sub addItem:b];
    NSMenuItem *bNote = [[NSMenuItem alloc] initWithTitle:@"  适合「不想装控制表面,只在乐器轨上学 CC」" action:nil keyEquivalent:@""];
    bNote.enabled = NO;
    [sub addItem:bNote];

    NSMenuItem *c = [[NSMenuItem alloc] initWithTitle:@"原样转发 MMC(F0 7F …,不做任何翻译)"
                                               action:@selector(selectTransportMode:) keyEquivalent:@""];
    c.target = self; c.representedObject = @"modeRaw";
    c.state = (!mackie && !ccMode) ? NSControlStateValueOn : NSControlStateValueOff;
    [sub addItem:c];

    _transportItem.submenu = sub;
}

- (void)selectTransportMode:(NSMenuItem *)sender {
    NSString *mode = sender.representedObject;
    MIDIMapper *mp = self.core.mapper;
    if ([mode isEqualToString:@"modeMackie"]) {
        mp.translateMMC = NO;
        if (!self.core.useMackieTransport) self.core.useMackieTransport = YES;
        [self.core log:@"走带: Mackie Control(MCU 口)"];
    } else if ([mode isEqualToString:@"modeCC"]) {
        if (self.core.useMackieTransport) self.core.useMackieTransport = NO;
        mp.translateMMC = YES;
        [self.core log:@"走带: 翻成 CC114-119"];
    } else {
        if (self.core.useMackieTransport) self.core.useMackieTransport = NO;
        mp.translateMMC = NO;
        [self.core log:@"走带: 原样转发 MMC"];
    }
    [mp saveConfig];
    [self rebuildTransportMenu];
    [self rebuildFilterMenu];   // 走带那项的语义提示跟着模式变
}

- (void)statusClicked:(id)sender {
    // 显示菜单(点状态栏图标自动弹出,这里刷新状态行)
    [self updateStatusRow];
}

- (void)updateStatusRow {
    NSString *src = self.core.usbInput ? @"USB直连" : (self.core.selectedSourceName ?: @"(未选)");
    NSString *dst = self.core.selectedDestName ?: @"(未选)";
    NSString *proto = @"自动";
    switch (self.core.protocolMode) {
        case CMEMIDIProtocolModeCME: proto = @"CME"; break;
        case CMEMIDIProtocolModeStandard: proto = @"标准"; break;
        default: proto = @"自动"; break;
    }
    _statusItem_row.title = [NSString stringWithFormat:@"● %@ → %@ [%@]", src, dst, proto];
    if (!_statusItem.button.image) {
        _statusItem.button.title = [NSString stringWithFormat:@"UF8:%@", src.length > 6 ? [src substringToIndex:6] : src];
    } else {
        // 有图标时详情放 tooltip,菜单栏保持干净
        _statusItem.button.toolTip = [NSString stringWithFormat:@"%@ → %@ [%@]", src, dst, proto];
    }
}

// ---------- 输入源子菜单 ----------
- (void)rebuildSourceMenu {
    NSMenu *sub = [[NSMenu alloc] init];
    BOOL usbOK = [USBMIDIReader devicePresent];
    NSString *usbTitle = usbOK ? @"用 USB 直连琴(不用转接头)" : @"用 USB 直连琴(未检测到琴)";
    NSMenuItem *usb = [[NSMenuItem alloc] initWithTitle:usbTitle action:@selector(selectUSBInput:) keyEquivalent:@""];
    usb.target = self;
    usb.state = self.core.usbInput ? NSControlStateValueOn : NSControlStateValueOff;
    [sub addItem:usb];
    [sub addItem:[NSMenuItem separatorItem]];
    for (NSString *name in self.core.sourceNames) {
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:name action:@selector(selectSource:) keyEquivalent:@""];
        item.target = self;
        item.representedObject = name;
        item.state = (!self.core.usbInput && [name isEqualToString:self.core.selectedSourceName])
                     ? NSControlStateValueOn : NSControlStateValueOff;
        [sub addItem:item];
    }
    if (self.core.sourceNames.count == 0) {
        NSMenuItem *none = [[NSMenuItem alloc] initWithTitle:@"(无可用源)" action:nil keyEquivalent:@""];
        none.enabled = NO;
        [sub addItem:none];
    }
    _srcItem.submenu = sub;
}

- (void)selectSource:(NSMenuItem *)sender {
    if (self.core.usbInput) self.core.usbInput = NO;   // 换端口就等于放弃 USB 直连
    self.core.selectedSourceName = sender.representedObject;
    [self updateStatusRow];
    [self rebuildSourceMenu];
    [self rebuildProtoMenu];
}

- (void)selectUSBInput:(id)sender {
    if (self.core.usbInput) {
        // 已经勾着:再点一次 = 重试(拔插之后必须能点活)
        self.core.usbInput = NO;
    }
    self.core.usbInput = YES;
    [self updateStatusRow];
    [self rebuildSourceMenu];
    [self rebuildProtoMenu];
}

// ---------- 输出目标子菜单 ----------
- (void)rebuildDestMenu {
    NSMenu *sub = [[NSMenu alloc] init];
    for (NSString *name in self.core.destNames) {
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:name action:@selector(selectDest:) keyEquivalent:@""];
        item.target = self;
        item.representedObject = name;
        item.state = [name isEqualToString:self.core.selectedDestName] ? NSControlStateValueOn : NSControlStateValueOff;
        [sub addItem:item];
    }
    if (self.core.destNames.count == 0) {
        NSMenuItem *none = [[NSMenuItem alloc] initWithTitle:@"(无可用目标)" action:nil keyEquivalent:@""];
        none.enabled = NO;
        [sub addItem:none];
    }
    _dstItem.submenu = sub;
}

- (void)selectDest:(NSMenuItem *)sender {
    self.core.selectedDestName = sender.representedObject;
    [self updateStatusRow];
    [self rebuildDestMenu];
}

// ---------- 协议模式 ----------
- (void)rebuildProtoMenu {
    NSMenu *sub = [[NSMenu alloc] init];
    NSArray *modes = @[
        @{@"title": @"自动识别", @"mode": @(CMEMIDIProtocolModeAuto)},
        @{@"title": @"CME-USB (0x0F 帧)", @"mode": @(CMEMIDIProtocolModeCME)},
        @{@"title": @"标准流 (DIN/串联)", @"mode": @(CMEMIDIProtocolModeStandard)},
    ];
    for (NSDictionary *m in modes) {
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:m[@"title"] action:@selector(selectProto:) keyEquivalent:@""];
        item.target = self;
        item.representedObject = m[@"mode"];
        item.state = (self.core.protocolMode == [m[@"mode"] integerValue]) ? NSControlStateValueOn : NSControlStateValueOff;
        [sub addItem:item];
    }
    _protoItem.submenu = sub;
}

- (void)selectProto:(NSMenuItem *)sender {
    self.core.protocolMode = (CMEMIDIProtocolMode)[sender.representedObject integerValue];
    [self updateStatusRow];
    [self rebuildProtoMenu];
}

// ---------- 过滤器 ----------
- (void)rebuildFilterMenu {
    NSMenu *sub = [[NSMenu alloc] init];
    NSMenuItem *legend = [[NSMenuItem alloc] initWithTitle:@"勾选 = 放行(不勾 = 丢弃)" action:nil keyEquivalent:@""];
    legend.enabled = NO;
    [sub addItem:legend];
    NSMenuItem *legend2 = [[NSMenuItem alloc] initWithTitle:@"白名单:没勾的东西一律进不了 DAW" action:nil keyEquivalent:@""];
    legend2.enabled = NO;
    [sub addItem:legend2];
    [sub addItem:[NSMenuItem separatorItem]];
    MIDIMapper *mp = self.core.mapper;
    NSArray *rows = @[
        @{@"title": @"键盘音符", @"key": @"allowNotes",   @"on": @(mp.allowNotes)},
        @{@"title": @"弯音轮", @"key": @"allowPitch",     @"on": @(mp.allowPitch)},
        @{@"title": @"控制器 CC(推子/旋钮,不含 #1/#2/#7/#64/#114-119)", @"key": @"allowCC", @"on": @(mp.allowCC)},
        @{@"title": @"系统专用(sysex / MMC / SPP)", @"key": @"allowSysEx", @"on": @(mp.allowSysEx)},
        @{@"title": @"时钟 F8(琴空闲也发 77 条/秒)", @"key": @"allowClock", @"on": @(mp.allowClock)},
        @{@"title": @"Active Sensing(心跳,纯噪音)", @"key": @"allowSensing", @"on": @(mp.allowSensing)},
    ];
    for (NSDictionary *r in rows) {
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:r[@"title"] action:@selector(toggleFilter:) keyEquivalent:@""];
        item.target = self;
        item.representedObject = r[@"key"];
        item.state = [r[@"on"] boolValue] ? NSControlStateValueOn : NSControlStateValueOff;
        [sub addItem:item];
    }
    // 四个常用号单独列出来(整类 CC 的开关不覆盖它们),默认全放行
    [sub addItem:[NSMenuItem separatorItem]];
    NSMenuItem *excParent = [[NSMenuItem alloc] initWithTitle:@"单个 CC 号(默认全放行)" action:nil keyEquivalent:@""];
    NSMenu *exc = [[NSMenu alloc] init];
    NSMenuItem *excLegend = [[NSMenuItem alloc] initWithTitle:@"整类 CC 不含这四号,这里单独管" action:nil keyEquivalent:@""];
    excLegend.enabled = NO;
    [exc addItem:excLegend];
    [exc addItem:[NSMenuItem separatorItem]];
    NSArray *excRows = @[
        @{@"title": @"CC#1 调制轮(历史故障源)", @"key": @"allowCC1",  @"on": @(mp.allowCC1)},
        @{@"title": @"CC#2 呼吸控制",           @"key": @"allowCC2",  @"on": @(mp.allowCC2)},
        @{@"title": @"CC#7 音量/推子(历史故障源)", @"key": @"allowCC7", @"on": @(mp.allowCC7)},
        @{@"title": @"CC#64 延音踏板",           @"key": @"allowCC64", @"on": @(mp.allowCC64)},
        @{@"title": @"走带: CC#114-119 + CC#60 Jog(RTZ/REW/FF/REC/STOP/PLAY)", @"key": @"allowCC114", @"on": @(mp.allowCC114)},
    ];
    for (NSDictionary *r in excRows) {
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:r[@"title"] action:@selector(toggleFilter:) keyEquivalent:@""];
        item.target = self;
        item.representedObject = r[@"key"];
        item.state = [r[@"on"] boolValue] ? NSControlStateValueOn : NSControlStateValueOff;
        [exc addItem:item];
    }
    NSMenuItem *mcuNote = [[NSMenuItem alloc] initWithTitle:@"开了 Mackie Control 时,走带走 MCU 端口,不受这里限制"
                                                     action:nil keyEquivalent:@""];
    mcuNote.enabled = NO;
    [exc addItem:[NSMenuItem separatorItem]];
    [exc addItem:mcuNote];
    excParent.submenu = exc;
    [sub addItem:excParent];

    [sub addItem:[NSMenuItem separatorItem]];
    NSMenuItem *pick = [[NSMenuItem alloc] initWithTitle:@"一键:只放行键盘+弯音+踏板(最干净)" action:@selector(presetCleanFilter:) keyEquivalent:@""];
    pick.target = self;
    [sub addItem:pick];
    NSMenuItem *all = [[NSMenuItem alloc] initWithTitle:@"一键:全部放行(排障时用)" action:@selector(presetAllowAll:) keyEquivalent:@""];
    all.target = self;
    [sub addItem:all];
    _filterItem.submenu = sub;
}

- (void)presetCleanFilter:(id)sender {
    MIDIMapper *mp = self.core.mapper;
    // 最干净 = 只留 键盘 / 弯音 / 延音踏板(CC#64)。其余全关:
    // 推子旋钮(整类 CC)、CC#1/#2/#7、走带 CC、sysex、时钟、心跳
    mp.allowNotes = YES; mp.allowPitch = YES; mp.allowCC = NO;
    mp.allowSysEx = NO; mp.allowClock = NO; mp.allowSensing = NO;
    mp.allowCC1 = NO; mp.allowCC2 = NO; mp.allowCC7 = NO; mp.allowCC64 = YES; mp.allowCC114 = NO;
    [mp saveConfig];
    [self rebuildFilterMenu];
    [self.core log:@"放行: 只留 键盘/弯音/延音踏板,其余全关"];
}

- (void)presetAllowAll:(id)sender {
    MIDIMapper *mp = self.core.mapper;
    mp.allowNotes = YES; mp.allowPitch = YES; mp.allowCC = YES;
    mp.allowSysEx = YES; mp.allowClock = YES; mp.allowSensing = YES;
    // 五个单独 CC 号也必须一起打开,否则预设跑完子菜单还是空勾(用户会以为没生效)
    mp.allowCC1 = YES; mp.allowCC2 = YES; mp.allowCC7 = YES; mp.allowCC64 = YES; mp.allowCC114 = YES;
    [mp saveConfig];
    [self rebuildFilterMenu];
    [self.core log:@"放行: 全部(含时钟与 ActiveSensing)"];
}

// 抓包默认关:它会写盘、也会把弹的东西落成日志。只有排障时才开
- (void)toggleCapture:(NSMenuItem *)sender {
    RouterCore *core = self.core;
    core.captureRawEnabled = !core.captureRawEnabled;
    sender.state = core.captureRawEnabled ? NSControlStateValueOn : NSControlStateValueOff;
    [self.core log:core.captureRawEnabled
        ? @"已开始抓原始报文: ~/Library/Application Support/cme-uf8-router/raw-capture.log"
        : @"已停止抓原始报文"];
}

- (void)toggleFilter:(NSMenuItem *)sender {
    NSString *key = sender.representedObject;
    MIDIMapper *mapper = self.core.mapper;   // 别用空 _mapper:菜单动作必须始终有主
    if ([key isEqualToString:@"allowNotes"])   mapper.allowNotes   = !mapper.allowNotes;
    if ([key isEqualToString:@"allowPitch"])   mapper.allowPitch   = !mapper.allowPitch;
    if ([key isEqualToString:@"allowCC"])      mapper.allowCC      = !mapper.allowCC;
    if ([key isEqualToString:@"allowSysEx"])   mapper.allowSysEx   = !mapper.allowSysEx;
    if ([key isEqualToString:@"allowClock"])   mapper.allowClock   = !mapper.allowClock;
    if ([key isEqualToString:@"allowSensing"]) mapper.allowSensing = !mapper.allowSensing;
    if ([key isEqualToString:@"allowCC1"])  mapper.allowCC1  = !mapper.allowCC1;
    if ([key isEqualToString:@"allowCC2"])  mapper.allowCC2  = !mapper.allowCC2;
    if ([key isEqualToString:@"allowCC7"])  mapper.allowCC7  = !mapper.allowCC7;
    if ([key isEqualToString:@"allowCC64"]) mapper.allowCC64 = !mapper.allowCC64;
    if ([key isEqualToString:@"allowCC114"]) mapper.allowCC114 = !mapper.allowCC114;
    if ([key isEqualToString:@"filterClock"]) mapper.filterClock = !mapper.filterClock;
    if ([key isEqualToString:@"filterSensing"]) mapper.filterSensing = !mapper.filterSensing;
    if ([key isEqualToString:@"translateMMC"]) mapper.translateMMC = !mapper.translateMMC;
    if ([key isEqualToString:@"useMackie"]) self.core.useMackieTransport = !self.core.useMackieTransport;
    [mapper saveConfig];
    [self rebuildFilterMenu];
    [self rebuildTransportMenu];
}


// ---------- 动作 ----------
- (void)refresh:(id)sender {
    [self.core refreshDevices];
    [self rebuildSourceMenu];
    [self rebuildDestMenu];
    [self updateStatusRow];
}

- (void)showLog:(id)sender {
    if (!_logWindow) {
        _logView = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 560, 320)];
        _logView.editable = NO;
        _logView.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
        NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 560, 320)];
        scroll.documentView = _logView;
        scroll.hasVerticalScroller = YES;
        _logWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(300, 300, 560, 320)
                                                 styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable)
                                                   backing:NSBackingStoreBuffered defer:NO];
        _logWindow.title = @"cme-uf8-router 日志";
        _logWindow.contentView = scroll;
        if (_logLines.count) {   // 回填窗口打开之前发生的事
            [_logView.textStorage appendAttributedString:
                [[NSAttributedString alloc] initWithString:[_logLines componentsJoinedByString:@"\n"]]];
            [_logView.textStorage appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n"]];
        }
    }
    [_logWindow makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

// ---------- 菜单自检(防「灰显点不动」回归) ----------
static int validateMenu(NSMenu *menu, NSString *prefix) {
    int fails = 0;
    for (NSMenuItem *item in menu.itemArray) {
        if (item.isSeparatorItem) continue;
        if (item.submenu) { fails += validateMenu(item.submenu, [prefix stringByAppendingFormat:@"%@ > ", item.title]); continue; }
        if (!item.action) continue;   // 纯标题行(状态行)无动作,正常
        NSString *label = [prefix stringByAppendingString:item.title];
        if (!item.target) {
            printf("FAIL 无 target: %s\n", label.UTF8String);
            fails++;
        } else if (![item.target respondsToSelector:item.action]) {
            printf("FAIL target 不响应 %s: %s (%s)\n", sel_getName(item.action), label.UTF8String,
                   item.target == NSApp ? "NSApp" : NSStringFromClass([item.target class]).UTF8String);
            fails++;
        } else {
            printf("ok   %s\n", label.UTF8String);
        }
    }
    return fails;
}

+ (int)runMenuSelfTest {
    NSApplication *app = [NSApplication sharedApplication];
    [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
    AppDelegate *d = [[AppDelegate alloc] init];
    d.core.delegate = d;
    [d setupStatusBar];
    [d.core start];               // 建虚拟端口 + 枚举真实设备
    [d.core refreshDevices];
    [d rebuildFilterMenu];
    [d rebuildTransportMenu];
    printf("=== 勾选态 ===\n");
    printf("info useMackieTransport=%s translateMMC=%s\n",
           d.core.useMackieTransport ? "YES" : "NO",
           d.core.mapper.translateMMC ? "YES" : "NO");
    for (NSMenuItem *top in d->_menu.itemArray) {
        if (!top.submenu) continue;
        for (NSMenuItem *it in top.submenu.itemArray) {
            if (it.action == @selector(toggleFilter:) && it.representedObject) {
                printf("info [%s] %s = %s\n", top.title.UTF8String, [it.representedObject description].UTF8String,
                       it.state == NSControlStateValueOn ? "勾" : "未勾");
            }
        }
    }
    printf("=== 当前系统 MIDI 设备 ===\n");
    printf("输入源 %lu 个:\n", (unsigned long)d.core.sourceNames.count);
    for (NSString *n in d.core.sourceNames) printf("  - %s\n", n.UTF8String);
    printf("输出目标 %lu 个:\n", (unsigned long)d.core.destNames.count);
    for (NSString *n in d.core.destNames) printf("  - %s\n", n.UTF8String);
    printf("=== 菜单自检 ===\n");
    printf("info AppDelegate 响应 terminate: ? %s\n", [d respondsToSelector:@selector(terminate:)] ? "YES" : "NO(旧 bug:退出灰显)");
    printf("info NSApp 响应 terminate: ? %s\n", [NSApp respondsToSelector:@selector(terminate:)] ? "YES" : "NO");
    int fails = validateMenu(d->_menu, @"");
    printf("=> %s (%d 项失败)\n", fails == 0 ? "PASS" : "FAIL", fails);
    return fails;
}

+ (int)runQuitSelfTest {
    // 端到端验证「退出」:真的触发菜单项动作,进程应立即退出(走不到下面那行)
    NSApplication *app = [NSApplication sharedApplication];
    [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
    AppDelegate *d = [[AppDelegate alloc] init];
    d.core = [[RouterCore alloc] init];
    [d setupStatusBar];
    NSMenuItem *quit = nil;
    for (NSMenuItem *it in d->_menu.itemArray) {
        if ([it.title isEqualToString:@"退出"]) { quit = it; break; }
    }
    if (!quit) { printf("FAIL 找不到「退出」菜单项\n"); return 1; }
    printf("触发「退出」: target=%s action=%s\n",
           quit.target == NSApp ? "NSApp" : NSStringFromClass([quit.target class]).UTF8String,
           sel_getName(quit.action));
    fflush(stdout);
    [NSApp sendAction:quit.action to:quit.target from:quit];
    printf("FAIL 退出后进程仍在运行\n");
    return 1;
}


// 端到端:模拟点菜单项,验证勾选/选择真的生效(用户报「点了勾不回切换」)
+ (int)runActionSelfTest {
    NSApplication *app = [NSApplication sharedApplication];
    [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
    AppDelegate *d = [[AppDelegate alloc] init];
    d.core.delegate = d;
    [d setupStatusBar];
    [d.core start];
    [d.core refreshDevices];
    int fails = 0;
    printf("=== 菜单动作自检 ===\n");

    // 1) 白名单「时钟」:点一下应翻转
    NSMenuItem *clockItem = nil;
    for (NSMenuItem *it in d->_filterItem.submenu.itemArray)
        if ([it.representedObject isEqual:@"allowClock"]) { clockItem = it; break; }
    BOOL before = d.core.mapper.allowClock;
    [NSApp sendAction:clockItem.action to:clockItem.target from:clockItem];
    BOOL after = d.core.mapper.allowClock;
    printf("%s 白名单 时钟 F8: %d -> %d\n", before != after ? "ok  " : "FAIL", before, after);
    if (before == after) fails++;
    [NSApp sendAction:clockItem.action to:clockItem.target from:clockItem];   // 复原

    // 2) 协议模式选 CME-USB:protocolMode 应变为 CME
    NSMenuItem *cmeItem = nil;
    for (NSMenuItem *it in d->_protoItem.submenu.itemArray)
        if ([it.title hasPrefix:@"CME-USB"]) cmeItem = it;
    [NSApp sendAction:cmeItem.action to:cmeItem.target from:cmeItem];
    BOOL protoOK = (d.core.protocolMode == CMEMIDIProtocolModeCME);
    printf("%s 协议模式 -> CME-USB (当前 %d)\n", protoOK ? "ok  " : "FAIL", (int)d.core.protocolMode);
    if (!protoOK) fails++;

    // 3) 输入源:点第一项,应成为选中源并真的连上
    if (d.core.sourceNames.count > 0) {
        // 第一项现在是「用 USB 直连琴」(representedObject=nil),要挑真正的端口项
        NSMenuItem *src0 = nil;
        for (NSMenuItem *it in d->_srcItem.submenu.itemArray)
            if ([it.representedObject isKindOfClass:[NSString class]]) { src0 = it; break; }
        [NSApp sendAction:src0.action to:src0.target from:src0];
        BOOL srcOK = [d.core.selectedSourceName isEqualToString:d.core.sourceNames.firstObject];
        printf("%s 选输入源 '%s'\n", srcOK ? "ok  " : "FAIL", d.core.selectedSourceName.UTF8String ?: "(nil)");
        if (!srcOK) fails++;
    } else {
        printf("skip 无输入源,跳过选择测试\n");
    }

    // 4) 走带三选一:先切「原样转发」清零,再切 Mackie,最后切回原样(端口该建该撤,不能卡死)
    NSMenuItem *mcuItem = nil, *rawItem = nil;
    for (NSMenuItem *it in d->_transportItem.submenu.itemArray) {
        if ([it.representedObject isEqualToString:@"modeMackie"]) mcuItem = it;
        if ([it.representedObject isEqualToString:@"modeRaw"])    rawItem = it;
    }
    if (mcuItem && rawItem) {
        [NSApp sendAction:rawItem.action to:rawItem.target from:rawItem];
        usleep(200000);
        BOOL off1 = (d.core.useMackieTransport == NO);
        printf("%s 走带 -> 原样转发(MCU 口应已撤) -> %d\n", off1 ? "ok  " : "FAIL", (int)d.core.useMackieTransport);
        if (!off1) fails++;

        [NSApp sendAction:mcuItem.action to:mcuItem.target from:mcuItem];
        usleep(200000);
        BOOL onOK = (d.core.useMackieTransport == YES);
        printf("%s 走带 -> Mackie Control(MCU 口应已建) -> %d\n", onOK ? "ok  " : "FAIL", (int)d.core.useMackieTransport);
        if (!onOK) fails++;

        [NSApp sendAction:rawItem.action to:rawItem.target from:rawItem];
        usleep(200000);
        BOOL off2 = (d.core.useMackieTransport == NO);
        printf("%s 再切回原样转发(未卡死) -> %d\n", off2 ? "ok  " : "FAIL", (int)d.core.useMackieTransport);
        if (!off2) fails++;
    } else {
        printf("FAIL 找不到走带模式菜单项\n");
        fails++;
    }

    // 4.5) 图标资源是否随包带上(打包漏拷时菜单栏会退回文字)
    NSImage *barIcon = [NSImage imageNamed:@"menubar"];
    BOOL iconOK = (barIcon != nil && barIcon.template && barIcon.size.width >= 16);
    printf("%s 菜单栏图标资源(menubar.png,模板图)\n", iconOK ? "ok  " : "FAIL");
    if (!iconOK) fails++;
    NSImage *appIcon = [NSImage imageNamed:NSImageNameApplicationIcon];
    printf("info 应用图标: %s\n", appIcon ? "已载入(Info.plist CFBundleIconFile)" : "未载入(非致命)");

    // 5) 退出项可用性(不真退出)
    NSMenuItem *quit = nil;
    for (NSMenuItem *it in d->_menu.itemArray) if ([it.title isEqualToString:@"退出"]) quit = it;
    BOOL quitOK = quit && quit.target && [quit.target respondsToSelector:quit.action];
    printf("%s 退出项可用\n", quitOK ? "ok  " : "FAIL");
    if (!quitOK) fails++;

    printf("=> %s (%d 项失败)\n", fails == 0 ? "PASS" : "FAIL", fails);
    return fails;
}

// ---------- RouterCoreDelegate ----------
- (void)routerDidRefreshDevices:(id)sender {
    if (![NSThread isMainThread]) { dispatch_async(dispatch_get_main_queue(), ^{ [self routerDidRefreshDevices:sender]; }); return; }
    [self rebuildSourceMenu];
    [self rebuildDestMenu];
    [self updateStatusRow];
}

// 日志先写进缓冲(最多 500 行),再刷到窗口。
// 以前「窗口没开就直接丢弃」,于是最需要看的那几条(启动/端口创建失败)永远看不到
- (void)router:(id)sender didLog:(NSString *)line {
    if (!line) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self->_logLines) self->_logLines = [NSMutableArray array];
        [self->_logLines addObject:line];
        while (self->_logLines.count > 500) [self->_logLines removeObjectAtIndex:0];
        if (self->_logView) {
            NSAttributedString *s = [[NSAttributedString alloc] initWithString:[line stringByAppendingString:@"\n"]];
            [self->_logView.textStorage appendAttributedString:s];
            [self->_logView scrollRangeToVisible:NSMakeRange(self->_logView.string.length, 0)];
        }
    });
}

@end