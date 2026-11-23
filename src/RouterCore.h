// RouterCore.h — CoreMIDI 路由核心
//
// 枚举系统所有 MIDI 源/目标,让用户选输入输出;
// 输入回调 -> 协议解码(自动/CME/标准) -> 映射/过滤 -> 输出。
// 支持设备热插拔(接收 MIDI 通知刷新列表)。

#import <Foundation/Foundation.h>
#import "CMEMIDIProtocol.h"
#import "MIDIMapper.h"

NS_ASSUME_NONNULL_BEGIN

@protocol RouterCoreDelegate <NSObject>
- (void)routerDidRefreshDevices:(id)sender;       // 设备列表/选择变化
- (void)router:(id)sender didLog:(NSString *)line; // 日志(状态行)
@end

@interface RouterCore : NSObject

@property(nonatomic, weak, nullable) id<RouterCoreDelegate> delegate;
@property(nonatomic, assign) CMEMIDIProtocolMode protocolMode;  // 协议模式(默认自动)
@property(nonatomic, strong, readonly) MIDIMapper *mapper;

// 设备快照
@property(nonatomic, strong, readonly) NSArray<NSString *> *sourceNames;
@property(nonatomic, strong, readonly) NSArray<NSString *> *destNames;

// 选择(存名字,枚举时匹配)
@property(nonatomic, copy, nullable) NSString *selectedSourceName;
@property(nonatomic, copy, nullable) NSString *selectedDestName;
// transport 键用 Mackie Control 格式发到 "CME UF8 Router MCU" 口(Logic 当控制表面用)
// 乐器/音符等仍在普通虚拟输出里,两者互不干扰
@property(nonatomic, assign) BOOL useMackieTransport;
// 原始报文抓包(排错用,默认关):默认关是因为它会在 MIDI 实时线程上产生磁盘 IO,
// 而且会把用户弹的东西持久化下来
@property(nonatomic, assign) BOOL captureRawEnabled;

- (void)log:(NSString *)line;  // 往日志(状态行/日志窗口)写一行
- (void)refreshDevices;        // 重新枚举
- (void)start;                  // 启动监听/路由
- (void)stop;

// 自检(无 GUI):喂一包数据走全链路,打印结果
+ (void)runSelfTest;
+ (void)runRouteSelfTest;
+ (int)runStopSelfTest;

@end

NS_ASSUME_NONNULL_END