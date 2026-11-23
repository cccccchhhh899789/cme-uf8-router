// main.m — cme-uf8-router 入口
//
// 用法:
//   cme-uf8-router --selftest    # 无 GUI,跑协议自检后退出
//   cme-uf8-router               # 启动菜单栏 App

#import <Cocoa/Cocoa.h>
#import "AppDelegate.h"
#import "RouterCore.h"
#include <sys/file.h>
#include <fcntl.h>
#include <unistd.h>

// 单实例锁:两个实例同时跑会抢同一个虚拟端口名、互相覆盖配置、对 Logic 重复响应。
// /tmp 下加 flock 即可(不能用 ~/Library,沙箱里跑自检时写不进去)。
static int gLockFD = -1;
static BOOL acquireSingleInstanceLock(void) {
    const char *path = "/tmp/cme-uf8-router.lock";
    gLockFD = open(path, O_CREAT | O_RDWR, 0644);
    if (gLockFD < 0) return YES;            // 打不开锁文件就不拦(宁可多跑也不要起不来)
    if (flock(gLockFD, LOCK_EX | LOCK_NB) != 0) {
        close(gLockFD); gLockFD = -1;
        return NO;
    }
    return YES;
}

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
        if (strcmp(argv[i], "--stop-selftest") == 0) {
            @autoreleasepool {
                return [RouterCore runStopSelfTest];
            }
        }
        if (strcmp(argv[i], "--quit-selftest") == 0) {
            @autoreleasepool {
                return [AppDelegate runQuitSelfTest];
            }
        }
    }
    @autoreleasepool {
        if (!acquireSingleInstanceLock()) {
            fprintf(stderr, "已经有一个 cme-uf8-router 在跑了(端口名会冲突),本次不启动。\n");
            return 0;
        }
        NSApplication *app = [NSApplication sharedApplication];
        AppDelegate *delegate = [[AppDelegate alloc] init];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}