// USBReader.h — 直读 CME UF8 的 USB 口(绕过 macOS 不认它的假 CDC 描述符)
//
// 背景(实测,见 复刻实现与排错.md):
//   这台琴的 USB 接口报 bInterfaceClass=2(CDC 串口)、4 个 bulk 端点,
//   macOS 不挂任何 MIDI 驱动 → CoreMIDI 里永远看不到它。
//   但数据本身是好的:0x82(64B bulk IN)里就是 MIDI,
//   其中音符/CC 用标准 CIN(0x09/0x0B...),走带(SPP/MMC)用 CME 私有 0x0F 帧。
//
// 所以这里只做一件事:把 0x82 的原始字节原样交给上层,
// 由 CMEMIDIProtocol 按 Auto 模式解(它能同时吃标准和 0x0F 帧)。

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface USBMIDIReader : NSObject

// 收到一包原始字节(通常是 4 字节的整数倍,但也可能是短包)
@property(nonatomic, copy, nullable) void (^packetHandler)(NSData *packet);
// 读失败/设备掉线时回报(返回后 loop 会继续重试,除非已 stop)
@property(nonatomic, copy, nullable) void (^errorHandler)(NSString *message);

// 设备是否在 USB 总线上(不打开)
+ (BOOL)devicePresent;

// 打开设备与端点;失败时 *err 给出原因(常见:被 Chrome 的 WebUSB 占着)
- (BOOL)openDevice:(NSError **)err;

// 开始/停止读取线程
- (void)start;
- (void)stop;
@property(nonatomic, readonly) BOOL isRunning;

@end

NS_ASSUME_NONNULL_END
