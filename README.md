# GO~（Onyx）越狱插件 — 完整资料与发布流程

> 包名 `com.yzdmm.onyx` ｜ 显示名 `GO~` ｜ 越狱源 https://yzdmm2024.github.io/repo/
> 适配：iOS 15–17，rootless（arm64 无根 Dopamine/palera1n + arm64e 隐根 Relaxin/RootHide），A12+
> 当前版本：**1.0.3**

---

## 一、这个插件是什么

一个系统级定位模拟插件 + 独立配置 App，用来把设备定位改到任意坐标（"想去哪里就去哪里"）。

两个核心能力：

1. **定位模拟** — 通过私有 API `CLSimulationManager` 做**系统级全局模拟**，所有 App 自动生效。
2. **地图选点** — 自带 App 内嵌自绘瓦片地图，可搜索 / 拖动 / 缩放选点；瓦片由 SpringBoard 进程代拉。

### 为什么钉钉检测不到

| 检测维度 | 本插件做法 |
|---|---|
| 注入范围 | **只注入 SpringBoard**（`com.apple.springboard`），钉钉进程里没有任何 dylib |
| 模拟方式 | `CLSimulationManager` 是 iOS 原生机制，App 侧无法查询/感知 |
| App 名称 | 显示名 `GO~`，图标为紫色渐变"GO"字样，不像定位工具 |

> 关键结论：**只要不往目标 App（钉钉）进程里注入任何东西，反作弊就扫不到。**
> 之前 v0.5.x–v0.7.x 走的是 per-app hook 路线（WildCard 注入所有 UIKit App），
> 钉钉扫自己进程的 dylib 列表就直接报"使用虚拟打卡"。

---

## 二、技术架构

```
┌─────────────────────────────┐         ┌──────────────────────────────┐
│  OnyxApp（独立配置 App）      │         │  SpringBoard（注入 Onyx.dylib）│
│  /var/jb/Applications/       │         │                              │
│      OnyxApp.app             │         │  1) CLSimulationManager      │
│                              │         │     → 系统级定位模拟           │
│  · 自绘瓦片地图选点            │         │                              │
│  · 写配置 plist               │         │  2) OnyxTileProxy            │
│  · 发 Darwin 通知             │         │     → 代拉地图瓦片             │
└──────────┬──────────────────┘         └───────────┬──────────────────┘
           │                                        │
           │  ① 配置：写多份 plist（原子写）           │
           │  ② 通知：com.yzdmm.onyx/changed          │
           ├────────────────────────────────────────┤
           │  ③ 瓦片：com.yzdmm.onyx/tilereq /tileok  │
           │     + 共享缓存 /var/mobile/Library/OnyxTileCache/<sha1(url)>
           ▼                                        ▼
```

### 2.1 定位模拟（src/Tweak.xm）

- 只在 `SpringBoard` 进程执行（`%ctor` 里判断进程名）。
- 用 `CLSimulationManager` 私有类：`[[cls alloc] init]` → `appendSimulatedLocation:` → `startLocationSimulation`。
- 停止：`stopLocationSimulation`。

> ⚠️ **API 必须完全对齐 LocSim**（`C:\Users\Administrator\Desktop\8月\修改定位dylib`）：
> - ✅ `alloc/init` + `appendSimulatedLocation:` + `startLocationSimulation`
> - ❌ 曾误用不存在的 `sharedSimulationManager` + `startSimulationWithLocation:` → **SpringBoard 崩溃进安全模式**

### 2.2 配置交换（App/ONYXPrefs.h）

App 端写配置时**同时写多份 plist**（原子写），Tweak 端按优先级依次尝试读取：

| 优先级 | 路径 | 用途 |
|---|---|---|
| 1 | `/var/jb/Library/MobileSubstrate/DynamicLibraries/com.yzdmm.onyx.prefs.plist` | rootless Tweak 同目录（dylib 能加载就能读） |
| 2 | `/Library/MobileSubstrate/DynamicLibraries/com.yzdmm.onyx.prefs.plist` | 标准路径 |
| 3 | `/var/tmp/com.yzdmm.onyx.plist` | 公共路径（沙盒 App 也能读写） |
| 4 | `/var/jb/var/mobile/Library/Preferences/com.yzdmm.onyx.plist` | rootless Preferences |
| 5 | `/var/mobile/Library/Preferences/com.yzdmm.onyx.plist` | 标准 Preferences |

配置字段：`enabled`(BOOL)、`Latitude`(double)、`Longitude`(double)。
写完发 `com.yzdmm.onyx/changed` 通知，SpringBoard 立刻重读并生效。

> ⚠️ **key 大小写必须一致**：App 写 `enabled`（小写），Tweak 曾误读 `Enabled` → 配置永远读不到、定位无效果。

### 2.3 瓦片代拉（src/OnyxTileProxy.m + App/ONYXAMapView.m）

**背景**：OnyxApp 是普通沙盒 App，在 rootless 环境下被网络策略拦截（`EHOSTUNREACH`），
即使补了 `platform-application` + `no-sandbox` entitlement 仍出不去。

**方案**：SpringBoard 是 platformized 进程，可正常联网。让它当代理：

1. OnyxApp 查共享缓存 `/var/mobile/Library/OnyxTileCache/<sha1(url)>`，命中直接用。
2. 未命中 → 写请求 plist 到请求目录 + 发 `com.yzdmm.onyx/tilereq` 通知。
3. SpringBoard 侧 `OnyxTileProxy` 收到 → **6 并发**下载瓦片 → 落盘共享缓存 → 发 `com.yzdmm.onyx/tileok`。
4. OnyxApp 收到 `tileok` → 重查缓存渲染；超时（智能重置）→ 切离线程序化底图兜底。

瓦片多源自动回退：**高德 webrd → 高德 webst → OSM → 离线程序化底图**。

---

## 三、目录结构

```
修改定位的DEB/
├── Makefile                      # theos 构建：Tweak + 独立 App
├── control                       # deb 元信息（Package/Version/Depends/Description）
├── Onyx.plist                    # 注入过滤器（只注入 com.apple.springboard）
├── preinst / postinst / prerm    # 安装/卸载脚本（uicache 刷新图标、卸载清理）
├── .github/workflows/build.yml   # CI：双架构出包 + 签名 entitlements
├── src/
│   ├── Tweak.xm                  # 定位模拟（CLSimulationManager 系统级）
│   ├── OnyxTileProxy.h/.m        # SpringBoard 侧瓦片代拉
├── App/                          # 独立配置 App（OnyxApp）
│   ├── main.m / ONYXAppDelegate.m
│   ├── ONYXMapViewController.m   # 主界面（选点/开关/恢复）
│   ├── ONYXAMapView.m            # 自绘瓦片地图
│   ├── ONYXCoordTransform.m      # WGS-84 ↔ GCJ-02 坐标转换
│   ├── ONYXPrefs.h               # 配置读写（多路径 plist）
│   ├── OnyxApp.entitlements      # App 权限签名
│   └── Resources/                # Info.plist + 图标
├── diag/                         # 真机诊断脚本（Frida / entitlement 探测）
├── publish_onyx.py               # ★ 发布到越狱源（主脚本）
├── push_deb.py                   # 发布到越狱源（通用版，支持 Icon 字段）
├── clean_onyx.py                 # 清理源里 Onyx 重复 stanza
└── onyx_debug.js                 # 真机调试用 Frida 脚本
```

> 构建产物（`dl/`、`downloads/`、`packages_ci/`、`.ci_artifacts/`、`*.deb`）不入库、不转移。

---

## 四、完整发布流程

### 前置环境

- Windows 本机：`gh`（已登录 `yzdmm2024`）、`git`、`python3`
- GitHub 仓库：`yzdmm2024/onyx`（源码）→ CI 出包 → `yzdmm2024/repo`（越狱源）
- CI 环境自带 theos + ldid（`build.yml` 自动装，无需本机 theos）

### 步骤 1 — 改代码

按需修改 `src/`、`App/`。改完**务必同步版本号**：

| 文件 | 字段 |
|---|---|
| `control` | `Version: x.y.z` + `Description:` 更新说明 |
| `App/Resources/Info.plist` | `CFBundleShortVersionString` / `CFBundleVersion` |

### 步骤 2 — 提交并推送（触发 CI）

```powershell
cd "C:\Users\Administrator\Desktop\8月\修改定位的DEB"
git add -A
git commit -m "vX.Y.Z: 说明"
$token = gh auth token
git -c credential.helper= push "https://x-access-token:$token@github.com/yzdmm2024/onyx.git" main
```

> 用 token 拼 URL 推送，可绕开本机 git 凭据/代理导致的 `Connection was reset`。

### 步骤 3 — 等 CI 构建

```powershell
gh run list --repo yzdmm2024/onyx --limit 1
gh run watch <RUN_ID> --repo yzdmm2024/onyx --exit-status --interval 15
```

CI 做了这些事（见 `build.yml`）：

1. 装 theos + iPhoneOS14.5 SDK
2. `make package` 出 fat 包（arm64+arm64e）→ `iphoneos-arm64.deb`
3. 派生 `iphoneos-arm64e.deb`（改 control 的 Architecture 字段）
4. 注入 `postinst` / `prerm`（theos 有时不自动打包）
5. `ldid -S App/OnyxApp.entitlements` 签 App 二进制
6. 校验 `platform-application` entitlement 已签入
7. 上传 artifact `Onyx-debs`

> 编译报错先看：`gh run view <RUN_ID> --log | Select-String "error:" -Context 0,2`

### 步骤 4 — 下载产物

```powershell
Remove-Item -Recurse -Force packages_ci -ErrorAction SilentlyContinue
gh run download <RUN_ID> --repo yzdmm2024/onyx -D packages_ci
```

### 步骤 5 — 发布到越狱源

```powershell
python publish_onyx.py `
  "packages_ci\Onyx-debs\com.yzdmm.onyx_X.Y.Z_iphoneos-arm64.deb" `
  "packages_ci\Onyx-debs\com.yzdmm.onyx_X.Y.Z_iphoneos-arm64e.deb"
```

`publish_onyx.py` 自动完成：

1. 解析 deb 的 `DEBIAN/control` 生成 stanza
2. 拉取 `yzdmm2024/repo` 当前 `Packages`，替换同包同架构旧条目
3. 重算并重写 `Packages` / `Packages.gz` / `Packages.bz2` / `Release`
4. 上传 deb 到 `debs/`，删除同包同架构旧 deb
5. 用 Git Data API 一次性提交到 `main` → GitHub Pages 自动重建

> 脚本自带 sanity 检查（`Filename/Size/MD5sum/SHA1/SHA256` 字段齐全），不齐全直接退出不推。
> **注意**：仓库里有 `gen.yml`，`debs/**` 一变会重跑 `gen_packages.py` 重建索引。
> 所以删旧版本必须**同时删 deb 文件**，只删 Packages 条目没用（会被 regen 还原）。

### 步骤 6 — 验证

- 打开 https://yzdmm2024.github.io/repo/ 确认 `Packages` 里版本已更新
- 手机 Sileo/Zebra 刷新源 → 装新版本 → **respring**

---

## 五、关键坑与注意事项

| # | 坑 | 规避 |
|---|---|---|
| 1 | `CLSimulationManager` API 写错 → SpringBoard 崩溃进安全模式 | 严格对齐 LocSim：`alloc/init` + `appendSimulatedLocation:` + `startLocationSimulation` |
| 2 | 配置 key 大小写不一致 → 定位无效果 | App/Tweak 统一 `enabled`（小写） |
| 3 | 沙盒 App 读不到 Preferences → 配置失效 | 多路径写 plist，Tweak 同目录优先 |
| 4 | 往目标 App 注入 → 被反作弊扫到 | **只注入 SpringBoard** |
| 5 | OnyxApp 无法联网 → 瓦片加载失败 | SpringBoard 代拉 + 共享文件缓存 |
| 6 | `Onyx.plist` 加 XML 注释 → ElleKit 解析异常 | plist 里**绝不加注释** |
| 7 | 卸载残留 / 卸载损坏 ElleKit | `prerm` 里先发 `com.yzdmm.onyx/stop` 停模拟，再清配置与缓存 |
| 8 | 依赖写死 `mobilesubstrate` → rootless 环境依赖异常 | 写 `mobilesubstrate \| ellekit` |
| 9 | 桌面无图标 | CI 注入 `postinst` 执行 `uicache -p` |
| 10 | 推送报 `Connection was reset` | 用 `gh auth token` 拼 URL 推送 |

### ElleKit 损坏的恢复方法

若出现 `error ellekit files are corrupted for unknown reasons please try reinstalling the ellekit package`：

1. Sileo/Zebra 里**重装 `ellekit`** 包
2. respring
3. 再装本插件

> 本插件 v1.0.1 起已从三个层面规避：只注入 SpringBoard（注入面从 30+ 降到 1）、
> 代码极简（无第三方 SDK hook）、`prerm` 主动清理。

---

## 六、版本历史

| 版本 | 变更 |
|---|---|
| **1.0.3** | 修复「其他 App 一直显示真实定位」：旧版只注入 SpringBoard 走系统级模拟（CLSimulationManager），第三方 App 的 CoreLocation 拿不到假坐标；现改为每个 App 进程内直接 Hook `CLLocationManager`（`location` 取值 / `startUpdatingLocation` / `requestLocation` / `setDelegate` 回调）注入假坐标兜底，覆盖系统模拟下不到的 App |
| **1.0.2** | 修复 relaxin/RootHide 卸载弹 "Ellekit files are corrupted"：deb 剥离 var/jb/Library 目录条目（CI `ci_strip_dirs.py`，防 dpkg 回收 ellekit 符号链接）、preinst/postinst/postrm 自愈 ellekit 符号链接 + jbctl trustcache 注册、脚本内绝不 killall 系统进程；Tweak 找回 `/var/tmp` 配置读取路径（修复 relaxin 上定位无效果）；Depends 改回 `mobilesubstrate`（ellekit Provides，避免 ellekit 被当依赖联动卸载） |
| 1.0.1 | 修复 SpringBoard 崩溃（CLSimulationManager API 对齐 LocSim）+ 修复配置 key 大小写 |
| 1.0.0 | 全新架构：只注入 SpringBoard，系统级全局模拟，极简代码（~110 行），卸载安全 |
| 0.7.5 | 修复桌面无图标（CI 注入 postinst），新增 prerm 卸载清理 |
| 0.7.4 | 移除 plist XML 注释防 ElleKit 损坏，依赖兼容 ellekit |
| 0.7.3 | 配置写 Tweak 同目录，加诊断日志 |
| 0.7.2 | 配置写 `/var/tmp` 公共路径 |
| 0.7.1 | 去掉系统级模拟，改纯 per-app hook（失败方案） |
| 0.7.0 | 黑名单模式（失败方案） |
| 0.6.x | 白名单模式 + App 改名 GO + 图标隐身 |
| 0.5.9.x | 瓦片多源回退、离线程序化底图、6 并发加速 |
| 0.5.x | 自绘瓦片地图替代 MKMapView |

---

## 七、参考

- 免检测定位实现参考：`C:\Users\Administrator\Desktop\8月\修改定位dylib`（LocSim）
- 越狱源仓库：https://github.com/yzdmm2024/repo
- 源码仓库：https://github.com/yzdmm2024/onyx
