// mculisten — 监听 "CME UF8 Router MCU" 虚拟源,打印收到的每个包(排查走带键是否真的发出去)
// 编译: clang -fobjc-arc -fmodules-cache-path=./build/clang-module-cache -framework Foundation -framework CoreMIDI -o tools/mculisten tools/mculisten.m
#import <Foundation/Foundation.h>
#import <CoreMIDI/CoreMIDI.h>
#include <unistd.h>

@interface L : NSObject
@property (nonatomic, assign) int count;
@end
@implementation L
@end

static void proc(const MIDIPacketList *list, void *ref, void *conn) {
    L *l = (__bridge L *)ref;
    MIDIPacket *p = (MIDIPacket *)list->packet;
    for (UInt32 i = 0; i < list->numPackets; i++) {
        NSMutableString *s = [NSMutableString string];
        for (UInt16 k = 0; k < p->length; k++) [s appendFormat:@"%02X ", p->data[k]];
        printf("[%d] %s\n", ++l.count, s.UTF8String);
        fflush(stdout);
        p = MIDIPacketNext(p);
    }
}

int main(void) { @autoreleasepool {
    MIDIClientRef client = 0;
    MIDIClientCreate(CFSTR("mculisten"), NULL, NULL, &client);
    MIDIEndpointRef src = 0;
    for (ItemCount i = 0; i < MIDIGetNumberOfSources(); i++) {
        MIDIEndpointRef ep = MIDIGetSource(i);
        CFStringRef nm = NULL; MIDIObjectGetStringProperty(ep, kMIDIPropertyName, &nm);
        NSString *n = nm ? (__bridge_transfer NSString *)nm : @"";
        if ([n isEqualToString:@"CME UF8 Router MCU"]) { src = ep; break; }
    }
    if (!src) {   // 端口是按需创建的:等 90 秒,等 App 那边勾上 MCU
        printf("等 CME UF8 Router MCU 出现(最多 90 秒)…\n"); fflush(stdout);
        for (int k = 0; k < 900 && !src; k++) {
            usleep(100000);
            for (ItemCount i = 0; i < MIDIGetNumberOfSources(); i++) {
                MIDIEndpointRef ep = MIDIGetSource(i);
                CFStringRef nm = NULL; MIDIObjectGetStringProperty(ep, kMIDIPropertyName, &nm);
                NSString *n = nm ? (__bridge_transfer NSString *)nm : @"";
                if ([n isEqualToString:@"CME UF8 Router MCU"]) { src = ep; break; }
            }
        }
        if (!src) { printf("没等到,退出\n"); return 1; }
        printf("端口出现了\n"); fflush(stdout);
    }
    L *l = [[L alloc] init];
    MIDIPortRef port = 0;
    MIDIInputPortCreate(client, CFSTR("listen"), proc, (__bridge void *)l, &port);
    MIDIPortConnectSource(port, src, NULL);
    printf("已连上 CME UF8 Router MCU,监听 300 秒(按琴上的键试试)\n"); fflush(stdout);
    for (int i = 0; i < 3000; i++) usleep(100000);
    printf("结束,共收到 %d 个包\n", l.count);
} return 0; }
