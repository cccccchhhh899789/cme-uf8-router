// MIDIMapper.h — 映射/过滤层
//
// 负责把解码后的标准 MIDI 消息再翻译成用户期望的输出:
//  - transport 键 → CC 114–119(默认,可配置)
//  - M.VOLUME → CC7 CH1(默认)
//  - 过滤器(CC1 调制轮 / CC7 音量 / 时钟 / ActiveSensing)可开关
// 配置从 ~/Library/Application Support/cme-uf8-router/midi-map.plist 读取。

#import <Foundation/Foundation.h>

@interface MIDIMapper : NSObject

@property(nonatomic, assign) BOOL filterCC1;       // 丢弃 CC#1 调制轮(故障件)
@property(nonatomic, assign) BOOL filterCC7;       // 丢弃 CC#7 音量
@property(nonatomic, assign) BOOL filterClock;     // 丢弃实时时钟 F8-FF
@property(nonatomic, assign) BOOL filterSensing;   // 丢弃 Active Sensing FE
@property(nonatomic, strong) NSDictionary<NSNumber *, NSNumber *> *transportMap; // 源CC -> 目标CC
@property(nonatomic, assign) BOOL translateMMC;   // MMC(F0 7F..06 x F7) / SPP(F2) -> CC114-119
// 只影响本次运行,不写进 plist:MCU 模式下临时关掉 CC 翻译,免得一个键触发两次
@property(nonatomic, assign) BOOL runtimeMuteCC;
@property(nonatomic, assign) BOOL useMackie;      // transport 是否走 Mackie Control(会存进 plist)
@property(nonatomic, copy) NSString *lastSource;   // 上次选的输入源(重启后自动恢复)
@property(nonatomic, copy) NSString *lastDest;     // 上次选的输出目标

// 处理一条消息,返回要输出的消息数组(可能 0/1/多条)
- (NSArray<NSData *> *)processMessage:(NSData *)msg;

// Mackie Control 输出:transport 事件 -> MCU 按键(Note On ch1)
// 返回 @[按下(vel 0x7F), 松开(vel 0x00)],非 transport 消息返回 @[]
- (NSArray<NSData *> *)mcuMessagesFor:(NSData *)msg;
// transport 归一化:1=RTZ 2=REW 3=FF 4=REC 5=STOP 6=PLAY,不是 transport 返回 0
- (NSInteger)transportKeyForMessage:(NSData *)msg;
- (void)setLastSourceIfNeeded:(NSString *)name;   // 只在变化时写盘,避免每包都写
- (void)setLastDestIfNeeded:(NSString *)name;
- (void)loadConfig;   // 从 plist 重载
- (void)saveConfig;   // 写回 plist

@end