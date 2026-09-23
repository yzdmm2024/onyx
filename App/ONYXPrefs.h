#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>

// App 端与 Tweak（src/Tweak.xm）通过同一份 plist 文件交换配置。
// 关键：Tweak 0.5.6 改为直接读 plist 文件（绕过 cfprefsd 在 rootless/RootHide 下
// 跨进程读不到配置的问题）；因此 App 端写入必须同步落到同一 plist 文件，不能只走
// CFPreferences（cfprefsd），否则 Tweak 读不到新配置导致定位失效 / 选中不生效。

// rootless 优先，回退标准路径（与 Tweak.xm _onyxLoadPlist 的候选路径一致）
static inline NSString *OnyxPrefsPlistPath(void) {
    NSString *a = @"/var/jb/var/mobile/Library/Preferences/com.yzdmm.onyx.plist";
    if ([[NSFileManager defaultManager] isWritableFileAtPath:a]) return a;
    return @"/var/mobile/Library/Preferences/com.yzdmm.onyx.plist";
}

// 读：优先 plist 文件，回退 CFPreferences（兼容旧写入）
static inline id OnyxPrefsRead(NSString *key) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:OnyxPrefsPlistPath()];
    if (d[key]) return d[key];
    CFStringRef domain = CFSTR("com.yzdmm.onyx");
    CFPropertyListRef v = CFPreferencesCopyValue((__bridge CFStringRef)key, domain,
                                                 kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    id out = v ? (__bridge_transfer id)v : nil;
    return out;
}

// 写：CFPreferences + 直写 plist 文件（两个候选路径都写，原子写），并立即同步给各进程的 Tweak。
static inline void OnyxPrefsWrite(NSString *key, id value) {
    CFStringRef domain = CFSTR("com.yzdmm.onyx");
    CFPreferencesSetValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)value,
                          domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    // 两个候选路径都写，保证 Tweak（rootless 优先读 /var/jb）一定能读到
    NSArray<NSString *> *paths = @[
        @"/var/jb/var/mobile/Library/Preferences/com.yzdmm.onyx.plist",
        @"/var/mobile/Library/Preferences/com.yzdmm.onyx.plist",
    ];
    for (NSString *path in paths) {
        NSMutableDictionary *d = [NSMutableDictionary dictionaryWithContentsOfFile:path];
        if (!d) d = [NSMutableDictionary dictionary];
        d[key] = value;
        [d writeToFile:path atomically:YES];
    }
    CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    // 跨进程：让所有已注入的 App 立即重读并推坐标
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         CFSTR("com.yzdmm.onyx/changed"), NULL, NULL, YES);
}