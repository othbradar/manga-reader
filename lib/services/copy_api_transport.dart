import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'copy_api_protocol.dart';
import 'copy_request_protocol.dart';

typedef CopyApiResultsValidator = bool Function(Object? results);

class CopyApiException implements Exception {
  const CopyApiException(
    this.message, {
    this.code,
    this.accountRestricted = false,
    this.retryAfter,
  });

  final String message;
  final int? code;
  final bool accountRestricted;
  final Duration? retryAfter;

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
    DateTime Function()? requestClock,
    this.accountRequestInterval = const Duration(seconds: 1),
  }) : _dio = dio ?? Dio(),
       _imageDio = imageDio ?? dio ?? Dio(),
       _requestClock = requestClock ?? DateTime.now,
       _startupDate = CopyRequestProtocol.startupDate(
         (requestClock ?? DateTime.now)(),
       ),
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
  final Duration accountRequestInterval;
  final DateTime Function() _requestClock;
  final DateTime _startupDate;
  Future<void> _accountTail = Future<void>.value();
  final Map<String, Future<dynamic>> _accountReads = {};
  DateTime? _lastAccountRequestEnd;
  DateTime? _accountRetryNotBefore;
  CopyApiException? _accountRestriction;
  int _tokenRevision = 0;
  int _credentialRevision = 0;
  Future<bool> Function()? renewExpiredSession;
  Future<bool>? _renewal;
  int? _renewalRevision, _failedRenewalRevision;
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
  int get sessionRevision => _tokenRevision;
  CopyApiRoute get apiRoute => _apiRoute;
  bool get inMainland => _isMainlandDomain(_apiDomain);

  void setToken(String token) {
    final value = token.trim();
    if (_token != value) {
      _tokenRevision++;
      _credentialRevision++;
    }
    _token = value;
  }

  /// Rotation of a verified token for the SAME account, not an account switch.
  void installRenewedToken(String token) {
    if (_token.isEmpty || token.trim().isEmpty) {
      throw const CopyApiException('自动续期的账号状态无效');
    }
    _token = token.trim();
    _credentialRevision++;
  }

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
    if (value != authenticationDomain) _tokenRevision++;
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
      if (fastest != authenticationDomain) _tokenRevision++;
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
    CopyApiResultsValidator? validateResults,
    String invalidResultsMessage = '节点返回了空数据',
    String? candidateToken,
  }) {
    // Candidate credentials may only be verified by the profile endpoint.
    // They never replace the current session before server + secure-store checks.
    if (candidateToken != null &&
        (path != CopyApiProtocol.profilePath ||
            !authenticated ||
            method.toUpperCase() != 'GET' ||
            candidateToken.trim().isEmpty)) {
      return Future.error(const CopyApiException('无效的凭证验证请求'));
    }
    if (authenticated != CopyApiProtocol.requiresAuthentication(path)) {
      return Future.error(const CopyApiException('接口登录凭据配置不匹配，已阻止请求'));
    }
    if ((authenticated || path == CopyApiProtocol.loginPath) &&
        method.toUpperCase() !=
            (CopyApiProtocol.isAccountWrite(path) ? 'POST' : 'GET')) {
      return Future.error(const CopyApiException('账号接口请求方式不匹配，已阻止请求'));
    }
    if (!path.startsWith('/api/v3/') ||
        path.contains('?') ||
        path.contains('#')) {
      return Future.error(const CopyApiException('无效的 API 请求路径'));
    }
    Future<dynamic> request() => _requestResults(
      path,
      method: method,
      query: query,
      data: data,
      authenticated: authenticated,
      formEncoded: formEncoded,
      validateResults: validateResults,
      invalidResultsMessage: invalidResultsMessage,
      candidateToken: candidateToken,
    );
    if (authenticated || path == CopyApiProtocol.loginPath) {
      Future<dynamic> accountRequest() => _withSessionRenewal(
        () => _accountRequest(request, authenticated: authenticated),
        enabled: authenticated && candidateToken == null,
        readOnly: method.toUpperCase() == 'GET',
      );
      if (authenticated &&
          method.toUpperCase() == 'GET' &&
          candidateToken == null) {
        final key = jsonEncode([_tokenRevision, path, query]);
        final pending = _accountReads[key];
        if (pending != null) return pending;
        Future<dynamic> read() async {
          try {
            return await accountRequest();
          } finally {
            _accountReads.remove(key);
          }
        }

        return _accountReads[key] = read();
      }
      return accountRequest();
    }
    return request();
  }

  Future<dynamic> _withSessionRenewal(
    Future<dynamic> Function() request, {
    required bool enabled,
    required bool readOnly,
  }) async {
    final revision = _tokenRevision;
    final credentialRevision = _credentialRevision;
    final previousToken = _token;
    try {
      return await request();
    } on CopyApiException catch (error) {
      if (!enabled ||
          error.code != 401 ||
          error.accountRestricted ||
          _accountRestriction != null ||
          previousToken.isEmpty ||
          revision != _tokenRevision ||
          renewExpiredSession == null) {
        rethrow;
      }
      // This catch is OUTSIDE the serialized account lane: login/profile must
      // be able to enter that lane without deadlocking the failed request.
      if (_credentialRevision == credentialRevision) {
        if (_failedRenewalRevision == revision) rethrow;
        if (_renewal == null || _renewalRevision != revision) {
          _renewalRevision = revision;
          final future = Future<bool>.sync(renewExpiredSession!);
          _renewal = future;
        }
        final pending = _renewal!;
        var renewed = false;
        try {
          renewed = await pending;
        } finally {
          if (!renewed) _failedRenewalRevision = revision;
          if (identical(_renewal, pending)) _renewal = null;
        }
        if (!renewed) rethrow;
      }
      if (revision != _tokenRevision ||
          _credentialRevision == credentialRevision) {
        throw const CopyApiException('账号或节点已切换，已停止旧会话续期');
      }
      if (!readOnly) {
        // Never replay a favorite mutation. UI re-reads the target state first.
        throw const CopyApiException('登录已自动续期，请重新确认收藏状态后操作');
      }
      // One retry only; a second 401 never causes a renewal loop.
      try {
        return await request();
      } on CopyApiException catch (retryError) {
        if (retryError.code == 401) _failedRenewalRevision = revision;
        rethrow;
      }
    }
  }

  // A shared lane for comic/novel favorites and login/profile requests.
  // Content and image downloads remain anonymous and do not enter this lane.
  Future<dynamic> _accountRequest(
    Future<dynamic> Function() request, {
    required bool authenticated,
  }) async {
    final previous = _accountTail;
    final done = Completer<void>();
    final tokenRevision = _tokenRevision;
    _accountTail = done.future;
    var started = false;
    try {
      await previous;
      final lastEnd = _lastAccountRequestEnd;
      if (lastEnd != null) {
        final wait =
            accountRequestInterval - DateTime.now().difference(lastEnd);
        if (wait > Duration.zero) await Future<void>.delayed(wait);
      }
      if (_accountRestriction case final restriction?) throw restriction;
      final retryAt = _accountRetryNotBefore;
      if (retryAt != null && DateTime.now().isBefore(retryAt)) {
        throw CopyApiException(
          '账号请求暂时限流，请稍后再试',
          code: 429,
          retryAfter: retryAt.difference(DateTime.now()),
        );
      }
      if (authenticated && tokenRevision != _tokenRevision) {
        throw const CopyApiException('账号已切换，已取消旧账号的待处理请求');
      }
      started = true;
      return await request();
    } on CopyApiException catch (error) {
      if (error.accountRestricted) _accountRestriction = error;
      if (error.code == 429) {
        // Do not extend the server's cooldown for requests rejected locally.
        if (started) {
          _accountRetryNotBefore = DateTime.now().add(
            error.retryAfter ?? const Duration(minutes: 1),
          );
        }
      }
      rethrow;
    } finally {
      if (started) _lastAccountRequestEnd = DateTime.now();
      done.complete();
    }
  }

  Future<dynamic> _requestResults(
    String path, {
    required String method,
    Map<String, dynamic>? query,
    Map<String, dynamic>? data,
    required bool authenticated,
    required bool formEncoded,
    CopyApiResultsValidator? validateResults,
    required String invalidResultsMessage,
    String? candidateToken,
  }) async {
    _requireIdentity();
    if (authenticated && candidateToken == null) _requireLogin();
    final tokenRevision = _tokenRevision;
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

    // Account requests stay on the selected domestic node. An ambiguous POST
    // result must never be replayed automatically, even after a timeout/404.
    final accountRequest = isLogin || authenticated;
    for (final domain in accountRequest ? candidates.take(1) : candidates) {
      try {
        // Discovery can await network I/O; don't send a newly selected token
        // as the continuation of a request scheduled for the previous user.
        if (authenticated && tokenRevision != _tokenRevision) {
          throw const CopyApiException('账号已切换，已取消旧账号的待处理请求');
        }
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
          candidateToken: candidateToken,
        );
        if (authenticated && tokenRevision != _tokenRevision) {
          throw const CopyApiException('账号已切换，已丢弃旧账号的响应');
        }
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
        if (accountRequest) {
          throw CopyApiException('账号节点请求失败，未自动重试：${failure.message}');
        }
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
    String? candidateToken,
  }) async {
    try {
      final isLogin = path == CopyApiProtocol.loginPath;
      final accountRequest = isLogin || authenticated;
      final commonParameters = CopyRequestProtocol.commonParameters(
        identity: _identity,
        date: _startupDate,
        region: accountRequest ? '0' : _regionForDomain(domain),
        // Login and ALL content endpoints use the logged-out request profile.
        token: authenticated && !isLogin ? (candidateToken ?? _token) : '',
      );
      if (isLogin && kDebugMode) {
        debugPrint(
          '[CopyLogin] request host=$domain '
          'version=${CopyRequestProtocol.version} platform=3 region=0',
        );
      }
      final response = await _dio.request<dynamic>(
        'https://$domain$path',
        queryParameters: {...?query, 'platform': 3},
        data: method.toUpperCase() == 'POST'
            ? CopyRequestProtocol.formBody(
                data: data ?? const {},
                commonParameters: commonParameters,
              )
            : data,
        options: Options(
          method: method,
          followRedirects: !accountRequest,
          validateStatus: accountRequest ? (status) => status != null : null,
          contentType: formEncoded || method.toUpperCase() == 'POST'
              ? Headers.formUrlEncodedContentType
              : null,
          headers: CopyRequestProtocol.headers(
            commonParameters: commonParameters,
            nativeMaterial: CopyRequestProtocol.certificateMd5,
            now: _requestClock(),
          ),
        ),
      );
      final status = response.statusCode ?? 0;
      if (accountRequest && (status == 429 || status == 403)) {
        Map<String, dynamic> errorMap;
        try {
          errorMap = _decodeResponseMap(response.data, status: status);
        } on _CopyNodeFailure {
          errorMap = const {};
        }
        final message =
            errorMap['message']?.toString() ??
            (status == 429 ? '账号请求暂时限流，请稍后再试' : '服务器拒绝了账号请求');
        throw CopyApiException(
          message,
          code: status,
          accountRestricted: _isAccountRestriction(message),
          retryAfter: _retryAfter(response.headers.value('retry-after')),
        );
      }
      final map = _decodeResponseMap(response.data, status: status);
      final code = _asInt(map['code'], fallback: status);
      if (isLogin && kDebugMode) {
        debugPrint(
          '[CopyLogin] response host=$domain status=$status code=$code '
          'hasMessage=${map['message'] != null}',
        );
      }

      if (status == 401 && authenticated) {
        final restricted = _isAccountRestriction(
          map['message']?.toString() ?? '',
        );
        throw CopyApiException(
          restricted ? map['message'].toString() : '登录已过期，请重新登录',
          code: 401,
          accountRestricted: restricted,
        );
      }
      if (status == 404 || status == 405 || status == 410) {
        throw _CopyNodeFailure(
          map['message']?.toString() ?? '节点不支持当前接口（HTTP $status）',
        );
      }
      if (status != 200 || code != 200) {
        final message =
            map['message']?.toString() ?? '请求失败（HTTP $status，code $code）';
        throw CopyApiException(
          message,
          code: code,
          accountRestricted: accountRequest && _isAccountRestriction(message),
          retryAfter: _retryAfter(response.headers.value('retry-after')),
        );
      }
      return map['results'];
    } on CopyApiException {
      rethrow;
    } on _CopyNodeFailure {
      rethrow;
    } on DioException catch (error) {
      // A failed favorite mutation must not be mistaken for an empty list or
      // silently replayed on every node. Keep diagnostics free of credentials.
      if (path == CopyApiProtocol.novelCollectPath &&
          error.response?.statusCode != null) {
        throw CopyApiException(
          '小说收藏提交失败（HTTP ${error.response!.statusCode}，$domain）',
          code: error.response!.statusCode,
        );
      }
      throw _CopyNodeFailure(_networkErrorMessage(error));
    } on FormatException {
      throw const _CopyNodeFailure('服务器返回了无效 JSON');
    }
  }

  static bool _isAccountRestriction(String message) => RegExp(
    r'风控|風控|封控|解封|账号.{0,8}(限制|受限|封禁)|帳[號戶].{0,8}(限制|受限|封禁)|account.{0,20}(restricted|suspended|blocked)',
    caseSensitive: false,
  ).hasMatch(message);

  static Duration? _retryAfter(String? value) {
    final seconds = int.tryParse(value ?? '');
    if (seconds != null) {
      return seconds >= 0 ? Duration(seconds: seconds) : null;
    }
    if (value == null) return null;
    try {
      final remaining = HttpDate.parse(value).difference(DateTime.now());
      return remaining > Duration.zero ? remaining : Duration.zero;
    } on FormatException {
      return null;
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
    _requireIdentity();
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
              startupDate: _startupDate,
              now: _requestClock(),
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
    _requireIdentity();
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
              startupDate: _startupDate,
              now: _requestClock(),
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
        'https://$domain${CopyApiProtocol.networkPath}',
        queryParameters: CopyApiProtocol.networkQuery,
        options: Options(
          headers: CopyApiProtocol.headers(
            region: forceMainland
                ? CopyApiRoute.mainland.region
                : _regionForDomain(domain),
            identity: _identity,
            startupDate: _startupDate,
            now: _requestClock(),
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
          results['api'] is! List) {
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
      throw const CopyApiException('请先登录拷贝漫画', code: 401);
    }
  }

  void _requireIdentity() {
    if (!_identity.isReady) {
      throw const CopyApiException('设备请求参数尚未初始化，请重启应用后重试；本地阅读不受影响');
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
