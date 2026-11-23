// main.m — cme-uf8-router 入口
//
// 用法:
//   cme-uf8-router --selftest    # 无 GUI,跑协议自检后退出
//   cme-uf8-router               # 启动菜单栏 App

#import <Cocoa/Cocoa.h>
#import "AppDelegate.h"
#import "RouterCore.h"

int main(int argc, const char *argv[]) {
    // 自检模式:不启动 GUI
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--reset-config") == 0) {
            // 把配置文件恢复默认(过滤器全关、MMC→CC 翻译开)
            NSString *dir = [@"~/Library/Application Support/cme-uf8-router" stringByExpandingTildeInPath];
            NSString *plist = [dir stringByAppendingPathComponent:@"midi-map.plist"];
            NSFileManager *fm = [NSFileManager defaultManager];
            [fm removeItemAtPath:plist error:NULL];
            MIDIMapper *m = [[MIDIMapper alloc] init];
            [m saveConfig];
            printf("已重置配置: %s\n", plist.UTF8String);
            printf("  filterCC1=%d filterCC7=%d filterClock=%d filterSensing=%d translateMMC=%d\n",
                   m.filterCC1, m.filterCC7, m.filterClock, m.filterSensing, m.translateMMC);
            return 0;
        }
        if (strcmp(argv[i], "--selftest") == 0) {
            @autoreleasepool {
                [RouterCore runSelfTest];
            }
            return 0;
        }
        if (strcmp(argv[i], "--route-selftest") == 0) {
            @autoreleasepool {
                [RouterCore runRouteSelfTest];
            }
            return 0;
        }
        if (strcmp(argv[i], "--menu-selftest") == 0) {
            @autoreleasepool {
                return [AppDelegate runMenuSelfTest];
            }
        }
        if (strcmp(argv[i], "--action-selftest") == 0) {
            @autoreleasepool {
                return [AppDelegate runActionSelfTest];
            }
        }
        if (strcmp(argv[i], "--quit-selftest") == 0) {
            @autoreleasepool {
                return [AppDelegate runQuitSelfTest];
            }
        }
    }
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        AppDelegate *delegate = [[AppDelegate alloc] init];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}