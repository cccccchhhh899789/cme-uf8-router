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
            case 0x07: key = 5; break;  // Record Exit
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
        else if (_lastSPP >= 0 && v > _lastSPP) key = 3;   // FF
        else if (_lastSPP >= 0 && v < _lastSPP) key = 2;   // REW
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
- (NSArray<NSData *> *)mcuMessagesFor:(NSData *)msg {
    NSInteger key = [self transportKeyForMessage:msg];
    if (key <= 0) return @[];
    uint8_t note = 0;
    switch (key) {
        case 1: note = 0x5B; break; // RTZ -> 也用 REWIND(MCU 没有「回到起点」键,F1 在 Logic 里默认没绑定)
        case 2: note = 0x5B; break; // REWIND
        case 3: note = 0x5C; break; // FAST FWD
        case 4: note = 0x5F; break; // RECORD
        case 5: note = 0x5D; break; // STOP
        case 6: note = 0x5E; break; // PLAY
        default: return @[];
    }
    uint8_t on[3]  = { 0x90, note, 0x7F };
    uint8_t off[3] = { 0x90, note, 0x00 };
    return @[[NSData dataWithBytes:on length:3], [NSData dataWithBytes:off length:3]];
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
            uint8_t out[3] = { 0xB0, (uint8_t)cc, 0x7F };
            return @[[NSData dataWithBytes:out length:3]];
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
    NSString *dir = [paths.firstObject stringByAppendingPathComponent:@"cme-uf8-router"];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:dir]) [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
    return [dir stringByAppendingPathComponent:@"midi-map.plist"];
}

- (void)loadConfig {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:self.configPath];
    if (!d) { [self saveConfig]; return; }
    if (![d[@"configVersion"] isEqual:@(1)]) {
        // 0.1.4 及更早版本的 plist 里,translateMMC 会被 MCU 模式连带写成 NO,
        // 那不是用户的选择 —— 见到没有版本号的老文件就恢复默认(翻译开),再按新格式存一遍。
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
    [d writeToFile:self.configPath atomically:YES];
}

@end