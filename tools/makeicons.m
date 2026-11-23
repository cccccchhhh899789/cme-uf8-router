// 生成图标:应用图标(.icns)+ 菜单栏模板图标(黑白,自动适配深浅色)
// 用法: clang -fobjc-arc ... -o tools/makeicons tools/makeicons.m && tools/makeicons <输出目录>
#import <Cocoa/Cocoa.h>

static NSColor *HexRGB(unsigned v) {
    return [NSColor colorWithSRGBRed:((v >> 16) & 0xFF) / 255.0
                               green:((v >> 8) & 0xFF) / 255.0
                                blue:(v & 0xFF) / 255.0 alpha:1.0];
}

// 画琴键:solidYes 控制「琴键是不是实心黑」(菜单栏模板需要实心黑,应用图标需要白键)
static void DrawKeyboard(CGFloat w, CGFloat h, BOOL darkKeys) {
    // 画布按 1024 设计,调用方已按目标尺寸缩放
    CGFloat keyH = h * 0.30;
    CGFloat baseY = h * 0.16;
    CGFloat left = w * 0.13, right = w * 0.87;
    CGFloat span = right - left;
    NSInteger whites = 8;
    CGFloat gap = span * 0.012;
    CGFloat kw = (span - gap * (whites - 1)) / whites;

    NSColor *whiteCol = darkKeys ? [NSColor blackColor] : HexRGB(0xF6F2EA);
    for (NSInteger i = 0; i < whites; i++) {
        NSRect r = NSMakeRect(left + i * (kw + gap), baseY, kw, keyH);
        NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:r xRadius:kw * 0.16 yRadius:kw * 0.16];
        [whiteCol setFill];
        [p fill];
    }
    // 黑键:只在白键缝上,几个固定位置
    NSColor *blackCol = darkKeys ? [NSColor blackColor] : HexRGB(0x16161A);
    NSInteger pos[5] = { 0, 1, 3, 4, 5 };   // 黑白键的标准分布(避开 2-3 与 6-7 之间)
    CGFloat bw = kw * 0.62, bh = keyH * 0.62;
    for (NSInteger i = 0; i < 5; i++) {
        CGFloat x = left + (pos[i] + 1) * (kw + gap) - bw / 2.0 - gap / 2.0;
        NSRect r = NSMakeRect(x, baseY + keyH - bh, bw, bh);
        NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:r xRadius:bw * 0.14 yRadius:bw * 0.14];
        [blackCol setFill];
        [p fill];
    }
}

// 应用图标:深色圆角方块 + 键盘 + 橙色走带箭头(旧版,留作备选)
static void DrawAppIcon(CGFloat s) {
    NSRect full = NSMakeRect(0, 0, s, s);
    // 背景(略带内缩,给图标一点呼吸感)
    CGFloat inset = s * 0.055;
    NSRect bg = NSInsetRect(full, inset, inset);
    NSBezierPath *sq = [NSBezierPath bezierPathWithRoundedRect:bg
                                                       xRadius:s * 0.225 yRadius:s * 0.225];
    NSGradient *g = [[NSGradient alloc] initWithStartingColor:HexRGB(0x2B2B33)
                                                  endingColor:HexRGB(0x14141A)];
    [g drawInBezierPath:sq angle:-90];

    DrawKeyboard(s, s, NO);

    // 走带箭头:键盘上方一条橙色信号向右
    CGFloat y = s * 0.63;
    NSColor *orange = HexRGB(0xFFB020);
    // 杆与箭头刻意重叠,否则小尺寸下会看成断开的闪电
    NSBezierPath *shaft = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(s * 0.20, y, s * 0.52, s * 0.045)
                                                         xRadius:s * 0.022 yRadius:s * 0.022];
    [orange setFill];
    [shaft fill];
    NSBezierPath *head = [NSBezierPath bezierPath];
    [head moveToPoint:NSMakePoint(s * 0.60, y + s * 0.095)];
    [head lineToPoint:NSMakePoint(s * 0.82, y + s * 0.0225)];
    [head lineToPoint:NSMakePoint(s * 0.60, y - s * 0.050)];
    [head closePath];
    [head fill];
}

// 应用图标(0.1.9 起):深色圆角底 + CME 原厂字标(白字 + 橙点,取自 cme-pro.com)+ UF8 字样
static void DrawAppIconCME(CGFloat s, NSImage *wordmark) {
    NSRect bg = NSInsetRect(NSMakeRect(0, 0, s, s), s * 0.055, s * 0.055);
    NSBezierPath *sq = [NSBezierPath bezierPathWithRoundedRect:bg xRadius:s * 0.225 yRadius:s * 0.225];
    NSGradient *g = [[NSGradient alloc] initWithStartingColor:HexRGB(0x2E2E38)
                                                  endingColor:HexRGB(0x14141A)];
    [g drawInBezierPath:sq angle:-90];

    // 只取 CME 三个字母,丢掉下面那行 slogan —— 16pt 下它就是一团噪点
    CGFloat srcW = 600, srcH = 215, cropH = 150;          // 原图 600x215,字母占上部
    NSRect from = NSMakeRect(0, srcH - cropH, srcW, cropH); // 原点在左下,取上部
    CGFloat wmW = s * 0.66;
    CGFloat wmH = wmW * (cropH / srcW);
    NSRect wmRect = NSMakeRect((s - wmW) / 2.0, s * 0.44, wmW, wmH);
    [wordmark drawInRect:wmRect fromRect:from operation:NSCompositingOperationSourceOver fraction:1.0];

    // 下面一行 UF8,弱化处理,只作型号识别
    NSDictionary *attrs = @{ NSFontAttributeName: [NSFont systemFontOfSize:s * 0.085 weight:NSFontWeightMedium],
                             NSForegroundColorAttributeName: HexRGB(0x9A9AA6) };
    NSString *model = @"UF8";
    NSSize sz = [model sizeWithAttributes:attrs];
    [model drawAtPoint:NSMakePoint((s - sz.width) / 2.0, s * 0.30) withAttributes:attrs];
}

// 菜单栏图标:纯黑剪影(alpha 决定形状),系统会按深浅色自动反色
static void DrawMenuBarIcon(CGFloat s) {
    // 键盘主体:5 个竖条,高矮交替,16pt 下也能认出来
    NSColor *c = [NSColor blackColor];
    [c setFill];
    CGFloat barW = s * 0.115;
    CGFloat gap = s * 0.045;
    CGFloat x0 = (s - (5 * barW + 4 * gap)) / 2.0;
    CGFloat heights[5] = { 0.62, 0.80, 0.66, 0.80, 0.62 };
    for (int i = 0; i < 5; i++) {
        CGFloat bh = s * heights[i];
        NSRect r = NSMakeRect(x0 + i * (barW + gap), (s - bh) / 2.0, barW, bh);
        NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:r xRadius:barW * 0.35 yRadius:barW * 0.35];
        [p fill];
    }
}

static BOOL WritePNG(NSImage *img, CGFloat px, NSString *path) {
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes:NULL pixelsWide:(NSInteger)px pixelsHigh:(NSInteger)px
                     bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
                    colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    NSGraphicsContext *ctx = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:ctx];
    [ctx setImageInterpolation:NSImageInterpolationHigh];
    [img drawInRect:NSMakeRect(0, 0, px, px) fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1.0];
    [NSGraphicsContext restoreGraphicsState];
    NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    if (!png) { printf("PNG 编码失败(px=%.0f)\n", px); return NO; }
    NSError *err = nil;
    // 外接 exFAT 盘上「原子写」要先建临时文件再改名,沙箱下会失败;普通写即可
    BOOL ok = [png writeToFile:path options:0 error:&err];
    if (!ok) printf("写文件失败 %s: %s\n", path.UTF8String, err.localizedDescription.UTF8String);
    return ok;
}

int main(int argc, const char *argv[]) { @autoreleasepool {
    NSString *outDir = (argc > 1) ? [NSString stringWithUTF8String:argv[1]] : @"resources";
    [[NSFileManager defaultManager] createDirectoryAtPath:outDir withIntermediateDirectories:YES attributes:nil error:NULL];

    // ---- 应用图标:1024 设计稿 -> 各尺寸 ----
    NSString *wmPath = [outDir stringByAppendingPathComponent:@"cme-wordmark.png"];
    NSImage *wordmark = [[NSImage alloc] initWithContentsOfFile:wmPath];
    if (!wordmark) { printf("缺 cme-wordmark.png(放在 %s 下)\n", outDir.UTF8String); wordmark = nil; }
    NSImage *appIcon = [[NSImage alloc] initWithSize:NSMakeSize(1024, 1024)];
    [appIcon lockFocus];
    if (wordmark) DrawAppIconCME(1024, wordmark); else DrawAppIcon(1024);
    [appIcon unlockFocus];

    NSString *iconset = [outDir stringByAppendingPathComponent:@"AppIcon.iconset"];
    [[NSFileManager defaultManager] createDirectoryAtPath:iconset withIntermediateDirectories:YES attributes:nil error:NULL];
    NSArray *spec = @[ @[@16, @"icon_16x16.png"], @[@32, @"icon_16x16@2x.png"],
                       @[@32, @"icon_32x32.png"], @[@64, @"icon_32x32@2x.png"],
                       @[@128, @"icon_128x128.png"], @[@256, @"icon_128x128@2x.png"],
                       @[@256, @"icon_256x256.png"], @[@512, @"icon_256x256@2x.png"],
                       @[@512, @"icon_512x512.png"], @[@1024, @"icon_512x512@2x.png"] ];
    for (NSArray *e in spec) {
        CGFloat px = [e[0] doubleValue];
        NSString *p = [iconset stringByAppendingPathComponent:e[1]];
        if (!WritePNG(appIcon, px, p)) { printf("写失败: %s\n", p.UTF8String); return 1; }
    }
    printf("iconset 已生成: %s\n", iconset.UTF8String);

    // ---- 菜单栏图标:18pt 模板,1x/2x ----
    NSImage *menu = [[NSImage alloc] initWithSize:NSMakeSize(18, 18)];
    [menu lockFocus];
    DrawMenuBarIcon(18);
    [menu unlockFocus];
    WritePNG(menu, 18, [outDir stringByAppendingPathComponent:@"menubar.png"]);
    WritePNG(menu, 36, [outDir stringByAppendingPathComponent:@"menubar@2x.png"]);
    printf("菜单栏图标已生成: %s/menubar.png(+@2x)\n", outDir.UTF8String);
} return 0; }
