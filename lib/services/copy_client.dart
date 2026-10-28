import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../models/chapter.dart';
import '../models/comic.dart';
import 'chinese_search_normalizer.dart';
import 'copy_api_protocol.dart';
import 'copy_api_transport.dart';
import 'copy_novel_client.dart';
import 'favorite_refresh_window.dart';

export 'copy_api_transport.dart' show CopyApiException, CopyApiNode;

class ComicGroup {
  const ComicGroup({
    required this.pathWord,
    required this.name,
    required this.count,
  });

  final String pathWord;
  final String name;
  final int count;
}

class ComicDetailsResult {
  const ComicDetailsResult({
    required this.comic,
    required this.groups,
    required this.rawComic,
  });

  final Comic comic;
  final List<ComicGroup> groups;
  final Map<String, dynamic> rawComic;
}

class ChapterContent {
  const ChapterContent({required this.urls, required this.pageCount});

  final List<String> urls;
  final int pageCount;
}

class CopyClient {
  CopyClient({
    Dio? dio,
    Dio? imageDio,
    String apiDomain = CopyApiProtocol.defaultDomain,
    this.normalizer,
  }) : _transport = CopyApiTransport(
         dio: dio,
         imageDio: imageDio,
         apiDomain: apiDomain,
       );

  final CopyApiTransport _transport;
  final ChineseSearchNormalizer? normalizer;
  CopyNovelClient? _novels;
  CopyNovelClient get novels =>
      _novels ??= CopyNovelClient(_transport, normalizer);

  String get apiDomain => _transport.apiDomain;
  String get apiUrl => _transport.apiUrl;
  String get authenticationDomain => _transport.authenticationDomain;
  String get authenticationUrl => _transport.authenticationUrl;
  List<String> get discoveredApiDomains => _transport.discoveredDomains;
  List<CopyApiNode> get apiNodes => _transport.apiNodes;
  List<CopyApiNode> get authenticationNodes => _transport.authenticationNodes;
  bool get usesAutomaticApiDomain => _transport.usesAutomaticDomain;
  bool get usesAutomaticAuthenticationDomain =>
      _transport.usesAutomaticAuthenticationDomain;
  bool get hasToken => _transport.hasToken;
  int get sessionRevision => _transport.sessionRevision;
  CopyApiRoute get apiRoute => _transport.apiRoute;

  void setToken(String token) => _transport.setToken(token);

  void setSessionRenewal(Future<bool> Function()? renewal) =>
      _transport.renewExpiredSession = renewal;

  void installRenewedToken(String token) =>
      _transport.installRenewedToken(token);

  void setDeviceIdentity(CopyDeviceIdentity identity) =>
      _transport.setDeviceIdentity(identity);

  void setApiRoute(CopyApiRoute route) => _transport.setApiRoute(route);

  void setApiDomain(String domain, {bool manual = true}) =>
      _transport.setApiDomain(domain, manual: manual);

  void useFastestApiDomain() => _transport.useFastestDomain();

  Future<List<CopyApiNode>> refreshApiDomains() async {
    await _transport.refreshDynamicDomains();
    return apiNodes;
  }

  void setAuthenticationDomain(String domain, {bool manual = true}) =>
      _transport.setAuthenticationDomain(domain, manual: manual);

  void useFastestAuthenticationDomain() =>
      _transport.useFastestAuthenticationDomain();

  Future<List<CopyApiNode>> refreshAuthenticationDomains() =>
      _transport.refreshAuthenticationDomains();

  Future<Map<String, dynamic>> login(String username, String password) async {
    final result = await authenticateCredentials(username, password);
    setToken(result['token']! as String);
    return result;
  }

  /// Verify without mutating the current account or recursively renewing it.
  Future<Map<String, dynamic>> authenticateCredentials(
    String username,
    String password,
  ) async {
    final revision = sessionRevision;
    final results = await _transport.requestResults(
      CopyApiProtocol.loginPath,
      method: 'POST',
      data: CopyApiProtocol.loginBody(username, password),
      formEncoded: true,
    );
    final map = _asMap(results);
    final token = map['token']?.toString() ?? '';
    if (token.isEmpty) throw const CopyApiException('登录成功但服务器未返回令牌');
    if (revision != sessionRevision) {
      throw const CopyApiException('账号或节点已切换，已停止旧登录请求');
    }
    final member = _asMap(
      await _transport.requestResults(
        CopyApiProtocol.profilePath,
        authenticated: true,
        candidateToken: token,
      ),
    );
    if (revision != sessionRevision) {
      throw const CopyApiException('账号或节点已切换，未保存旧登录凭证');
    }
    if (kDebugMode) {
      debugPrint(
        '[CopyLogin] token verified by member profile '
        'profilePresent=${member.isNotEmpty}',
      );
    }
    return <String, dynamic>{...map, ...member, 'token': token};
  }

  Future<Map<String, dynamic>> profile() async {
    return _asMap(
      await _transport.requestResults(
        CopyApiProtocol.profilePath,
        authenticated: true,
      ),
    );
  }

  Future<List<Comic>> favorites({
    String ordering = '-datetime_updated',
    Set<String> knownUuids = const {},
  }) async {
    final window = FavoriteRefreshWindow(knownUuids);
    final revision = sessionRevision;
    const limit = 18;
    var offset = 0;
    var total = 1;
    final comics = <Comic>[];
    final seen = <String>{};
    while (offset < total) {
      if (revision != sessionRevision) {
        throw const CopyApiException('账号已切换，已停止旧账号的收藏分页');
      }
      final results = _asMap(
        await _transport.requestResults(
          CopyApiProtocol.favoritesPath,
          query: CopyApiProtocol.favoritesQuery(
            limit: limit,
            offset: offset,
            ordering: knownUuids.isEmpty
                ? ordering
                : FavoriteRefreshWindow.ordering,
          ),
          authenticated: true,
          validateResults: (value) => _asMap(value)['list'] is List,
        ),
      );
      if (revision != sessionRevision) {
        throw const CopyApiException('账号已切换，已停止旧账号的收藏分页');
      }
      final list = _asList(results['list']);
      final before = comics.length;
      final pageIds = <String>[];
      for (final item in list) {
        final row = _asMap(item);
        final comicData = row['comic'] is Map ? _asMap(row['comic']) : row;
        final comic = Comic.fromApi(comicData, favorite: true);
        if (comic.uuid.isEmpty) {
          throw const CopyApiException('漫画收藏缺少标识，已保留原收藏缓存');
        }
        pageIds.add(comic.uuid);
        if (comic.uuid.isNotEmpty && seen.add(comic.uuid)) comics.add(comic);
      }
      total = _asInt(results['total'], fallback: comics.length);
      offset += list.length;
      if (list.isEmpty && offset < total ||
          list.isNotEmpty && comics.length == before) {
        throw const CopyApiException('漫画收藏分页不完整，已保留原收藏缓存');
      }
      if (window.accept(pageIds, total)) break;
    }
    return comics;
  }

  Future<void> setFavorite(Comic comic, bool selected) async {
    if (comic.uuid.isEmpty ||
        comic.pathWord.isEmpty ||
        comic.pathWord.startsWith('local-')) {
      throw const CopyApiException('本地漫画没有在线收藏标识');
    }
    await _transport.requestResults(
      CopyApiProtocol.comicCollectPath,
      method: 'POST',
      authenticated: true,
      formEncoded: true,
      data: CopyApiProtocol.comicCollectBody(comic.uuid, selected),
    );
  }

  Future<List<Comic>> search(String keyword, {int page = 1}) async {
    final variants =
        normalizer?.queryVariants(keyword) ?? <String>[keyword.trim()];
    for (final variant in variants) {
      final results = await _searchOnce(variant, page: page);
      if (results.isNotEmpty) return results;
    }
    return const [];
  }

  Future<List<Comic>> _searchOnce(String keyword, {required int page}) async {
    const limit = 20;
    final results = _asMap(
      await _transport.requestResults(
        CopyApiProtocol.searchPath,
        query: CopyApiProtocol.searchQuery(
          keyword: keyword,
          limit: limit,
          offset: (page - 1) * limit,
        ),
        validateResults: (value) => _asMap(value)['list'] is List,
        invalidResultsMessage: '搜索节点没有返回结果列表',
      ),
    );
    return _asList(results['list'])
        .map((item) => Comic.fromApi(_asMap(item)))
        .where((comic) => comic.pathWord.isNotEmpty && comic.title.isNotEmpty)
        .toList(growable: false);
  }

  Future<ComicDetailsResult> comicDetails(String pathWord) async {
    await _transport.prepare();
    final results = _asMap(
      await _transport.requestResults(
        CopyApiProtocol.comicDetailsPath(pathWord),
        query: CopyApiProtocol.comicDetailsQuery(
          inMainland: _transport.inMainland,
        ),
        validateResults: (value) {
          final comic = _asMap(_asMap(value)['comic']);
          final uuid = comic['uuid']?.toString().trim() ?? '';
          final returnedPath =
              (comic['path_word'] ?? comic['pathWord'])?.toString().trim() ??
              '';
          return uuid.isNotEmpty &&
              returnedPath.isNotEmpty &&
              returnedPath.toLowerCase() == pathWord.trim().toLowerCase();
        },
        invalidResultsMessage: '详情节点返回的漫画标识不匹配',
      ),
    );
    final rawComic = _asMap(results['comic']);
    final comic = Comic.fromApi(rawComic);
    final groupMap = _asMap(results['groups']);
    final groups = <ComicGroup>[];
    for (final entry in groupMap.entries) {
      final value = _asMap(entry.value);
      groups.add(
        ComicGroup(
          pathWord:
              value['path_word']?.toString() ??
              value['pathWord']?.toString() ??
              entry.key,
          name: value['name']?.toString() ?? entry.key,
          count: _asInt(value['count']),
        ),
      );
    }
    return ComicDetailsResult(comic: comic, groups: groups, rawComic: rawComic);
  }

  Future<List<Chapter>> groupChapters({
    required Comic comic,
    required ComicGroup group,
  }) async {
    const limit = 100;
    if (group.count <= 0) return const <Chapter>[];
    var offset = 0;
    var total = group.count;
    final chapters = <Chapter>[];
    while (offset < total) {
      final expectRows = offset < total;
      final results = _asMap(
        await _transport.requestResults(
          CopyApiProtocol.groupChaptersPath(comic.pathWord, group.pathWord),
          query: CopyApiProtocol.groupChaptersQuery(
            limit: limit,
            offset: offset,
          ),
          validateResults: (value) {
            final list = _asMap(value)['list'];
            return list is List && (!expectRows || list.isNotEmpty);
          },
          invalidResultsMessage: '${group.name}节点返回了空章节列表',
        ),
      );
      final list = _asList(results['list']);
      chapters.addAll(
        list.map(
          (item) => Chapter.fromApi(
            _asMap(item),
            comicUuid: comic.uuid,
            groupPathWord: group.pathWord,
            groupName: group.name,
          ),
        ),
      );
      total = _asInt(results['total'], fallback: chapters.length);
      offset += limit;
      if (list.isEmpty) break;
    }
    return chapters;
  }

  Future<ChapterContent> chapterContent({
    required String comicPathWord,
    required String chapterUuid,
  }) async {
    await _transport.prepare();
    // Reading and saving to ZIP both consume anonymous reading images.
    // The user explicitly prefers this to the account-only download endpoint.
    final rawResults = await _transport.requestResults(
      CopyApiProtocol.chapterContentPath(comicPathWord, chapterUuid),
      query: CopyApiProtocol.chapterContentQuery(
        inMainland: _transport.inMainland,
      ),
      validateResults: _hasChapterImages,
      invalidResultsMessage: '章节没有返回可下载的图片',
    );

    final results = _asMap(rawResults);
    final chapter = _asMap(results['chapter']);
    final urls = _chapterUrls(results);
    if (urls.isEmpty) {
      throw const CopyApiException('章节没有返回可下载的图片');
    }
    return ChapterContent(
      urls: urls,
      pageCount: _asInt(chapter['size'], fallback: urls.length),
    );
  }

  static bool _hasChapterImages(Object? results) =>
      _chapterUrls(_asMap(results)).isNotEmpty;

  static List<String> _chapterUrls(Map<String, dynamic> results) {
    final chapter = _asMap(results['chapter']);
    return _asList(chapter['contents'])
        .map(
          (item) =>
              item is String ? item : _asMap(item)['url']?.toString() ?? '',
        )
        .where((url) => url.isNotEmpty)
        .toList(growable: false);
  }

  Future<Uint8List> imageBytes(
    String url, {
    ProgressCallback? onReceiveProgress,
    CancelToken? cancelToken,
  }) async {
    return _transport.imageBytes(
      url,
      onReceiveProgress: onReceiveProgress,
      cancelToken: cancelToken,
    );
  }

  static Map<String, dynamic> _asMap(Object? value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) return Map<String, dynamic>.from(value);
    return <String, dynamic>{};
  }

  static List<dynamic> _asList(Object? value) =>
      value is List ? value : const <dynamic>[];

  static int _asInt(Object? value, {int fallback = 0}) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? fallback;
  }
}
