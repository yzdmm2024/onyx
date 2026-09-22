# ============ Onyx Makefile：rootless tweak + 设置面板 ============
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

# ===== 设置面板 PreferenceBundle =====
# Info.plist / Root.plist 放 layout/Library/PreferenceBundles/OnyxPrefs.bundle/
BUNDLE_NAME = OnyxPrefs
OnyxPrefs_FILES = Preferences/OnyxSettingsController.m
OnyxPrefs_INSTALL_PATH = /Library/PreferenceBundles
OnyxPrefs_FRAMEWORKS = UIKit Foundation
OnyxPrefs_PRIVATE_FRAMEWORKS = Preferences   # 坑E：必须显式链 Preferences
OnyxPrefs_LDFLAGS = -F$(TARGET_PRIVATE_FRAMEWORK_PATH)  # 坑3：补 -F 搜索路径
OnyxPrefs_CFLAGS = -fobjc-arc -fobjc-exceptions -w

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/bundle.mk
