import 'dart:convert';
import 'dart:math';

import 'copy_device_identity_model.dart';
import 'copy_request_protocol.dart';
export 'copy_device_identity_model.dart';

enum CopyApiRoute {
  overseas(
    settingValue: 'overseas',
    label: '海外线路',
    region: '1',
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
    region: '1',
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
  static const String apiVersion = CopyRequestProtocol.version;
  static const String versionCode = '83';
  static const String platform = '3';
  static const String source = CopyRequestProtocol.source;
  static const String webp = CopyRequestProtocol.webp;
  static final Random _loginRandom = Random.secure();
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

  static const String loginPath = '/api/v3/login';
  static const String profilePath = '/api/v3/member/info';
  static const String favoritesPath = '/api/v3/member/collect/comics';
  static const String comicCollectPath = '/api/v3/member/collect/comic';
  static const String searchPath = '/api/v3/search/comic';
  static const String networkPath = '/api/v3/system/network2';

  static const String novelSearchPath = '/api/v3/search/books';
  static const String novelFavoritesPath = '/api/v3/member/collect/books';
  static const String novelCollectPath = '/api/v3/member/collect/book';

  /// An explicit allowlist prevents accidental token use on content or CDN URLs.
  static const memberPaths = {
    profilePath,
    favoritesPath,
    comicCollectPath,
    novelFavoritesPath,
    novelCollectPath,
  };
  static bool requiresAuthentication(String path) => memberPaths.contains(path);
  static bool isAccountWrite(String path) =>
      path == loginPath || path == comicCollectPath || path == novelCollectPath;
  static Map<String, dynamic> comicCollectBody(String uuid, bool collected) => {
    'comic_id': uuid,
    'is_collect': collected ? 1 : 0,
  };
  static String novelDetailsPath(String pathWord) =>
      '/api/v3/book/${Uri.encodeComponent(pathWord)}';
  static String novelVolumesPath(String pathWord) =>
      '${novelDetailsPath(pathWord)}/volumes';
  static String novelVolumePath(String pathWord, String id) =>
      '${novelDetailsPath(pathWord)}/volume/${Uri.encodeComponent(id)}';
  static Map<String, dynamic> novelCollectBody(String uuid, bool collected) => {
    'book_id': uuid,
    'is_collect': collected ? 1 : 0,
  };

  static String comicDetailsPath(String pathWord) => '/api/v3/comic2/$pathWord';

  static String groupChaptersPath(String comicPathWord, String groupPathWord) =>
      '/api/v3/comic/$comicPathWord/group/$groupPathWord/chapters';

  static String chapterContentPath(String comicPathWord, String chapterUuid) =>
      '/api/v3/comic/$comicPathWord/chapter2/$chapterUuid';

  static Map<String, dynamic> loginBody(
    String username,
    String password, {
    int? salt,
  }) {
    // APK 3.0.9: Random.secure().nextInt(9999), then toString().
    final requestSalt = salt ?? _loginRandom.nextInt(9999);
    if (requestSalt < 0 || requestSalt >= 9999) {
      throw RangeError.range(requestSalt, 0, 9998, 'salt');
    }
    return <String, dynamic>{
      'username': username,
      'password': base64Encode(utf8.encode('$password-$requestSalt')),
      'salt': requestSalt.toString(),
    };
  }

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
    'platform': 3,
  };

  static Map<String, dynamic> comicDetailsQuery({required bool inMainland}) =>
      <String, dynamic>{
        'platform': 3,
        'in_mainland': inMainland,
        'request_id': '',
      };

  static Map<String, dynamic> groupChaptersQuery({
    required int limit,
    required int offset,
  }) => <String, dynamic>{'limit': limit, 'offset': offset};

  static Map<String, dynamic> chapterContentQuery({required bool inMainland}) =>
      <String, dynamic>{
        'platform': 3,
        'in_mainland': inMainland,
        'request_id': '',
      };

  static const Map<String, dynamic> networkQuery = <String, dynamic>{
    'platform': 3,
  };

  /// One shared normal-API profile. Logged-out requests carry the APK's empty
  /// `Token ` value; that is not a credential. CDN requests bypass this method.
  static Map<String, String> headers({
    String? token,
    String region = '1',
    required CopyDeviceIdentity identity,
    DateTime? now,
    DateTime? startupDate,
  }) {
    final current = now ?? DateTime.now();
    return CopyRequestProtocol.headers(
      commonParameters: CopyRequestProtocol.commonParameters(
        identity: identity,
        date: startupDate ?? CopyRequestProtocol.startupDate(current),
        region: region,
        token: token ?? '',
      ),
      nativeMaterial: CopyRequestProtocol.certificateMd5,
      now: current,
    );
  }

  static String authSignature(String timestamp) =>
      CopyRequestProtocol.signature(
        timestamp,
        nativeMaterial: CopyRequestProtocol.certificateMd5,
      );

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
