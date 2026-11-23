#import <Foundation/Foundation.h>
#import "MIDIMapper.h"
static void t(MIDIMapper *m, const uint8_t *b, NSUInteger n, const char *label) {
    NSData *d = [NSData dataWithBytes:b length:n];
    NSArray *out = [m processMessage:d];
    NSMutableString *s = [NSMutableString string];
    for (NSData *o in out) for (NSUInteger i=0;i<o.length;i++)
        [s appendFormat:@"%02X ", ((const uint8_t*)o.bytes)[i]];
    printf("%-28s 输入=%02X.. → 输出: %s\n", label, b[0], s.length? s.UTF8String : "(无)");
}
int main(void){@autoreleasepool{
    MIDIMapper *m = [[MIDIMapper alloc] init];
    printf("translateMMC=%d\n", (int)m.translateMMC);
    uint8_t rec[]  = {0xF0,0x7F,0x00,0x06,0x06,0xF7};
    uint8_t rex[]  = {0xF0,0x7F,0x00,0x06,0x07,0xF7};
    uint8_t stop[] = {0xF0,0x7F,0x00,0x06,0x01,0xF7};
    uint8_t play[] = {0xF0,0x7F,0x00,0x06,0x02,0xF7};
    uint8_t ff[]   = {0xF0,0x7F,0x00,0x06,0x04,0xF7};
    uint8_t rew[]  = {0xF0,0x7F,0x00,0x06,0x05,0xF7};
    uint8_t spp0[] = {0xF2,0x00,0x00};
    uint8_t spp32[]= {0xF2,0x20,0x00};
    uint8_t spp16[]= {0xF2,0x10,0x00};
    uint8_t note[] = {0x90,0x35,0x4C};
    t(m,rec,6,"MMC 06 Record Strobe");   t(m,rex,6,"MMC 07 Record Exit");
    t(m,stop,6,"MMC 01 Stop");           t(m,play,6,"MMC 02 Play");
    t(m,ff,6,"MMC 04 FF");               t(m,rew,6,"MMC 05 REW");
    t(m,spp0,3,"SPP 0 (首次)");          t(m,spp32,3,"SPP 32");
    t(m,spp16,3,"SPP 16");               t(m,spp0,3,"SPP 0 (回零)");
    uint8_t fa[]={0xFA}, fc[]={0xFC}, f8[]={0xF8}, fe[]={0xFE};
    t(m,fa,1,"实时 FA Start");           t(m,fc,1,"实时 FC Stop");
    t(m,f8,1,"时钟 F8 直通");            t(m,fe,1,"Active Sensing");
    t(m,note,3,"Note On 无影响");
    m.translateMMC = NO;
    t(m,rec,6,"关闭翻译后 MMC");
}return 0;}
