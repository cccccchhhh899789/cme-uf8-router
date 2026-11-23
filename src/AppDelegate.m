// AppDelegate.m — 菜单栏 App 主体
//
// 菜单结构:
//   [状态行: ● 输入源名 → 输出目标名]
//   ——
//   输入源 > (子菜单,单选,列出所有系统 MIDI 源)
//   输出目标 > (子菜单,单选,列出所有系统 MIDI 目标)
//   协议模式 > 自动识别 / CME-USB / 标准流
//   ——
//   过滤器 > CC#1 调制轮 / CC#7 音量 / 时钟 / ActiveSensing(可勾选)
//   ——
//   刷新设备
//   查看日志(面板)
//   退出

#import "AppDelegate.h"
#import "CMEMIDIProtocol.h"
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
}

- (void)setupStatusBar {
    _statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    _statusItem.button.title = @"UF8";
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

    // 过滤器
    _filterItem = [[NSMenuItem alloc] initWithTitle:@"过滤器" action:nil keyEquivalent:@""];
    [_menu addItem:_filterItem];

    // transport 键翻译(MMC/SPP -> CC),Logic 里能直接学习
    _transportItem = [[NSMenuItem alloc] initWithTitle:@"transport 键" action:nil keyEquivalent:@""];
    [_menu addItem:_transportItem];
    [_menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *refresh = [[NSMenuItem alloc] initWithTitle:@"刷新设备" action:@selector(refresh:) keyEquivalent:@"r"];
    refresh.target = self;
    [_menu addItem:refresh];

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
    NSMenuItem *legend = [[NSMenuItem alloc] initWithTitle:@"琴发的是 MMC(非 CC),这里翻成 CC 才能被 DAW 学到" action:nil keyEquivalent:@""];
    legend.enabled = NO;
    [sub addItem:legend];
    [sub addItem:[NSMenuItem separatorItem]];
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:@"MMC/SPP → CC114-119(推荐勾选)" action:@selector(toggleFilter:) keyEquivalent:@""];
    item.target = self;
    item.representedObject = @"translateMMC";
    item.state = self.core.mapper.translateMMC ? NSControlStateValueOn : NSControlStateValueOff;
    [sub addItem:item];
    NSMenuItem *mcu = [[NSMenuItem alloc] initWithTitle:@"用 Mackie Control 发 transport(Logic 装 Mackie Control 表面)" action:@selector(toggleFilter:) keyEquivalent:@""];
    mcu.target = self;
    mcu.representedObject = @"useMackie";
    mcu.state = self.core.useMackieTransport ? NSControlStateValueOn : NSControlStateValueOff;
    [sub addItem:mcu];
    NSMenuItem *mcuNote = [[NSMenuItem alloc] initWithTitle:@"  开了它:琴的键走 MCU 口,弹奏照旧从虚拟输出进 DAW" action:nil keyEquivalent:@""];
    mcuNote.enabled = NO;
    [sub addItem:mcuNote];
    [sub addItem:[NSMenuItem separatorItem]];
    NSMenuItem *note = [[NSMenuItem alloc] initWithTitle:@"不勾 = 原样发 MMC(F0 7F..)" action:nil keyEquivalent:@""];
    note.enabled = NO;
    [sub addItem:note];
    _transportItem.submenu = sub;
}

- (void)statusClicked:(id)sender {
    // 显示菜单(点状态栏图标自动弹出,这里刷新状态行)
    [self updateStatusRow];
}

- (void)updateStatusRow {
    NSString *src = self.core.selectedSourceName ?: @"(未选)";
    NSString *dst = self.core.selectedDestName ?: @"(未选)";
    NSString *proto = @"自动";
    switch (self.core.protocolMode) {
        case CMEMIDIProtocolModeCME: proto = @"CME"; break;
        case CMEMIDIProtocolModeStandard: proto = @"标准"; break;
        default: proto = @"自动"; break;
    }
    _statusItem_row.title = [NSString stringWithFormat:@"● %@ → %@ [%@]", src, dst, proto];
    _statusItem.button.title = [NSString stringWithFormat:@"UF8:%@", src.length > 6 ? [src substringToIndex:6] : src];
}

// ---------- 输入源子菜单 ----------
- (void)rebuildSourceMenu {
    NSMenu *sub = [[NSMenu alloc] init];
    for (NSString *name in self.core.sourceNames) {
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:name action:@selector(selectSource:) keyEquivalent:@""];
        item.target = self;
        item.representedObject = name;
        item.state = [name isEqualToString:self.core.selectedSourceName] ? NSControlStateValueOn : NSControlStateValueOff;
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
    self.core.selectedSourceName = sender.representedObject;
    [self updateStatusRow];
    [self rebuildSourceMenu];
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
    NSMenuItem *legend = [[NSMenuItem alloc] initWithTitle:@"勾选 = 丢弃该类消息(默认全不勾)" action:nil keyEquivalent:@""];
    legend.enabled = NO;
    [sub addItem:legend];
    [sub addItem:[NSMenuItem separatorItem]];
    NSArray *filters = @[
        @{@"title": @"过滤 CC#1 调制轮(故障源)", @"key": @"filterCC1"},
        @{@"title": @"过滤 CC#7 音量(故障源)", @"key": @"filterCC7"},
        @{@"title": @"过滤 时钟/实时消息", @"key": @"filterClock"},
        @{@"title": @"过滤 Active Sensing", @"key": @"filterSensing"},
    ];
    for (NSDictionary *f in filters) {
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:f[@"title"] action:@selector(toggleFilter:) keyEquivalent:@""];
        item.target = self;
        item.representedObject = f[@"key"];
        BOOL on = NO;
        if ([f[@"key"] isEqualToString:@"filterCC1"]) on = self.core.mapper.filterCC1;
        if ([f[@"key"] isEqualToString:@"filterCC7"]) on = self.core.mapper.filterCC7;
        if ([f[@"key"] isEqualToString:@"filterClock"]) on = self.core.mapper.filterClock;
        if ([f[@"key"] isEqualToString:@"filterSensing"]) on = self.core.mapper.filterSensing;
        item.state = on ? NSControlStateValueOn : NSControlStateValueOff;
        [sub addItem:item];
    }
    _filterItem.submenu = sub;
}

- (void)toggleFilter:(NSMenuItem *)sender {
    NSString *key = sender.representedObject;
    MIDIMapper *mapper = self.core.mapper;   // 别用空 _mapper:菜单动作必须始终有主
    if ([key isEqualToString:@"filterCC1"]) mapper.filterCC1 = !mapper.filterCC1;
    if ([key isEqualToString:@"filterCC7"]) mapper.filterCC7 = !mapper.filterCC7;
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

    // 1) 过滤器 CC#1:点一下应翻转
    NSMenuItem *cc1 = nil;
    for (NSMenuItem *it in d->_filterItem.submenu.itemArray)
        if (it.action == @selector(toggleFilter:)) { cc1 = it; break; }
    BOOL before = d.core.mapper.filterCC1;
    [NSApp sendAction:cc1.action to:cc1.target from:cc1];
    BOOL after = d.core.mapper.filterCC1;
    printf("%s 过滤器 CC#1: %d -> %d\n", before != after ? "ok  " : "FAIL", before, after);
    if (before == after) fails++;

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
        NSMenuItem *src0 = d->_srcItem.submenu.itemArray.firstObject;
        [NSApp sendAction:src0.action to:src0.target from:src0];
        BOOL srcOK = [d.core.selectedSourceName isEqualToString:d.core.sourceNames.firstObject];
        printf("%s 选输入源 '%s'\n", srcOK ? "ok  " : "FAIL", d.core.selectedSourceName.UTF8String ?: "(nil)");
        if (!srcOK) fails++;
    } else {
        printf("skip 无输入源,跳过选择测试\n");
    }

    // 4) Mackie Control 开关:点两次(on -> off),端口该建该撤,不能卡死
    NSMenuItem *mcuItem = nil;
    for (NSMenuItem *it in d->_transportItem.submenu.itemArray)
        if ([it.representedObject isEqualToString:@"useMackie"]) mcuItem = it;
    if (mcuItem) {
        BOOL before2 = d.core.useMackieTransport;
        [NSApp sendAction:mcuItem.action to:mcuItem.target from:mcuItem];
        usleep(200000);
        BOOL onOK = (d.core.useMackieTransport != before2);
        printf("%s 勾选 Mackie Control transport -> %d\n", onOK ? "ok  " : "FAIL", (int)d.core.useMackieTransport);
        if (!onOK) fails++;
        [NSApp sendAction:mcuItem.action to:mcuItem.target from:mcuItem];
        usleep(200000);
        BOOL offOK = (d.core.useMackieTransport == before2);
        printf("%s 取消勾选(端口应已撤,未卡死) -> %d\n", offOK ? "ok  " : "FAIL", (int)d.core.useMackieTransport);
        if (!offOK) fails++;
    } else {
        printf("FAIL 找不到 Mackie Control 菜单项\n");
        fails++;
    }

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

- (void)router:(id)sender didLog:(NSString *)line {
    if (_logView) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSAttributedString *s = [[NSAttributedString alloc] initWithString:[line stringByAppendingString:@"\n"]];
            [self->_logView.textStorage appendAttributedString:s];
            [self->_logView scrollRangeToVisible:NSMakeRange(self->_logView.string.length, 0)];
        });
    }
}

@end