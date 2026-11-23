// MIDIMapper.m — 映射/过滤层实现
//
// 默认映射表(来源:复刻规格书.md §3,官方 2006 readme):
//   RTZ->115  REW->116  FF->117  REC->114  STOP->118  PLAY->119
//   M.VOLUME(CC7)CH1
// 过滤默认:全部关闭(原样直通)。需要丢弃故障消息时在菜单里勾选。
// 全部可配置,存 ~/Library/Application Support/cme-uf8-router/midi-map.plist。

#import "MIDIMapper.h"

@implementation MIDIMapper {
    NSInteger _lastSPP;            // 上一次 Song Position Pointer 值(判断 REW/FF 方向)
    CFTimeInterval _lastMMCTime;   // 收到上一条 MMC 的时刻(用于吞掉紧跟其后的 SPP)
}

- (instancetype)init {
    if ((self = [super init])) {
        // 默认不过滤:接进来什么就送出去什么(用户要勾才丢)
        _filterCC1 = NO;
        _filterCC7 = NO;
        _filterClock = NO;
        _filterSensing = NO;
        _translateMMC = YES;
        _lastSPP = -1;
        // 默认 transport 映射(源 CC -> 目标 CC)
        _transportMap = @{
            @(114): @(114), // REC
            @(115): @(115), // RTZ
            @(116): @(116), // REW
            @(117): @(117), // FF
            @(118): @(118), // STOP
            @(119): @(119), // PLAY
        };
        [self loadConfig];
    }
    return self;
}

// 判定一条消息是不是 transport 事件
// 返回 1=RTZ 2=REW 3=FF 4=REC 5=STOP 6=PLAY,0=不是
- (NSInteger)transportKeyForMessage:(NSData *)msg {
    const uint8_t *b = msg.bytes;
    NSUInteger len = msg.length;
    if (len == 0) return 0;

    // MMC:F0 7F <id> 06 <cmd> F7
    if (len >= 6 && b[0] == 0xF0 && b[1] == 0x7F && b[3] == 0x06 && b[len-1] == 0xF7) {
        NSInteger key = 0;
        switch (b[4]) {
            case 0x01: key = 5; break;  // Stop
            case 0x02: key = 6; break;  // Play
            case 0x03: key = 6; break;  // Deferred Play
            case 0x04: key = 3; break;  // Fast Forward
            case 0x05: key = 2; break;  // Rewind
            case 0x06: key = 4; break;  // Record Strobe
            // Record Exit(0x07)不是「停止」:它是录音状态的收尾,映射成 STOP 会让
            // 「按一次 REC」在 DAW 里先录音再停住。这里直接忽略
            case 0x07: key = 0; break;
            default: key = 0; break;
        }
        if (key) _lastMMCTime = CFAbsoluteTimeGetCurrent();
        return key;
    }
    // SPP:F2 lsb msb
    if (len == 3 && b[0] == 0xF2) {
        // 琴在发完 MMC 后约 3ms 会补一条 SPP(报告当前位置)。
        // 那条 SPP 的值通常等于 _lastSPP,下面的方向判断会自然返回 0(忽略);
        // 这里额外兜一层:紧跟在 MMC 之后(150ms 内)且数值没变的 SPP 直接吞掉。
        NSInteger v = (NSInteger)(b[1] | (b[2] << 7));
        NSInteger key = 0;
        BOOL justAfterMMC = (CFAbsoluteTimeGetCurrent() - _lastMMCTime < 0.15);
        if (justAfterMMC && v == _lastSPP) { key = 0; }     // MMC 后附带的当前位置报告
        else if (v == 0) key = 1;                          // RTZ(琴在 0 位时 RTZ 和 REW 发的都是 F2 00 00)
        // 第一次收到 SPP 时不知道基准位置:位置非 0 就当「往后」,
        // 否则 App 刚启动那一下按 >> 什么都不会发生(踩过)。
        else if (_lastSPP < 0) key = 3;
        else if (v > _lastSPP) key = 3;                    // FF
        else if (v < _lastSPP) key = 2;                    // REW
        _lastSPP = v;
        return key;
    }
    // 实时:FA Start / FB Continue / FC Stop
    if (len == 1) {
        if (b[0] == 0xFA || b[0] == 0xFB) return 6;
        if (b[0] == 0xFC) return 5;
    }
    return 0;
}

// transport 事件 -> 默认 CC 编号(CME 2006 文档的号)
- (NSInteger)ccForTransportKey:(NSInteger)key {
    switch (key) {
        case 1: return 115; // RTZ
        case 2: return 116; // REW
        case 3: return 117; // FF
        case 4: return 114; // REC
        case 5: return 118; // STOP
        case 6: return 119; // PLAY
        default: return 0;
    }
}

// Mackie Control:transport 事件 -> MCU 按键(Note On CH1,按下 0x7F / 松开 0x00)
- (NSArray<NSData *> *)mcuMessagesForKey:(NSInteger)key {
    // 走带「前后一格」用 Jog 轮(CC 0x3C)而不是 FF/REW 按键(0x5B/0x5C):
    // FF/REW 在 Logic 里收到按下就开始连续快进,而它对随后那条松开消息
    // 完全无反应(实测 82ms/157ms/253ms/3s 全都不停,只有 STOP 能停),
    // 所以「按住-松开」这条路在这个 DAW 上根本不成立。
    // Jog 轮是一格一条消息,天然没有按下/松开状态机,一次 = 一小节。
    // 0x01 = 顺时针 +1(向右/向后),0x41 = 逆时针 -1(向左/向前)。
    uint8_t jogFwd[3] = { 0xB0, 0x3C, 0x01 };
    uint8_t jogBack[3] = { 0xB0, 0x3C, 0x41 };
    switch (key) {
        case 1: return @[[NSData dataWithBytes:jogBack length:3]]; // RTZ -> 向左一小节
        case 2: return @[[NSData dataWithBytes:jogBack length:3]]; // REWIND
        case 3: return @[[NSData dataWithBytes:jogFwd length:3]];  // FAST FWD
        default: break;
    }
    uint8_t note = 0;
    switch (key) {
        case 4: note = 0x5F; break; // RECORD
        case 5: note = 0x5D; break; // STOP
        case 6: note = 0x5E; break; // PLAY
        default: return @[];
    }
    uint8_t on[3]  = { 0x90, note, 0x7F };
    uint8_t off[3] = { 0x90, note, 0x00 };
    return @[[NSData dataWithBytes:on length:3], [NSData dataWithBytes:off length:3]];
}

- (NSArray<NSData *> *)mcuMessagesFor:(NSData *)msg {
    // 注意:transportKeyForMessage: 会更新 _lastSPP/_lastMMCTime。
    // 调用方若已经算过 key,必须用 mcuMessagesForKey:,否则第二次调用会
    // 因为 _lastSPP 已被更新而算成 key=0(SPP 方向判断直接失效)。
    return [self mcuMessagesForKey:[self transportKeyForMessage:msg]];
}

- (NSArray<NSData *> *)processMessage:(NSData *)msg {
    const uint8_t *b = msg.bytes;
    NSUInteger len = msg.length;
    if (len == 0) return @[];

    // 单字节实时:ActiveSensing / 时钟单独处理;FA FB FC 交给 transport 判定
    if (len == 1) {
        uint8_t s = b[0];
        if (s == 0xFE) { if (_filterSensing) return @[]; return @[msg]; }
        if (s >= 0xF8 && s != 0xFA && s != 0xFB && s != 0xFC) {
            if (_filterClock) return @[];
            return @[msg];
        }
    }

    // transport 事件(MMC sysex / SPP / 实时 FA FC)
    NSInteger key = [self transportKeyForMessage:msg];
    if (key > 0) {
        if (!_translateMMC || _runtimeMuteCC) return @[msg];   // 不翻译:原样转发 MMC/SPP
        NSInteger cc = [self ccForTransportKey:key];
        if (cc > 0) {
            // 成对发「按下 127 + 松开 0」:很多 DAW/插件只在值「变化」时触发,
            // 每次都是 127 等于没变化,第二次按就没反应
            uint8_t on[3]  = { 0xB0, (uint8_t)cc, 0x7F };
            uint8_t off[3] = { 0xB0, (uint8_t)cc, 0x00 };
            return @[[NSData dataWithBytes:on length:3], [NSData dataWithBytes:off length:3]];
        }
        return @[msg];
    }

    // CC 消息(B0 ch CC val)
    if (len >= 3 && (b[0] & 0xF0) == 0xB0) {
        uint8_t ch = b[0] & 0x0F;
        uint8_t cc = b[1];
        uint8_t val = b[2];
        // 过滤
        if (cc == 1 && _filterCC1) return @[];
        if (cc == 7 && _filterCC7) return @[];
        // transport 映射(仅 CH1 或全通道?)
        NSNumber *target = _transportMap[@(cc)];
        if (target && ch == 0) {
            uint8_t out[3] = { 0xB0, (uint8_t)target.unsignedIntValue, val };
            return @[[NSData dataWithBytes:out length:3]];
        }
        // 放行其余 CC
        return @[msg];
    }

    // 其余消息原样放行(Note/PB/Program/Aftertouch/SysEx…)
    return @[msg];
}

// ---------- 配置持久化 ----------
- (NSString *)configPath {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,
                                                         NSUserDomainMask, YES);
    NSString *base = paths.firstObject;
    if (!base) return nil;   // 极端情况下没有 Application Support:返回 nil,调用方要判空,
                             // 否则 writeToFile:nil 会抛 NSInvalidArgumentException(直接崩)
    NSString *dir = [base stringByAppendingPathComponent:@"cme-uf8-router"];
    if (!dir) return nil;
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:dir]) {
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
    }
    return [dir stringByAppendingPathComponent:@"midi-map.plist"];
}

// 只在真的变了才写盘:refreshDevices 会被热插拔频繁触发,每次都写文件既慢又会和
// 另一个实例互相覆盖
- (void)setLastSourceIfNeeded:(NSString *)name {
    if (!name) return;
    if ([_lastSource isEqualToString:name]) return;
    _lastSource = [name copy];
    [self saveConfig];
}

- (void)setLastDestIfNeeded:(NSString *)name {
    if (!name) return;
    if ([_lastDest isEqualToString:name]) return;
    _lastDest = [name copy];
    [self saveConfig];
}

- (void)loadConfig {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:self.configPath];
    if (!d) { [self saveConfig]; return; }
    if (![d[@"configVersion"] isEqual:@(1)]) {
        // 0.1.4 及更早版本的 plist 里,translateMMC 会被 MCU 模式连带写成 NO,
        // 那不是用户的选择 —— 见到没有版本号的老文件就恢复默认(翻译开),再按新格式存一遍。
        // 但输入/输出记忆要照常读回来,否则升级后第一次启动会「忘记上次选的设备」
        if ([d[@"lastSource"] isKindOfClass:[NSString class]]) _lastSource = d[@"lastSource"];
        if ([d[@"lastDest"] isKindOfClass:[NSString class]])   _lastDest   = d[@"lastDest"];
        if (d[@"useMackie"]) _useMackie = [d[@"useMackie"] boolValue];
        _translateMMC = YES;
        [self saveConfig];
        return;
    }
    if (d[@"filterCC1"])     _filterCC1   = [d[@"filterCC1"] boolValue];
    if (d[@"filterCC7"])     _filterCC7   = [d[@"filterCC7"] boolValue];
    if (d[@"filterClock"])   _filterClock = [d[@"filterClock"] boolValue];
    if (d[@"filterSensing"]) _filterSensing = [d[@"filterSensing"] boolValue];
    // 只有用户显式在菜单里关掉才算关(老版本会把 MCU 模式的副作用写进来,不能信)
    if (d[@"translateMMCOffByUser"]) _translateMMC = ![d[@"translateMMCOffByUser"] boolValue];
    if (d[@"useMackie"]) _useMackie = [d[@"useMackie"] boolValue];
    if ([d[@"lastSource"] isKindOfClass:[NSString class]]) _lastSource = d[@"lastSource"];
    if ([d[@"lastDest"] isKindOfClass:[NSString class]])     _lastDest   = d[@"lastDest"];
    if (d[@"transportMap"] && [d[@"transportMap"] isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *map = [NSMutableDictionary dictionary];
        for (NSString *k in d[@"transportMap"]) {
            map[@(k.intValue)] = @([d[@"transportMap"][k] intValue]);
        }
        if (map.count) _transportMap = map;
    }
}

- (void)saveConfig {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"configVersion"] = @(1);
    d[@"filterCC1"]     = @(_filterCC1);
    d[@"filterCC7"]     = @(_filterCC7);
    d[@"filterClock"]   = @(_filterClock);
    d[@"filterSensing"] = @(_filterSensing);
    d[@"translateMMC"]  = @(_translateMMC);
    d[@"translateMMCOffByUser"] = @(!_translateMMC);
    d[@"useMackie"] = @(_useMackie);
    if (_lastSource) d[@"lastSource"] = _lastSource;
    if (_lastDest)   d[@"lastDest"]   = _lastDest;
    NSMutableDictionary *map = [NSMutableDictionary dictionary];
    for (NSNumber *k in _transportMap) map[k.stringValue] = _transportMap[k];
    d[@"transportMap"] = map;
    NSString *path = self.configPath;
    if (!path) { NSLog(@"[cme-uf8-router] 没有配置目录,设置无法保存"); return; }
    NSError *err = nil;
    if (![d writeToFile:path atomically:YES]) { }   // 占位,下面统一报错
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        NSLog(@"[cme-uf8-router] 配置保存失败: %@", err.localizedDescription ?: @"(未知原因)");
    }
}

@end