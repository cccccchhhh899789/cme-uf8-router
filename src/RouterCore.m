// RouterCore.m — CoreMIDI 路由核心实现

#import "RouterCore.h"
#import <CoreMIDI/CoreMIDI.h>
#include <sys/time.h>

// 固定 uniqueID:DAW 靠它认设备,每次重启都换新 ID 会让 Logic 把控制表面判成「离线」
enum {
    kCMEVirtualSourceUID = 0x55463801,   // 'UF8' 01
    kCMEMCUSourceUID     = 0x55463802,
    kCMEMCUDestUID       = 0x55463803,
};

// 回调上下文
typedef struct {
    __unsafe_unretained RouterCore *core;
} RouterCoreCallbackCtx;

static void mcuReadProc(const MIDIPacketList *pktlist, void *refCon, void *connRefCon);


// 统计系统里名字匹配的 MIDI 端点数量(源+目标都算),用于端口泄漏检查
static NSInteger CMECountEndpointsNamed(NSString *name) {
    NSInteger n = 0;
    for (ItemCount i = 0; i < MIDIGetNumberOfSources(); i++) {
        MIDIEndpointRef ep = MIDIGetSource(i);
        CFStringRef nm = NULL;
        MIDIObjectGetStringProperty(ep, kMIDIPropertyName, &nm);
        NSString *s = nm ? (__bridge_transfer NSString *)nm : @"";
        if ([s isEqualToString:name]) n++;
    }
    for (ItemCount i = 0; i < MIDIGetNumberOfDestinations(); i++) {
        MIDIEndpointRef ep = MIDIGetDestination(i);
        CFStringRef nm = NULL;
        MIDIObjectGetStringProperty(ep, kMIDIPropertyName, &nm);
        NSString *s = nm ? (__bridge_transfer NSString *)nm : @"";
        if ([s isEqualToString:name]) n++;
    }
    return n;
}

@implementation RouterCore {
    MIDIClientRef _client;
    MIDIPortRef _inputPort;
    MIDIPortRef _outputPort;
    MIDIEndpointRef _virtualSource;   // 本 App 自己发的虚拟 MIDI 源(给 DAW 读)
    MIDIEndpointRef _mcuSource;       // Mackie Control 输出口(Logic 控制表面读它)
    MIDIEndpointRef _mcuDest;         // Mackie Control 输入口(Logic 把反馈发到这里)
    RouterCoreCallbackCtx _readCtx;
    dispatch_queue_t _midiQueue;      // 串行队列(抓包落盘等后台活)
    dispatch_queue_t _mcuQueue;       // 串行队列:MCU 按键的「延迟松开」
    dispatch_queue_t _captureQueue;
    BOOL _running;
    volatile BOOL _stopping;          // 正在收摊:回调看到立刻返回,避免碰已 dispose 的句柄
    NSMutableArray<NSString *> *_sourceNames;
    NSMutableArray<NSString *> *_destNames;
    // 名字 -> MIDIEndpointRef(存成 intptr_t)。以前存的是枚举下标,热插拔后会把音符
    // 发到别人家的合成器上,这是 CoreMIDI 里最经典的错投 bug
    NSMutableDictionary<NSString *, NSNumber *> *_sourceRefs;
    NSMutableDictionary<NSString *, NSNumber *> *_destRefs;
    NSMutableData *_sysexBuf;         // 跨包不完整的 sysex(U2MIDI Pro 会把 sysex 拆成多包)
    CFTimeInterval _sysexBufTime;     // 最后一次拼包时间,用于「残包超时清理」
    NSInteger _lastTransportKey;      // 上一个 transport 事件(1..6),用于按住连发的去重
    CFTimeInterval _lastTransportTime;
}

@synthesize mapper = _mapper;
@synthesize captureRawEnabled = _captureRawEnabled;

- (instancetype)init {
    _mcuQueue = dispatch_queue_create("cme-uf8-router.mcu", DISPATCH_QUEUE_SERIAL);
    if ((self = [super init])) {
        _mapper = [[MIDIMapper alloc] init];
        _protocolMode = CMEMIDIProtocolModeAuto;
        _sourceNames = [NSMutableArray array];
        _destNames = [NSMutableArray array];
        _sourceRefs = [NSMutableDictionary dictionary];
        _destRefs = [NSMutableDictionary dictionary];
        _midiQueue = dispatch_queue_create("cme-uf8-router.midi", DISPATCH_QUEUE_SERIAL);
        _captureQueue = dispatch_queue_create("cme-uf8-router.capture", DISPATCH_QUEUE_SERIAL);
        _readCtx.core = self;
        _lastTransportKey = 0;
    }
    return self;
}

#pragma mark - 发送原语

// 发一条消息到某个 endpoint(MIDIReceived 方向:我们是发送方)。
// 必须动态分配包列表:栈上 MIDIPacketList 只装得下 256 字节,长 sysex 会被 MIDIPacketListAdd 静默拒掉
static OSStatus CMESendToEndpoint(MIDIEndpointRef ep, NSData *msg) {
    if (!ep || msg.length == 0 || msg.length > 65535) return kMIDIInvalidPort;
    size_t size = sizeof(MIDIPacketList) + msg.length;
    MIDIPacketList *pl = (MIDIPacketList *)malloc(size);
    if (!pl) return -1;
    MIDIPacket *pkt = MIDIPacketListInit(pl);
    if (!MIDIPacketListAdd(pl, (ByteCount)size, pkt, 0, (ByteCount)msg.length, msg.bytes)) {
        free(pl);
        return -1;
    }
    OSStatus st = MIDIReceived(ep, pl);
    free(pl);
    return st;
}

// 发一条消息到真实设备的 destination(MIDISend 方向)
static OSStatus CMESendToPort(MIDIPortRef port, MIDIEndpointRef dest, NSData *msg) {
    if (!port || !dest || msg.length == 0 || msg.length > 65535) return kMIDIInvalidPort;
    size_t size = sizeof(MIDIPacketList) + msg.length;
    MIDIPacketList *pl = (MIDIPacketList *)malloc(size);
    if (!pl) return -1;
    MIDIPacket *pkt = MIDIPacketListInit(pl);
    if (!MIDIPacketListAdd(pl, (ByteCount)size, pkt, 0, (ByteCount)msg.length, msg.bytes)) {
        free(pl);
        return -1;
    }
    OSStatus st = MIDISend(port, dest, pl);
    free(pl);
    return st;
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

// 枚举必须只在主线程做:菜单在遍历这些数组,后台线程一边改一边遍历会直接崩
- (void)refreshDevices {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self refreshDevices]; });
        return;
    }
    if (_stopping) return;

    NSMutableArray<NSString *> *srcNames = [NSMutableArray array];
    NSMutableArray<NSString *> *dstNames = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSNumber *> *srcRefs = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSNumber *> *dstRefs = [NSMutableDictionary dictionary];

    ItemCount srcCount = MIDIGetNumberOfSources();
    for (ItemCount i = 0; i < srcCount; i++) {
        MIDIEndpointRef ep = MIDIGetSource(i);
        // 自己的两个端口绝不能当输入,否则自己发出去的东西又转回来(回环/自激)
        if (_virtualSource && ep == _virtualSource) continue;
        if (_mcuSource && ep == _mcuSource) continue;
        NSString *n = CMEEndpointDisplayName(ep, i, @"源");
        NSString *unique = [self uniqueName:n in:srcNames];
        [srcNames addObject:unique];
        srcRefs[unique] = @((intptr_t)ep);
    }
    // 虚拟输出永远排第一(默认),DAW 选它当输入即可
    if (_virtualSource) {
        NSString *vname = @"CME UF8 Router (虚拟输出 → 给 DAW 用)";
        [dstNames addObject:vname];
        dstRefs[vname] = @(-1);
    }
    ItemCount dstCount = MIDIGetNumberOfDestinations();
    for (ItemCount i = 0; i < dstCount; i++) {
        MIDIEndpointRef ep = MIDIGetDestination(i);
        if (_virtualSource && ep == _virtualSource) continue;
        if (_mcuDest && ep == _mcuDest) continue;   // 自己的 MCU 输入口,不当普通目标
        NSString *n = CMEEndpointDisplayName(ep, i, @"目标");
        NSString *unique = [self uniqueName:n in:dstNames];
        [dstNames addObject:unique];
        dstRefs[unique] = @((intptr_t)ep);
    }

    // 选择失效则清空;只有一个源时自动选上(接管设备不用先点菜单)
    NSString *selSrc, *selDst;
    @synchronized (self) {
        [_sourceNames setArray:srcNames];
        [_destNames setArray:dstNames];
        [_sourceRefs removeAllObjects];
        [_sourceRefs addEntriesFromDictionary:srcRefs];
        [_destRefs removeAllObjects];
        [_destRefs addEntriesFromDictionary:dstRefs];

        if (_selectedSourceName && !_sourceRefs[_selectedSourceName]) {
            [self log:[NSString stringWithFormat:@"上次的输入源「%@」已不在列表,已清空", _selectedSourceName]];
            _selectedSourceName = nil;
        }
        if (_selectedDestName && !_destRefs[_selectedDestName]) {
            [self log:[NSString stringWithFormat:@"上次的输出目标「%@」已不在列表,已清空", _selectedDestName]];
            _selectedDestName = nil;
        }
        if (!_selectedSourceName && _sourceNames.count == 1) {
            _selectedSourceName = _sourceNames.firstObject;
            [self log:[NSString stringWithFormat:@"自动选中唯一输入源: %@", _selectedSourceName]];
        }
        if (!_selectedDestName) {
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
        selSrc = _selectedSourceName;
        selDst = _selectedDestName;
    }
    // 日志里报的是「真正能选的数量」,别再把自己的端口算进去误导排障
    [self log:[NSString stringWithFormat:@"枚举: %lu 个输入源, %lu 个输出目标",
               (unsigned long)srcNames.count, (unsigned long)dstNames.count]];

    [self reconnectInputForSelected];
    [self.delegate routerDidRefreshDevices:self];

    if (selSrc) [self.mapper setLastSourceIfNeeded:selSrc];
    if (selDst) [self.mapper setLastDestIfNeeded:selDst];
}

// 同名端点(如两个 "Port 1")加序号区分,避免字典键冲突
- (NSString *)uniqueName:(NSString *)base in:(NSArray<NSString *> *)existing {
    if (![existing containsObject:base]) return base;
    NSInteger k = 2;
    NSString *cand;
    do { cand = [NSString stringWithFormat:@"%@ (%ld)", base, (long)k++]; } while ([existing containsObject:cand]);
    return cand;
}

- (void)start {
    if (_running) return;
    _stopping = NO;
    OSStatus st = MIDIClientCreate(CFSTR("cme-uf8-router"), midiNotifyProc, (__bridge void *)self, &_client);
    if (st != noErr) {
        [self log:[NSString stringWithFormat:@"MIDIClientCreate 失败 %d", (int)st]];
        _client = 0;
        return;
    }
    // 建一个虚拟 MIDI 源:别的 App(DAW)在输入里能选到 "CME UF8 Router"
    if (!_virtualSource) {
        OSStatus vs = MIDISourceCreate(_client, CFSTR("CME UF8 Router"), &_virtualSource);
        if (vs != noErr) {
            [self log:[NSString stringWithFormat:@"虚拟端口创建失败 %d", (int)vs]];
            _virtualSource = 0;
            [self stop];
            return;
        }
        CFStringRef man = CFSTR("cme-uf8-router");
        MIDIObjectSetStringProperty(_virtualSource, kMIDIPropertyManufacturer, man);
        MIDIObjectSetStringProperty(_virtualSource, kMIDIPropertyModel, CFSTR("UF8"));
        // 固定 uniqueID:DAW(尤其 Logic 的控制表面)靠它认设备。每次重启都换一个新 ID,
        // 控制表面就会「离线,请重选端口」——这是 LOGIC 侧最高频的抱怨来源
        SInt32 uid = (SInt32)kCMEVirtualSourceUID;
        MIDIObjectSetIntegerProperty(_virtualSource, kMIDIPropertyUniqueID, uid);
        [self log:@"已创建虚拟输出端口: CME UF8 Router"];
    }
    st = MIDIInputPortCreate(_client, CFSTR("input"), midiReadProc, &_readCtx, &_inputPort);
    if (st != noErr) {
        [self log:[NSString stringWithFormat:@"MIDIInputPortCreate 失败 %d", (int)st]];
        _inputPort = 0;
        [self stop];
        return;
    }
    st = MIDIOutputPortCreate(_client, CFSTR("output"), &_outputPort);
    if (st != noErr) {
        [self log:[NSString stringWithFormat:@"MIDIOutputPortCreate 失败 %d", (int)st]];
        _outputPort = 0;
        [self stop];
        return;
    }
    _running = YES;
    [self refreshDevices];

    // 恢复上次选的输入/输出(名字还在就自动接上,免得每次重启都要手动选)
    BOOL restored = NO;
    if (_mapper.lastSource && [_sourceNames containsObject:_mapper.lastSource]) {
        _selectedSourceName = _mapper.lastSource;
        [self reconnectInputForSelected];
        [self log:[NSString stringWithFormat:@"已恢复输入源: %@", _mapper.lastSource]];
        restored = YES;
    } else if (_mapper.lastSource) {
        [self log:[NSString stringWithFormat:@"上次的输入源「%@」不在列表,回退到默认", _mapper.lastSource]];
    }
    if (_mapper.lastDest && [_destNames containsObject:_mapper.lastDest]) {
        _selectedDestName = _mapper.lastDest;
        [self log:[NSString stringWithFormat:@"已恢复输出目标: %@", _mapper.lastDest]];
        restored = YES;
    } else if (_mapper.lastDest) {
        [self log:[NSString stringWithFormat:@"上次的输出目标「%@」不在列表,回退到默认", _mapper.lastDest]];
    }
    if (_mapper.useMackie && !_useMackieTransport) [self setUseMackieTransport:YES];  // 恢复上次的选择

    // 恢复完之后必须再广播一次:菜单是在上面那次 refreshDevices 里建好的,
    // 不补这一次就会出现「勾着 A、实际发往 B」(上次事故的根因之一)
    if (restored) [self.delegate routerDidRefreshDevices:self];
    [self log:@"已启动"];
}

- (void)stop {
    // 不带 _running 门槛:start 半途失败时 _running 还是 NO,但有端口已经建出来了,
    // 那种情况下正是最需要收摊的时候
    _stopping = YES;
    if (_inputPort) { MIDIPortDispose(_inputPort); _inputPort = 0; }
    if (_outputPort) { MIDIPortDispose(_outputPort); _outputPort = 0; }
    [self teardownMCUEndpoints];
    if (_virtualSource) { MIDIEndpointDispose(_virtualSource); _virtualSource = 0; }
    if (_client) { MIDIClientDispose(_client); _client = 0; }
    _running = NO;
    [self log:@"已停止"];
}

#pragma mark - 回调

// 通知回调跑在 CoreMIDI 自己的线程上:这里绝不能碰菜单/数组,更不能在回调里改 MIDI 图
// (在通知回调里 Connect/Disconnect 会和 MIDIServer 的内部锁撞上 → 卡死)
static void midiNotifyProc(const MIDINotification *msg, void *refCon) {
    RouterCore *core = (__bridge RouterCore *)refCon;
    switch (msg->messageID) {
        case kMIDIMsgSetupChanged:
        case kMIDIMsgObjectAdded:
        case kMIDIMsgObjectRemoved: {
            // 只投递,不做任何实际工作
            dispatch_async(dispatch_get_main_queue(), ^{
                if (core->_stopping) return;
                [core refreshDevices];
                [core log:@"设备列表已刷新"];
            });
            break;
        }
        default: break;
    }
}

static void midiReadProc(const MIDIPacketList *pktlist, void *readProcRefCon, void *srcConnRefCon) {
    RouterCoreCallbackCtx *ctx = (RouterCoreCallbackCtx *)readProcRefCon;
    RouterCore *core = ctx->core;
    if (!core || core->_stopping) return;
    [core handleIncoming:pktlist];
}

#pragma mark - 原始报文抓包(排错用,默认关)

// 落盘 ~/Library/Application Support/cme-uf8-router/raw-capture.log
// 注意:这是 MIDI 实时线程上的热路径,所以只做一次内存拷贝,写盘甩到后台串行队列
- (void)captureRaw:(const uint8_t *)bytes length:(NSUInteger)len {
    if (!_captureRawEnabled || len == 0) return;
    NSData *copy = [NSData dataWithBytes:bytes length:len];
    dispatch_async(_captureQueue, ^{ [self writeRawLine:copy]; });
}

- (void)writeRawLine:(NSData *)data {
    static NSString *path = nil;
    static NSFileHandle *fh = nil;
    if (!path) {
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES);
        NSString *dir = [paths.firstObject stringByAppendingPathComponent:@"cme-uf8-router"];
        if (!dir) return;
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
        path = [dir stringByAppendingPathComponent:@"raw-capture.log"];
        fh = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!fh) {
            [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:NULL];
            fh = [NSFileHandle fileHandleForWritingAtPath:path];
        }
        [fh seekToEndOfFile];
    }
    if (!fh) return;
    // 8MB 上限:排错日志不该把磁盘写满,也不该长期留着一整场演出的音符
    unsigned long long size = [fh seekToEndOfFile];
    if (size > 8ULL * 1024 * 1024) {
        [fh closeFile];
        [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
        [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:NULL];
        fh = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!fh) return;
    }
    const uint8_t *p = data.bytes;
    NSMutableString *hex = [NSMutableString stringWithCapacity:data.length * 3];
    for (NSUInteger i = 0; i < data.length && i < 64; i++) [hex appendFormat:@"%02X ", p[i]];
    struct timeval tv;
    gettimeofday(&tv, NULL);
    struct tm tmv;
    localtime_r(&tv.tv_sec, &tmv);
    NSString *line = [NSString stringWithFormat:@"%02d:%02d:%02d.%03d [%lu] %@\n",
                      tmv.tm_hour, tmv.tm_min, tmv.tm_sec, (int)(tv.tv_usec / 1000),
                      (unsigned long)data.length, hex];
    @try { [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; } @catch (NSException *e) { }
}

#pragma mark - 解码(含跨包 sysex 拼接)

- (NSArray<NSData *> *)decodePacket:(const uint8_t *)data length:(NSUInteger)len {
    if (!data || len == 0) return @[];
    if (!_sysexBuf) _sysexBuf = [NSMutableData data];

    if (_sysexBuf.length) {
        const uint8_t first = data[0];
        BOOL newStatus = (first >= 0x80) && !(first >= 0xF8);   // 实时字节可以合法插进 sysex 中间
        BOOL stale = (CFAbsoluteTimeGetCurrent() - _sysexBufTime > 1.0);
        // 残包处理:设备把 F7 丢了(拔线/丢字节)。不清掉的话后面每一包都会被拼到 F0 后面
        // 当成 sysex 吃掉 → 「琴突然不响,只能重启」。这是本工程最隐蔽的一个致命 bug
        if (stale || (newStatus && first != 0xF7)) {
            NSLog(@"[cme-uf8-router] 丢弃未完成的 sysex 残包(%lu 字节,新包首字节 0x%02X)",
                  (unsigned long)_sysexBuf.length, first);
            [_sysexBuf setLength:0];
        }
    }
    if (_sysexBuf.length > 65536) [_sysexBuf setLength:0];

    NSMutableData *buf = [NSMutableData dataWithCapacity:_sysexBuf.length + len];
    [buf appendData:_sysexBuf];
    [buf appendBytes:data length:len];
    [_sysexBuf setLength:0];

    NSArray<NSData *> *msgs = [CMEMIDIProtocol decodeBytes:buf.bytes
                                                    length:buf.length
                                                      mode:_protocolMode
                                             sniffedToCME:NULL];
    NSMutableArray<NSData *> *out = [NSMutableArray array];
    for (NSData *m in msgs) {
        if (m.length == 0) continue;
        const uint8_t *p = m.bytes;
        if (p[0] == 0xF0 && p[m.length - 1] != 0xF7) {
            [_sysexBuf appendData:m];
            _sysexBufTime = CFAbsoluteTimeGetCurrent();
            continue;
        }
        [out addObject:m];
    }
    if (_sysexBuf.length > 65536) [_sysexBuf setLength:0];   // 硬上限,兜底
    return out;
}

// 同一个 transport 键按住时琴会每 ~250ms 重发一次同样的报文。
// 以前按「时间窗+note」去重,会把「两次真实快按」也吞掉,还会让长按每 250ms 触发一次。
// 改成事件级:同一个键在 0.4s 内重复出现就当是按住重发,整条忽略
- (BOOL)mcuEventShouldEmitKey:(NSInteger)key {
    CFTimeInterval now = CFAbsoluteTimeGetCurrent();
    if (key == _lastTransportKey && now - _lastTransportTime < 0.4) return NO;
    _lastTransportKey = key;
    _lastTransportTime = now;
    return YES;
}

- (void)handleIncoming:(const MIDIPacketList *)pktlist {
    if (_stopping) return;
    // 主线程在改选择/枚举,这里先取一份不可变快照,后面不再碰可变字典
    BOOL useMackie = NO;
    NSNumber *destRef = nil;
    @synchronized (self) {
        useMackie = _useMackieTransport;
        if (_selectedDestName) destRef = _destRefs[_selectedDestName];
    }

    MIDIPacket *packet = (MIDIPacket *)pktlist->packet;
    for (UInt32 i = 0; i < pktlist->numPackets; i++) {
        [self captureRaw:packet->data length:packet->length];
        for (NSData *m in [self decodePacket:packet->data length:packet->length]) {
            if (useMackie) {
                NSInteger key = [_mapper transportKeyForMessage:m];
                if (key > 0) {
                    if ([self mcuEventShouldEmitKey:key]) {
                        NSArray<NSData *> *mcu = [_mapper mcuMessagesFor:m];
                        if (mcu.count >= 2) {
                            // 按下立刻发,松开故意晚 80ms:
                            // 1) 同一时刻的 note-on/note-off 有些 DAW 会当成抖动丢掉 off,
                            //    结果按键「卡住」——Logic 里表现成走带键一直快退/快进;
                            // 2) 一次干脆的按下-松开 = 走一小节,不会连滚。
                            [self sendToMCUSource:mcu[0]];
                            NSData *release = mcu[1];
                            // 用独立串行队列,不用主队列:主线程一忙(开菜单、日志刷新)
                            // 松开就会迟到,按钮又「卡住」了
                            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(80 * NSEC_PER_MSEC)),
                                           self->_mcuQueue, ^{
                                [self sendToMCUSource:release];
                            });
                        } else {
                            for (NSData *out in mcu) [self sendToMCUSource:out];
                        }
                    }
                    continue;   // transport 只走 MCU 口,不混进乐器输出
                }
            }
            for (NSData *out in [_mapper processMessage:m]) [self sendMessage:out destRef:destRef];
        }
        packet = MIDIPacketNext(packet);
    }
}

#pragma mark - Mackie Control 端口

// 端口对只在「勾了 MCU transport」时存在,避免平时多出两个口干扰(用户明确要求别多分口)
- (BOOL)ensureMCUEndpoints {
    if (!_client) return NO;
    if (!_mcuSource) {
        OSStatus ms = MIDISourceCreate(_client, CFSTR("CME UF8 Router MCU"), &_mcuSource);
        if (ms == noErr) {
            MIDIObjectSetStringProperty(_mcuSource, kMIDIPropertyManufacturer, CFSTR("cme-uf8-router"));
            MIDIObjectSetStringProperty(_mcuSource, kMIDIPropertyModel, CFSTR("Mackie Control"));
            MIDIObjectSetIntegerProperty(_mcuSource, kMIDIPropertyUniqueID, (SInt32)kCMEMCUSourceUID);
            [self log:@"已创建 Mackie Control 输出口: CME UF8 Router MCU"];
        } else {
            _mcuSource = 0;
            [self log:[NSString stringWithFormat:@"MCU 输出口创建失败 %d", (int)ms]];
        }
    }
    if (!_mcuDest) {
        OSStatus md = MIDIDestinationCreate(_client, CFSTR("CME UF8 Router MCU"), mcuReadProc, (__bridge void *)self, &_mcuDest);
        if (md == noErr) {
            MIDIObjectSetStringProperty(_mcuDest, kMIDIPropertyManufacturer, CFSTR("cme-uf8-router"));
            MIDIObjectSetStringProperty(_mcuDest, kMIDIPropertyModel, CFSTR("Mackie Control"));
            MIDIObjectSetIntegerProperty(_mcuDest, kMIDIPropertyUniqueID, (SInt32)kCMEMCUDestUID);
            [self log:@"已创建 Mackie Control 输入口: CME UF8 Router MCU"];
        } else {
            _mcuDest = 0;
            [self log:[NSString stringWithFormat:@"MCU 输入口创建失败 %d", (int)md]];
        }
    }
    return (_mcuSource && _mcuDest);
}

- (void)teardownMCUEndpoints {
    if (_mcuDest) { MIDIEndpointDispose(_mcuDest); _mcuDest = 0; }
    if (_mcuSource) { MIDIEndpointDispose(_mcuSource); _mcuSource = 0; }
}

- (void)sendMCUDeviceReady {
    // 主机唤醒 F0 00 00 66 14 00 F7 -> 设备回 Device Ready F0 00 00 66 14 01 F7
    if (!_mcuSource) return;
    const uint8_t ready[7] = { 0xF0, 0x00, 0x00, 0x66, 0x14, 0x01, 0xF7 };
    CMESendToEndpoint(_mcuSource, [NSData dataWithBytes:ready length:7]);
}

- (void)setUseMackieTransport:(BOOL)on {
    if (on) {
        if (![self ensureMCUEndpoints]) {
            // 端口建不出来就别装作开着:菜单勾着但 transport 全丢是最难查的状态
            _useMackieTransport = NO;
            _mapper.useMackie = NO;
            [_mapper saveConfig];
            [self log:@"MCU 端口创建失败,transport 仍走 MMC→CC 翻译"];
            [self refreshDevices];
            return;
        }
        _useMackieTransport = YES;
        _mapper.runtimeMuteCC = YES;   // 只在本次运行静音 CC 翻译,不动用户设置
        [self log:@"transport 改走 Mackie Control: CME UF8 Router MCU(Logic 里装 Mackie Control 表面)"];
        [self sendMCUDeviceReady];
    } else {
        _useMackieTransport = NO;
        [self teardownMCUEndpoints];
        _mapper.runtimeMuteCC = NO;    // 恢复 CC114-119 翻译
        [self log:@"transport 不再走 Mackie Control(多余端口已撤),恢复 MMC→CC 翻译"];
    }
    if (_mapper.useMackie != on) { _mapper.useMackie = on; [_mapper saveConfig]; }
    [self refreshDevices];
}

- (void)setSelectedDestName:(NSString *)name {
    _selectedDestName = [name copy];
    if (name) [_mapper setLastDestIfNeeded:name];
}

- (void)setSelectedSourceName:(NSString *)sourceName {
    _selectedSourceName = [sourceName copy];
    [self reconnectInputForSelected];
    if (sourceName) [_mapper setLastSourceIfNeeded:sourceName];
}

// transport 键专用出口:Mackie Control 虚拟源(DAW 当控制表面输入)
- (void)sendToMCUSource:(NSData *)msg {
    if (!_mcuSource) return;
    CMESendToEndpoint(_mcuSource, msg);
}

// 按「快照里的 endpoint 引用」发出去。ref == -1 表示虚拟输出(喂给自己的虚拟源)
- (void)sendMessage:(NSData *)msg destRef:(NSNumber *)refNum {
    if (msg.length == 0 || !refNum || _stopping) return;
    NSInteger ref = refNum.integerValue;
    if (ref == -1) {
        if (_virtualSource) CMESendToEndpoint(_virtualSource, msg);
        return;
    }
    if (!_outputPort) return;
    CMESendToPort(_outputPort, (MIDIEndpointRef)(intptr_t)ref, msg);
}

// 只在选中的源上连接(避免串流其他源)
- (void)reconnectInputForSelected {
    if (!_inputPort || _stopping) return;
    // 断开所有,连接选中的
    ItemCount srcCount = MIDIGetNumberOfSources();
    for (ItemCount i = 0; i < srcCount; i++) {
        MIDIPortDisconnectSource(_inputPort, MIDIGetSource(i));
    }
    MIDIEndpointRef ep = 0;
    NSString *selName = nil;
    @synchronized (self) {
        selName = _selectedSourceName;
        if (selName) ep = (MIDIEndpointRef)(intptr_t)_sourceRefs[selName].unsignedLongLongValue;
    }
    if (ep) {
        OSStatus st = MIDIPortConnectSource(_inputPort, ep, NULL);
        if (st == noErr) {
            [self log:[NSString stringWithFormat:@"输入源: %@", selName]];
        } else {
            [self log:[NSString stringWithFormat:@"连接输入源失败 %d: %@", (int)st, selName]];
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
    volatile int count;    // 收到几条(用于「按住连发只该产生一对」这类计数断言)
    volatile int totalBytes; // 累计字节数:CoreMIDI 会把连着发的两条合并进同一个 packet
    uint8_t bytes[16];
    int len;
    uint8_t want;      // 只收首字节等于它的包(0=全都收)
    BOOL ignoreRelease; // 忽略 Note On 的「松开」(vel=0),只关心按下
} CMERouteProbe;

static void routeProbeProc(const MIDIPacketList *pktlist, void *refCon, void *connRefCon) {
    CMERouteProbe *probe = (CMERouteProbe *)refCon;
    const MIDIPacket *p = &pktlist->packet[0];
    for (UInt32 i = 0; i < pktlist->numPackets; i++) {
        if (probe->want && p->length > 0 && p->data[0] != probe->want) { p = MIDIPacketNext(p); continue; }
        // 0.1.10 起 MCU 的「松开」故意延迟 80ms 才发,会串到下一个测试里,所以按需过滤
        if (probe->ignoreRelease && p->length >= 3 && (p->data[0] & 0xF0) == 0x90 && p->data[2] == 0x00) {
            p = MIDIPacketNext(p); continue;
        }
        probe->count++;
        probe->totalBytes += (int)p->length;
        probe->len = (int)p->length;
        if (probe->len > 16) probe->len = 16;
        memcpy(probe->bytes, p->data, probe->len);
        probe->got = 1;
        p = MIDIPacketNext(p);
    }
}

+ (void)runRouteSelfTest {
    printf("=== 路由端到端自检(虚拟 MIDI 源 → 虚拟 MIDI 目标) ===\n");
    MIDIClientRef client = 0;
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
        core.useMackieTransport = NO;    // 配置里可能记着 useMackie=YES,恢复会让 MMC 走 MCU 口
        usleep(100000);
        core.mapper.translateMMC = YES;
        core.mapper.runtimeMuteCC = NO;
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
            probe.ignoreRelease = YES;       // 松开是延迟发的,会串场
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

    // ---- 测试 5:按住连发只该产生「一对」MCU 报文(连按也不能被吞) ----
    {
        core.useMackieTransport = YES;
        usleep(200000);
        MIDIEndpointRef mcuSrc5 = 0;
        for (ItemCount i = 0; i < MIDIGetNumberOfSources(); i++) {
            MIDIEndpointRef ep = MIDIGetSource(i);
            CFStringRef nm = NULL; MIDIObjectGetStringProperty(ep, kMIDIPropertyName, &nm);
            NSString *n = nm ? (__bridge_transfer NSString *)nm : @"";
            if ([n isEqualToString:@"CME UF8 Router MCU"]) { mcuSrc5 = ep; break; }
        }
        if (mcuSrc5) {
            probe.want = 0x90;
            probe.ignoreRelease = NO;        // 这条要数「按下+松开」两半
            probe.got = 0;
            probe.count = 0;
            MIDIPortRef in6 = 0;
            MIDIInputPortCreate(client, CFSTR("test-in6"), routeProbeProc, &probe, &in6);
            MIDIPortConnectSource(in6, mcuSrc5, NULL);
            usleep(200000);
            probe.count = 0;
            probe.totalBytes = 0;
            // 同一个 MMC Stop 连发三次(模拟按住键时琴的重发)
            Byte mmcStop[] = { 0xF0, 0x7F, 0x00, 0x06, 0x01, 0xF7 };
            for (int k = 0; k < 3; k++) {
                MIDIPacketList pls; MIDIPacket *pks = MIDIPacketListInit(&pls);
                MIDIPacketListAdd(&pls, sizeof(pls), pks, 0, 6, mmcStop);
                MIDIReceived(testSrc, &pls);
                usleep(60000);
            }
            usleep(300000);
            // 期望:只有一对(按下 + 松开)= 2 条;不应是 6 条(按键来回跳)
            // 一条 MCU 按键事件 = 按下(3 字节)+ 松开(3 字节)= 6 字节;
            // 连发三次若都发出去就是 18 字节(DAW 里 PLAY/STOP 会来回跳)
            int events = probe.totalBytes / 6;
            printf("MCU 按住连发 3 次 → 收到 %d 字节(%d 次触发) => %s\n", probe.totalBytes, events,
                   (events == 1) ? "PASS(只触发一次)" : (events > 1 ? "FAIL(会反复触发)" : "FAIL(被吞了)"));
            MIDIPortDispose(in6);
            probe.want = 0;

            // ---- 测试 6:虚拟端点必须有稳定 uniqueID(Logic 靠它认设备) ----
            SInt32 uid = 0;
            MIDIObjectGetIntegerProperty(core->_virtualSource, kMIDIPropertyUniqueID, &uid);
            printf("虚拟端口 uniqueID = 0x%08X => %s\n", (unsigned)uid,
                   (uid == 0x55463801) ? "PASS(重启不变)" : "FAIL(每次重启都会换,Logic 会判离线)");
        } else {
            printf("MCU 端口没找到,跳过测试 5/6\n");
        }
    }

    // ---- 测试 7:残包恢复 —— 收到缺 F7 的 sysex 之后,普通音符必须还能出来 ----
    {
        const uint8_t broken[] = { 0xF0, 0x7F, 0x00 };
        NSArray *a = [core decodePacket:broken length:3];
        const uint8_t note[] = { 0x90, 0x3C, 0x40 };
        NSArray *b = [core decodePacket:note length:3];
        BOOL recovered = NO;
        for (NSData *m in b) {
            const uint8_t *p = m.bytes;
            if (m.length == 3 && p[0] == 0x90 && p[1] == 0x3C) recovered = YES;
        }
        printf("残包后普通音符(丢弃 %lu 条残包) => %s\n", (unsigned long)a.count,
               recovered ? "PASS(不会被永久吞掉)" : "FAIL(琴从此不响)");
    }

    [core stop];
    MIDIEndpointDispose(testSrc);
    MIDIEndpointDispose(testDst);
    MIDIClientDispose(client);
}

#pragma mark - 自检


// 退出撤端口的自动化验证:start 后应该有我们的两个口,stop 之后必须一个都不剩
+ (int)runStopSelfTest {
    printf("=== 退出清理自检 ===\n");
    RouterCore *core = [[RouterCore alloc] init];
    [core start];
    [core setUseMackieTransport:YES];   // 让 MCU 端口也建出来
    usleep(300000);

    NSInteger before = CMECountEndpointsNamed(@"CME UF8 Router");
    NSInteger beforeMCU = CMECountEndpointsNamed(@"CME UF8 Router MCU");
    printf("stop 前: CME UF8 Router=%ld  CME UF8 Router MCU=%ld\n", (long)before, (long)beforeMCU);

    [core stop];
    usleep(800000);   // 给 MIDIServer 一点时间回收

    NSInteger after = CMECountEndpointsNamed(@"CME UF8 Router");
    NSInteger afterMCU = CMECountEndpointsNamed(@"CME UF8 Router MCU");
    printf("stop 后: CME UF8 Router=%ld  CME UF8 Router MCU=%ld\n", (long)after, (long)afterMCU);

    int fails = 0;
    if (before < 1) { printf("FAIL 虚拟端口没建出来\n"); fails++; }
    if (beforeMCU < 1) { printf("FAIL MCU 端口没建出来\n"); fails++; }
    if (after != 0) { printf("FAIL stop 后虚拟端口仍在\n"); fails++; }
    if (afterMCU != 0) { printf("FAIL stop 后 MCU 端口仍在\n"); fails++; }
    if (!fails) printf("=> PASS (退出时所有端口都已撤)\n");
    else printf("=> FAIL (%d 项)\n", fails);
    return fails;
}

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

    // ---- 回归:running status(标准流设备几乎一定用,以前这里会丢音符/音高错乱) ----
    uint8_t rs[] = { 0x90, 0x3C, 0x40, 0x44, 0x50 };   // 第二个音靠 running status
    msgs = [CMEMIDIProtocol decodeBytes:rs length:5 mode:CMEMIDIProtocolModeStandard sniffedToCME:NULL];
    BOOL rsOK = (msgs.count == 2);
    if (rsOK) {
        const uint8_t *a = ((NSData *)msgs[0]).bytes, *b2 = ((NSData *)msgs[1]).bytes;
        rsOK = (a[0] == 0x90 && a[1] == 0x3C && b2[0] == 0x90 && b2[1] == 0x44 && b2[2] == 0x50);
    }
    printf("running status(90 3C 40 44 50 应解析成 2 个音符): %lu 条 => %s\n",
           (unsigned long)msgs.count, rsOK ? "PASS" : "FAIL(丢音符/音高错乱)");

    // ---- 回归:通道 16 的 0x9F/0xBF 不能被误判成 CME 私有帧 ----
    uint8_t ch16[] = { 0x9F, 0x3C, 0x40, 0xBF, 0x07, 0x64, 0xCF, 0x10 };
    BOOL isCME2 = YES;
    msgs = [CMEMIDIProtocol decodeBytes:ch16 length:8 mode:CMEMIDIProtocolModeAuto sniffedToCME:&isCME2];
    printf("CH16 数据(不能被当成 CME 帧): isCME=%d => %s\n", isCME2,
           (isCME2 == NO && msgs.count >= 2) ? "PASS" : "FAIL");
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
