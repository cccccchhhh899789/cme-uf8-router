// MIDIMapper.h — 映射/过滤层
//
// 负责把解码后的标准 MIDI 消息再翻译成用户期望的输出:
//  - transport 键 → CC 114–119(默认,可配置)
//  - M.VOLUME → CC7 CH1(默认)
//  - 过滤器(CC1 调制轮 / CC7 音量 / 时钟 / ActiveSensing)可开关
// 配置从 ~/Library/Application Support/cme-uf8-router/midi-map.plist 读取。

#import <Foundation/Foundation.h>

@interface MIDIMapper : NSObject

// —— 白名单:勾选 = 放行,不勾 = 丢弃 ——
// (0.1.13 从「黑名单式过滤」改成白名单:白名单才说得清「琴上到底哪些东西会进 DAW」)
@property(nonatomic, assign) BOOL allowNotes;      // 键盘音符(Note On/Off)
@property(nonatomic, assign) BOOL allowPitch;      // 弯音轮
@property(nonatomic, assign) BOOL allowCC;         // 控制器(推子/旋钮/踏板/程序改变)
@property(nonatomic, assign) BOOL allowSysEx;      // 系统专用(MMC 等 sysex、SPP)
@property(nonatomic, assign) BOOL allowClock;      // 时钟 F8 等实时消息
@property(nonatomic, assign) BOOL allowSensing;    // Active Sensing FE(琴空闲时 4 条/秒,纯噪音)

@property(nonatomic, assign) BOOL allowCC1;        // 单独放行 CC#1 调制轮(默认放行)
@property(nonatomic, assign) BOOL allowCC2;        // 单独放行 CC#2 呼吸控制
@property(nonatomic, assign) BOOL allowCC7;        // 单独放行 CC#7 音量/推子
@property(nonatomic, assign) BOOL allowCC64;       // 单独放行 CC#64 延音踏板
@property(nonatomic, assign) BOOL allowCC114;      // 单独放行 CC#114-119 走带(含 Jog)
@property(nonatomic, assign) BOOL filterClock;     // 丢弃实时时钟 F8-FF
@property(nonatomic, assign) BOOL filterSensing;   // 丢弃 Active Sensing FE
@property(nonatomic, strong) NSDictionary<NSNumber *, NSNumber *> *transportMap; // 源CC -> 目标CC
@property(nonatomic, assign) BOOL translateMMC;   // MMC(F0 7F..06 x F7) / SPP(F2) -> CC114-119
// 只影响本次运行,不写进 plist:MCU 模式下临时关掉 CC 翻译,免得一个键触发两次
@property(nonatomic, assign) BOOL runtimeMuteCC;
@property(nonatomic, assign) BOOL useMackie;      // transport 是否走 Mackie Control(会存进 plist)
@property(nonatomic, copy) NSString *lastSource;   // 上次选的输入源(重启后自动恢复)
@property(nonatomic, copy) NSString *lastDest;     // 上次选的输出目标
// 输入方式:NO = 从 CoreMIDI 源读(U2MIDI Pro 等);YES = 直读琴的 USB 口
// (琴的 USB 口报的是假 CDC,macOS 不给它挂 MIDI 驱动,所以只能自己读)
@property(nonatomic, assign) BOOL useUSB;

// 处理一条消息,返回要输出的消息数组(可能 0/1/多条)
- (NSArray<NSData *> *)processMessage:(NSData *)msg;

// Mackie Control 输出:transport 事件 -> MCU 按键(Note On ch1)
// 返回 @[按下(vel 0x7F), 松开(vel 0x00)],非 transport 消息返回 @[]
- (NSArray<NSData *> *)mcuMessagesFor:(NSData *)msg;
- (NSArray<NSData *> *)mcuMessagesForKey:(NSInteger)key;
// transport 归一化:1=RTZ 2=REW 3=FF 4=REC 5=STOP 6=PLAY,不是 transport 返回 0
- (NSInteger)transportKeyForMessage:(NSData *)msg;
- (void)setLastSourceIfNeeded:(NSString *)name;   // 只在变化时写盘,避免每包都写
- (void)setLastDestIfNeeded:(NSString *)name;
- (void)loadConfig;   // 从 plist 重载
- (void)saveConfig;   // 写回 plist

@end