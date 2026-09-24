// OnyxNetDaemon — 独立 root launchd daemon，唯一负责代 OnyxApp 下载瓦片。
// OnyxApp 是沙盒受限的 mobile 用户 App，本环境无法出站联网；
// 本 daemon 以 root + platform-application 运行，网络正常，代拉瓦片落盘共享缓存。
// 通过 Darwin 通知 com.yzdmm.onyx/tilereq 接收请求，完成后发 com.yzdmm.onyx/tileok。
#import <Foundation/Foundation.h>
#import "OnyxTileProxy.h"

int main(int argc, char *argv[]) {
    @autoreleasepool {
        // launchd 已经 fork，无需 daemon() 传统 double-fork；直接用 runloop 阻塞
        [[OnyxTileProxy shared] startObserving];
        // 长时间运行，必须让主 runloop 转起来以投递 Darwin 通知回调
        [[NSRunLoop currentRunLoop] run];
    }
    return 0;
}