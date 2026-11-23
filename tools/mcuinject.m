// mcuinject — 往 "CME UF8 Router MCU" 虚拟源按时间轴发 MCU 报文,用来和 Logic 对时序。
// 编译: clang -fobjc-arc -fmodules-cache-path=./build/clang-module-cache \
//        -framework Foundation -framework CoreMIDI -o tools/mcuinject tools/mcuinject.m
// 用法: tools/mcuinject        (等 /tmp/mcu_go 出现后开始,方便你在 Logic 里先选好端口)
#import <Foundation/Foundation.h>
#import <CoreMIDI/CoreMIDI.h>
#include <unistd.h>

static MIDIEndpointRef gSrc = 0;
static MIDIEndpointRef gDst = 0;
static MIDIClientRef gClient = 0;
static NSString *LOG = @"/tmp/mcu_inject.log";

static void stamp(const char *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *body = [[NSString alloc] initWithFormat:[NSString stringWithUTF8String:fmt] arguments:ap];
    va_end(ap);
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"HH:mm:ss.SSS";
    NSString *line = [NSString stringWithFormat:@"%@ %@", [df stringFromDate:[NSDate date]], body];
    printf("%s\n", line.UTF8String); fflush(stdout);
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:LOG];
    if (!fh) [[NSFileManager defaultManager] createFileAtPath:LOG contents:nil attributes:nil];
    fh = [NSFileHandle fileHandleForWritingAtPath:LOG];
    [fh seekToEndOfFile];
    NSData *data = [[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
    [fh writeData:data];
    [fh closeFile];
}

// 发一条 3 字节报文(90 note vel);返回是否成功
static void sendNote(uint8_t note, uint8_t vel) {
    MIDIPacketList list; MIDIPacket *p = MIDIPacketListInit(&list);
    Byte bytes[3] = { 0x90, note, vel };
    p = MIDIPacketListAdd(&list, sizeof(list), p, 0, 3, bytes);
    OSStatus st = MIDIReceived(gSrc, &list);
    stamp("  → 发送 90 %02X %02X %s%s", note, vel,
          st == noErr ? "(ok)" : "(失败)",
          vel ? "  ← 按下" : "  ← 松开");
}

static void pressRelease(uint8_t note, int holdMs) {
    sendNote(note, 0x7F);
    usleep(holdMs * 1000);
    sendNote(note, 0x00);
}

// Logic 唤醒表面时会发 F0 00 00 66 14 00 F7,必须回 Device Ready
static void readProc(const MIDIPacketList *pkts, void *refCon, void *conn) {
    const MIDIPacket *p = &pkts->packet[0];
    for (UInt32 i = 0; i < pkts->numPackets; i++) {
        const uint8_t *d = p->data; NSUInteger n = p->length;
        NSLog(@"收到 %lu 字节", (unsigned long)n);
        if (n == 7 && d[0] == 0xF0 && d[1] == 0x00 && d[2] == 0x00 && d[3] == 0x66 &&
            (d[4] == 0x14 || d[4] == 0x15) && d[5] == 0x00 && d[6] == 0xF7) {
            MIDIPacketList reply; MIDIPacket *q = MIDIPacketListInit(&reply);
            Byte ready[7] = { 0xF0, 0x00, 0x00, 0x66, 0x14, 0x01, 0xF7 };
            q = MIDIPacketListAdd(&reply, sizeof(reply), q, 0, 7, ready);
            MIDIReceived(gSrc, &reply);
            stamp("[握手] Logic 唤醒表面 → 已回 Device Ready");
        }
        p = MIDIPacketNext(p);
    }
}

int main(void) { @autoreleasepool {
    [[NSFileManager defaultManager] removeItemAtPath:LOG error:NULL];
    MIDIClientCreate(CFSTR("mcuinject"), NULL, NULL, &gClient);
    // 两个端点:source 用来往 Logic 发, destination 用来接 Logic 的唤醒握手
    MIDIDestinationCreate(gClient, CFSTR("CME UF8 Router MCU"), readProc, NULL, &gDst);
    MIDISourceCreate(gClient, CFSTR("CME UF8 Router MCU"), &gSrc);
    if (!gSrc) { printf("创建端口失败(可能 App 还在跑)\n"); return 1; }
    if (gDst) MIDIObjectSetIntegerProperty(gDst, kMIDIPropertyUniqueID, 0x55463804);
    MIDIObjectSetIntegerProperty(gSrc, kMIDIPropertyUniqueID, 0x55463802);
    MIDIObjectSetStringProperty(gSrc, kMIDIPropertyManufacturer, CFSTR("cme-uf8-router"));

    stamp("=== MCU 信号发生器已就绪,端口 'CME UF8 Router MCU' ===");
    stamp("请确认 Logic 控制表面输入/输出都选了这个端口,然后说「开始」");
    stamp("=== 就绪:每个动作单独触发,改 /tmp/mcu_cmd 里的数字 ===");
    stamp("  1=FF按下松开80ms  2=FF只按下3秒后松开  3=FF松开150ms  4=FF松开250ms");
    stamp("  5=FF用80h note-off  6=REW  7=STOP  8=PLAY  0=全部松开(panic)");
    for (int round = 0; round < 100000; round++) {
        if (![[NSFileManager defaultManager] fileExistsAtPath:@"/tmp/mcu_cmd"]) { usleep(300000); continue; }
        NSString *c = [NSString stringWithContentsOfFile:@"/tmp/mcu_cmd" encoding:NSUTF8StringEncoding error:NULL];
        [[NSFileManager defaultManager] removeItemAtPath:@"/tmp/mcu_cmd" error:NULL];
        int which = c ? c.intValue : 0;
        switch (which) {
            case 1: stamp("[1] FF 按下 + 80ms 松开");   pressRelease(0x5C, 80);  break;
            case 2: stamp("[2] FF 只按下,3 秒后松开");  sendNote(0x5C, 0x7F); sleep(3); sendNote(0x5C, 0x00); break;
            case 3: stamp("[3] FF 按下 + 150ms 松开");  pressRelease(0x5C, 150); break;
            case 4: stamp("[4] FF 按下 + 250ms 松开");  pressRelease(0x5C, 250); break;
            case 5: stamp("[5] FF 用 80h(note-off) 松开");
                    sendNote(0x5C, 0x7F); usleep(80000);
                    { MIDIPacketList l; MIDIPacket *q = MIDIPacketListInit(&l);
                      Byte off[3] = { 0x80, 0x5C, 0x00 };
                      q = MIDIPacketListAdd(&l, sizeof(l), q, 0, 3, off);
                      MIDIReceived(gSrc, &l); stamp("  → 发送 80 5C 00 (note-off)"); }
                    break;
            case 6: stamp("[6] REW 按下 + 80ms 松开");  pressRelease(0x5B, 80);  break;
            case 7: stamp("[7] STOP");                 pressRelease(0x5D, 80);  break;
            case 8: stamp("[8] PLAY");                 pressRelease(0x5E, 80);  break;
            case 9: stamp("[9] 只发 80 5C 00 (真 note-off,不按)");
                    { MIDIPacketList l; MIDIPacket *q = MIDIPacketListInit(&l);
                      Byte off[3] = { 0x80, 0x5C, 0x00 };
                      q = MIDIPacketListAdd(&l, sizeof(l), q, 0, 3, off);
                      MIDIReceived(gSrc, &l); stamp("  → 发送 80 5C 00"); }
                    break;
            case 10: stamp("[10] FF 按下 → 80ms → 真 note-off(80 5C 00)");
                    sendNote(0x5C, 0x7F); usleep(80000);
                    { MIDIPacketList l; MIDIPacket *q = MIDIPacketListInit(&l);
                      Byte off[3] = { 0x80, 0x5C, 0x00 };
                      q = MIDIPacketListAdd(&l, sizeof(l), q, 0, 3, off);
                      MIDIReceived(gSrc, &l); stamp("  → 发送 80 5C 00 (note-off)"); }
                    break;
            case 11: stamp("[11] FF 按下 → 250ms → 90 5C 00");  pressRelease(0x5C, 250); break;
            case 13: stamp("[13] Jog 轮 CC 3C = 01 (顺时针 +1)");
                     { MIDIPacketList l; MIDIPacket *q = MIDIPacketListInit(&l);
                       Byte m[3] = { 0xB0, 0x3C, 0x01 };
                       q = MIDIPacketListAdd(&l, sizeof(l), q, 0, 3, m);
                       MIDIReceived(gSrc, &l); stamp("  → 发送 B0 3C 01"); }
                     break;
            case 14: stamp("[14] Jog 轮 CC 3C = 41 (逆时针 -1)");
                     { MIDIPacketList l; MIDIPacket *q = MIDIPacketListInit(&l);
                       Byte m[3] = { 0xB0, 0x3C, 0x41 };
                       q = MIDIPacketListAdd(&l, sizeof(l), q, 0, 3, m);
                       MIDIReceived(gSrc, &l); stamp("  → 发送 B0 3C 41"); }
                     break;
            case 15: stamp("[15] 连发 4 次 CC 3C = 01");
                     for (int k = 0; k < 4; k++) {
                       MIDIPacketList l; MIDIPacket *q = MIDIPacketListInit(&l);
                       Byte m[3] = { 0xB0, 0x3C, 0x01 };
                       q = MIDIPacketListAdd(&l, sizeof(l), q, 0, 3, m);
                       MIDIReceived(gSrc, &l); usleep(120000);
                     }
                     break;
            case 0: stamp("[0] panic: 把六个键的松开全发一遍");
                    sendNote(0x5B,0); sendNote(0x5C,0); sendNote(0x5D,0);
                    sendNote(0x5E,0); sendNote(0x5F,0); break;
            default: stamp("未知命令: %d", which); break;
        }
        stamp("    —— 动作完成,等你观察 ——");
    }
    stamp("=== 结束;日志在 /tmp/mcu_inject.log ===");
    sleep(2);
    MIDIEndpointDispose(gSrc); if (gDst) MIDIEndpointDispose(gDst); MIDIClientDispose(gClient);
}   return 0; }
