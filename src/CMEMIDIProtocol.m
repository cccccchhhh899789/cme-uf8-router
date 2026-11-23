// CMEMIDIProtocol.m — CME UF 私有 USB-MIDI 协议解码/编码实现
//
// 依据:Linux 内核 sound/usb/midi.c 的 snd_usbmidi_cme_input / snd_usbmidi_transmit_byte。
// 详见 复刻规格书.md §2。

#import "CMEMIDIProtocol.h"

// 标准 CIN -> 数据字节数(USB-MIDI v1.0 规范)
static const uint8_t kCINLength[16] = {
    0, 0, 2, 3, 3, 1, 2, 3, 3, 3, 3, 3, 2, 2, 3, 1
};

@implementation CMEMIDIFrame
- (instancetype)init {
    if ((self = [super init])) {
        _messages = [NSMutableArray array];
    }
    return self;
}
@end

@implementation CMEMIDIProtocol

+ (NSUInteger)standardLengthForCIN:(uint8_t)cin {
    return kCINLength[cin & 0x0F];
}

// 标准 USB-MIDI 4 字节包解析:逐包取 CIN+数据
+ (void)parseStandardPackets:(const uint8_t *)buf length:(NSUInteger)len into:(NSMutableArray<NSData *> *)out {
    NSUInteger i = 0;
    while (i + 3 < len) {
        uint8_t cin = buf[i] & 0x0F;
        NSUInteger dl = kCINLength[cin];
        if (dl > 0) {
            NSData *msg = [NSData dataWithBytes:buf + i + 1 length:dl];
            if (dl == 3 && (buf[i+1] & 0x80) == 0) {
                // 边缘:CIN 3 但首字节不是状态(非标准),按 2 字节处理
                msg = [NSData dataWithBytes:buf + i + 1 length:2];
            }
            [out addObject:msg];
        }
        i += 4;
    }
}

// CME 私有输入:0x0F 前缀的变长帧,整条 sysex/SPP/实时 + 可多条同包
+ (void)parseCMEPackets:(const uint8_t *)buf length:(NSUInteger)len into:(NSMutableArray<NSData *> *)out {
    NSUInteger remaining = len;
    const uint8_t *p = buf;
    while (remaining >= 4) {
        NSUInteger sourceLen = 4;
        uint8_t head = p[0];
        if ((head & 0x0F) == 0x0F) {
            NSUInteger dataLen = 1;
            if (p[1] == 0xF0) {
                // SysEx:向后找 F7(整条在一个包内,CME 不分片)
                NSUInteger j = 2;
                while (j < remaining && p[j] != 0xF7) j++;
                if (j < remaining) {
                    dataLen = j + 1 - 1; // F0..F7 含两端
                    sourceLen = dataLen + 1;
                } else if (j == remaining) {
                    // 未闭合:把剩下全当 sysex(容错)
                    dataLen = remaining - 1;
                    sourceLen = remaining;
                } else {
                    dataLen = 1;
                }
            } else if (p[1] == 0xF2) {
                dataLen = 3; // Song Position Pointer
            } else if (p[1] >= 0xF8) {
                dataLen = 1; // 实时
            } else if (p[1] == 0xFE) {
                dataLen = 1; // Active Sensing
            } else {
                dataLen = 1;
            }
            if (dataLen > 0) {
                NSData *msg = [NSData dataWithBytes:p + 1 length:dataLen];
                [out addObject:msg];
            }
        } else {
            // 普通通道消息:标准解析 4 字节子块
            [self parseStandardPackets:p length:4 into:out];
        }
        p += sourceLen;
        remaining -= sourceLen;
    }
}

+ (NSArray<NSData *> *)decodeBytes:(const uint8_t *)bytes
                            length:(NSUInteger)length
                              mode:(CMEMIDIProtocolMode)mode
                    sniffedToCME:(BOOL *)outIsCME {
    NSMutableArray<NSData *> *result = [NSMutableArray array];
    if (!bytes || length == 0) { if (outIsCME) *outIsCME = NO; return result; }
    if (mode == CMEMIDIProtocolModeStandard) {
        // 标准流:把输入直接按 MIDI 字节流切消息(非 4 字节包)
        [self parseRawByteStream:bytes length:length into:result];
        if (outIsCME) *outIsCME = NO;
        return result;
    }
    if (mode == CMEMIDIProtocolModeCME) {
        [self parseCMEPackets:bytes length:length into:result];
        if (outIsCME) *outIsCME = YES;
        return result;
    }
    // Auto:探测 0x0F 前缀帧;出现即按 CME,否则按标准
    BOOL looksCME = NO;
    for (NSUInteger i = 0; i + 3 < length; i += 4) {
        if ((bytes[i] & 0x0F) == 0x0F) { looksCME = YES; break; }
    }
    if (looksCME) {
        [self parseCMEPackets:bytes length:length into:result];
    } else {
        [self parseRawByteStream:bytes length:length into:result];
    }
    if (outIsCME) *outIsCME = looksCME;
    return result;
}

// 标准 MIDI 字节流切消息(运行状态支持)
+ (void)parseRawByteStream:(const uint8_t *)buf length:(NSUInteger)len into:(NSMutableArray<NSData *> *)out {
    NSUInteger i = 0;
    uint8_t runningStatus = 0;
    while (i < len) {
        uint8_t b = buf[i++];
        if (b < 0x80) {
            // 数据字节,无运行状态则丢弃
            if (!runningStatus) continue;
            // 补运行状态消息
            if (runningStatus >= 0xC0 && runningStatus <= 0xDF) {
                if (i < len) {
                    NSData *msg = [NSData dataWithBytes:(const uint8_t[]){runningStatus, buf[i]} length:2];
                    [out addObject:msg];
                    i++;
                }
            } else if (runningStatus >= 0x80) {
                if (i + 1 < len) {
                    NSData *msg = [NSData dataWithBytes:(const uint8_t[]){runningStatus, buf[i], buf[i+1]} length:3];
                    [out addObject:msg];
                    i += 2;
                }
            }
            continue;
        }
        if (b >= 0xF8) {
            // 实时消息(单字节)
            [out addObject:[NSData dataWithBytes:(const uint8_t[]){b} length:1]];
            runningStatus = 0;
            continue;
        }
        if (b == 0xF0 || b == 0xF7) {
            // SysEx:直到 F7
            NSMutableData *sysex = [NSMutableData dataWithBytes:&b length:1];
            while (i < len) {
                uint8_t d = buf[i++];
                [sysex appendBytes:&d length:1];
                if (d == 0xF7) break;
            }
            [out addObject:sysex];
            runningStatus = 0;
            continue;
        }
        if (b >= 0xF0) {
            // 其他系统消息:SysEx 已处理,这里 F1/F2/F3/F4/F5/F6
            if (b == 0xF1 || b == 0xF3) {
                if (i < len) {
                    [out addObject:[NSData dataWithBytes:(const uint8_t[]){b, buf[i]} length:2]];
                    i++;
                }
            } else if (b == 0xF2) {
                if (i + 1 < len) {
                    [out addObject:[NSData dataWithBytes:(const uint8_t[]){b, buf[i], buf[i+1]} length:3]];
                    i += 2;
                }
            } else if (b == 0xF6) {
                [out addObject:[NSData dataWithBytes:(const uint8_t[]){b} length:1]];
            }
            runningStatus = 0;
            continue;
        }
        // 通道消息(0x80-0xFF,含运行状态记录)
        if (b >= 0x80) {
            runningStatus = b;
            if (b >= 0xC0 && b <= 0xDF) {
                if (i < len) {
                    [out addObject:[NSData dataWithBytes:(const uint8_t[]){b, buf[i]} length:2]];
                    i++;
                }
            } else {
                if (i + 1 < len) {
                    [out addObject:[NSData dataWithBytes:(const uint8_t[]){b, buf[i], buf[i+1]} length:3]];
                    i += 2;
                }
            }
        }
    }
}

// 输出:标准 MIDI 消息 -> CME USB 帧(0x0F 规则,依据内核 transmit_byte)
+ (NSArray<NSData *> *)encodeCMEFramesFromMessage:(NSData *)msg {
    const uint8_t *b = msg.bytes;
    NSUInteger len = msg.length;
    NSMutableArray<NSData *> *frames = [NSMutableArray array];
    if (len == 0) return frames;

    // 实时单字节:0x0F 前缀
    if (len == 1 && b[0] >= 0xF8) {
        uint8_t frame[4] = { 0x0F, b[0], 0, 0 };
        [frames addObject:[NSData dataWithBytes:frame length:4]];
        return frames;
    }
    // Active Sensing
    if (len == 1 && b[0] == 0xFE) {
        uint8_t frame[4] = { 0x0F, 0xFE, 0, 0 };
        [frames addObject:[NSData dataWithBytes:frame length:4]];
        return frames;
    }
    // SysEx:整条 + 0x0F 前缀
    if (b[0] == 0xF0 || b[0] == 0xF7) {
        NSUInteger total = len + 1; // 0x0F + 整条
        NSMutableData *frame = [NSMutableData dataWithCapacity:total];
        uint8_t head = 0x0F;
        [frame appendBytes:&head length:1];
        [frame appendData:msg];
        // 补 0 到 4 的倍数
        while (frame.length % 4 != 0) [frame appendBytes:(const uint8_t[]){0} length:1];
        [frames addObject:frame];
        return frames;
    }
    // 其他系统消息
    if (b[0] >= 0xF0) {
        if (b[0] == 0xF6) {
            uint8_t frame[4] = { 0x05, 0xF6, 0, 0 };
            [frames addObject:[NSData dataWithBytes:frame length:4]];
            return frames;
        }
        if (b[0] == 0xF2 && len >= 3) {
            uint8_t frame[4] = { 0x0F, 0xF2, b[1], b[2] };
            [frames addObject:[NSData dataWithBytes:frame length:4]];
            return frames;
        }
        if ((b[0] == 0xF1 || b[0] == 0xF3) && len >= 2) {
            uint8_t frame[4] = { 0x02, b[0], b[1], 0 };
            [frames addObject:[NSData dataWithBytes:frame length:4]];
            return frames;
        }
        // F4/F5 忽略
        return frames;
    }
    // 通道消息
    if (b[0] >= 0x80) {
        uint8_t status = b[0];
        uint8_t cin = (status >= 0xC0 && status <= 0xDF) ? 0x0C : (status & 0xF0) >> 4;
        // 0x0C=2字节,0x08=3字节
        if (status >= 0xC0 && status <= 0xDF) {
            if (len >= 2) {
                uint8_t frame[4] = { status >> 4 | 0x08 | 0x04, status, b[1], 0 };
                // 简化:2 字节通道(CIN 0x0C)
                frame[0] = (status >> 4) | 0x08; // 0x0C = 2字节通道(0x08|0x04)
                [frames addObject:[NSData dataWithBytes:frame length:4]];
            }
            return frames;
        }
        if (len >= 3) {
            uint8_t frame[4] = { (status >> 4) | 0x08, status, b[1], b[2] };
            [frames addObject:[NSData dataWithBytes:frame length:4]];
        } else if (len >= 2) {
            uint8_t frame[4] = { (status >> 4) | 0x08, status, b[1], 0 };
            [frames addObject:[NSData dataWithBytes:frame length:4]];
        }
    }
    return frames;
}

@end