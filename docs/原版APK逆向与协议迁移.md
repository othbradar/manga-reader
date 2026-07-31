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

## 18. 新 APK 到手后的标准作业顺序

不要先打开 JADX 随机搜索。按下面顺序执行，可以在最短时间内判断“只换节点”“只换版本
头”“签名变化”还是“整个接口响应变化”。

### 18.1 前 15 分钟：固化和分类

```bash
export SAMPLE_DIR="reverse_engineering/original_<version>_<source>"
mkdir -p "$SAMPLE_DIR"/{extracted,jadx_out,apktool_out,strings,captures,hooks,notes}
cp /path/to/base.apk "$SAMPLE_DIR/base.apk"

shasum -a 256 "$SAMPLE_DIR/base.apk" |
  tee "$SAMPLE_DIR/SHA256SUMS.txt"
unzip -t "$SAMPLE_DIR/base.apk"
apkanalyzer manifest print "$SAMPLE_DIR/base.apk" \
  > "$SAMPLE_DIR/manifest.xml"
unzip -l "$SAMPLE_DIR/base.apk" \
  > "$SAMPLE_DIR/zip-list.txt"
```

立即回答并记录：

1. 包名有没有变化。
2. `versionName`、`versionCode` 有没有变化。
3. 是否仍有 `libapp.so`、`libflutter.so`。
4. ABI 是否新增或删除。
5. 是否出现新的自定义 native 库。
6. APK 是单包还是 split。
7. 签名证书摘要是否变化。

证书只用于确认样本来源和是否换壳，不等于 API 请求签名：

```bash
apksigner verify --print-certs "$SAMPLE_DIR/base.apk" \
  > "$SAMPLE_DIR/signing-cert.txt"
```

### 18.2 15–30 分钟：先做字符串级版本差分

```bash
unzip -q "$SAMPLE_DIR/base.apk" -d "$SAMPLE_DIR/extracted"

strings -a "$SAMPLE_DIR/extracted/lib/arm64-v8a/libapp.so" |
  sort -u > "$SAMPLE_DIR/strings/libapp.strings"
strings -a "$SAMPLE_DIR/extracted/lib/arm64-v8a/libflutter.so" |
  sort -u > "$SAMPLE_DIR/strings/libflutter.strings"
```

和上一版比较：

```bash
comm -13 \
  reverse_engineering/original_<old>/strings/libapp.strings \
  "$SAMPLE_DIR/strings/libapp.strings" \
  > "$SAMPLE_DIR/strings/added.txt"

comm -23 \
  reverse_engineering/original_<old>/strings/libapp.strings \
  "$SAMPLE_DIR/strings/libapp.strings" \
  > "$SAMPLE_DIR/strings/removed.txt"
```

优先检查：

```bash
rg -n -i \
  'api/v3|network2|chapter2|login|authorization|timestamp|signature|region|in_mainland|versionCode|platform|webp' \
  "$SAMPLE_DIR/strings"
```

如果路径、头名和域名都没变化，不代表算法没变化，但可以先用旧协议构造一组匿名搜索
请求验证。一次只改变一个变量：

1. 只替换域名。
2. 只替换版本头。
3. 只替换 platform/region。
4. 最后才替换签名。

### 18.3 30–90 分钟：让原版跑一条最小链路

先在原版完成：

```text
启动
→ 刷新节点
→ 匿名搜索一个固定关键词
→ 打开唯一结果
→ 打开一个免费章节
→ 加载第一页图片
```

然后再做：

```text
登录测试账号
→ 获取资料
→ 打开收藏第一页
```

不要一上来批量扫描或下载。最小链路能把节点、普通头、详情、章节和图片五层问题分开。

## 19. 建议工具版本和产物

每次记录实际版本，不要只写“用了 JADX”：

```bash
adb version
java -version
jadx --version
apktool --version
frida --version
python3 --version
```

推荐用途：

| 工具 | 用途 | 不能证明什么 |
| --- | --- | --- |
| `apkanalyzer` / `aapt2` | 包名、版本、Manifest、权限 | 不能恢复 Dart 业务 |
| `apktool` | 资源、Manifest、smali、network config | 不能可靠还原 Flutter AOT |
| `jadx` | Java/Kotlin 插件、MethodChannel、JNI、TLS 壳 | 找不到路径不代表没有 API |
| `strings` / `rg` | 快速发现稳定字面量 | 不能证明运行时使用 |
| Blutter | Dart 对象池、函数、AOT 汇编、Frida 模板 | 输出偏移只对当前构建有效 |
| Ghidra/IDA | 交叉引用、控制流、native/JNI | 类型需要结合运行时确认 |
| Frida | 运行时参数、返回值、调用顺序 | Hook 不命中不等于函数没执行 |
| mitmproxy/Charles/Burp | HTTP 请求/响应和顺序 | Flutter TLS pinning 可能使其不可见 |
| `adb logcat` | 崩溃、原生日志、Flutter debugPrint | Release 业务对象通常不完整 |

每个工具的原始输出保存在样本目录；手工结论放 `notes/findings.md`，不要在原始文件上改。

## 20. 证据记录格式

每条协议结论至少记录：

```text
结论：
影响功能：
静态证据：
运行时证据：
独立重放：
反例/已排除：
适用 APK SHA-256：
置信度：已确认 / 高 / 中 / 假设
迁移文件：
回归测试：
```

示例：

```text
结论：普通请求的 X-Auth-Signature 是 HMAC-SHA256(timestamp, timestamp)
影响功能：节点、搜索、详情、章节、图片头
静态证据：pp.txt 中头名；AOT 函数调用 Hmac/SHA256/utf8/hex
运行时证据：Hook 到 timestamp 和最终 64 字符小写摘要
独立重放：固定 timestamp=... 时 Dart/Python/原版输出一致
反例：Umeng app key 作为 HMAC key 时不匹配
适用样本：<sha256>
置信度：已确认
迁移文件：copy_api_protocol.dart
回归测试：固定签名向量
```

只有字符串证据的结论不能标“已确认”。

## 21. Flutter AOT：从字符串回到实际函数

### 21.1 为什么要以稳定字符串为锚

Flutter Release 中：

- Dart 类名可能混淆；
- 函数序号会随编译变化；
- 对象池偏移会变化；
- native 绝对地址受 ASLR 影响；
- 但 API 路径、Header 名、JSON key、错误文案通常必须在运行时存在。

因此升级后搜索顺序应是：

```text
稳定字符串
→ 对象池条目
→ 引用该对象的 AOT 函数
→ 函数内相邻常量
→ 上下游调用者
→ 运行时 Hook 验证
```

### 21.2 Blutter 产物分别怎么看

| 产物 | 用法 |
| --- | --- |
| `pp.txt` | 对象池常量、字符串、类型线索 |
| `objs.txt` | Dart 对象/类关系 |
| `asm/` | 反汇编后的 Dart 函数 |
| `addNames.py` | 给 IDA/Ghidra 添加函数名和对象标注 |
| `blutter_frida.js` | 已恢复对象打印和地址辅助 |
| `ida_script/` | 批量导入符号和结构 |

先查字符串：

```bash
rg -n -C 8 \
  'X-Auth-Timestamp|X-Auth-Signature|/api/v3/login|/api/v3/system/network2|/api/v3/comic2/' \
  "$SAMPLE_DIR/blutter_out/pp.txt"
```

再在汇编和命名脚本中查相同对象偏移或字面量：

```bash
rg -n -C 20 'X-Auth-Signature|comic2|network2' \
  "$SAMPLE_DIR/blutter_out/asm" \
  "$SAMPLE_DIR/blutter_out/addNames.py"
```

### 21.3 判断一个函数的角色

签名拦截器通常同时引用：

- 时间戳头名；
- 签名头名；
- UTF-8 编码；
- HMAC/SHA；
- 十六进制或 Base64；
- RequestOptions/headers。

登录函数通常同时引用：

- `/api/v3/login`；
- `username`；
- `password`；
- `salt`；
- Base64；
- form-urlencoded；
- 登录专用版本头。

节点发现函数通常同时引用：

- `/api/v3/system/network2`；
- `api`；
- `in_mainland`；
- `region`；
- 域名或 URL 解析；
- 延迟/测速相关对象。

如果一个函数只有路径字符串，没有 Header/请求对象引用，它可能只是路由常量表，不是正式
发请求的函数。

### 21.4 从调用者判断数据流

对候选函数回答：

1. 输入是字符串、Map、RequestOptions 还是业务模型？
2. 返回是 Future、Map、List 还是字节？
3. 是否在 `await` 前构造 Map？
4. 是否在响应后读取 `code`、`results`、`message`？
5. 是否在错误分支换域名？
6. 是否只有会员接口读取 Token？
7. `in_mainland` 是固定值还是随节点重新写入？

把这些答案画成数据流比给混淆函数猜名字可靠。

## 22. 运行时观察分层

不要只准备一种抓包方法。按由低到高的侵入程度推进。

### 22.1 层 0：原版界面行为

记录：

- 当前选择的线路；
- 搜索是否成功；
- 详情是否成功；
- 章节列表是否为空；
- 图片是否能显示；
- 登录在哪条线路成功；
- 错误出现的准确时间。

界面只证明功能是否成功，不证明具体请求参数。

### 22.2 层 1：系统代理

```bash
adb reverse tcp:8080 tcp:8080
adb shell settings put global http_proxy 127.0.0.1:8080
```

结束后必须恢复：

```bash
adb shell settings put global http_proxy :0
```

记录代理 CA 是否安装、应用是否遵循系统代理、失败是证书拒绝还是连接绕过。

### 22.3 层 2：Java/OkHttp

JADX 找到 OkHttp、TrustManager、HostnameVerifier 时，先 Hook Java 层。若请求完全不经过
这些类，应立即转 Flutter/native 层，不要重复写十个 OkHttp 脚本。

### 22.4 层 3：Flutter/BoringSSL

Flutter 常用自己的 BoringSSL。需要：

1. 根据当前 `libflutter.so` 找 TLS 验证函数模式；
2. 用模块基址 + 相对偏移；
3. Hook 前验证指令签名；
4. 偏移不匹配立即停止，不能盲写返回值；
5. 每个 Flutter 引擎版本单独保存脚本。

不要把旧引擎的绝对偏移复用到新 APK。

### 22.5 层 4：Dart 请求对象

如果 TLS 层难以稳定 Hook，直接观察 Dart 层更有价值：

- Dio `RequestOptions` 创建后；
- headers Map 写入后；
- query/data 编码前；
- response JSON 解码后；
- 节点候选循环切换时。

目标是取得结构化对象，而不是解密整条 TLS。

### 22.6 层 5：独立重放

从运行时样本中取出：

- URL；
- method；
- query；
- body；
- headers；
- 时间戳；
- 签名；
- 响应。

去掉 Token 后重放匿名接口。每次只删一个 Header，得到“真正必需”和“原版顺手携带”的
区别。会员接口使用专门测试账号和短生命周期 Token，抓包文件必须脱敏。

## 23. Frida 脚本组织

每个样本目录按功能拆分，不要把所有 Hook 写进一个 2000 行脚本：

```text
hooks/
├── 00_module_inventory.js
├── 10_tls_observe.js
├── 20_dart_headers.js
├── 30_signature_inputs.js
├── 40_login_body.js
├── 50_node_results.js
├── 60_chapter_results.js
└── common/
    └── blutter_helpers.js
```

基础模块清单：

```javascript
setImmediate(function () {
  for (const name of ["libapp.so", "libflutter.so"]) {
    const module = Process.findModuleByName(name);
    if (module) {
      console.log(name, module.base, module.size, module.path);
    }
  }
});
```

地址记录必须用相对地址：

```javascript
const app = Process.getModuleByName("libapp.so");
const target = app.base.add(0xRELATIVE_OFFSET);
console.log("target", target, "relative", target.sub(app.base));
```

Hook 前校验：

```javascript
console.log(hexdump(target, { length: 32, ansi: false }));
```

如果前 32 字节与静态反汇编不符，说明 ABI、版本或偏移错误，停止而不是继续 attach。

运行命令记录在 `notes/findings.md`：

```bash
frida -U -f com.copymanga.app \
  -l hooks/00_module_inventory.js \
  --no-pause
```

打印对象时：

- 密码只打印长度，不打印内容；
- Token 只保留前后各 4 字符；
- 设备 ID 做哈希；
- 图片 URL 可保留域名和路径结构，但查询签名应脱敏；
- 不把完整输出提交 Git。

## 24. 每个功能的逆向卡片

下面按本项目实际功能列出升级时必须逐项恢复的内容。

### 24.1 设备身份

稳定锚点：

```text
device
deviceInfo
androidId
pseudoID
platform
```

需要确认：

1. 字段是否仍存在。
2. Android ID 是否原值、哈希或派生值。
3. pseudoID 是否和 Android ID 相同。
4. iOS 是否允许同一格式。
5. 匿名请求缺设备字段是否仍成功。
6. 登录是否反而要求最小头、不允许旧设备字段。

迁移位置：

- `copy_device_identity.dart`
- Android `MainActivity.kt`
- iOS `AppDelegate.swift`
- `CopyApiProtocol.headers()`

回归：

- 固定设备身份头快照；
- 匿名请求不带 Token；
- 登录头不意外混入普通设备头。

### 24.2 动态节点 `network2`

稳定锚点：

```text
/api/v3/system/network2
api
in_mainland
platform
region
```

需要恢复：

- 发现入口列表；
- GET/POST；
- query/body；
- 普通签名头是否必需；
- `results.api` 是字符串、数组还是嵌套对象；
- 国内/海外节点如何标记；
- 是否返回图片/CDN 节点；
- TTL 是否由服务端返回；
- 旧入口失效时是否仍有内置后备。

动态验证：

1. 原版切海外并刷新节点。
2. 保存响应。
3. 原版切国内重复。
4. 比较 `api`、`in_mainland`、region。
5. 对每个节点发匿名搜索探针。
6. 确认不是“TCP 可连”而是完整 JSON 语义可用。

迁移位置：

- `CopyApiProtocol.discoveryDomains/domainsFor/networkQuery`
- `extractApiDomains()`
- `CopyApiTransport._refreshDynamicDomains()`
- `_refreshAuthenticationDomains()`

### 24.3 节点测速

不能只用 ping 或首页 HTTP：

- 节点可能禁止 ICMP；
- 首页 200 不等于 API 可用；
- 风控页也可能 HTTP 200；
- 返回空 Map 的节点不应参与最快选择。

当前探针要求：

```text
HTTP 200
业务 code 200
results 是 Map
results.list 是 List
```

升级时确认搜索探针是否仍是成本最低的匿名接口。如果搜索也需要新参数，先更新探针，否则
应用会把所有健康节点误判为不可用。

### 24.4 普通请求头和签名

稳定锚点：

```text
User-Agent
userAgent
source
platform
version
versionCode
referer
region
webp
umString
device
deviceInfo
androidId
pseudoID
dt
X-Auth-Timestamp
X-Auth-Signature
authorization
```

逐字段记录：

| 字段 | 值来自哪里 | 是否每请求变化 | 匿名必需 | 会员必需 |
| --- | --- | --- | --- | --- |
| User-Agent | 版本常量 | 否 | 待测 | 待测 |
| region | 线路/节点 | 随节点 | 待测 | 待测 |
| 时间戳 | 当前时间 | 是 | 待测 | 待测 |
| 签名 | 时间戳/请求派生 | 是 | 待测 | 待测 |
| authorization | Token | 否 | 应省略 | 是 |

签名恢复必须排查：

- 秒、毫秒还是微秒；
- key/message 顺序；
- path/query/body 是否参与；
- 参数排序；
- URL 编码时机；
- HMAC、普通 hash 或 AES；
- hex 大小写；
- Base64 标准/URL-safe；
- 时间容差；
- 是否混入设备 ID 或固定盐。

至少收集两条不同路径、两个不同时间戳。如果只看一条请求，多个错误算法可能碰巧生成同样
长度和格式。

### 24.5 登录

稳定锚点：

```text
/api/v3/login
username
password
salt
token
```

必须分别确认：

- 登录域名池；
- 国内/海外账号是否互通；
- method；
- Content-Type；
- 登录专用 User-Agent；
- version/platform/webp/region；
- 是否带普通签名头；
- 是否带空 Authorization；
- salt 是固定、随机、时间戳还是服务端挑战；
- 密码变换顺序；
- Token 响应路径；
- 错误 code 和 message；
- 登录后资料验证接口。

验证账号不存在时不要立即改密码编码。依次比较：

1. 原版和本项目是否用同一账号节点。
2. Content-Type 是否相同。
3. body 是表单还是 JSON。
4. username 是否经过 trim/大小写处理。
5. salt 类型是数字还是字符串。
6. Base64 输入是否包含连字符。
7. version/platform 是否是登录专用值。
8. 服务端 message 是真实业务错误还是节点数据库不互通。

迁移位置：

- `loginHeaders()`
- `loginBody()`
- `CopyApiTransport._requestFromDomain()` 的登录分支
- `CopyClient.login()`

### 24.6 账号资料

稳定锚点：

```text
/api/v3/member/info
username
nickname
avatar
```

确认：

- Token 前缀是 `Token `、`Bearer ` 还是其他。
- Token 在 Header 还是 Cookie。
- HTTP 401 与业务 code 401 的区别。
- 昵称和头像的字段路径。
- 登录成功后资料接口是否立即可用。

本项目只有资料验证成功才保存登录。升级后不能因为登录响应有 Token 就删除这个验证。

### 24.7 收藏

稳定锚点：

```text
/api/v3/member/collect/comics
limit
offset
free_type
ordering
total
list
comic
```

确认：

- 是否必须登录；
- 每页最大 limit；
- offset 还是 page；
- `total` 是否可靠；
- list 项是漫画本身还是 `{comic: ...}`；
- 排序值；
- 收藏是否跨国内/海外账号节点一致；
- 免费/会员筛选字段是否变化。

独立验证至少两页，避免第一页结构正常、后续分页参数错误而只同步 18 部。

### 24.8 搜索

稳定锚点：

```text
/api/v3/search/comic
q
q_type
limit
offset
platform
list
path_word
uuid
```

确认：

- 匿名是否可用；
- Token 是否应完全省略；
- 简繁搜索是否服务端自己处理；
- path_word 字段名；
- 搜索结果 UUID 是否可靠；
- 同名漫画如何区分；
- 风控/空结果的响应结构。

测试关键词要覆盖：

- 一个唯一简体标题；
- 对应繁体标题；
- 作者名；
- 同名多结果；
- 不存在的字符串；
- 探针字符串。

搜索结果点击错误通常不是搜索列表问题，而是把 `path_word` 当 UUID、或详情没有验证返回
标识。两层必须分别验证。

### 24.9 漫画详情

稳定锚点：

```text
/api/v3/comic2/
comic
groups
path_word
uuid
author
cover
alias
brief
status
last_chapter
theme
region
popular
```

确认：

- 路径参数用 path_word 还是 UUID；
- query 是否包含 platform/in_mainland/request_id；
- `comic.path_word` 是否与请求一致；
- groups 是 Map 还是 List；
- group key 与 `path_word` 的关系；
- 作者、状态、末章是否为对象；
- 简介是否可能为空/null/HTML；
- 封面 URL 是否已经带尺寸后缀。

安全校验：

```text
返回 uuid 非空
返回 path_word 非空
返回 path_word == 请求 path_word（忽略大小写）
```

不满足时切节点或报错，不能把错误漫画写入索引。

### 24.10 章节组和章节列表

稳定锚点：

```text
/api/v3/comic/<path_word>/group/<group>/chapters
limit
offset
total
list
uuid
name
ordered
size
```

确认：

- 分页 limit；
- total 是否为字符串；
- ordered 是整数、小数或字符串；
- size 是页数还是文件大小；
- group name/path_word 来自详情还是章节行；
- 空组如何表示；
- 卷、话、其他系列是否同时存在。

验证至少选择：

- 只有“话”的漫画；
- 只有“卷”的漫画；
- 同时有卷和话的漫画；
- 大于 100 章的漫画；
- 一组 count=0 的漫画。

预期还有章节时返回空 list 应视为节点异常并换节点，不能把本地完整章节索引覆盖成空。

### 24.11 章节图片

当前需要检查三条路径：

```text
/api/v3/comic/<path_word>/chapter/<chapter_uuid>
/api/v3/comic/<path_word>/chapter2/<chapter_uuid>
/api/v3/comic/<path_word>/chapter2download/<chapter_uuid>
```

升级时不要假设路径名字里的 “download” 一定需要会员。逐条确认：

- 匿名能否访问；
- in_mainland/region 是否匹配实际节点；
- Token 是否会触发额外风控；
- `results.chapter.contents` 是字符串还是对象；
- URL 是否需要二次解密；
- `chapter.size` 是否与 URL 数相同；
- 空数组是未授权、接口退役、节点故障还是章节真空。

本项目的判断标准是“能提取到至少一个非空图片 URL”。HTTP 200、code 200 但 contents 为空
仍然失败，并继续尝试兼容路径。

### 24.12 图片 CDN

确认：

- URL 是完整绝对地址还是相对路径；
- 是否需要普通签名 Header；
- 是否需要 Referer；
- 是否需要 Cookie/Token；
- 是否有防盗链；
- 是否返回 WebP/JPEG/PNG/JXL；
- Content-Type 是否准确；
- 302 跳转是否允许；
- Range 是否支持；
- URL 过期时间。

无论 Content-Type 是什么，都要检查文件魔数。原版曾返回 `binary/octet-stream` 但内容是
正常图片；按 MIME 拒绝会让封面/页面全部失败。

## 25. 签名算法恢复的完整验证

### 25.1 固定输入

从原版取：

```text
timestamp = T
method = M
path = P
query = Q
body = B
device = D
signature = S
```

写独立脚本枚举候选，不直接在 Flutter 页面里试：

```python
import base64
import hashlib
import hmac

timestamp = b"<T>"
expected = "<S>"

candidates = {
    "sha256(ts)": hashlib.sha256(timestamp).hexdigest(),
    "hmac(ts, ts)": hmac.new(timestamp, timestamp, hashlib.sha256).hexdigest(),
    "hmac(const, ts)": hmac.new(b"<candidate>", timestamp, hashlib.sha256).hexdigest(),
    "b64-hmac(ts, ts)": base64.b64encode(
        hmac.new(timestamp, timestamp, hashlib.sha256).digest()
    ).decode(),
}

for name, value in candidates.items():
    print(name, value, value == expected)
```

如果新版包含 path/query/body，必须用原版真实序列化后的字节，而不是自己猜的 Map 顺序。

### 25.2 固定向量

确认算法后保存不含账号的固定向量：

```text
输入时间戳：
输入 path/query/body：
预期签名：
原版 APK SHA-256：
```

然后在 `copy_api_protocol_test.dart` 写精确断言。以后重构网络层时，固定向量能区分
“服务器挂了”和“客户端签名被改坏了”。

### 25.3 时间偏差

记录服务端是否返回 Date 或时间错误。如果本机时间偏差导致签名失败：

- 不要把服务器时间永久缓存为常量；
- 计算一次 offset；
- 每次用当前时间 + offset；
- 给 offset 设置有效期；
- 测试跨分钟和跨日。

当前基线没有实现时间校正；只有新版证明确实需要时再增加。

## 26. 响应解析的防御规则

每个接口都要区分四层成功：

```text
传输成功：建立连接并收到响应
HTTP 成功：状态为 200
业务成功：code 为 200
语义成功：results 中有该功能需要的数据
```

例子：

- 搜索需要 `results.list is List`。
- 详情需要匹配的 UUID 和 path_word。
- 章节列表在预期有数据时不能是空 list。
- 章节内容需要非空图片 URL。
- 登录需要非空 Token。
- 登录最终还需要资料验证成功。

解析时允许服务端数字使用 int、double 或字符串，但不能把任意 HTML/WAF 页面当 Map。

## 27. 节点切换与业务错误

### 27.1 应切节点

- DNS/连接/超时；
- TLS 失败；
- HTTP 404/405/410 表示节点未部署接口；
- 空响应；
- 非 JSON；
- JSON 顶层不是对象；
- 功能语义校验失败；
- 预期章节/图片却返回空。

### 27.2 不应切节点掩盖

- 密码错误；
- 账号不存在；
- 没有会员权限；
- Token 过期；
- 服务器明确返回业务错误 code/message。

如果所有业务错误都自动切节点，用户会看到最后一个节点的错误，丢失第一个真实结果，还会
把同一账号密码发给不必要的更多节点。

### 27.3 账号和内容候选池

独立记录：

```text
content candidates =
authentication candidates =
current content =
current authentication =
manual/automatic =
region/in_mainland =
latency =
```

内容节点成功不能自动提升为账号节点；账号节点成功也不能改变内容线路。

## 28. 新旧版本自动差分

### 28.1 APK 文件清单

```bash
diff -u \
  reverse_engineering/original_<old>/zip-list.txt \
  reverse_engineering/original_<new>/zip-list.txt \
  > reverse_engineering/original_<new>/notes/zip-list.diff || true
```

### 28.2 Manifest

```bash
diff -u \
  reverse_engineering/original_<old>/manifest.xml \
  reverse_engineering/original_<new>/manifest.xml \
  > reverse_engineering/original_<new>/notes/manifest.diff || true
```

### 28.3 Blutter 稳定线索

给每版生成只包含关键上下文的摘要：

```bash
rg -n -C 6 \
  'api/v3|X-Auth|authorization|versionCode|network2|in_mainland|chapter2|salt' \
  "$SAMPLE_DIR/blutter_out/pp.txt" \
  > "$SAMPLE_DIR/notes/protocol-anchors.txt"
```

对两个摘要 diff，比直接 diff 几十万行 `pp.txt` 更容易定位协议变化。

### 28.4 请求矩阵

每版保存 CSV/Markdown：

```text
功能,域名,方法,路径,query keys,body keys,header keys,匿名/会员,结果结构
```

差分时先比 key 集合，再比值和算法。这样能快速发现只是增加 `request_id`，而不是误判为
整个接口改版。

## 29. 症状到逆向目标

| 症状 | 优先检查 | 不要先做 |
| --- | --- | --- |
| 所有接口连接失败 | discovery、域名、TLS、版本头、签名 | 改 UI |
| 搜索正常，详情失败 | comic2 路径、in_mainland、path_word 校验 | 改搜索解析 |
| 详情正常，章节空 | groups、章节分页、limit/offset、语义换节点 | 删除本地章节 |
| 章节列表正常，图片空 | 三条章节内容路径、contents 结构、匿名/Token | 重命名 ZIP |
| 图片 URL 有但下载失败 | CDN Header、跳转、过期、魔数 | 只信 Content-Type |
| 国内登录成功、海外账号不存在 | 账号节点池和账号数据库分区 | 改用户输入 |
| 登录返回 Token 但收藏 401 | Authorization 格式、资料验证、账号节点 | 保存 Token 后跳过验证 |
| 第一次成功后全是空章节 | 节点提升、TTL、in_mainland 随候选重算 | 把空列表写库 |
| 原版能看，本项目被风控 | 多余 Token、设备头、版本、签名、请求频率 | 盲目增加所有原版 Header |
| 批量扫描大量失败 | 并发、限流、节点语义、重试间隔 | 无限重试 |

## 30. 迁移到源码的逐文件步骤

### 30.1 只换域名

修改：

- `CopyApiProtocol.defaultDomain`
- `discoveryDomains`
- `overseasDomains`
- `mainlandDomains`
- `retiredDomains`

验证：

- 域名规范化；
- 旧设置自动迁移；
- 动态发现；
- 内容和账号节点独立；
- 手动/自动模式。

### 30.2 换版本头或签名

只修改 `copy_api_protocol.dart`：

- 版本常量；
- `headers()`；
- `authSignature()`；
- 登录专用头。

先写固定向量测试，再改实现。页面、下载器和数据库不应感知签名。

### 30.3 换路径或参数

路径和 query/body builder 放 `copy_api_protocol.dart`；调用顺序、分页和结果语义放
`copy_client.dart`；不要在页面拼 URL。

### 30.4 换响应结构

优先扩展兼容解析：

- `Comic.fromApi()`；
- `Chapter.fromApi()`；
- `CopyClient._chapterUrls()`；
- 详情 groups 解析。

如果新旧字段可以同时支持，保留旧兼容；只有证实旧接口完全退休再删除。

### 30.5 换节点策略

修改 `copy_api_transport.dart`：

- 候选池来源；
- TTL；
- 测速探针；
- 哪类错误切节点；
- region/in_mainland 计算；
- 内容/账号分池。

任何修改都要增加“第一个节点失败、第二个节点成功”和“业务错误不切节点”测试。

### 30.6 换登录

修改：

- 登录 path/body/headers；
- form/JSON Content-Type；
- Token 解析；
- profile 验证；
- Authorization 格式。

不要把测试账号密码写进测试文件。协议单元测试只验证固定的编码输入输出；真实登录用运行时
环境变量或人工实机验证。

### 30.7 换章节图片

修改候选路径和 `_chapterUrls()`，同时验证：

- 在线阅读；
- 正式下载；
- 空列表换接口；
- 无 Token；
- 页面对象/字符串两种结构；
- 图片 MIME 误报；
- 暂停取消和断点。

## 31. 回归测试矩阵

### 31.1 纯单元测试

- 固定 Header 快照；
- 固定 HMAC 向量；
- 登录密码固定编码；
- 匿名请求完全没有 authorization；
- 会员接口才带 Token；
- dynamic domain 提取；
- retired domain 迁移；
- 节点按延迟排序；
- 手动节点不被自动覆盖；
- path_word 详情匹配；
- 空章节换节点；
- 三条图片接口回退；
- code/message 原样保留。

### 31.2 模拟 HTTP

至少模拟：

1. 首节点连接超时，次节点成功。
2. 首节点 HTTP 404，次节点成功。
3. 首节点 code 200 但结果语义为空，次节点成功。
4. 登录返回密码错误，不切第二节点。
5. 登录返回 Token，profile 失败，最终登录失败。
6. 收藏超过一页。
7. 章节超过 100 条。
8. contents 同时测试字符串和对象。

### 31.3 Android 真机

```text
匿名搜索
→ 点准确详情
→ 更新章节
→ 在线阅读前后页
→ 章节选择下载
→ 下载进度
→ 暂停
→ 杀进程
→ 重开后恢复 paused
→ 继续完成 ZIP
→ 本地阅读
→ 国内账号节点登录
→ 同步收藏
```

### 31.4 iPhone/iPad

除同样的网络链路，还要验证：

- 未登录匿名阅读；
- Keychain Token 恢复；
- 本机库；
- Files 目录选择器；
- 外置盘 security scope；
- 重启后 bookmark 恢复；
- 恢复默认位置后可拔盘；
- 标准 Bundle ID 和兼容 Bundle ID 两份 IPA。

## 32. 逆向完成交付物

每个新 APK 版本至少留下：

```text
base/split APK 及 SHA-256
版本、包名、ABI、证书摘要
Manifest 和文件清单
JADX/apktool 输出
Blutter 输出和工具版本
稳定协议锚点摘要
脱敏请求矩阵
每个功能的静态/动态证据
新旧差分
已尝试和排除路径
源码迁移清单
单元/模拟/实机结果
仍不确定的事项
回滚提交或旧安装包位置
```

最终 `findings.md` 应让另一个维护者在没有本次聊天记录的情况下回答：

1. 当前原版实际用了哪个内容节点和账号节点。
2. 搜索、详情、章节、图片和登录各自发送什么。
3. 哪些接口匿名，哪些才带 Token。
4. 签名输入、编码和输出是什么。
5. 新版相对上一版具体改了什么。
6. 项目改了哪些文件。
7. 哪些测试证明迁移没有破坏本地漫画库和下载。
