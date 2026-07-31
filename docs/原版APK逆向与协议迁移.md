# 原版 APK 逆向与协议迁移

本文记录本项目分析拷贝漫画 Android 原版 APK、恢复 Flutter AOT 中的接口协议、
验证运行时请求并迁移到阅读器的完整方法。目标是新版 APK 到手后做增量差分，而不是
每次从零开始。

文中的 APK、账号和网络操作只用于本人设备、本人账号和本项目兼容性维护。原始 APK、
反编译产物、流量包、令牌和设备标识只保存在本机 `reverse_engineering`，该目录被
Git 忽略。

## 1. 已知基线：原版 3.0.9

本机参考样本：

```text
reverse_engineering/
└── original_3.0.9_device/
    ├── base.apk
    ├── extracted/
    │   └── lib/
    └── blutter_out/
        ├── asm/
        ├── ida_script/
        ├── blutter_frida.js
        ├── objs.txt
        └── pp.txt
```

3.0.9 APK 同时包含：

- `lib/arm64-v8a/libapp.so`
- `lib/arm64-v8a/libflutter.so`
- `lib/armeabi-v7a/libapp.so`
- `lib/armeabi-v7a/libflutter.so`

这说明主要业务逻辑是 Flutter AOT。只用 JADX 查看 Java/Kotlin 层无法恢复 API
拼接、Dio 拦截器和 Dart 签名逻辑；Java 层主要用于插件、Activity 和平台桥接。

3.0.9 的 Blutter 池中已经确认过以下稳定线索：

| 线索 | 3.0.9 位置示例 | 用途 |
| --- | --- | --- |
| `X-Auth-Timestamp`、`X-Auth-Signature` | `pp.txt` 约 `0x8d80` | 定位签名拦截器 |
| 内容域名常量 | `pp.txt` 约 `0x8ee0`–`0x8f20` | 定位线路配置 |
| `region=-0800` 和线路中文名 | `pp.txt` 约 `0x8628` | 判断线路属性 |
| `/api/v3/login`、`salt`、`password` | `pp.txt` 约 `0x23790`–`0x23828` | 定位登录编码 |
| `/api/v3/system/network2` | `addNames.py` 字符池 | 定位动态节点 |
| `/api/v3/comic2/` | `addNames.py` 字符池 | 定位详情接口 |
| `/api/v3/member/collect/comics` | `addNames.py` 字符池 | 定位收藏接口 |

偏移和混淆类名只对同一 APK 构建有效。升级后应该重新按稳定字符串定位，不能复用
旧绝对地址。

3.0.9 已经迁移到项目的关键结论：

- 内容请求与登录请求使用不同版本协商和请求头集合。
- 内容请求带秒级时间戳和 HMAC-SHA256 签名。
- 当前基线的 HMAC key 和 message 都是时间戳 UTF-8 字节。
- 登录密码是 `Base64(UTF8("$password-$salt"))`，salt 同时作为表单字段发送。
- 动态节点来自 `/api/v3/system/network2`。
- 国内/海外实际节点决定 `region` 和 `in_mainland`。
- 搜索、详情、章节和图片可匿名访问，不应携带会员 token。
- 登录返回 token 后还必须用资料接口验证。
- 章节图片接口需要多个兼容路径和非空列表校验。

这些结论是“基线”，不是永久真理。新版必须重新验证变化项。

## 2. 每次逆向的目录和记录规范

新版样本按版本和来源单独建目录：

```text
reverse_engineering/
└── original_<version>_<source>/
    ├── base.apk
    ├── SHA256SUMS.txt
    ├── metadata.txt
    ├── extracted/
    ├── jadx_out/
    ├── blutter_out/
    ├── strings/
    ├── captures/
    │   ├── anonymous/
    │   ├── member/
    │   └── redacted/
    ├── hooks/
    └── notes/
        ├── findings.md
        ├── request-matrix.md
        └── migration-checklist.md
```

`source` 建议使用 `device`、`official` 或下载渠道简称。

必须记录：

- APK 版本名、versionCode、包名。
- APK SHA-256。
- 取得日期和来源。
- 支持 ABI。
- Flutter 引擎特征或版本。
- 测试设备和 Android 版本。
- 原版登录所用线路。
- 每个结论的静态证据、动态证据和置信度。
- 与上一版的差异。
- 迁移到源码的文件和测试。

直接复制[逆向记录模板](逆向记录模板.md)开始新记录。

## 3. 阶段一：取得原始 APK

### 3.1 从已安装设备提取

先确认包名：

```bash
adb shell pm list packages | grep -i copy
```

取得 APK 路径：

```bash
adb shell pm path com.copymanga.app
```

如果输出一个 base 和多个 split，全部保存：

```bash
adb pull /data/app/.../base.apk base.apk
adb pull /data/app/.../split_config.arm64_v8a.apk .
adb pull /data/app/.../split_config.xxhdpi.apk .
```

不能只保存 base 后假定资源完整。AAB 安装常把 ABI、语言和密度资源放在 split。

### 3.2 固化样本

```bash
shasum -a 256 base.apk > SHA256SUMS.txt
file base.apk
unzip -t base.apk
```

记录安装信息：

```bash
adb shell dumpsys package com.copymanga.app |
  grep -E 'versionName|versionCode|firstInstallTime|lastUpdateTime'
```

不要覆盖旧版本目录。旧 APK 是差分的基准。

## 4. 阶段二：快速分类

先判断应用技术栈和最有价值的分析层。

```bash
unzip -l base.apk | grep -E \
  'libapp.so|libflutter.so|kernel_blob|isolate_snapshot|classes[0-9]*.dex'
```

判断：

- 有 `libapp.so` + `libflutter.so`：Flutter AOT，业务重点在 Dart AOT。
- 有 `kernel_blob.bin`：可能是 Debug/JIT，可直接提取更多 Dart 信息。
- 只有 DEX/Java/Kotlin：优先 JADX。
- 同时有 Flutter 和大量自定义 native `.so`：签名可能转移到 JNI/native。

开发者视角先问：

- 域名是内置还是从 network/config 接口下发？
- 签名在 Dio 拦截器、Dart helper、Java 插件还是 native 库？
- 服务端需要哪些设备字段才能重放？
- 账号和内容是否共用后端？
- 图片 URL 是明文返回、解密后生成还是二次签名？

不要先在 UI 文本里漫无目的搜索。

## 5. 阶段三：清单、资源和 Java 层

### 5.1 解包

```bash
mkdir -p extracted
unzip -q base.apk -d extracted
```

### 5.2 Manifest 和资源

可用工具：

```bash
apkanalyzer manifest print base.apk > manifest.xml
aapt2 dump badging base.apk > badging.txt
apktool d -f base.apk -o apktool_out
```

关注：

- 包名和版本。
- `networkSecurityConfig`。
- 自定义 Application/Activity。
- Deep Link。
- VPN/代理/证书相关配置。
- 存储和设备标识权限。
- 原生库加载。

### 5.3 JADX

```bash
jadx -d jadx_out base.apk
rg -n -i \
  'certificate|trustmanager|ssl|proxy|methodchannel|device|android_id|umeng' \
  jadx_out
```

JADX 的价值：

- 找平台设备身份字段来源。
- 找 MethodChannel 名称。
- 找证书校验和代理检测。
- 找 Flutter 插件配置。
- 找可能转移到 native 的加密 JNI。

如果 API 路径和 Dio 逻辑搜不到，不代表不存在；Flutter Release 的 Dart 代码在
`libapp.so`。

## 6. 阶段四：Flutter AOT 与 Blutter

### 6.1 准备 arm64 输入

arm64 是当前手机和平板的主要目标，也最适合与运行时地址对应：

```bash
mkdir -p extracted_arm64
cp extracted/lib/arm64-v8a/libapp.so extracted_arm64/
cp extracted/lib/arm64-v8a/libflutter.so extracted_arm64/
```

### 6.2 运行 Blutter

Blutter 版本必须支持该 APK 对应的 Flutter Snapshot。典型调用：

```bash
python3 /path/to/blutter/blutter.py \
  extracted/lib/arm64-v8a \
  blutter_out
```

如果提示 Snapshot/VM 版本不支持：

1. 先保存当前错误和 Flutter 引擎哈希线索。
2. 更新 Blutter。
3. 按目标 Flutter 版本重建 Blutter 的 Dart SDK/引擎依赖。
4. 仍失败再尝试从 APK 内 `libflutter.so` 识别引擎版本。

不要用旧版 Blutter 输出勉强解释新 Snapshot。

主要产物：

- `pp.txt`：对象池、字符串、闭包和字段。
- `objs.txt`：类和函数对象。
- `asm/*.dart`：按类拆分的 AOT 汇编伪代码。
- `ida_script/addNames.py`：导入 IDA 的对象和注释。
- `blutter_frida.js`：运行时对象/地址辅助。

### 6.3 先搜稳定字面量

```bash
rg -n -i \
  'https://|/api/v3/|X-Auth|authorization|network2|in_mainland|'\
  'versionCode|platform|region|salt|password|HMAC|SHA|Base64|umString' \
  blutter_out/pp.txt \
  blutter_out/objs.txt \
  blutter_out/asm \
  blutter_out/ida_script
```

按功能建立线索表：

| 功能 | 稳定搜索词 |
| --- | --- |
| 节点 | `https://`、`network2`、线路中文名 |
| 普通请求头 | `versionCode`、`platform`、`region`、`referer` |
| 签名 | `X-Auth-Timestamp`、`X-Auth-Signature`、`HMAC` |
| 登录 | `/api/v3/login`、`username`、`password`、`salt` |
| 收藏 | `/api/v3/member/collect/comics` |
| 搜索 | `/api/v3/search/comic`、`q_type` |
| 详情 | `/api/v3/comic2/`、`path_word` |
| 分组 | `/group/`、`chapters` |
| 图片 | `chapter2`、`chapter2download`、`contents` |

### 6.4 从字符串回溯函数

单个字符串只能证明“存在”，不能证明运行时使用。

回溯步骤：

1. 在 `pp.txt` 记录字符串池偏移。
2. 在 `asm` 或 IDA 注释中找引用该池对象的函数。
3. 看同一函数附近构造的 Map 键、常量和调用顺序。
4. 找 Dio `Options`、Interceptor、HMAC、Base64 等对象。
5. 给混淆类和函数建立自己的语义名。
6. 记录函数地址，但把它标为“只适用于当前构建”。

建议语义命名：

- `buildCommonHeaders`
- `buildLoginHeaders`
- `buildSignature`
- `encodeLoginPassword`
- `discoverNetworkNodes`
- `resolveComicDetails`
- `resolveChapterContents`

## 7. 阶段五：版本差分

新版逆向的最快路径不是重新阅读全部 AOT，而是与已知基线差分。

### 7.1 文件级差分

```bash
find old/extracted -type f -print | sort > old-files.txt
find new/extracted -type f -print | sort > new-files.txt
diff -u old-files.txt new-files.txt

shasum -a 256 old/extracted/lib/arm64-v8a/*.so
shasum -a 256 new/extracted/lib/arm64-v8a/*.so
```

如果 `libapp.so` 未变但域名行为变了，优先检查动态配置，而不是重复分析签名。

### 7.2 稳定字符串差分

从两个 `pp.txt` 提取感兴趣字符串：

```bash
rg 'String: ".*(api|version|region|platform|salt|Signature|Timestamp).*"' \
  old/blutter_out/pp.txt > old-protocol-strings.txt
rg 'String: ".*(api|version|region|platform|salt|Signature|Timestamp).*"' \
  new/blutter_out/pp.txt > new-protocol-strings.txt
diff -u old-protocol-strings.txt new-protocol-strings.txt
```

再单独比较所有 API 路径和域名：

```bash
rg -o 'https?://[^" ]+|/api/v[0-9]+/[^" ]+' \
  old/blutter_out/pp.txt | sort -u > old-routes.txt
rg -o 'https?://[^" ]+|/api/v[0-9]+/[^" ]+' \
  new/blutter_out/pp.txt | sort -u > new-routes.txt
diff -u old-routes.txt new-routes.txt
```

### 7.3 请求矩阵差分

对每个版本固定比较：

| 场景 | 登录 | 线路 |
| --- | --- | --- |
| 搜索 | 否 | 国内、海外 |
| 详情 | 否 | 国内、海外 |
| 章节目录 | 否 | 国内、海外 |
| 章节图片 | 否 | 国内、海外 |
| 登录 | 无 token | 国内、海外 |
| 资料 | 是 | 账号节点 |
| 收藏 | 是 | 账号节点 |

不要只比较一个“成功请求”。参数可能按线路、登录状态或接口类别变化。

## 8. 阶段六：运行时验证

静态结果必须用原版实际运行验证。运行时优先验证“最终出网请求”，其次才是中间
函数。

### 8.1 准备测试设备

保存当前状态：

```bash
adb devices -l
adb shell dumpsys package com.copymanga.app > package-before.txt
adb shell settings get global http_proxy > proxy-before.txt
```

使用专门测试账号。不要把本人主账号密码、token 或完整 Cookie 写入文档和 Git。

### 8.2 代理抓包

电脑运行 mitmproxy/Burp 后，可使用同一局域网 IP，或通过 USB 反向端口：

```bash
adb reverse tcp:8080 tcp:8080
adb shell settings put global http_proxy 127.0.0.1:8080
```

结束后必须恢复：

```bash
adb shell settings put global http_proxy :0
adb reverse --remove tcp:8080
```

如果 Flutter/BoringSSL 不信任用户 CA 或存在证书固定，Java 层
`TrustManager` Hook 往往无效，因为请求可能完全走 `libflutter.so`。

### 8.3 Frida

确认进程和 ABI：

```bash
frida-ps -Uai | grep -i copy
adb shell pidof com.copymanga.app
```

启动：

```bash
frida -U -f com.copymanga.app -l hooks/request_trace.js
```

Flutter AOT 常用策略：

1. 先载入当前 APK 生成的 `blutter_frida.js`。
2. 根据当前 `libapp.so` 基址加函数相对偏移。
3. Hook 已定位的 header builder、signature builder 或 Dio 调用前函数。
4. 只打印方法、URL、键名、长度和脱敏值。
5. 如果需要 TLS 验证旁路，优先定位当前版本 `libflutter.so` 的
   BoringSSL 校验回调；不要假定旧地址仍有效。

Frida Hook 必须与 APK SHA-256 绑定。应用更新后先重新算偏移。

### 8.4 不解密 TLS 时的 Dart 层观察

即使代理看不到明文，也可以在请求 Map 构建完成后 Hook：

- Dio `request`/`fetch` 前的 wrapper。
- `Options.headers` 写入。
- URL/path 拼接函数。
- HMAC `convert` 调用前后的输入输出。
- Base64 编码前后的字节。

只需要得到协议结论，不要长期记录用户内容。

## 9. 签名算法恢复方法

### 9.1 收集至少两组样本

每组记录：

- 时间戳。
- 签名。
- 方法。
- path。
- query 原始顺序。
- body 原始字节。
- region。
- device 字段。

只有一组样本容易误判常量或碰巧一致。

### 9.2 从 AOT 判断组成

围绕 `X-Auth-*` 引用看：

- 使用 SHA-1、SHA-256、MD5 还是其他摘要。
- 是普通 hash 还是 HMAC。
- key 来自常量、时间戳、设备字段还是 token。
- message 是否拼入 path/query/body。
- 编码是 UTF-8、十六进制、Base64 还是 URL 编码。
- 输出大小写。

### 9.3 用独立小脚本验证

当前 3.0.9 基线可以用：

```python
import hashlib
import hmac

timestamp = "1785460000"
data = timestamp.encode("utf-8")
signature = hmac.new(data, data, hashlib.sha256).hexdigest()
print(signature)
```

把输出与原版同一时间戳的实际请求比较。新版若不一致，一次只改变一个候选：

- key
- message
- path
- query
- body
- 分隔符
- 编码
- 摘要算法

不要在项目代码里边猜边发大量请求；先离线复现，再做一次端到端请求。

## 10. 登录编码恢复方法

围绕 `/api/v3/login` 的调用链确认：

- Content-Type 是表单还是 JSON。
- 用户字段名。
- 密码是否加 salt。
- salt 是固定、随机还是服务端下发。
- 拼接顺序和分隔符。
- Base64 前是否 UTF-8。
- 登录请求是否应带空 `Authorization`。
- 登录专用 User-Agent/version/platform/region。

当前基线：

```text
password_field = Base64(UTF8(password + "-" + salt))
```

但新版必须动态验证 salt 和最小请求头。服务端返回 `code=200` 仍不够，必须用返回
token 请求资料接口。资料失败说明节点、token 或登录协议仍有问题。

## 11. 节点和线路恢复方法

先找内置入口，再找动态下发：

1. 在字符串池提取所有 `https://` 域名。
2. 找 `/api/v3/system/network2` 的调用。
3. 记录 query、headers 和响应结构。
4. 区分发现入口、业务节点、图片 CDN 和营销域名。
5. 判断响应中是否有 `in_mainland`。
6. 对每个实际节点发最小匿名探测。
7. 分别测试内容接口和账号接口。

不要仅凭延迟把节点判为可用。节点可能：

- 搜索可用但详情不可用。
- 匿名可用但登录不可用。
- 国内账号存在而海外账号不存在。
- 返回 HTTP 200 但 `results` 结构错误。

项目的自动选择先测速，再用业务 validator 做二次确认。

## 12. 图片与章节恢复方法

出现“空章节”“没有返回图片”时，按层拆分：

1. 详情是否返回正确漫画和分组。
2. 分组 count 是否大于零。
3. 分页章节列表是否为空。
4. 章节 UUID 是否真实。
5. 当前阅读路径、兼容阅读路径和下载路径分别返回什么。
6. `contents` 是 URL 字符串还是对象数组。
7. 图片请求需要哪些 headers。
8. CDN 是否返回图片字节但 Content-Type 为
   `binary/octet-stream`。

图片格式以字节和解码结果为准，不信任 Content-Type。

## 13. 迁移到本项目

按照变化类型修改最少文件：

| 变化 | 优先修改 |
| --- | --- |
| 版本、头、签名、路径、参数 | `copy_api_protocol.dart` |
| 节点发现、线路、重试、鉴权注入 | `copy_api_transport.dart` |
| 返回字段和业务对象 | `copy_client.dart` |
| 设备字段 | `copy_device_identity.dart` 与平台桥接 |
| 页面行为 | 最后才改 Controller/Page |

迁移顺序：

1. 为新结论先写或修改协议测试。
2. 只改 protocol/transport/client。
3. 运行 `copy_api_protocol_test.dart`。
4. 用匿名请求验证搜索、详情、章节和图片。
5. 再用测试账号验证登录、资料和收藏。
6. 运行完整串行测试。
7. 构建 APK 安装到测试机。
8. 保留旧协议回退，确认旧路径完全失效后再删除。

## 14. 回归命令

```bash
dart format lib test
dart analyze --fatal-infos
flutter test --no-pub test/copy_api_protocol_test.dart
flutter test --no-pub --concurrency=1
flutter build apk --release --no-pub
```

实机最少验证：

- 未登录搜索。
- 搜索结果进入正确详情。
- 获取所有章节分组。
- 未下载章节在线阅读至少首、中、末三页。
- 正式下载一章并生成 ZIP。
- 国内账号登录与资料验证。
- 收藏同步。
- 切换内容节点后重复详情和章节请求。

## 15. 这次逆向中已经排除的误区

### 只看 JADX

Flutter Release 的业务逻辑在 `libapp.so`。JADX 找不到 URL 并不说明 URL 是服务端
动态下发。

### 只看字符串

APK 中可能同时保留旧接口、后备接口和未使用功能。字符串必须结合引用函数和运行时
请求。

### 把 Umeng key 当签名密钥

统计 key、`umString` 和 API HMAC 可能同时出现在同一个请求头构建器附近，但不代表
它们参与同一算法。当前基线已经证明签名输入是时间戳。

### 给所有请求带 token

搜索、详情、章节和图片匿名可用。强行携带 token 会把内容故障和账号风控绑定在
一起。

### 把 HTTP 200 或空列表当成功

节点可能返回 HTTP 200、业务 code 200，却没有目标漫画或章节。必须为每种请求提供
结构 validator。

### 登录拿到 token 就算成功

错误节点可能返回不可用 token。必须用资料接口验证后再保存。

### 只测一个线路

国内、海外的内容和账号数据库可能不一致。必须分别验证。

### 每次改页面绕过协议问题

页面报错只是结果。协议参数变化应在 protocol/transport/client 层解决，页面保持
稳定。

## 16. 证据优先级

从高到低：

1. 原版同版本运行时最终请求与响应。
2. 原版同版本函数 Hook 的输入输出。
3. AOT 函数控制流和对象池引用。
4. 单独字符串。
5. 旧版本行为或第三方项目实现。

第三方下载器只能提供线索，不能覆盖新版原版的运行时证据。源代码与运行行为冲突时，
先确认 APK SHA-256、安装版本和 Hook 地址，再以可复现的运行结果为准。

## 17. 完成标准

一次协议迁移只有同时满足以下条件才算完成：

- 新 APK、哈希和分析产物已独立保存。
- 变化点有静态证据和动态证据。
- 匿名请求不带 token。
- 登录 token 通过资料接口验证。
- 国内、海外至少各验证一条适用链路。
- 空章节和错误详情能触发节点回退。
- 协议测试和完整测试通过。
- Android 真机完成搜索、详情、在线阅读和下载。
- 文档更新了新版本差异和仍保留的后备。
- Git 提交中没有 APK、抓包、令牌、私钥和个人账号。
