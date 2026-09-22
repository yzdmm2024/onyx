# ============ Onyx Makefile：rootless tweak + 独立 App 配置面板 ============
# 来源：键盘下方状态 v1.0.3 模板（CI 绿 + 真机面板可加载）
# 适配：iOS16.0+（16.6 / 17.3 均测），Relaxin rootless

# 坑G：SDK 14.5（新 Xcode SDK 无私有框架 tbd，链不了 Preferences）
TARGET := iphone:clang:14.5:14.0
# 坑F：arm64e 设备「设置」进程跑 arm64e，纯 arm64 的 bundle 加载报「已损坏」
ARCHS = arm64 arm64e
THEOS_PACKAGE_SCHEME = rootless
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

# ===== Tweak 本体（按 app 注入，per-app 控制）=====
TWEAK_NAME = Onyx
Onyx_FILES = src/Tweak.xm
Onyx_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -w
Onyx_FRAMEWORKS = UIKit Foundation CoreLocation CoreGraphics

# ===== 独立配置 App =====
# 生成 /Applications/OnyxApp.app，桌面打开配置
APPLICATION_NAME = OnyxApp
OnyxApp_FILES = App/main.m App/ONYXAppDelegate.m App/ONYXMapViewController.m App/ONYXAppsViewController.m App/ONYXCoordTransform.m App/ONYXMapView.m App/ONYXAMapView.m App/ONYXLocationSimulator.m
OnyxApp_FRAMEWORKS = UIKit Foundation CoreLocation CoreGraphics WebKit
OnyxApp_CFLAGS = -fobjc-arc -fobjc-exceptions -Wno-deprecated-declarations -w
OnyxApp_LDFLAGS = -Wl,-undefined,dynamic_lookup
OnyxApp_ENTITLEMENTS = App/OnyxApp.entitlements
OnyxApp_RESOURCE_DIRS = App/Resources

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/application.mk

after-install::
	install.exec "uicache -p /var/jb/Applications/OnyxApp.app"
