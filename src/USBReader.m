// USBReader.m — 直读 CME UF8 的 0x82 bulk IN 端点

#import "USBReader.h"

#import <IOKit/IOKitLib.h>
#import <IOUSBHost/IOUSBHost.h>
#include <unistd.h>

#define CME_VENDOR_ID   0x7104
#define CME_PRODUCT_ID  0x2202
#define CME_EP_IN       0x82
#define CME_READ_LEN    64          // 琴的 bulk IN 包大小
#define CME_READ_TIMEOUT 1.0

@implementation USBMIDIReader {
    IOUSBHostInterface *_iface;
    IOUSBHostPipe *_pipeIn;
    NSThread *_thread;
    volatile BOOL _running;
}

#pragma mark - 设备查找

// 在 IOUSBHostInterface 里按 idVendor/idProduct 找(接口节点会继承设备属性)
+ (io_service_t)copyServiceForCME {
    CFMutableDictionaryRef match = IOServiceMatching("IOUSBHostInterface");
    if (!match) return 0;
    io_iterator_t it = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, match, &it) != KERN_SUCCESS) return 0;

    io_service_t found = 0;
    io_service_t svc;
    while ((svc = IOIteratorNext(it))) {
        int vid = -1, pid = -1;
        CFTypeRef v = IORegistryEntryCreateCFProperty(svc, CFSTR("idVendor"), kCFAllocatorDefault, 0);
        CFTypeRef p = IORegistryEntryCreateCFProperty(svc, CFSTR("idProduct"), kCFAllocatorDefault, 0);
        if (v) { CFNumberGetValue(v, kCFNumberIntType, &vid); CFRelease(v); }
        if (p) { CFNumberGetValue(p, kCFNumberIntType, &pid); CFRelease(p); }
        if (vid == CME_VENDOR_ID && pid == CME_PRODUCT_ID) { found = svc; break; }
        IOObjectRelease(svc);
    }
    IOObjectRelease(it);
    return found;
}

+ (BOOL)devicePresent {
    io_service_t svc = [self copyServiceForCME];
    if (svc) { IOObjectRelease(svc); return YES; }
    return NO;
}

#pragma mark - 打开

- (BOOL)openDevice:(NSError **)err {
    if (_iface) return YES;
    io_service_t svc = [[self class] copyServiceForCME];
    if (!svc) {
        if (err) *err = [NSError errorWithDomain:@"USBMIDIReader" code:1
                                       userInfo:@{NSLocalizedDescriptionKey:
                                                      @"USB 总线上没有 CME UF8(0x7104:0x2202)。请确认琴已开机、USB 线插的是方口那个口。"}];
        return NO;
    }

    NSError *e = nil;
    _iface = [[IOUSBHostInterface alloc] initWithIOService:svc options:0 queue:nil error:&e interestHandler:nil];
    IOObjectRelease(svc);
    if (!_iface) {
        if (err) *err = e ?: [NSError errorWithDomain:@"USBMIDIReader" code:2
                                           userInfo:@{NSLocalizedDescriptionKey:
                                                          @"打开 USB 接口失败。常见原因:另一个程序(可能是 Chrome 的 WebUSB 页面)占着这台琴。"}];
        return NO;
    }

    e = nil;
    _pipeIn = [_iface copyPipeWithAddress:CME_EP_IN error:&e];
    if (!_pipeIn) {
        if (err) *err = e ?: [NSError errorWithDomain:@"USBMIDIReader" code:3
                                           userInfo:@{NSLocalizedDescriptionKey:@"取不到 0x82 端点。"}];
        _iface = nil;   // ARC 收尾时会 close
        return NO;
    }
    return YES;
}

#pragma mark - 读取线程

- (void)start {
    if (_running) return;
    if (!_pipeIn) return;
    _running = YES;
    _thread = [[NSThread alloc] initWithTarget:self selector:@selector(readLoop) object:nil];
    _thread.name = @"cme-usb-read";
    _thread.qualityOfService = NSQualityOfServiceUserInteractive;   // 琴空闲也在喷包,别被降频
    [_thread start];
}

- (void)stop {
    _running = NO;
}

- (void)readLoop {
    NSMutableData *buf = [NSMutableData dataWithLength:CME_READ_LEN];
    int consecutiveFailures = 0;
    while (_running) {
        @autoreleasepool {
            NSError *e = nil;
            NSUInteger transferred = 0;
            BOOL ok = [_pipeIn sendIORequestWithData:buf
                                    bytesTransferred:&transferred
                                   completionTimeout:CME_READ_TIMEOUT
                                               error:&e];
            if (!ok) {
                consecutiveFailures++;
                if (_running && self.errorHandler) {
                    NSString *msg = e.localizedDescription ?: @"读取 USB 失败";
                    self.errorHandler([NSString stringWithFormat:@"%@ (连续 %d 次)", msg, consecutiveFailures]);
                }
                // 前几次多半是超时/瞬时错误,只等一等;连续失败说明 pipe 已经废了
                // (拔线、琴休眠、被别的进程抢走),必须重新枚举设备,否则就永远读空
                if (consecutiveFailures >= 3) {
                    consecutiveFailures = 0;
                    _running = NO;                     // 先让当前循环退出
                    usleep(300000);
                    NSError *reopenErr = nil;
                    BOOL reopened = NO;
                    for (int attempt = 0; attempt < 5 && _running == NO; attempt++) {
                        _pipeIn = nil;   // 旧 SDK 没有 abort/close,交给 ARC 释放管道
                        _iface = nil;                  // ARC 收尾(close 在旧 SDK 不可见)
                        if ([self openDevice:&reopenErr]) { reopened = YES; break; }
                        usleep(700000);                // 等琴重新枚举出来
                    }
                    if (reopened) {
                        _running = YES;
                        if (self.errorHandler) self.errorHandler(@"USB 已重新连上");
                        continue;
                    }
                    if (self.errorHandler) {
                        self.errorHandler([NSString stringWithFormat:@"USB 重新打开失败: %@",
                                           reopenErr.localizedDescription ?: @"设备不在?"]);
                    }
                    _running = YES;                    // 继续循环,下一轮再试
                }
                // 设备可能被拔了:稍等再试,不要空转烧 CPU
                for (int i = 0; i < 20 && _running; i++) usleep(50000);
                continue;
            }
            consecutiveFailures = 0;
            if (transferred == 0) continue;     // 空包(ZLP):丢掉即可
            if (self.packetHandler) {
                NSData *pkt = [NSData dataWithBytes:buf.bytes length:transferred];
                self.packetHandler(pkt);
            }
        }
    }
}

@end
