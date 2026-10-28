import 'package:flutter/foundation.dart';

import '../models/comic.dart';
import '../services/copy_client.dart';
import '../services/library_database.dart';

class FavoritesController extends ChangeNotifier {
  FavoritesController({required this.database, required this.client});

  final LibraryDatabase database;
  final CopyClient client;

  bool loading = false;
  String error = '';
  List<Comic> comics = const [];
  (int, String, String?)? _verifiedScope;
  final Map<(int, String, String?), Future<void>> _reads = {};
  bool _changing = false;
  bool _disposed = false;
  (int, String, String?) get _scope => (
    client.sessionRevision,
    database.libraryKey,
    database.favoritesAccountKey,
  );

  void changeAccount(String account) {
    database.favoritesAccountKey = account;
    comics = const [];
    error = '';
    loading = false;
    _verifiedScope = null;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _checkScope((int, String, String?) scope) {
    if (_disposed || scope != _scope) {
      throw const CopyApiException('账号或漫画库已切换，已停止收藏操作');
    }
  }

  Future<void> loadCache() async {
    final scope = _scope;
    final loaded = await database.loadFavorites(accountKey: scope.$3);
    if (_disposed || scope != _scope) return;
    comics = loaded;
    _notify();
  }

  Future<void> refresh() async {
    final scope = _scope;
    error = '';
    try {
      await _synchronize(force: true);
    } on CopyApiException catch (exception) {
      if (scope == _scope) error = exception.message;
    } catch (exception) {
      if (scope == _scope) error = '收藏刷新失败：$exception';
    } finally {
      _notify();
    }
  }

  Future<void> _synchronize({bool force = false}) {
    final scope = _scope;
    if (scope.$3 == '') throw const CopyApiException('请先登录账号');
    if (!force && _verifiedScope == scope) return Future.value();
    return _reads.putIfAbsent(scope, () async {
      loading = true;
      _notify();
      try {
        final remote = await client.favorites();
        _checkScope(scope);
        await database.localDatabase.replaceFavorites(
          scope.$2,
          remote,
          accountKey: scope.$3,
        );
        _checkScope(scope);
        final loaded = await database.loadFavorites(accountKey: scope.$3);
        _checkScope(scope);
        comics = loaded;
        _verifiedScope = scope;
      } finally {
        _reads.remove(scope);
        loading = _reads.containsKey(_scope);
        _notify();
      }
    });
  }

  Future<bool> isCollected(Comic comic) async {
    await _synchronize();
    return comics.any((item) => item.uuid == comic.uuid);
  }

  Future<void> setFavorite(Comic comic, bool selected) async {
    if (_changing) throw const CopyApiException('正在处理收藏，请稍后再试');
    _changing = true;
    final scope = _scope;
    try {
      final existing = await isCollected(comic);
      _checkScope(scope);
      if (existing == selected) return;
      // One write only. An uncertain response must never trigger replay.
      await client.setFavorite(comic, selected);
      _checkScope(scope);
      _verifiedScope = null;
      await _synchronize(force: true);
      if (comics.any((item) => item.uuid == comic.uuid) != selected) {
        throw const CopyApiException('服务器尚未确认收藏变更，请同步收藏后检查');
      }
    } catch (_) {
      _verifiedScope = null;
      rethrow;
    } finally {
      _changing = false;
      _notify();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
