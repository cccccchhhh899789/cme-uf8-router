// CMEMIDIProtocol.h — CME UF 系列私有 USB-MIDI 协议解码/编码
//
// 依据:Linux 内核 sound/usb/midi.c 的 snd_usbmidi_cme_input / transmit_byte
// 以及本机老驱动逆向结论(见 复刻规格书.md §2)。
// 协议模式支持:自动识别(默认) / 强制 CME-USB / 强制标准流。

#import <Foundation/Foundation.h>
#include <stdint.h>

typedef NS_ENUM(NSInteger, CMEMIDIProtocolMode) {
    CMEMIDIProtocolModeAuto = 0,
    CMEMIDIProtocolModeCME,
    CMEMIDIProtocolModeStandard,
};

// 一帧解码结果:若干条标准 MIDI 消息(字节流,可能 0 条)
@interface CMEMIDIFrame : NSObject
@property(nonatomic, strong) NSMutableArray<NSData *> *messages; // 每条 = 一条完整标准 MIDI 消息
@end

@interface CMEMIDIProtocol : NSObject

// 输入:USB 批量包(64B 等)或标准流缓冲;输出:解析出的多条标准 MIDI 消息。
// mode 决定解析策略;Auto 时先遇 0x0F 前缀帧则按 CME,否则按标准。
+ (NSArray<NSData *> *)decodeBytes:(const uint8_t *)bytes
                            length:(NSUInteger)length
                              mode:(CMEMIDIProtocolMode)mode
                    sniffedToCME:(BOOL *)outIsCME;

// 输出:把标准 MIDI 消息编码成 CME USB 帧(0x0F 规则),用于回写 EP 0x02。
+ (NSArray<NSData *> *)encodeCMEFramesFromMessage:(NSData *)msg;

// 工具:单字节 CIN 长度表(标准)
+ (NSUInteger)standardLengthForCIN:(uint8_t)cin;

@end