import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'copy_api_protocol.dart';

typedef CopyApiResultsValidator = bool Function(Object? results);

class CopyApiException implements Exception {
  const CopyApiException(this.message, {this.code});

  final String message;
  final int? code;

  @override
  String toString() => message;
}

class CopyApiNode {
  const CopyApiNode({
    required this.domain,
    required this.latencyMs,
    required this.current,
  });

  final String domain;
  final int? latencyMs;
  final bool current;

  String get url => 'https://$domain';
  bool get reachable => latencyMs != null;
}

/// 带签名、动态节点发现和节点故障切换的网络传输层。
final class CopyApiTransport {
  CopyApiTransport({
    Dio? dio,
    Dio? imageDio,
    String apiDomain = CopyApiProtocol.defaultDomain,
  }) : _dio = dio ?? Dio(),
       _imageDio = imageDio ?? dio ?? Dio(),
       _apiDomain = CopyApiProtocol.normalizeDomain(apiDomain) {
    if (_apiDomain.isEmpty) {
      _apiDomain = CopyApiProtocol.defaultDomain;
    }
    _configure();
  }

  static const Duration _discoveryTtl = Duration(minutes: 30);
  static const Duration _failedDiscoveryRetry = Duration(minutes: 2);

  final Dio _dio;
  final Dio _imageDio;
  final List<String> _dynamicDomains = <String>[];
  final List<String> _authenticationDomains = <String>[];
  final Map<String, bool> _domainMainland = <String, bool>{};
  final Map<String, int?> _domainLatencyMs = <String, int?>{};
  final Map<String, int?> _authenticationDomainLatencyMs = <String, int?>{};

  late String _apiDomain;
  String _authenticationDomain = '';
  bool _manualDomain = false;
  bool _manualAuthenticationDomain = false;
  String _token = '';
  CopyDeviceIdentity _identity = CopyDeviceIdentity.fallback;
  CopyApiRoute _apiRoute = CopyApiRoute.overseas;
  bool _detectedInMainland = false;
  DateTime? _lastDiscoveryAttempt;
  DateTime? _lastAuthenticationDiscoveryAttempt;
  Future<void>? _discoveryFuture;
  Future<void>? _authenticationDiscoveryFuture;

  String get apiDomain => _apiDomain;
  String get apiUrl => 'https://$_apiDomain';
  String get authenticationDomain => _authenticationDomain.isNotEmpty
      ? _authenticationDomain
      : _authenticationDomains.isNotEmpty
      ? _authenticationDomains.first
      : CopyApiRoute.mainland.primaryDomain;
  String get authenticationUrl => 'https://$authenticationDomain';
  List<String> get discoveredDomains =>
      List<String>.unmodifiable(_dynamicDomains);
  List<CopyApiNode> get apiNodes => _dynamicDomains
      .map(
        (domain) => CopyApiNode(
          domain: domain,
          latencyMs: _domainLatencyMs[domain],
          current: domain == _apiDomain,
        ),
      )
      .toList(growable: false);
  List<CopyApiNode> get authenticationNodes {
    final domains = <String>{
      if (_authenticationDomain.isNotEmpty) _authenticationDomain,
      ..._authenticationDomains,
      ...CopyApiProtocol.mainlandDomains,
    }.toList(growable: false);
    domains.sort((left, right) {
      if (left == _authenticationDomain) return -1;
      if (right == _authenticationDomain) return 1;
      return _compareLatency(
        _authenticationDomainLatencyMs[left],
        _authenticationDomainLatencyMs[right],
      );
    });
    return domains
        .map(
          (domain) => CopyApiNode(
            domain: domain,
            latencyMs: _authenticationDomainLatencyMs[domain],
            current: domain == authenticationDomain,
          ),
        )
        .toList(growable: false);
  }

  bool get usesAutomaticDomain => !_manualDomain;
  bool get usesAutomaticAuthenticationDomain => !_manualAuthenticationDomain;
  bool get hasToken => _token.isNotEmpty;
  CopyApiRoute get apiRoute => _apiRoute;
  bool get inMainland => _isMainlandDomain(_apiDomain);

  void setToken(String token) => _token = token.trim();

  void setDeviceIdentity(CopyDeviceIdentity identity) => _identity = identity;

  void setApiRoute(CopyApiRoute route) {
    if (_apiRoute == route &&
        _apiDomain == CopyApiProtocol.normalizeDomain(route.primaryDomain)) {
      return;
    }
    _apiRoute = route;
    _apiDomain = CopyApiProtocol.normalizeDomain(route.primaryDomain);
    _dynamicDomains.clear();
    _domainMainland.clear();
    _domainLatencyMs.clear();
    _manualDomain = false;
    _lastDiscoveryAttempt = null;
  }

  void setApiDomain(String domain, {bool manual = true}) {
    final value = CopyApiProtocol.normalizeDomain(domain);
    if (value.isEmpty) {
      throw const CopyApiException('API 域名不能为空');
    }
    _apiDomain = value;
    _manualDomain = manual;
    _lastDiscoveryAttempt = null;
  }

  void useFastestDomain() {
    _manualDomain = false;
    final fastest = _fastestReachableDomain();
    if (fastest != null) {
      _apiDomain = fastest;
    }
  }

  void setAuthenticationDomain(String domain, {bool manual = true}) {
    final value = CopyApiProtocol.normalizeDomain(domain);
    if (value.isEmpty) {
      throw const CopyApiException('账号 API 域名不能为空');
    }
    _authenticationDomain = value;
    _manualAuthenticationDomain = manual;
    if (!_authenticationDomains.contains(value)) {
      _authenticationDomains.insert(0, value);
    }
  }

  void useFastestAuthenticationDomain() {
    _manualAuthenticationDomain = false;
    final fastest = _fastestReachableAuthenticationDomain();
    if (fastest != null) {
      _authenticationDomain = fastest;
    }
  }

  void _configure() {
    _dio.options = BaseOptions(
      connectTimeout: const Duration(seconds: 20),
      receiveTimeout: const Duration(seconds: 45),
      sendTimeout: const Duration(seconds: 45),
      validateStatus: (status) => status != null && status < 500,
    );
    if (!identical(_dio, _imageDio)) {
      _imageDio.options = BaseOptions(
        connectTimeout: const Duration(seconds: 20),
        receiveTimeout: const Duration(seconds: 90),
        sendTimeout: const Duration(seconds: 45),
        validateStatus: (status) => status != null && status < 500,
      );
    }
  }

  Future<void> prepare() => _ensureDynamicDomains();

  Future<List<String>> refreshDynamicDomains() async {
    _lastDiscoveryAttempt = null;
    await _ensureDynamicDomains();
    return discoveredDomains;
  }

  Future<List<CopyApiNode>> refreshAuthenticationDomains() async {
    _lastAuthenticationDiscoveryAttempt = null;
    await _ensureAuthenticationDomains();
    return authenticationNodes;
  }

  Future<dynamic> requestResults(
    String path, {
    String method = 'GET',
    Map<String, dynamic>? query,
    Map<String, dynamic>? data,
    bool authenticated = false,
    bool formEncoded = false,
    bool includeEmptyAuthorization = false,
    CopyApiResultsValidator? validateResults,
    String invalidResultsMessage = '节点返回了空数据',
  }) async {
    if (authenticated) _requireLogin();
    final isLogin = path == CopyApiProtocol.loginPath;
    final Set<String> candidates;
    if (isLogin || authenticated) {
      await _ensureAuthenticationDomains();
      candidates = <String>{
        if (_authenticationDomain.isNotEmpty) _authenticationDomain,
        ..._authenticationDomains,
        ...CopyApiProtocol.mainlandDomains,
      };
    } else {
      await _ensureDynamicDomains();
      candidates = <String>{
        _apiDomain,
        ..._dynamicDomains,
        ...CopyApiProtocol.domainsFor(_apiRoute),
      };
    }
    _CopyNodeFailure? lastFailure;

    for (final domain in candidates) {
      try {
        final domainQuery = query == null
            ? null
            : Map<String, dynamic>.from(query);
        if (domainQuery?.containsKey('in_mainland') ?? false) {
          domainQuery!['in_mainland'] = _isMainlandDomain(domain);
        }
        final results = await _requestFromDomain(
          domain,
          path,
          method: method,
          query: domainQuery,
          data: data,
          formEncoded: formEncoded,
          authenticated: authenticated,
          includeEmptyAuthorization: includeEmptyAuthorization,
        );
        if (validateResults != null && !validateResults(results)) {
          throw _CopyNodeFailure(invalidResultsMessage);
        }
        if (isLogin || authenticated) {
          _promoteAuthenticationDomain(domain);
        } else {
          _promoteDomain(domain);
        }
        return results;
      } on CopyApiException catch (failure) {
        // Anonymous content endpoints occasionally return 401/403 on one CDN
        // node even though the same request succeeds on another node. Treat
        // that as a node failure, but never hide a real login/authentication
        // failure.
        if (!isLogin &&
            !authenticated &&
            (failure.code == 401 || failure.code == 403)) {
          lastFailure = _CopyNodeFailure(failure.message);
          continue;
        }
        rethrow;
      } on _CopyNodeFailure catch (failure) {
        lastFailure = failure;
      }
    }

    throw CopyApiException(
      lastFailure == null
          ? '没有可用的拷贝漫画 API 节点'
          : '所有拷贝漫画 API 节点均连接失败：${lastFailure.message}',
    );
  }

  Future<Uint8List> imageBytes(
    String url, {
    ProgressCallback? onReceiveProgress,
    CancelToken? cancelToken,
  }) async {
    try {
      final response = await _imageDio.get<List<int>>(
        url,
        options: Options(responseType: ResponseType.bytes),
        onReceiveProgress: onReceiveProgress,
        cancelToken: cancelToken,
      );
      if (response.statusCode != 200 || response.data == null) {
        throw CopyApiException(
          '图片下载失败（HTTP ${response.statusCode}）',
          code: response.statusCode,
        );
      }
      return Uint8List.fromList(response.data!);
    } on CopyApiException {
      rethrow;
    } on DioException catch (error) {
      throw CopyApiException(_networkErrorMessage(error));
    }
  }

  Future<dynamic> _requestFromDomain(
    String domain,
    String path, {
    required String method,
    Map<String, dynamic>? query,
    Map<String, dynamic>? data,
    required bool formEncoded,
    required bool authenticated,
    required bool includeEmptyAuthorization,
  }) async {
    try {
      final isLogin = path == CopyApiProtocol.loginPath;
      if (isLogin && kDebugMode) {
        debugPrint(
          '[CopyLogin] request host=$domain '
          'version=${CopyApiProtocol.loginVersion} '
          'platform=${CopyApiProtocol.loginPlatform} '
          'region=${CopyApiProtocol.loginRegion}',
        );
      }
      final response = await _dio.request<dynamic>(
        'https://$domain$path',
        queryParameters: query,
        data: data,
        options: Options(
          method: method,
          contentType: formEncoded ? Headers.formUrlEncodedContentType : null,
          headers: isLogin
              ? CopyApiProtocol.loginHeaders()
              : CopyApiProtocol.headers(
                  token: authenticated ? _token : null,
                  includeEmptyAuthorization: includeEmptyAuthorization,
                  region: _regionForDomain(domain),
                  identity: _identity,
                ),
        ),
      );
      final status = response.statusCode ?? 0;
      final map = _decodeResponseMap(response.data, status: status);
      final code = _asInt(map['code'], fallback: status);
      if (isLogin && kDebugMode) {
        debugPrint(
          '[CopyLogin] response host=$domain status=$status code=$code '
          'message=${map['message'] ?? ''}',
        );
      }

      if (status == 401 && authenticated) {
        throw const CopyApiException('登录已过期，请重新登录', code: 401);
      }
      if (status == 404 || status == 405 || status == 410) {
        throw _CopyNodeFailure(
          map['message']?.toString() ?? '节点不支持当前接口（HTTP $status）',
        );
      }
      if (status != 200 || code != 200) {
        throw CopyApiException(
          map['message']?.toString() ?? '请求失败（HTTP $status，code $code）',
          code: code,
        );
      }
      return map['results'];
    } on CopyApiException {
      rethrow;
    } on _CopyNodeFailure {
      rethrow;
    } on DioException catch (error) {
      throw _CopyNodeFailure(_networkErrorMessage(error));
    } on FormatException {
      throw const _CopyNodeFailure('服务器返回了无效 JSON');
    }
  }

  Map<String, dynamic> _decodeResponseMap(Object? body, {required int status}) {
    Object? decoded = body;
    if (body is String) {
      final text = body.trim();
      if (text.isEmpty) {
        throw _CopyNodeFailure('服务器返回空内容（HTTP $status）');
      }
      try {
        decoded = jsonDecode(text);
      } on FormatException {
        throw _CopyNodeFailure('服务器返回非 JSON 内容（HTTP $status）');
      }
    }
    if (decoded is! Map) {
      throw _CopyNodeFailure('服务器返回了无法识别的数据（HTTP $status）');
    }
    return Map<String, dynamic>.from(decoded);
  }

  Future<void> _ensureDynamicDomains() async {
    final now = DateTime.now();
    final lastAttempt = _lastDiscoveryAttempt;
    if (lastAttempt != null) {
      final retryAfter = _dynamicDomains.isEmpty
          ? _failedDiscoveryRetry
          : _discoveryTtl;
      if (now.difference(lastAttempt) < retryAfter) return;
    }

    final pending = _discoveryFuture;
    if (pending != null) {
      await pending;
      return;
    }

    final future = _refreshDynamicDomains();
    _discoveryFuture = future;
    try {
      await future;
    } finally {
      _discoveryFuture = null;
    }
  }

  Future<void> _ensureAuthenticationDomains() async {
    final now = DateTime.now();
    final lastAttempt = _lastAuthenticationDiscoveryAttempt;
    if (lastAttempt != null) {
      final retryAfter = _authenticationDomains.isEmpty
          ? _failedDiscoveryRetry
          : _discoveryTtl;
      if (now.difference(lastAttempt) < retryAfter) return;
    }

    final pending = _authenticationDiscoveryFuture;
    if (pending != null) {
      await pending;
      return;
    }

    final future = _refreshAuthenticationDomains();
    _authenticationDiscoveryFuture = future;
    try {
      await future;
    } finally {
      _authenticationDiscoveryFuture = null;
    }
  }

  Future<void> _refreshAuthenticationDomains() async {
    _lastAuthenticationDiscoveryAttempt = DateTime.now();
    final discovered = <String>{
      if (_authenticationDomain.isNotEmpty) _authenticationDomain,
      ...CopyApiProtocol.mainlandDomains,
    };
    for (final discoveryDomain in CopyApiProtocol.mainlandDomains) {
      try {
        final response = await _dio.get<dynamic>(
          'https://$discoveryDomain${CopyApiProtocol.networkPath}',
          queryParameters: CopyApiProtocol.networkQuery,
          options: Options(
            headers: CopyApiProtocol.headers(
              region: CopyApiRoute.mainland.region,
              identity: _identity,
            ),
            connectTimeout: const Duration(seconds: 8),
            receiveTimeout: const Duration(seconds: 12),
          ),
        );
        if (response.statusCode != 200) continue;
        final map = _decodeResponseMap(
          response.data,
          status: response.statusCode ?? 0,
        );
        if (_asInt(map['code'], fallback: response.statusCode ?? 0) != 200) {
          continue;
        }
        final results = map['results'];
        final apiNodes = results is Map ? results['api'] : results;
        discovered.addAll(CopyApiProtocol.extractApiDomains(apiNodes));
      } on Object {
        // 登录只在国内认证节点有效；发现失败时回退到原版国内入口。
      }
    }
    _authenticationDomains
      ..clear()
      ..addAll(discovered);
    await _benchmarkAuthenticationDomains(_authenticationDomains);
    final fastest = _fastestReachableAuthenticationDomain();
    if (!_manualAuthenticationDomain && fastest != null) {
      _authenticationDomain = fastest;
    } else if (_authenticationDomain.isEmpty) {
      _authenticationDomain = _authenticationDomains.first;
    }
  }

  Future<void> _refreshDynamicDomains() async {
    _lastDiscoveryAttempt = DateTime.now();
    final discovered = <String>{};
    final discoveredMainland = <String, bool>{};
    final replaceCurrentDomain = CopyApiProtocol.isPresetDomain(_apiDomain);
    for (final discoveryDomain in CopyApiProtocol.domainsFor(_apiRoute)) {
      try {
        final response = await _dio.get<dynamic>(
          'https://$discoveryDomain${CopyApiProtocol.networkPath}',
          queryParameters: CopyApiProtocol.networkQuery,
          options: Options(
            headers: CopyApiProtocol.headers(
              region: _regionForDiscoveryDomain(discoveryDomain),
              identity: _identity,
            ),
            connectTimeout: const Duration(seconds: 8),
            receiveTimeout: const Duration(seconds: 12),
          ),
        );
        if (response.statusCode != 200) continue;
        final map = _decodeResponseMap(
          response.data,
          status: response.statusCode ?? 0,
        );
        if (_asInt(map['code'], fallback: response.statusCode ?? 0) != 200) {
          continue;
        }
        final results = map['results'];
        final discoveryInMainland =
            results is Map && results['in_mainland'] is bool
            ? results['in_mainland'] as bool
            : _inMainlandForDiscoveryDomain(discoveryDomain);
        if (results is Map && results['in_mainland'] is bool) {
          _detectedInMainland = results['in_mainland'] as bool;
        }
        final apiNodes = results is Map ? results['api'] : results;
        final domains = CopyApiProtocol.extractApiDomains(apiNodes);
        discovered.addAll(domains);
        for (final domain in domains) {
          discoveredMainland[domain] = discoveryInMainland;
        }
      } on Object {
        // 发现服务不可用时保留当前节点，正式请求仍会执行候选节点切换。
      }
    }
    if (discovered.isEmpty) return;
    _dynamicDomains
      ..clear()
      ..addAll(discovered);
    _domainMainland
      ..clear()
      ..addAll(discoveredMainland);
    await _benchmarkDomains(_dynamicDomains);
    final fastest = _fastestReachableDomain();
    if (!_manualDomain && fastest != null) {
      _apiDomain = fastest;
    } else if (replaceCurrentDomain && !_manualDomain) {
      _apiDomain = _dynamicDomains.first;
    }
  }

  Future<void> _benchmarkDomains(List<String> domains) async {
    final measurements = await Future.wait(
      domains.map(
        (domain) async =>
            MapEntry<String, int?>(domain, await _measureDomainLatency(domain)),
      ),
    );
    _domainLatencyMs
      ..clear()
      ..addEntries(measurements);
    _dynamicDomains.sort((left, right) {
      return _compareLatency(_domainLatencyMs[left], _domainLatencyMs[right]);
    });
  }

  Future<void> _benchmarkAuthenticationDomains(List<String> domains) async {
    final measurements = await Future.wait(
      domains.map(
        (domain) async => MapEntry<String, int?>(
          domain,
          await _measureDomainLatency(domain, forceMainland: true),
        ),
      ),
    );
    _authenticationDomainLatencyMs
      ..clear()
      ..addEntries(measurements);
    _authenticationDomains.sort(
      (left, right) => _compareLatency(
        _authenticationDomainLatencyMs[left],
        _authenticationDomainLatencyMs[right],
      ),
    );
  }

  Future<int?> _measureDomainLatency(
    String domain, {
    bool forceMainland = false,
  }) async {
    final stopwatch = Stopwatch()..start();
    try {
      final response = await _dio.get<dynamic>(
        'https://$domain${CopyApiProtocol.searchPath}',
        queryParameters: CopyApiProtocol.nodeProbeQuery,
        options: Options(
          headers: CopyApiProtocol.headers(
            region: forceMainland
                ? CopyApiRoute.mainland.region
                : _regionForDomain(domain),
            identity: _identity,
          ),
          connectTimeout: const Duration(seconds: 5),
          receiveTimeout: const Duration(seconds: 5),
          sendTimeout: const Duration(seconds: 5),
        ),
      );
      final status = response.statusCode ?? 0;
      final map = _decodeResponseMap(response.data, status: status);
      final results = map['results'];
      if (status != 200 ||
          _asInt(map['code'], fallback: status) != 200 ||
          results is! Map ||
          results['list'] is! List) {
        return null;
      }
      return stopwatch.elapsedMilliseconds;
    } on Object {
      return null;
    } finally {
      stopwatch.stop();
    }
  }

  String? _fastestReachableDomain() {
    for (final domain in _dynamicDomains) {
      if (_domainLatencyMs[domain] != null) return domain;
    }
    return null;
  }

  String? _fastestReachableAuthenticationDomain() {
    for (final domain in _authenticationDomains) {
      if (_authenticationDomainLatencyMs[domain] != null) return domain;
    }
    return null;
  }

  void _promoteDomain(String domain) {
    _apiDomain = domain;
    _dynamicDomains
      ..remove(domain)
      ..insert(0, domain);
  }

  void _promoteAuthenticationDomain(String domain) {
    _authenticationDomain = domain;
    _authenticationDomains
      ..remove(domain)
      ..insert(0, domain);
  }

  static int _compareLatency(int? left, int? right) {
    if (left == null && right == null) return 0;
    if (left == null) return 1;
    if (right == null) return -1;
    return left.compareTo(right);
  }

  bool _isMainlandDomain(String domain) {
    return _apiRoute.inMainland ??
        _domainMainland[CopyApiProtocol.normalizeDomain(domain)] ??
        _detectedInMainland;
  }

  bool _inMainlandForDiscoveryDomain(String domain) {
    final normalized = CopyApiProtocol.normalizeDomain(domain);
    if (CopyApiProtocol.mainlandDomains.contains(normalized)) return true;
    if (CopyApiProtocol.overseasDomains.contains(normalized)) return false;
    return _apiRoute.inMainland ?? _detectedInMainland;
  }

  String _regionForDiscoveryDomain(String domain) =>
      _inMainlandForDiscoveryDomain(domain)
      ? CopyApiRoute.mainland.region
      : CopyApiRoute.overseas.region;

  String _regionForDomain(String domain) => _isMainlandDomain(domain)
      ? CopyApiRoute.mainland.region
      : CopyApiRoute.overseas.region;

  void _requireLogin() {
    if (_token.isEmpty) {
      throw const CopyApiException('请先登录拷贝漫画');
    }
  }

  static String _networkErrorMessage(DioException error) {
    final detail = error.message?.trim();
    return detail == null || detail.isEmpty ? '网络连接失败' : '网络连接失败：$detail';
  }

  static int _asInt(Object? value, {int fallback = 0}) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? fallback;
  }
}

final class _CopyNodeFailure implements Exception {
  const _CopyNodeFailure(this.message);

  final String message;
}
