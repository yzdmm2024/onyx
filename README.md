# GO~（Onyx）越狱插件 — 完整资料与发布流程

> 包名 `com.yzdmm.onyx` ｜ 显示名 `GO~` ｜ 越狱源 https://yzdmm2024.github.io/repo/
> 适配：iOS 15–17，rootless（arm64 无根 Dopamine/palera1n + arm64e 隐根 Relaxin/RootHide），A12+
> 当前版本：**1.4.2**

---

## 一、这个插件是什么

一个系统级定位模拟插件 + 独立配置 App，用来把设备定位改到任意坐标（"想去哪里就去哪里"）。

两个核心能力：

1. **定位模拟** — **主力 = per-app hook**（v1.4.3 起用 `Mode:WildCard` + `Bundles:[com.apple.UIKit]` 注入所有 GUI App，这是 v0.5.8 验证可用的注入方式）：在 App 进程内 hook `CLLocationManager` 及百度/高德/腾讯 SDK，直接把 App 读到的坐标替换成假坐标，对单个 App 生效；SpringBoard 内的 `CLSimulationManager` 系统模拟作为补充尝试（但 SpringBoard 缺少 `com.apple.locationd.simulation` 权限，真机通常被 locationd 无视，不要依赖）。
2. **地图选点** — 自带 App 内嵌自绘瓦片地图，可搜索 / 拖动 / 缩放选点；瓦片由 SpringBoard 进程代拉。

### 关于反作弊检测（重要）

| 检测维度 | v1.2.0 做法 |
|---|---|
| 注入范围 | **注入所有 App 进程**（per-app hook 才能让第三方 App 生效），钉钉等进程里会有 Onyx dylib |
| 模拟方式 | Hook `CoreLocation` / 地图 SDK，App 读到的坐标即被替换 |
| App 名称 | 显示名 `GO~`，图标为紫色渐变"GO"字样，不像定位工具 |

> ⚠️ **为让第三方 App 一定生效，per-app hook 要求 dylib 注入所有 App（WildCard UIKit）。**
> 这意味着钉钉这类反作弊 App **能扫到自己进程里的 Onyx dylib**，可能报"使用虚拟定位"。
> 若你需要避开钉钉检测，请把它加入**黑名单**（黑名单里保持真实定位）。
> **两难取其一：要覆盖所有 App，就接受可被检测。**
>
> 📌 **v1.4.3 订正（之前版本的真正根因）**：v1.3.0→v1.4.2 的「改定位无效」**不是 per-app 思路不行，是注入 Filter 写错了**：
> - v1.3.0 的 plist 只列 `com.apple.springboard`（无 `WildCard`）→ dylib 只进 SpringBoard，per-app hook 全在 `else` 分支永远不执行（死代码）；
> - v1.4.2 又把 Filter 删成空 dict，ElleKit 下等价于"不注入普通 App"，照样失效；
> - 能用的 **v0.5.8 用的是 `Mode:WildCard` + `Bundles:[com.apple.UIKit]`**，dylib 注入所有 GUI App，per-app hook 才真正生效。
> v1.4.3 改回这个验证过的写法。

### v1.2.0 修的是什么（定位改了 App 仍显示真实位置）

v1.1.0 的 `startUpdatingLocation` 是**先 `%orig`（真的启动 GPS）再推一帧假坐标**。
App 的 delegate 因此**同时收到真、假两帧**，而 App 普遍采用「以最后一次定位为准」，
真实那帧照常在假帧之后到达 → 覆盖掉假坐标。表现就是"改了定位，App 还是显示真实位置"。
v1.2.0 已改为「启用时完全不启动真实定位 + 接管 delegate 回调」，**代码逻辑是对的**。

### v1.3.0：为什么还要继续改 —— 日志证明 dylib 没进 App 进程

v1.2.0 的真机日志里，**只有 SpringBoard 的 BOOT，没有任何第三方 App 的 BOOT**：

```
=== Onyx v1.2.0 BOOT proc=SpringBoard bundle=com.apple.springboard ===
```

只要 App 进程加载了 dylib，`%ctor` 就一定会写这一行。一行都没有 = **dylib 没进 App 进程**。
所以在 App 内部 `hook CLLocationManager` 这套思路，在这台 relaxin 设备上**前提就不成立**，
逻辑再对也没机会执行。v1.3.0 因此把主力切到唯一被日志证明"能跑起来"的注入点 —— **SpringBoard**。

v1.3.0 做法：

1. **SpringBoard 内驱动 `CLSimulationManager`** → 系统级模拟，所有 App 同时拿到假坐标，不依赖 App 注入；
2. 先塞 3 帧建立轨迹，再 `startLocationSimulation`；
3. **每 3 秒补帧心跳**，locationd 偶发丢模拟点时自动钉住；
4. **SpringBoard 内每 3 秒重读 plist**（Darwin 通知丢包自愈），启用/关闭即时生效；
5. App 内 hook 全部保留 —— 哪天某个 App 进程真被注入了，它会额外生效。

> 已知取舍：系统级模拟对**所有** App 生效，黑名单在模拟模式下无法给单个 App 还原真实位置
> （模拟器本身没有"只给某 App 放行"的开关）。要个别 App 保持真实，请改用需要注入思路的旧版本。

### v1.4.1：日志系统自证失效——刷屏把判定冲掉了

v1.4.0 真机日志显示：SpringBoard 链路全通（`sim: START`、心跳 `HB #8 simulating=1`），
但看不到任何 `ECHO:` 判定行。原因不在回声本身，而在日志系统：

1. **刷屏**：轮询每 3 秒打 `plist hit` + `prefs:` 两行，一天 5 万多行，512KB 日志几小时截断，
   最早那条 `ECHO:` 判定被冲掉；
2. **静默限流**：回声 90 秒内重试直接 return，日志里"没有 ECHO"分不清是没触发还是被限流；
3. **没时间戳**：多条线索之间没法对时间。

v1.4.1：每行日志带 `HH:mm:ss` 时间戳；配置没变化不再重复打日志；限流跳过时写 `ECHO: skip (rate-limit)`。

### v1.4.0：从"模拟启动了"到"模拟真的在投递"

v1.3.0 的日志已经证明 SpringBoard 侧链路是通的（plist 读到了、`sim: created`、
`sim: START` 都打出来了、开关状态机也正常）。**但「START 打印了」不等于「locationd 真的在把
模拟点投递给 App」** —— SpringBoard 完全可能被 locationd 无声拒绝，而这一步在日志里不留痕。

v1.4.0 因此加了一个**端到端回声自检**：模拟启动 3 秒后，SpringBoard 自己起一个
`CLLocationManager` 向 locationd 要一次定位，拿到的坐标直接判死：

| 日志 | 含义 | 下一步 |
|---|---|---|
| `ECHO: FAKE -> 26.89,112.57` | **系统模拟生效** | 问题在 App 自身（彩云多是用 IP/城市定位，不是 GPS） |
| `ECHO: REAL -> 22.5,113.9` | 模拟被 locationd 无视 | SpringBoard 没有模拟权限，要换注入方式 |
| `ECHO: ERROR code=...` | SpringBoard 自己也拿不到定位 | 看错误码（`kCLErrorDenied` = 权限被拒） |
| `ECHO: TIMEOUT` | 5 秒无回调 | locationd 没响应，配合上面看 |

其他改动：优先改用 `+sharedSimulationManager` 单例（`alloc/init` 可能拿到没接上 locationd 的
独立实例，后面所有调用都是空响）；心跳补帧加日志；模拟被 locationd 消费完后自动复活；
诊断日志合并 `/var/tmp`、`/tmp`、`/var/jb/tmp` 三个路径。

### 排查：诊断日志

改完还是无效时，用日志定位，别再盲调：

- 日志路径：**`/var/tmp/onyx_debug.log`**（写不进去自动 fallback 到 `/tmp/onyx_debug.log`）
- 打开 Onyx App → 主界面底部「**诊断日志**」按钮 → v1.4.0 会**自动合并三个路径**的内容，截图/复制发来即可
- 每次进程加载都会**强制写一行 BOOT**，格式：
  `=== Onyx v1.4.1 BOOT pid=<pid> proc=<进程名> bundle=<bundle id> ... img=<dylib 镜像路径> ===`
  - **关键**：`proc=SpringBoard` = 只有系统进程加载了它（预期，主力在这）；
    **出现 `proc=ColorfulClouds` 之类的行 = 该 App 进程确实注入成功了**。
  - `img=(not in dyld image list)` → dylib 被加载过但不在镜像表里，`plist=MISS` 通常是同一类问题（路径在 App 命名空间里不可见）。
- 系统模拟行：`sim: START -> lat,lng` / `sim: STOP` / `sim: HB #n` / `sim: RESTART` / `ECHO: ...`
  出现 `WARN appendSimulatedLocation: unavailable` = 该 iOS 版本私有 API 名不同，需要换写法。
- 日志上限 512KB 自动截断，不会撑爆磁盘

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

- v1.4.3 起 `Onyx.plist` 用 **`Mode:WildCard` + `Bundles:[com.apple.UIKit]`**（v0.5.8 验证可用的写法）：dylib 注入所有 GUI App。SpringBoard 内继续承载瓦片代拉 `OnyxTileProxy`；第三方 App 进程内执行 `OnyxHooks` / `Baidu` / `AMap` / `Tencent` 的 per-app hook。
- **主力 = per-app hook**：App 进程内 hook `CLLocationManager` 及百度/高德/腾讯 SDK，直接把 App 读到的坐标替换成假坐标，不依赖系统模拟权限。
- ⚠️ **注入 Filter 写错是历史「改定位无效」的唯一根因**：v1.3.0 只列 `com.apple.springboard`（无 WildCard）→ per-app hook 全死；v1.4.2 把 Filter 删空 → ElleKit 不注入普通 App，照样死。两者都让 per-app hook 永远不执行。
- **主力 = per-app hook**：App 进程内 hook `CLLocationManager` 及百度/高德/腾讯 SDK，直接把 App 读到的坐标替换成假坐标，不依赖系统模拟权限。
- SpringBoard 内的 `CLSimulationManager` 系统模拟保留作补充尝试，但它需要 `com.apple.locationd.simulation` 权限（SpringBoard 没有），真机上通常被 locationd 无视——不要再依赖它。

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
| **1.4.3** | **真正修复「改定位无效」**：根因是注入 Filter 写错——v1.3.0 只列 `com.apple.springboard`（无 `WildCard`）让 per-app hook 全死；v1.4.2 把 Filter 删成空 dict，ElleKit 下不注入普通 App，照样死。本版改回 **v0.5.8 验证可用的 `Mode:WildCard` + `Bundles:[com.apple.UIKit]`**，dylib 注入所有 GUI App，per-app hook 才真正生效。代价：dylib 进入第三方 App 进程，反作弊可能检测到（见 Onyx.plist）。 |
| **1.4.2** | ⚠️ 无效版本：意图放开注入（删空 Filter）但 ElleKit 下空 dict 不注入普通 App，per-app hook 仍未执行。已被 1.4.3 取代。 |
| **1.1.0** | **彻底修复「第三方 App 一直显示真实定位」**：回到 v0.7 验证可用的 per-app 直注方案——直接 Hook `CLLocation` 类本体（`coordinate` / `initWithLatitude:longitude:` / `locationWithLatitude:longitude:`）+ `CLLocationManager` + 百度/高德/腾讯三家地图 SDK，任何 App 读到/构造的坐标都被洗成假坐标；SpringBoard 保留 `CLSimulationManager` 系统级模拟作兜底。**新增黑名单**：App 内「黑名单（排除应用）」可把不需要改定位的 App 加进去，这些 App 保持真实位置。注意：此版为让第三方 App 生效改为 per-app hook，dylib 会注入所有 App（含钉钉），反作弊可能检测到注入——若需避开某 App 检测，后续可加进程过滤 |
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
