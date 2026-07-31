import 'dart:convert';

import 'package:crypto/crypto.dart';

class CopyDeviceIdentity {
  const CopyDeviceIdentity({
    required this.device,
    required this.deviceInfo,
    required this.androidId,
    required this.pseudoId,
  });

  static const fallback = CopyDeviceIdentity(
    device: 'Flutter',
    deviceInfo: 'AndroidOS',
    androidId: '0000000000000000',
    pseudoId: '0000000000000000',
  );

  final String device;
  final String deviceInfo;
  final String androidId;
  final String pseudoId;
}

enum CopyApiRoute {
  overseas(
    settingValue: 'overseas',
    label: '海外线路',
    region: '-0800',
    inMainland: false,
    primaryDomain: 'api.manga2026.xyz',
  ),
  mainland(
    settingValue: 'mainland',
    label: '国内线路',
    region: '0',
    inMainland: true,
    primaryDomain: 'api.copy202602.com',
  ),
  automatic(
    settingValue: 'automatic',
    label: '自动选择',
    region: '-0800',
    inMainland: null,
    primaryDomain: 'api.manga2026.xyz',
  );

  const CopyApiRoute({
    required this.settingValue,
    required this.label,
    required this.region,
    required this.inMainland,
    required this.primaryDomain,
  });

  final String settingValue;
  final String label;
  final String region;
  final bool? inMainland;
  final String primaryDomain;

  static CopyApiRoute fromSetting(String value) {
    return CopyApiRoute.values.firstWhere(
      (route) => route.settingValue == value,
      orElse: () => CopyApiRoute.overseas,
    );
  }
}

/// 拷贝漫画服务端协议。
///
/// 版本号、签名、请求头、接口路径与参数统一放在这里。服务端协议变化时，
/// 应优先修改本文件，页面和业务模型不需要感知这些细节。
final class CopyApiProtocol {
  CopyApiProtocol._();

  static const String appVersion = '3.0.9';
  static const String apiVersion = '3.0.0';
  static const String versionCode = '83';
  static const String platform = '3';
  static const String source = '#utm_source=FlutterTest';
  static const String webp = '0';
  static const int loginSalt = 1729;
  static const String loginUserAgent = 'COPY/3.0.0';
  static const String loginVersion = '2025.08.15';
  static const String loginPlatform = '1';
  static const String loginWebp = '1';
  static const String loginRegion = '1';
  // 3.0.9 原版内置的节点发现入口。业务请求优先使用 network2 返回的
  // 节点；账号、收藏、搜索、详情和章节共用同一套节点池。
  static const String defaultDomain = 'api.manga2026.xyz';
  static const List<String> discoveryDomains = <String>[
    defaultDomain,
    'api.copy202602.com',
    'mapi.mangacopy.com',
  ];
  static const List<String> overseasDomains = <String>[defaultDomain];
  static const List<String> mainlandDomains = <String>[
    'api.copy202602.com',
    // 原版保留的旧国内入口，当前不可用但可作为最后兼容后备。
    'mapi.mangacopy.com',
  ];

  static const Set<String> retiredDomains = <String>{
    'api.copy-manga.com',
    'mapi.copy-manga.com',
  };

  // 原版 3.0.9 Android 客户端内置的 Umeng app key。它只用于统计相关
  // 请求头，不能作为 API 请求签名密钥。
  static const String _umengAppKey = '65ddae8ba7208a5af1b1bdca';
  static final String _umString = sha256
      .convert(utf8.encode(_umengAppKey))
      .toString();

  static const String loginPath = '/api/v3/login';
  static const String profilePath = '/api/v3/member/info';
  static const String favoritesPath = '/api/v3/member/collect/comics';
  static const String searchPath = '/api/v3/search/comic';
  static const String networkPath = '/api/v3/system/network2';

  static String comicDetailsPath(String pathWord) => '/api/v3/comic2/$pathWord';

  static String groupChaptersPath(String comicPathWord, String groupPathWord) =>
      '/api/v3/comic/$comicPathWord/group/$groupPathWord/chapters';

  static String legacyChapterContentPath(
    String comicPathWord,
    String chapterUuid,
  ) => '/api/v3/comic/$comicPathWord/chapter/$chapterUuid';

  static String chapterContentPath(String comicPathWord, String chapterUuid) =>
      '/api/v3/comic/$comicPathWord/chapter2/$chapterUuid';

  static String chapterDownloadPath(String comicPathWord, String chapterUuid) =>
      '/api/v3/comic/$comicPathWord/chapter2download/$chapterUuid';

  static Map<String, dynamic> loginBody(
    String username,
    String password, {
    int? salt,
  }) {
    final requestSalt = salt ?? loginSalt;
    return <String, dynamic>{
      'username': username,
      'password': base64Encode(utf8.encode('$password-$requestSalt')),
      'salt': requestSalt,
    };
  }

  /// 当前可用账号接口所要求的最小请求头。
  ///
  /// 登录接口与搜索、详情等匿名接口的版本协商不同。这里保持与当前
  /// 上游客户端一致，不携带会员 token、旧版设备指纹或旧版签名头。
  static Map<String, String> loginHeaders() => const <String, String>{
    'User-Agent': loginUserAgent,
    'Accept': 'application/json',
    'version': loginVersion,
    'platform': loginPlatform,
    'webp': loginWebp,
    'region': loginRegion,
  };

  static Map<String, dynamic> favoritesQuery({
    required int limit,
    required int offset,
    required String ordering,
  }) => <String, dynamic>{
    'limit': limit,
    'offset': offset,
    'free_type': 1,
    'ordering': ordering,
  };

  static Map<String, dynamic> searchQuery({
    required String keyword,
    required int limit,
    required int offset,
  }) => <String, dynamic>{
    'limit': limit,
    'offset': offset,
    'q': keyword,
    'q_type': '',
    'platform': platform,
  };

  static const Map<String, dynamic> nodeProbeQuery = <String, dynamic>{
    'limit': 1,
    'offset': 0,
    'q': '__copy_node_probe__',
    'q_type': '',
    'platform': platform,
  };

  static Map<String, dynamic> comicDetailsQuery({required bool inMainland}) =>
      <String, dynamic>{
        'platform': platform,
        'in_mainland': inMainland,
        'request_id': '',
      };

  static Map<String, dynamic> groupChaptersQuery({
    required int limit,
    required int offset,
  }) => <String, dynamic>{'limit': limit, 'offset': offset};

  static Map<String, dynamic> chapterContentQuery({required bool inMainland}) =>
      <String, dynamic>{
        'platform': platform,
        'in_mainland': inMainland,
        'request_id': '',
      };

  static const Map<String, dynamic> networkQuery = <String, dynamic>{
    'platform': platform,
  };

  static Map<String, String> headers({
    String? token,
    bool includeEmptyAuthorization = false,
    String region = '-0800',
    CopyDeviceIdentity identity = CopyDeviceIdentity.fallback,
    DateTime? now,
  }) {
    final current = now ?? DateTime.now();
    final timestamp = (current.microsecondsSinceEpoch ~/ 1000000).toString();
    final signature = authSignature(timestamp);
    final date =
        '${current.year.toString().padLeft(4, '0')}.'
        '${current.month.toString().padLeft(2, '0')}.'
        '${current.day.toString().padLeft(2, '0')}';

    final headers = <String, String>{
      'Accept': 'application/json',
      'Accept-Language': 'zh-CN,zh;q=0.9',
      'User-Agent': 'COPY/$appVersion',
      'userAgent': 'COPY/$appVersion',
      'source': source,
      'platform': platform,
      'version': apiVersion,
      'versionCode': versionCode,
      'referer': 'com.copymanga.app-$appVersion',
      'region': region,
      'webp': webp,
      'umString': _umString,
      'device': identity.device,
      'deviceInfo': identity.deviceInfo,
      'androidId': identity.androidId,
      'pseudoID': identity.pseudoId,
      'dt': date,
      'X-Auth-Timestamp': timestamp,
      'X-Auth-Signature': signature,
    };
    final memberToken = token?.trim() ?? '';
    if (memberToken.isNotEmpty) {
      headers['authorization'] = 'Token $memberToken';
    } else if (includeEmptyAuthorization) {
      // 原版 3.0.9 登录请求会保留这个空 Token 头。它不包含会员
      // 凭据，但服务端会用它区分官方客户端协议与普通网页请求。
      headers['authorization'] = 'Token ';
    }
    return headers;
  }

  /// 3.0.9 原版 `_Lv` 请求拦截器的签名算法。
  ///
  /// 原版把秒级时间戳的 UTF-8 字节同时作为 HMAC-SHA256 的 key 和
  /// message，再将摘要编码成小写十六进制。Umeng app key 不参与签名。
  static String authSignature(String timestamp) {
    final timestampBytes = utf8.encode(timestamp);
    return Hmac(sha256, timestampBytes).convert(timestampBytes).toString();
  }

  static List<String> domainsFor(CopyApiRoute route) {
    return switch (route) {
      CopyApiRoute.overseas => overseasDomains,
      CopyApiRoute.mainland => mainlandDomains,
      CopyApiRoute.automatic => <String>[
        ...overseasDomains,
        ...mainlandDomains,
      ],
    };
  }

  static bool isPresetDomain(String domain) {
    final normalized = normalizeDomain(domain);
    return domainsFor(CopyApiRoute.automatic).contains(normalized) ||
        discoveryDomains.contains(normalized);
  }

  static String normalizeDomain(String domain) {
    final value = domain
        .trim()
        .replaceFirst(RegExp(r'^https?://', caseSensitive: false), '')
        .split('/')
        .first
        .replaceAll(RegExp(r'/+$'), '')
        .toLowerCase();
    return retiredDomains.contains(value) ? defaultDomain : value;
  }

  static List<String> extractApiDomains(Object? value) {
    final domains = <String>{};

    void visit(Object? node) {
      if (node is Map) {
        for (final child in node.values) {
          visit(child);
        }
        return;
      }
      if (node is Iterable) {
        for (final child in node) {
          visit(child);
        }
        return;
      }
      if (node is! String) return;

      final raw = node.trim();
      if (raw.isEmpty || !raw.contains('.')) return;
      final uri = Uri.tryParse(
        raw.startsWith('http://') || raw.startsWith('https://')
            ? raw
            : 'https://$raw',
      );
      if (uri == null || uri.host.isEmpty || !uri.host.contains('.')) return;
      final labels = uri.host.split('.');
      if (!RegExp(r'^[a-z0-9.-]+$', caseSensitive: false).hasMatch(uri.host) ||
          !RegExp(r'[a-z]', caseSensitive: false).hasMatch(labels.last)) {
        return;
      }
      final domain = normalizeDomain(uri.host);
      if (domain.isNotEmpty && !retiredDomains.contains(domain)) {
        domains.add(domain);
      }
    }

    visit(value);
    return domains.toList(growable: false);
  }
}
