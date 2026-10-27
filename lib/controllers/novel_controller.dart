import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../core/file_names.dart';
import '../models/comic.dart';
import '../models/library_view.dart';
import '../models/novel.dart';
import '../services/copy_novel_client.dart';
import '../services/copy_api_transport.dart';
import '../services/novel_store.dart';
import '../services/novel_text.dart';

class NovelController extends ChangeNotifier {
  NovelController({required this.store, required this.client});
  final NovelStore store;
  final CopyNovelClient client;
  List<Novel> books = [];
  List<Novel> _loadedBooks = [];
  ComicSourceFilter sourceFilter = ComicSourceFilter.all;
  ComicSortMode sortMode = ComicSortMode.original;
  int _refreshRevision = 0;
  List<Novel> favorites = [];
  List<Map<String, Object?>> tasks = [];
  bool loading = false, paused = true;
  String error = '', query = '';
  bool collecting = false;
  bool _cancelCollect = false;
  int collectDone = 0, collectTotal = 0;
  final Map<String, String> collectFailures = {};
  (int, String, String)? _verifiedFavorites;
  final Map<(int, String, String), Future<void>> _favoriteReads = {};
  bool _changingFavorite = false;
  (int, String, String) _favoriteScope(String account) =>
      (client.sessionRevision, store.key, account);

  void _checkFavoriteScope((int, String, String) scope) {
    if (_disposed ||
        scope.$1 != client.sessionRevision ||
        scope.$2 != store.key) {
      throw const CopyApiException('账号或漫画库已切换，已停止收藏操作');
    }
  }

  String _key = '';
  bool _disposed = false;
  Future<void>? _run;
  CancelToken? _cancel;
  Database get local => store.library.localDatabase.database;

  Future<void> initialize() async {
    await pause();
    _key = store.key;
    loading = true;
    error = '';
    _notify();
    try {
      await store.ensureSchema();
      await _restoreViewPreferences();
      await local.update(
        'novel_tasks',
        {'state': 'paused'},
        where: "library_key=? AND state IN ('queued','downloading')",
        whereArgs: [_key],
      );
      await refresh();
    } catch (e) {
      error = '小说库打开失败：$e';
    } finally {
      loading = false;
      _notify();
    }
  }

  Future<void> refresh({String? search}) async {
    if (search != null) query = search;
    final revision = ++_refreshRevision;
    final key = store.key;
    final loaded = await store.books(query: query);
    if (_disposed || revision != _refreshRevision || key != store.key) return;
    _loadedBooks = loaded;
    _applyView();
    await _loadTasks();
    _notify();
  }

  Future<void> setSourceFilter(ComicSourceFilter value) async {
    if (sourceFilter == value) return;
    sourceFilter = value;
    _applyView();
    _notify();
    await store.library.localDatabase.setPreference(
      'novel_library_source_filter',
      value.name,
    );
  }

  Future<void> setSortMode(ComicSortMode value) async {
    if (sortMode == value) return;
    sortMode = value;
    _applyView();
    _notify();
    await store.library.localDatabase.setPreference(
      'novel_library_sort_mode',
      value.name,
    );
  }

  Future<void> _restoreViewPreferences() async {
    final preferences = store.library.localDatabase;
    final source = await preferences.preference('novel_library_source_filter');
    sourceFilter = ComicSourceFilter.values.firstWhere(
      (value) => value.name == source,
      orElse: () => ComicSourceFilter.all,
    );
    final sort = await preferences.preference('novel_library_sort_mode');
    sortMode = ComicSortMode.values.firstWhere(
      (value) => value.name == sort,
      orElse: () => ComicSortMode.original,
    );
  }

  void _applyView() {
    final visible = _loadedBooks
        .where(
          (book) =>
              sourceFilter.acceptsSource(ComicSource.fromDatabase(book.source)),
        )
        .toList();
    visible.sort((left, right) {
      if (sortMode == ComicSortMode.titleInitial) {
        final leftKey = left.titleSortKey.isEmpty
            ? left.title.toLowerCase()
            : left.titleSortKey;
        final rightKey = right.titleSortKey.isEmpty
            ? right.title.toLowerCase()
            : right.titleSortKey;
        final byKey = leftKey.compareTo(rightKey);
        if (byKey != 0) return byKey;
      }
      final byOrder = left.order.compareTo(right.order);
      if (byOrder != 0) return byOrder;
      final byTitle = left.title.compareTo(right.title);
      return byTitle != 0 ? byTitle : left.uuid.compareTo(right.uuid);
    });
    books = List.unmodifiable(visible);
  }

  Future<int> scanLocal() async {
    final count = await store.importLocalFolders();
    await refresh();
    return count;
  }

  Future<Novel> updateBook(Novel book) async {
    if (book.isLocal) return book;
    final detailed = await client.details(book.pathWord);
    final volumes = await client.volumes(detailed);
    if (volumes.isEmpty) throw const FormatException('服务器没有返回小说分卷，已保留本地目录');
    final saved = await store.saveBook(detailed);
    await store.saveVolumes(volumes);
    await refresh();
    return saved;
  }

  Future<void> loadFavorites(String account, {bool online = false}) async {
    final scope = _favoriteScope(account);
    if (online) {
      return _favoriteReads.putIfAbsent(scope, () async {
        try {
          await _loadFavorites(account, online: true);
          _checkFavoriteScope(scope);
          _verifiedFavorites = scope;
        } finally {
          _favoriteReads.remove(scope);
        }
      });
    }
    if (_verifiedFavorites == scope) return;
    await _loadFavorites(account);
  }

  Future<void> _loadFavorites(String account, {bool online = false}) async {
    final scope = _favoriteScope(account);
    final key = store.key;
    if (online) {
      final remote = await client.favorites();
      _checkFavoriteScope(scope);
      await local.transaction((txn) async {
        await txn.delete(
          'novel_favorites',
          where: 'library_key=? AND account_key=?',
          whereArgs: [key, account],
        );
        for (final (i, b) in remote.indexed) {
          if (b.uuid.isEmpty) continue;
          await txn.insert('novel_favorites', {
            'library_key': key,
            'account_key': account,
            'novel_uuid': b.uuid,
            'path_word': b.pathWord,
            'title': b.title,
            'authors': b.authors,
            'alias': b.alias,
            'brief': b.brief,
            'cover_url': b.coverUrl,
            'position': i,
          });
        }
      });
    }
    final loaded = (await local.query(
      'novel_favorites',
      where: 'library_key=? AND account_key=?',
      whereArgs: [key, account],
      orderBy: 'position',
    )).map(Novel.fromRow).toList();
    _checkFavoriteScope(scope);
    favorites = loaded;
    _notify();
  }

  Future<bool> isCollected(Novel book, String account) async {
    if (_verifiedFavorites != _favoriteScope(account)) {
      await loadFavorites(account, online: true);
    }
    return favorites.any((b) => b.uuid == book.uuid);
  }

  Future<void> favorite(Novel book, bool selected, String account) async {
    if (_changingFavorite || collecting) {
      throw const CopyApiException('正在处理收藏，请稍后再试');
    }
    _changingFavorite = true;
    final scope = _favoriteScope(account);
    try {
      final existing = await isCollected(book, account);
      _checkFavoriteScope(scope);
      if (existing == selected) return;
      await client.setFavorite(book, selected);
      _checkFavoriteScope(scope);
      _verifiedFavorites = null;
      await loadFavorites(account, online: true);
      if (favorites.any((b) => b.uuid == book.uuid) != selected) {
        throw const CopyApiException('服务器尚未确认收藏变更，请同步收藏后检查');
      }
    } catch (_) {
      _verifiedFavorites = null;
      rethrow;
    } finally {
      _changingFavorite = false;
      _notify();
    }
  }

  /// Explicit UI action only; never changes or removes existing remote favorites.
  Future<int> collectLocalBooks(
    String account, {
    bool retryOnly = false,
  }) async {
    if (collecting || _changingFavorite) {
      throw const CopyApiException('正在处理收藏，请稍后再试');
    }
    collecting = true;
    _cancelCollect = false;
    collectDone = 0;
    collectTotal = 0;
    final key = store.key;
    final scope = _favoriteScope(account);
    final previousFailures = collectFailures.keys.toSet();
    collectFailures.clear();
    _notify();
    final attempted = <String>{};
    try {
      await loadFavorites(account, online: true);
      _checkFavoriteScope(scope);
      final remote = favorites.map((b) => b.uuid).toSet();
      final candidates = (await store.books())
          .where(
            (b) =>
                !b.isLocal &&
                b.uuid.isNotEmpty &&
                b.pathWord.isNotEmpty &&
                b.downloadedVolumes > 0 &&
                !remote.contains(b.uuid) &&
                (!retryOnly || previousFailures.contains(b.uuid)),
          )
          .toList();
      collectTotal = candidates.length;
      for (final b in candidates) {
        if (_disposed || store.key != key || _cancelCollect) break;
        _checkFavoriteScope(scope);
        attempted.add(b.uuid);
        try {
          await client.setFavorite(b, true);
        } catch (e) {
          collectFailures[b.uuid] = '${b.title}：$e';
          collectDone++;
          _notify();
          // An uncertain write/service failure must stop the batch at once.
          // Do not keep mutating more books or perform another account read.
          rethrow;
        }
        collectDone++;
        _notify();
        await Future<void>.delayed(const Duration(milliseconds: 350));
      }
      _checkFavoriteScope(scope);
      await loadFavorites(account, online: true);
      final verified = favorites.map((b) => b.uuid).toSet();
      collectFailures.removeWhere((uuid, _) => verified.contains(uuid));
      for (final b in candidates) {
        if (attempted.contains(b.uuid) && !verified.contains(b.uuid)) {
          collectFailures.putIfAbsent(
            b.uuid,
            () => '${b.title}：未在服务器收藏中确认，请重试',
          );
        }
      }
      return attempted.where(verified.contains).length;
    } catch (_) {
      _verifiedFavorites = null;
      rethrow;
    } finally {
      collecting = false;
      _notify();
    }
  }

  void cancelCollect() {
    _cancelCollect = true;
  }

  Future<int> enqueue(Novel book, Iterable<NovelVolume> volumes) async {
    final saved = await store.saveBook(book);
    final values = volumes.where((v) => !v.downloaded).toList();
    await store.saveVolumes(values);
    var count = 0;
    for (final v in values) {
      final old = await local.query(
        'novel_tasks',
        where: 'library_key=? AND novel_uuid=? AND volume_id=?',
        whereArgs: [store.key, saved.uuid, v.id],
      );
      if (old.isNotEmpty &&
          ['queued', 'downloading'].contains(old.first['state'])) {
        continue;
      }
      await local.insert('novel_tasks', {
        'library_key': store.key,
        'novel_uuid': saved.uuid,
        'volume_id': v.id,
        'state': 'queued',
        'queued_at': DateTime.now().toUtc().toIso8601String(),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      count++;
    }
    await _loadTasks();
    await resume();
    return count;
  }

  Future<void> _loadTasks() async {
    tasks = await local.query(
      'novel_tasks',
      where: 'library_key=?',
      whereArgs: [store.key],
      orderBy: 'queued_at',
    );
  }

  Future<void> pause() async {
    cancelCollect();
    paused = true;
    _cancel?.cancel('暂停小说下载');
    await _run;
    if (_key.isNotEmpty) {
      await local.update(
        'novel_tasks',
        {'state': 'paused'},
        where: "library_key=? AND state IN ('queued','downloading')",
        whereArgs: [_key],
      );
      if (store.library.root != null && _key == store.key) await _loadTasks();
    }
    _notify();
  }

  Future<void> resume() async {
    if (_key.isEmpty) _key = store.key;
    paused = false;
    await local.update(
      'novel_tasks',
      {'state': 'queued', 'error_message': ''},
      where: "library_key=? AND state='paused'",
      whereArgs: [_key],
    );
    await _loadTasks();
    _notify();
    _start();
  }

  Future<void> retryFailures() async {
    await local.update(
      'novel_tasks',
      {'state': 'queued', 'error_message': ''},
      where: "library_key=? AND state='failed'",
      whereArgs: [store.key],
    );
    await resume();
  }

  Future<void> clearFinished() async {
    await local.delete(
      'novel_tasks',
      where: "library_key=? AND state IN ('completed','failed')",
      whereArgs: [store.key],
    );
    await _loadTasks();
    _notify();
  }

  void _start() {
    if (_run != null || paused || _disposed) return;
    _run = _pump().whenComplete(() {
      _run = null;
    });
  }

  Future<void> _pump() async {
    try {
      while (!paused && !_disposed && _key == store.key) {
        final rows = await local.query(
          'novel_tasks',
          where: "library_key=? AND state='queued'",
          whereArgs: [_key],
          orderBy: 'queued_at',
          limit: 1,
        );
        if (rows.isEmpty) break;
        final row = rows.single;
        final uuid = novelText(row['novel_uuid']),
            vid = novelText(row['volume_id']);
        _cancel = CancelToken();
        try {
          await _state(uuid, vid, 'downloading', 0);
          final book = await store.book(uuid);
          if (book == null) throw const FormatException('下载任务对应的小说不存在');
          final volume = await store.volume(uuid, vid);
          await _download(book, volume);
          _check();
          await _state(uuid, vid, 'completed', 1);
        } catch (e) {
          await _state(
            uuid,
            vid,
            paused ? 'paused' : 'failed',
            null,
            error: paused ? '' : e.toString(),
          );
        } finally {
          _cancel = null;
        }
      }
    } catch (e) {
      error = '小说下载队列失败：$e';
    }
    if (!_disposed && _key == store.key) await refresh();
  }

  void _check() {
    if (paused || _disposed || _key != store.key) throw StateError('小说下载已暂停');
  }

  Future<T> _retry<T>(Future<T> Function() action) async {
    for (var attempt = 0; ; attempt++) {
      _check();
      try {
        return await action();
      } catch (_) {
        _check();
        if (attempt >= 3) rethrow;
        // Short interruptible backoff, never delay pause for a full retry window.
        for (var i = 0; i < (1 << attempt) * 10; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          _check();
        }
      }
    }
  }

  Future<void> _download(Novel book, NovelVolume original) async {
    final volume = await _retry(() => client.content(book, original));
    _check();
    final directory = book.relativeDir.isEmpty
        ? '小说/${comicDirectoryName(book.title, book.authors)} - 拷贝小说'
        : book.relativeDir;
    final folder = Directory(store.absolute(directory));
    await folder.create(recursive: true);
    final duplicates =
        (await store.volumes(
          book.uuid,
        )).where((v) => v.title == volume.title).length >
        1;
    final stem =
        '${comicDirectoryName(book.title, book.authors)} - ${safeFileName(volume.title)}'
        '${duplicates ? ' [${safeFileName(volume.id)}]' : ''}';
    final text = await _retry(
      () async => decodeNovelText(
        await client.bytes(volume.textUrl, cancelToken: _cancel),
        encoding: volume.encoding,
      ),
    );
    _check();
    final bytes = utf8.encode(text);
    final textFile = File(p.join(folder.path, '$stem.txt'));
    await _writeNew(textFile, bytes);
    final imageSections = volume.sections.where((s) => s.isImage).toList();
    final paths = <int, String>{};
    var next = 0, done = 0;
    final parallel =
        int.tryParse(
          await store.library.setting('image_download_concurrency'),
        )?.clamp(1, 10) ??
        3;
    await Future.wait(
      List.generate(parallel, (_) async {
        while (next < imageSections.length) {
          final section = imageSections[next++];
          _check();
          final data = await _retry(
            () => client.bytes(section.imageUrl, cancelToken: _cancel),
          );
          _check();
          final ext = _imageExtension(data);
          final file = File(
            p.join(
              folder.path,
              '$stem - ${(section.index + 1).toString().padLeft(3, '0')} ${safeFileName(section.title)}.$ext',
            ),
          );
          await _writeNew(file, data);
          paths[section.index] = store.relative(file.path);
          done++;
          await _state(
            book.uuid,
            volume.id,
            'downloading',
            (done + 1) / (imageSections.length + 2),
          );
        }
      }),
    );
    _check();
    var cover = book.coverRelativePath;
    if (cover.isEmpty && book.coverUrl.isNotEmpty) {
      final data = await _retry(
        () => client.bytes(book.coverUrl, cancelToken: _cancel),
      );
      _check();
      final file = File(
        p.join(
          folder.path,
          coverFileName(
            book.title,
            book.authors,
            extension: _imageExtension(data),
          ),
        ),
      );
      await _writeNew(file, data);
      cover = store.relative(file.path);
    }
    _check();
    await store.saveBook(book.withFiles(directory: directory, cover: cover));
    await store.completeVolume(
      volume,
      store.relative(textFile.path),
      sha256.convert(bytes).toString(),
      paths,
    );
  }

  static String _imageExtension(List<int> b) {
    if (b.length >= 3 && b[0] == 255 && b[1] == 216 && b[2] == 255) {
      return 'jpg';
    }
    if (b.length >= 8 &&
        b[0] == 137 &&
        b[1] == 80 &&
        b[2] == 78 &&
        b[3] == 71) {
      return 'png';
    }
    if (b.length >= 12 &&
        ascii.decode(b.take(4).toList(), allowInvalid: true) == 'RIFF' &&
        ascii.decode(b.sublist(8, 12), allowInvalid: true) == 'WEBP') {
      return 'webp';
    }
    if (b.length >= 6 &&
        ascii.decode(b.take(3).toList(), allowInvalid: true) == 'GIF') {
      return 'gif';
    }
    throw const FormatException('插图返回的不是图片，未保存错误响应');
  }

  static Future<void> _writeNew(File file, List<int> data) async {
    if (await file.exists()) {
      if (sha256.convert(await file.readAsBytes()).toString() ==
          sha256.convert(data).toString()) {
        return;
      }
      throw FileSystemException('已有文件内容不同，已保留原文件', file.path);
    }
    final part = File('${file.path}.novel-part');
    await part.writeAsBytes(data, flush: true);
    await part.rename(file.path);
  }

  Future<void> _state(
    String uuid,
    String vid,
    String state,
    double? progress, {
    String error = '',
  }) async {
    await local.update(
      'novel_tasks',
      {'state': state, 'progress': ?progress, 'error_message': error},
      where: 'library_key=? AND novel_uuid=? AND volume_id=?',
      whereArgs: [_key, uuid, vid],
    );
    await _loadTasks();
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    paused = true;
    _cancel?.cancel();
    super.dispose();
  }
}
