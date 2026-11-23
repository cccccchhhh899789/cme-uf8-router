// AppDelegate.h — 菜单栏 App 主体

#import <Cocoa/Cocoa.h>
#import "RouterCore.h"

@interface AppDelegate : NSObject <NSApplicationDelegate, RouterCoreDelegate>

@property(nonatomic, strong) RouterCore *core;

// 菜单自检:检查菜单项 target 是否响应 action(防「灰显点不动」)
+ (int)runMenuSelfTest;
+ (int)runQuitSelfTest;
+ (int)runActionSelfTest;

@end