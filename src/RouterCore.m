// RouterCore.m — CoreMIDI 路由核心实现

#import "RouterCore.h"
#import <CoreMIDI/CoreMIDI.h>

// 回调上下文
typedef struct {
    __unsafe_unretained RouterCore *core;
} RouterCoreCallbackCtx;

static void mcuReadProc(const MIDIPacketList *pktlist, void *refCon, void *connRefCon);

@implementation RouterCore {
    MIDIClientRef _client;
    MIDIPortRef _inputPort;
    MIDIPortRef _outputPort;
    MIDIEndpointRef _virtualSource;   // 本 App 自己发的虚拟 MIDI 源(给 DAW 读)
    MIDIEndpointRef _mcuSource;       // Mackie Control 输出口(Logic 控制表面读它)
    MIDIEndpointRef _mcuDest;         // Mackie Control 输入口(Logic 把反馈发到这里)
    RouterCoreCallbackCtx _readCtx;
    dispatch_queue_t _midiQueue;
    BOOL _running;
    NSMutableArray<NSString *> *_sourceNames;
    NSMutableArray<NSString *> *_destNames;
    NSMutableDictionary<NSString *, NSNumber *> *_sourceIndex; // name -> endpoint index
    NSMutableDictionary<NSString *, NSNumber *> *_destIndex;
    NSMutableData *_sysexBuf;   // 跨包不完整的 sysex 缓冲区(U2MIDI Pro 会把 sysex 拆成多包)
    uint8_t _lastMCUNote;       // 上一发出去的 MCU 按键(按住连发去重用)
    CFTimeInterval _lastMCUNoteTime;
}

@synthesize mapper = _mapper;

- (instancetype)init {
    if ((self = [super init])) {
        _mapper = [[MIDIMapper alloc] init];
        _protocolMode = CMEMIDIProtocolModeAuto;
        _sourceNames = [NSMutableArray array];
        _destNames = [NSMutableArray array];
        _sourceIndex = [NSMutableDictionary dictionary];
        _destIndex = [NSMutableDictionary dictionary];
        _midiQueue = dispatch_queue_create("cme-uf8-router.midi", DISPATCH_QUEUE_SERIAL);
        _readCtx.core = self;
    }
    return self;
}

#pragma mark - 枚举


// 端点显示名:端口名 + 所属设备名(如 "Port 1 — U2MIDI Pro"),方便认出是哪台琴
static NSString *CMEEndpointDisplayName(MIDIEndpointRef ep, ItemCount i, NSString *fallbackPrefix) {
    CFStringRef nm = NULL, dev = NULL;
    MIDIObjectGetStringProperty(ep, kMIDIPropertyName, &nm);
    MIDIEntityRef ent = 0;
    MIDIEndpointGetEntity(ep, &ent);
    if (ent) {
        MIDIDeviceRef d = 0;
        MIDIEntityGetDevice(ent, &d);
        if (d) MIDIObjectGetStringProperty(d, kMIDIPropertyName, &dev);
    }
    NSString *port = nm ? (__bridge_transfer NSString *)nm : [NSString stringWithFormat:@"%@ %lu", fallbackPrefix, (unsigned long)i];
    NSString *device = dev ? (__bridge_transfer NSString *)dev : nil;
    if (device.length && ![device isEqualToString:port]) {
        return [NSString stringWithFormat:@"%@ — %@", port, device];
    }
    return port;
}

- (void)refreshDevices {
    [_sourceNames removeAllObjects];
    [_destNames removeAllObjects];
    [_sourceIndex removeAllObjects];
    [_destIndex removeAllObjects];

    ItemCount srcCount = MIDIGetNumberOfSources();
    for (ItemCount i = 0; i < srcCount; i++) {
        MIDIEndpointRef ep = MIDIGetSource(i);
        if (_virtualSource && ep == _virtualSource) continue;   // 别把自己的虚拟口当输入(会成环)
        NSString *n = CMEEndpointDisplayName(ep, i, @"源");
        NSString *unique = [self uniqueName:n in:_sourceNames];
        [_sourceNames addObject:unique];
        _sourceIndex[unique] = @(i);
    }
    // 虚拟输出永远排第一(默认),DAW 选它当输入即可
    if (_virtualSource) {
        NSString *vname = @"CME UF8 Router (虚拟输出 → 给 DAW 用)";
        [_destNames addObject:vname];
        _destIndex[vname] = @(-1);
    }
    ItemCount dstCount = MIDIGetNumberOfDestinations();
    for (ItemCount i = 0; i < dstCount; i++) {
        MIDIEndpointRef ep = MIDIGetDestination(i);
        if (_mcuDest && ep == _mcuDest) continue;   // 自己的 MCU 输入口,不当普通目标
        NSString *n = CMEEndpointDisplayName(ep, i, @"目标");
        NSString *unique = [self uniqueName:n in:_destNames];
        [_destNames addObject:unique];
        _destIndex[unique] = @(i);
    }

    // 选择失效则清空;只有一个源时自动选上(接管设备不用先点菜单)
    if (_selectedSourceName && !_sourceIndex[_selectedSourceName]) _selectedSourceName = nil;
    if (_selectedDestName && !_destIndex[_selectedDestName]) _selectedDestName = nil;
    if (!_selectedSourceName && _sourceNames.count == 1) {
        _selectedSourceName = _sourceNames.firstObject;
        [self log:[NSString stringWithFormat:@"自动选中唯一输入源: %@", _selectedSourceName]];
    }
    if (!_selectedDestName) {
        // 默认输出 = 虚拟端口(DAW 直接选 "CME UF8 Router" 当输入)
        NSString *vname = nil;
        for (NSString *n in _destNames) if ([n hasPrefix:@"CME UF8 Router"]) { vname = n; break; }
        if (vname) {
            _selectedDestName = vname;
            [self log:[NSString stringWithFormat:@"默认输出: %@", vname]];
        } else if (_destNames.count == 1) {
            _selectedDestName = _destNames.firstObject;
            [self log:[NSString stringWithFormat:@"自动选中唯一输出目标: %@", _selectedDestName]];
        }
    }
    [self log:[NSString stringWithFormat:@"枚举: %lu 个输入源, %lu 个输出目标",
               (unsigned long)srcCount, (unsigned long)dstCount]];

    [self reconnectInputForSelected];
    [self.delegate routerDidRefreshDevices:self];
}

// 同名端点(如两个 "Port 1")加序号区分,避免字典键冲突
- (NSString *)uniqueName:(NSString *)base in:(NSArray<NSString *> *)existing {
    if (![existing containsObject:base]) return base;
    NSInteger k = 2;
    NSString *cand;
    do { cand = [NSString stringWithFormat:@"%@ (%ld)", base, (long)k++]; } while ([existing containsObject:cand]);
    return cand;
}

// 选中的源/目标在端点上设置 refcon,回调里通过它取回
- (void)start {
    if (_running) return;
    OSStatus st = MIDIClientCreate(CFSTR("cme-uf8-router"), midiNotifyProc, (__bridge void *)self, &_client);
    if (st != noErr) { [self log:[NSString stringWithFormat:@"MIDIClientCreate 失败 %d", (int)st]]; return; }
    // 建一个虚拟 MIDI 源:别的 App(DAW)在输入里能选到 "CME UF8 Router"
    if (!_virtualSource) {
        OSStatus vs = MIDISourceCreate(_client, CFSTR("CME UF8 Router"), &_virtualSource);
        if (vs != noErr) [self log:[NSString stringWithFormat:@"虚拟端口创建失败 %d", (int)vs]];
        else {
            CFStringRef man = CFSTR("cme-uf8-router");
            MIDIObjectSetStringProperty(_virtualSource, kMIDIPropertyManufacturer, man);
            MIDIObjectSetStringProperty(_virtualSource, kMIDIPropertyModel, CFSTR("UF8"));
            [self log:@"已创建虚拟输出端口: CME UF8 Router"];
        }
    }
    st = MIDIInputPortCreate(_client, CFSTR("input"), midiReadProc, &_readCtx, &_inputPort);
    if (st != noErr) { [self log:[NSString stringWithFormat:@"MIDIInputPortCreate 失败 %d", (int)st]]; return; }
    st = MIDIOutputPortCreate(_client, CFSTR("output"), &_outputPort);
    if (st != noErr) { [self log:[NSString stringWithFormat:@"MIDIOutputPortCreate 失败 %d", (int)st]]; return; }
    _running = YES;
    [self refreshDevices];
    [self reconnectInputForSelected];   // 只连接选中的源(默认无选择 = 什么都不接)
    // 恢复上次选的输入/输出(名字还在就自动接上,免得每次重启都要手动选)
    if (_mapper.lastSource && [_sourceNames containsObject:_mapper.lastSource]) {
        _selectedSourceName = _mapper.lastSource;
        [self reconnectInputForSelected];
        [self log:[NSString stringWithFormat:@"已恢复输入源: %@", _mapper.lastSource]];
    }
    if (_mapper.lastDest && [_destNames containsObject:_mapper.lastDest]) {
        _selectedDestName = _mapper.lastDest;
        [self log:[NSString stringWithFormat:@"已恢复输出目标: %@", _mapper.lastDest]];
    }
    if (_mapper.useMackie && !_useMackieTransport) [self setUseMackieTransport:YES];  // 恢复上次的选择
    [self log:@"已启动(请从菜单选择输入源)"];
}

- (void)connectInput {
    if (!_inputPort) return;
    ItemCount srcCount = MIDIGetNumberOfSources();
    for (ItemCount i = 0; i < srcCount; i++) {
        MIDIEndpointRef ep = MIDIGetSource(i);
        MIDIPortConnectSource(_inputPort, ep, NULL);
    }
}

- (void)stop {
    if (!_running) return;
    if (_inputPort) { MIDIPortDispose(_inputPort); _inputPort = 0; }
    if (_outputPort) { MIDIPortDispose(_outputPort); _outputPort = 0; }
    [self teardownMCUEndpoints];
    if (_virtualSource) { MIDIEndpointDispose(_virtualSource); _virtualSource = 0; }
    if (_client) { MIDIClientDispose(_client); _client = 0; }
    _running = NO;
    [self log:@"已停止"];
}

#pragma mark - 回调

static void midiNotifyProc(const MIDINotification *msg, void *refCon) {
    RouterCore *core = (__bridge RouterCore *)refCon;
    switch (msg->messageID) {
        case kMIDIMsgSetupChanged:
        case kMIDIMsgObjectAdded:
        case kMIDIMsgObjectRemoved:
            [core refreshDevices];
            [core log:@"设备列表已刷新"];
            break;
        default: break;
    }
}

static void midiReadProc(const MIDIPacketList *pktlist, void *readProcRefCon, void *srcConnRefCon) {
    RouterCoreCallbackCtx *ctx = (RouterCoreCallbackCtx *)readProcRefCon;
    RouterCore *core = ctx->core;
    [core handleIncoming:pktlist];
}

// 原始报文落盘:~ /Library/Application Support/cme-uf8-router/raw-capture.log
- (void)captureRaw:(const uint8_t *)bytes length:(NSUInteger)len {
    if (len == 0) return;
    static NSString *path = nil;
    static NSFileHandle *fh = nil;
    if (!path) {
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES);
        NSString *dir = [paths.firstObject stringByAppendingPathComponent:@"cme-uf8-router"];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
        path = [dir stringByAppendingPathComponent:@"raw-capture.log"];
        fh = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!fh) { [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
                   fh = [NSFileHandle fileHandleForWritingAtPath:path]; }
        [fh seekToEndOfFile];
    }
    NSMutableString *hex = [NSMutableString string];
    for (NSUInteger i = 0; i < len; i++) [hex appendFormat:@"%02X ", bytes[i]];
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"HH:mm:ss.SSS";
    NSString *line = [NSString stringWithFormat:@"%@ [%lu] %@\n", [df stringFromDate:[NSDate date]], (unsigned long)len, hex];
    @try { [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; } @catch (NSException *e) { }
}

// 解码一包,并把跨包不完整的 sysex 拼起来
- (NSArray<NSData *> *)decodePacket:(const uint8_t *)data length:(NSUInteger)len {
    NSMutableData *buf = [NSMutableData data];
    if (_sysexBuf.length) { [buf appendData:_sysexBuf]; [_sysexBuf setLength:0]; }
    [buf appendBytes:data length:len];

    NSArray<NSData *> *msgs = [CMEMIDIProtocol decodeBytes:buf.bytes
                                                    length:buf.length
                                                      mode:_protocolMode
                                             sniffedToCME:NULL];
    NSMutableArray<NSData *> *out = [NSMutableArray array];
    for (NSData *m in msgs) {
        if (m.length == 0) continue;
        const uint8_t *p = m.bytes;
        if (p[0] == 0xF0 && p[m.length - 1] != 0xF7) {
            // 还没收到 F7:暂存,等后续包拼完整
            if (!_sysexBuf) _sysexBuf = [NSMutableData data];
            [_sysexBuf appendData:m];
            continue;
        }
        [out addObject:m];
    }
    return out;
}

- (void)handleIncoming:(const MIDIPacketList *)pktlist {
    // 只处理选择的源:无法直接知道来源,改为在 connectInput 时只连选中的源
    MIDIPacket *packet = (MIDIPacket *)pktlist->packet;
    for (UInt32 i = 0; i < pktlist->numPackets; i++) {
        [self captureRaw:packet->data length:packet->length];
        NSArray<NSData *> *msgs = [self decodePacket:packet->data length:packet->length];
        for (NSData *m in msgs) {
            if (_useMackieTransport) {
                // transport 键走 MCU 口(控制表面),不再混进输出目标,避免误触 Logic 按键
                NSArray<NSData *> *mcu = [_mapper mcuMessagesFor:m];
                if (mcu.count) {
                    for (NSData *out in mcu) [self sendToMCUSource:out];
                    continue;
                }
            }
            NSArray<NSData *> *outMsgs = [_mapper processMessage:m];
            for (NSData *out in outMsgs) {
                [self sendToSelectedDest:out];
            }
        }
        packet = MIDIPacketNext(packet);
    }
}

// Mackie Control 端口对只在「勾了 MCU transport」时存在,避免平时多出两个口干扰
- (void)ensureMCUEndpoints {
    if (!_client) return;
    if (!_mcuSource) {
        OSStatus ms = MIDISourceCreate(_client, CFSTR("CME UF8 Router MCU"), &_mcuSource);
        if (ms == noErr) {
            MIDIObjectSetStringProperty(_mcuSource, kMIDIPropertyManufacturer, CFSTR("cme-uf8-router"));
            MIDIObjectSetStringProperty(_mcuSource, kMIDIPropertyModel, CFSTR("Mackie Control"));
            [self log:@"已创建 Mackie Control 输出口: CME UF8 Router MCU"];
        } else {
            [self log:[NSString stringWithFormat:@"MCU 输出口创建失败 %d", (int)ms]];
        }
    }
    if (!_mcuDest) {
        OSStatus md = MIDIDestinationCreate(_client, CFSTR("CME UF8 Router MCU"), mcuReadProc, (__bridge void *)self, &_mcuDest);
        if (md == noErr) {
            MIDIObjectSetStringProperty(_mcuDest, kMIDIPropertyManufacturer, CFSTR("cme-uf8-router"));
            MIDIObjectSetStringProperty(_mcuDest, kMIDIPropertyModel, CFSTR("Mackie Control"));
            [self log:@"已创建 Mackie Control 输入口: CME UF8 Router MCU"];
        } else {
            [self log:[NSString stringWithFormat:@"MCU 输入口创建失败 %d", (int)md]];
        }
    }
}

- (void)teardownMCUEndpoints {
    if (_mcuDest) { MIDIEndpointDispose(_mcuDest); _mcuDest = 0; }
    if (_mcuSource) { MIDIEndpointDispose(_mcuSource); _mcuSource = 0; }
}

- (void)sendMCUDeviceReady {
    // 主机唤醒 F0 00 00 66 14 00 F7 -> 设备回 Device Ready F0 00 00 66 14 01 F7
    if (!_mcuSource) return;
    const uint8_t ready[7] = { 0xF0, 0x00, 0x00, 0x66, 0x14, 0x01, 0xF7 };
    MIDIPacketList pktlist;
    MIDIPacket *pkt = MIDIPacketListInit(&pktlist);
    MIDIPacketListAdd(&pktlist, sizeof(pktlist), pkt, 0, 7, ready);
    MIDIReceived(_mcuSource, &pktlist);
}

- (void)setUseMackieTransport:(BOOL)on {
    _useMackieTransport = on;
    if (_mapper.useMackie != on) { _mapper.useMackie = on; [_mapper saveConfig]; }
    if (on) {
        [self ensureMCUEndpoints];
        [self log:@"transport 改走 Mackie Control: CME UF8 Router MCU(Logic 里装 Mackie Control 表面)"];
        [self sendMCUDeviceReady];
        _mapper.runtimeMuteCC = YES;   // 只在本次运行静音 CC 翻译,不动用户设置
    } else {
        [self teardownMCUEndpoints];
        _mapper.runtimeMuteCC = NO;   // 恢复 CC114-119 翻译
        [self log:@"transport 不再走 Mackie Control(多余端口已撤),恢复 MMC→CC 翻译"];
    }
    [self refreshDevices];
}

- (void)setSelectedDestName:(NSString *)name {
    _selectedDestName = [name copy];
    if (name && ![_mapper.lastDest isEqualToString:name]) {
        _mapper.lastDest = name; [_mapper saveConfig];
    }
}

// transport 键专用出口:Mackie Control 虚拟源(DAW 当控制表面输入)
- (void)sendToMCUSource:(NSData *)msg {
    if (!_mcuSource) { [self log:@"MCU 端口不存在,transport 键丢弃"]; return; }
    // 按住走带键时琴会连发同样的报文,250ms 内的同一个按键只发一次,避免在 DAW 里疯狂步进
    if (msg.length == 3 && ((const uint8_t *)msg.bytes)[0] == 0x90) {
        uint8_t note = ((const uint8_t *)msg.bytes)[1];
        uint8_t vel  = ((const uint8_t *)msg.bytes)[2];
        CFTimeInterval now = CFAbsoluteTimeGetCurrent();
        // 只挡「连发的按下」(按住键时琴会重复发),松开(vel=0)必须原样送出去,
        // 否则 Logic 里按键会一直停在「按下」状态,后面再按就对不上了
        if (vel != 0 && note == _lastMCUNote && now - _lastMCUNoteTime < 0.25) return;
        if (vel != 0) { _lastMCUNote = note; _lastMCUNoteTime = now; }
    }
    MIDIPacketList pktlist;
    MIDIPacket *pkt = MIDIPacketListInit(&pktlist);
    if (!MIDIPacketListAdd(&pktlist, sizeof(pktlist), pkt, 0, (ByteCount)msg.length, msg.bytes)) return;
    MIDIReceived(_mcuSource, &pktlist);
}

- (void)sendToSelectedDest:(NSData *)msg {
    if (!_selectedDestName) return;
    NSNumber *idx = _destIndex[_selectedDestName];
    if (!idx) return;
    MIDIPacketList pktlist;
    MIDIPacket *pkt = MIDIPacketListInit(&pktlist);
    MIDIPacketListAdd(&pktlist, sizeof(pktlist), pkt, 0, (ByteCount)msg.length, msg.bytes);
    if (idx.integerValue == -2) {
        if (_mcuSource) MIDIReceived(_mcuSource, &pktlist);
        return;
    }
    if (idx.integerValue == -1) {
        // 虚拟输出:喂给自己的虚拟源,系统里所有客户端(DAW)都能收到
        if (_virtualSource) MIDIReceived(_virtualSource, &pktlist);
        return;
    }
    if (!_outputPort) return;
    MIDIEndpointRef dest = MIDIGetDestination((ItemCount)idx.unsignedIntValue);
    if (!dest) return;
    MIDISend(_outputPort, dest, &pktlist);
}

// 只在选中的源上连接(避免串流其他源)
- (void)setSelectedSourceName:(NSString *)sourceName {
    _selectedSourceName = [sourceName copy];
    [self reconnectInputForSelected];
    if (sourceName && ![_mapper.lastSource isEqualToString:sourceName]) {
        _mapper.lastSource = sourceName; [_mapper saveConfig];
    }
}

- (void)reconnectInputForSelected {
    if (!_inputPort) return;
    // 断开所有,连接选中的
    ItemCount srcCount = MIDIGetNumberOfSources();
    for (ItemCount i = 0; i < srcCount; i++) {
        MIDIEndpointRef ep = MIDIGetSource(i);
        MIDIPortDisconnectSource(_inputPort, ep);
    }
    if (_selectedSourceName && _sourceIndex[_selectedSourceName]) {
        ItemCount idx = _sourceIndex[_selectedSourceName].unsignedIntValue;
        MIDIEndpointRef ep = MIDIGetSource(idx);
        if (ep) {
            MIDIPortConnectSource(_inputPort, ep, NULL);
            [self log:[NSString stringWithFormat:@"输入源: %@", _selectedSourceName]];
        }
    }
}

#pragma mark - 日志

- (void)log:(NSString *)line {
    [self.delegate router:self didLog:line];
}


#pragma mark - 路由端到端自检(虚拟源→虚拟目标,不碰真设备)

typedef struct {
    volatile int got;
    uint8_t bytes[16];
    int len;
    uint8_t want;      // 只收首字节等于它的包(0=全都收)
} CMERouteProbe;

static void routeProbeProc(const MIDIPacketList *pktlist, void *refCon, void *connRefCon) {
    CMERouteProbe *probe = (CMERouteProbe *)refCon;
    if (pktlist->numPackets < 1) return;
    const MIDIPacket *p = &pktlist->packet[0];
    if (probe->want && p->length > 0 && p->data[0] != probe->want) return;   // 只收指定状态字节
    probe->len = (int)p->length;
    if (probe->len > 16) probe->len = 16;
    memcpy(probe->bytes, p->data, probe->len);
    probe->got = 1;
}

+ (void)runRouteSelfTest {
    printf("=== 路由端到端自检(虚拟 MIDI 源 → 虚拟 MIDI 目标) ===\n");
    MIDIClientRef client = 0;
    MIDISourceCreate(client, CFSTR("x"), NULL); // 占位避免未用告警
    OSStatus st = MIDIClientCreate(CFSTR("cme-uf8-router-test"), NULL, NULL, &client);
    if (st != noErr) { printf("FAIL MIDIClientCreate %d\n", (int)st); return; }

    MIDIEndpointRef testSrc = 0, testDst = 0;
    st = MIDISourceCreate(client, CFSTR("CME-Test-Src"), &testSrc);
    if (st != noErr) { printf("FAIL MIDISourceCreate %d\n", (int)st); return; }
    static CMERouteProbe probe;
    memset(&probe, 0, sizeof probe);
    st = MIDIDestinationCreate(client, CFSTR("CME-Test-Dst"), routeProbeProc, &probe, &testDst);
    if (st != noErr) { printf("FAIL MIDIDestinationCreate %d\n", (int)st); return; }

    RouterCore *core = [[RouterCore alloc] init];
    [core start];                      // 会 refreshDevices
    NSString *srcName = nil, *dstName = nil;
    for (NSString *n in core.sourceNames) if ([n hasPrefix:@"CME-Test-Src"]) srcName = n;
    for (NSString *n in core.destNames) if ([n hasPrefix:@"CME-Test-Dst"]) dstName = n;
    printf("测试源='%s' 测试目标='%s'\n", srcName.UTF8String ?: "(未找到)", dstName.UTF8String ?: "(未找到)");
    if (!srcName || !dstName) { printf("FAIL 虚拟设备没被枚举到\n"); MIDIClientDispose(client); return; }
    core.selectedSourceName = srcName;
    core.selectedDestName = dstName;

    // 发一条标准 Note On:90 3C 40
    Byte midi[] = { 0x90, 0x3C, 0x40 };
    MIDIPacketList pl;
    MIDIPacket *pk = MIDIPacketListInit(&pl);
    MIDIPacketListAdd(&pl, sizeof(pl), pk, 0, 3, midi);
    MIDIReceived(testSrc, &pl);

    for (int i = 0; i < 200 && !probe.got; i++) usleep(10000);   // 最多等 2 秒
    if (probe.got) {
        printf("收到: %02x %02x %02x  => %s\n", probe.bytes[0], probe.bytes[1], probe.bytes[2],
               (probe.len == 3 && probe.bytes[0] == 0x90 && probe.bytes[1] == 0x3C && probe.bytes[2] == 0x40) ? "PASS" : "内容不符 FAIL");
    } else {
        printf("2 秒内未收到 => FAIL\n");
    }

    // ---- 测试 2:输出选「虚拟端口」,外部客户端应能收到(这就是 DAW 的场景) ----
    MIDIPortRef inPort = 0;
    MIDIInputPortCreate(client, CFSTR("test-in"), routeProbeProc, &probe, &inPort);
    MIDIEndpointRef vSrc = 0;
    for (ItemCount i = 0; i < MIDIGetNumberOfSources(); i++) {
        MIDIEndpointRef ep = MIDIGetSource(i);
        CFStringRef nm = NULL; MIDIObjectGetStringProperty(ep, kMIDIPropertyName, &nm);
        NSString *n = nm ? (__bridge_transfer NSString *)nm : @"";
        if ([n isEqualToString:@"CME UF8 Router"]) { vSrc = ep; break; }
    }
    NSString *vDestName = nil;
    for (NSString *n in core.destNames) if ([n isEqualToString:@"CME UF8 Router (虚拟输出 → 给 DAW 用)"]) vDestName = n;
    printf("虚拟输出端点=%s 菜单项='%s'\n", vSrc ? "找到" : "没找到", vDestName.UTF8String ?: "(无)");
    if (vSrc && vDestName) {
        MIDIPortConnectSource(inPort, vSrc, NULL);
        core.selectedSourceName = srcName;
        core.selectedDestName = vDestName;
        probe.got = 0;
        Byte midi2[] = { 0x90, 0x40, 0x50 };
        MIDIPacketList pl2;
        MIDIPacket *pk2 = MIDIPacketListInit(&pl2);
        MIDIPacketListAdd(&pl2, sizeof(pl2), pk2, 0, 3, midi2);
        MIDIReceived(testSrc, &pl2);
        for (int i = 0; i < 200 && !probe.got; i++) usleep(10000);
        if (probe.got) {
            printf("调试: probe.len=%d 菜单项=%s\n", probe.len, vDestName.UTF8String);
            printf("虚拟端口收到: %02x %02x %02x  => %s\n", probe.bytes[0], probe.bytes[1], probe.bytes[2],
                   (probe.bytes[0] == 0x90 && probe.bytes[1] == 0x40 && probe.bytes[2] == 0x50) ? "PASS" : "内容不符 FAIL");
        } else {
            printf("虚拟端口 2 秒内未收到 => FAIL\n");
        }
        MIDIPortDispose(inPort);
    } else {
        printf("FAIL 虚拟输出不可用\n");
    }

    // ---- 测试 3:MMC sysex 被拆成两包(现场真实情况)能否拼回并翻成 CC ----
    if (vSrc) {
        MIDIPortRef in3 = 0;
        MIDIInputPortCreate(client, CFSTR("test-in3"), routeProbeProc, &probe, &in3);
        MIDIPortConnectSource(in3, vSrc, NULL);
        core.selectedSourceName = srcName;
        core.selectedDestName = vDestName;
        core.mapper.translateMMC = YES;
        probe.got = 0;
        Byte part1[] = { 0xF0, 0x7F, 0x00 };
        Byte part2[] = { 0x06, 0x06, 0xF7 };
        MIDIPacketList pl3; MIDIPacket *pk3 = MIDIPacketListInit(&pl3);
        MIDIPacketListAdd(&pl3, sizeof(pl3), pk3, 0, 3, part1);
        MIDIReceived(testSrc, &pl3);
        usleep(20000);
        MIDIPacketList pl4; MIDIPacket *pk4 = MIDIPacketListInit(&pl4);
        MIDIPacketListAdd(&pl4, sizeof(pl4), pk4, 0, 3, part2);
        MIDIReceived(testSrc, &pl4);
        for (int i = 0; i < 200 && !probe.got; i++) usleep(10000);
        if (probe.got) {
            printf("MMC 分两包(F0 7F 00 | 06 06 F7)→ 收到: %02x %02x %02x => %s\n",
                   probe.bytes[0], probe.bytes[1], probe.bytes[2],
                   (probe.len >= 3 && probe.bytes[0] == 0xB0 && probe.bytes[1] == 0x72) ? "PASS(已拼包+翻成 CC114 REC)" : "内容不符 FAIL");
        } else {
            printf("MMC 分两包 2 秒内未收到 => FAIL(跨包 sysex 没拼上)\n");
        }
        MIDIPortDispose(in3);
    }

    // ---- 测试 4:Mackie Control transport(输出目标仍是虚拟输出,弹奏不受影响) ----
    {
        core.useMackieTransport = YES;   // 端口是按需创建的,必须先开再枚举
        usleep(300000);
        MIDIEndpointRef mcuSrc = 0;
        for (ItemCount i = 0; i < MIDIGetNumberOfSources(); i++) {
            MIDIEndpointRef ep = MIDIGetSource(i);
            CFStringRef nm = NULL; MIDIObjectGetStringProperty(ep, kMIDIPropertyName, &nm);
            NSString *n = nm ? (__bridge_transfer NSString *)nm : @"";
            if ([n isEqualToString:@"CME UF8 Router MCU"]) { mcuSrc = ep; break; }
        }
        NSString *vName = nil;
        for (NSString *n in core.destNames) if ([n isEqualToString:@"CME UF8 Router (虚拟输出 → 给 DAW 用)"]) vName = n;
        printf("MCU 端口=%s 输出目标='%s'\n", mcuSrc ? "找到" : "没找到", vName.UTF8String ?: "(无)");
        if (mcuSrc && vName) {
            core.selectedSourceName = srcName;
            core.selectedDestName = vName;
            core.useMackieTransport = YES;   // 会先发一次 device ready,必须在这之后连接探针
            probe.want = 0x90;               // 只关心 MCU 按键(Note On),忽略其它主机的握手包
            usleep(200000);
            MIDIPortRef in4 = 0;
            MIDIInputPortCreate(client, CFSTR("test-in4"), routeProbeProc, &probe, &in4);
            MIDIPortConnectSource(in4, mcuSrc, NULL);
            usleep(150000);
            probe.got = 0;                       // 排掉握手 device-ready 的残留包
            usleep(150000);
            probe.got = 0;

            // 4a: MMC Play -> MCU PLAY 键
            probe.got = 0;
            Byte mmcPlay[] = { 0xF0, 0x7F, 0x00, 0x06, 0x02, 0xF7 };
            MIDIPacketList pl5; MIDIPacket *pk5 = MIDIPacketListInit(&pl5);
            MIDIPacketListAdd(&pl5, sizeof(pl5), pk5, 0, 6, mmcPlay);
            MIDIReceived(testSrc, &pl5);
            for (int i = 0; i < 200 && !probe.got; i++) usleep(10000);
            if (probe.got) {
                printf("调试: 收 %d 字节:", probe.len);
                for (int i = 0; i < probe.len && i < 16; i++) printf(" %02x", probe.bytes[i]);
                printf("\n");
                printf("MCU:MMC Play(len=%d) → 收到: %02x %02x %02x => %s\n", probe.len,
                       probe.bytes[0], probe.bytes[1], probe.bytes[2],
                       (probe.len >= 3 && probe.bytes[0] == 0x90 && probe.bytes[1] == 0x5E && probe.bytes[2] == 0x7F) ? "PASS(MCU PLAY 键)" : "内容不符 FAIL");
            } else {
                printf("MCU 2 秒内未收到 => FAIL\n");
            }

            // 4b: 同一时刻弹奏的音符必须仍然从虚拟输出进 DAW
            if (vSrc) {
                MIDIPortRef in5 = 0;
                MIDIInputPortCreate(client, CFSTR("test-in5"), routeProbeProc, &probe, &in5);
                MIDIPortConnectSource(in5, vSrc, NULL);
                usleep(50000);
                probe.got = 0;
                Byte note[] = { 0x90, 0x48, 0x60 };
                MIDIPacketList pl6; MIDIPacket *pk6 = MIDIPacketListInit(&pl6);
                MIDIPacketListAdd(&pl6, sizeof(pl6), pk6, 0, 3, note);
                MIDIReceived(testSrc, &pl6);
                for (int i = 0; i < 200 && !probe.got; i++) usleep(10000);
                if (probe.got) {
                    printf("MCU 模式下弹奏 → 虚拟输出收到: %02x %02x %02x => %s\n",
                           probe.bytes[0], probe.bytes[1], probe.bytes[2],
                           (probe.bytes[0] == 0x90 && probe.bytes[1] == 0x48) ? "PASS(键盘照常可用)" : "内容不符 FAIL");
                } else {
                    printf("MCU 模式下音符没出来 => FAIL\n");
                }
                MIDIPortDispose(in5);
            }
            // 4c: REC 键 -> MCU RECORD
            probe.got = 0;
            Byte mmcRec[] = { 0xF0, 0x7F, 0x00, 0x06, 0x06, 0xF7 };
            MIDIPacketList pl7; MIDIPacket *pk7 = MIDIPacketListInit(&pl7);
            MIDIPacketListAdd(&pl7, sizeof(pl7), pk7, 0, 6, mmcRec);
            MIDIReceived(testSrc, &pl7);
            for (int i = 0; i < 200 && !probe.got; i++) usleep(10000);
            if (probe.got) {
                printf("MCU:MMC Record Strobe(len=%d) → 收到: %02x %02x %02x => %s\n", probe.len,
                       probe.bytes[0], probe.bytes[1], probe.bytes[2],
                       (probe.len >= 3 && probe.bytes[1] == 0x5F && probe.bytes[2] == 0x7F) ? "PASS(MCU RECORD 键)" : "内容不符 FAIL");
            } else {
                printf("MCU RECORD 2 秒内未收到 => FAIL\n");
            }
            MIDIPortDispose(in4);
            probe.want = 0;
        }
    }

    [core stop];
    MIDIEndpointDispose(testSrc);
    MIDIEndpointDispose(testDst);
    MIDIClientDispose(client);
}

#pragma mark - 自检

+ (void)runSelfTest {
    // 喂标准消息(如 0x90 0x3C 0x40)与 CME 帧,验证协议层
    printf("=== cme-uf8-router 自检 ===\n");
    // 标准 Note On
    uint8_t noteOn[] = { 0x90, 0x3C, 0x40 };
    NSArray *msgs = [CMEMIDIProtocol decodeBytes:noteOn length:3 mode:CMEMIDIProtocolModeStandard sniffedToCME:NULL];
    printf("标准 NoteOn(应 1 条): %lu\n", msgs.count);
    // CME 帧:0x0F F0 7E 7F 09 01 F7 00 (sysex)
    uint8_t cmeFrame[] = { 0x0F, 0xF0, 0x7E, 0x7F, 0x09, 0x01, 0xF7, 0x00 };
    BOOL isCME = NO;
    msgs = [CMEMIDIProtocol decodeBytes:cmeFrame length:8 mode:CMEMIDIProtocolModeAuto sniffedToCME:&isCME];
    printf("CME sysex auto(应 1 条,isCME=1): %lu isCME=%d\n", msgs.count, isCME);
    // 编码往返
    uint8_t noteFrame[] = { 0x90, 0x3C, 0x40 };
    NSData *nd = [NSData dataWithBytes:noteFrame length:3];
    NSArray *f = [CMEMIDIProtocol encodeCMEFramesFromMessage:nd];
    const uint8_t *fb = ((NSData *)f.firstObject).bytes;
    printf("编码 NoteOn 帧(应 0x09 0x90 0x3c 0x40 = cable0+CIN9,3字节 Note On): %02x %02x %02x %02x\n",
           fb[0], fb[1], fb[2], fb[3]);
}

@end

#pragma mark - Mackie Control 回调

// Logic(控制表面)发过来的数据:只需识别设备查询并回 Device Ready;
// 其余(推子/LED/屏幕回传)本 App 不回写,忽略即可。
static void mcuReadProc(const MIDIPacketList *pktlist, void *refCon, void *connRefCon) {
    RouterCore *core = (__bridge RouterCore *)refCon;
    if (!core) return;
    const MIDIPacket *packet = &pktlist->packet[0];
    for (UInt32 i = 0; i < pktlist->numPackets; i++) {
        const uint8_t *d = packet->data;
        NSUInteger n = packet->length;
        BOOL query = (n == 7 && d[0] == 0xF0 && d[1] == 0x00 && d[2] == 0x00 &&
                      d[3] == 0x66 && (d[4] == 0x14 || d[4] == 0x15) &&
                      d[5] == 0x00 && d[6] == 0xF7);
        if (query) {
            [core sendMCUDeviceReady];
        }
        packet = MIDIPacketNext(packet);
    }
}
