import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../core/file_names.dart';
import '../models/chapter.dart';
import '../models/comic.dart';
import '../models/library_view.dart';
import '../services/copy_client.dart';
import '../services/library_database.dart';
import '../services/library_locator.dart';
import '../services/local_app_database.dart';

class ComicRefreshResult {
  const ComicRefreshResult({required this.comic, required this.chapters});

  final Comic comic;
  final List<Chapter> chapters;
}

class LibraryController extends ChangeNotifier {
  LibraryController({
    required this.database,
    required this.locator,
    required this.client,
    required this.localDatabase,
  });

  final LibraryDatabase database;
  final LibraryLocator locator;
  final CopyClient client;
  final LocalAppDatabase localDatabase;

  bool loading = false;
  bool ready = false;
  String error = '';
  String operationStatus = '';
  String query = '';
  List<Comic> comics = const [];
  List<Comic> _loadedComics = const [];
  ComicSourceFilter sourceFilter = ComicSourceFilter.all;
  ComicSortMode sortMode = ComicSortMode.original;
  int batchScanConcurrency = 4;

  int get totalCount => _loadedComics.length;

  Directory? get root => database.root;
  String get rootPath => root?.path ?? '';
  bool get usingExternal => locator.usingExternal;

  Future<void> initialize() async {
    loading = true;
    error = '';
    operationStatus = '正在打开漫画库';
    notifyListeners();
    try {
      final located = await locator.locate();
      await database.open(
        located,
        databaseFile: await locator.databaseFileFor(
          located,
          onProgress: _setOperationStatus,
        ),
      );
      await _restoreViewPreferences();
      _setOperationStatus('正在加载漫画列表');
      await refresh();
      ready = true;
    } catch (exception) {
      error = '漫画库打开失败：$exception';
    } finally {
      loading = false;
      operationStatus = '';
      notifyListeners();
    }
  }

  Future<void> refresh({String? search}) async {
    if (search != null) query = search;
    _loadedComics = await database.loadComics(query: query);
    _applyView();
    notifyListeners();
  }

  Future<void> setSourceFilter(ComicSourceFilter value) async {
    if (sourceFilter == value) return;
    sourceFilter = value;
    _applyView();
    notifyListeners();
    await localDatabase.setPreference('library_source_filter', value.name);
  }

  Future<void> setSortMode(ComicSortMode value) async {
    if (sortMode == value) return;
    sortMode = value;
    _applyView();
    notifyListeners();
    await localDatabase.setPreference('library_sort_mode', value.name);
  }

  Future<void> setBatchScanConcurrency(int value) async {
    final normalized = value.clamp(1, 10);
    if (batchScanConcurrency == normalized) return;
    batchScanConcurrency = normalized;
    notifyListeners();
    await localDatabase.setPreference(
      'batch_scan_concurrency',
      normalized.toString(),
    );
  }

  void _applyView() {
    final visible = _loadedComics
        .where(sourceFilter.accepts)
        .toList(growable: false);
    final sorted = visible.toList();
    switch (sortMode) {
      case ComicSortMode.original:
        sorted.sort((left, right) {
          final byOrder = left.libraryOrder.compareTo(right.libraryOrder);
          return byOrder != 0 ? byOrder : left.title.compareTo(right.title);
        });
      case ComicSortMode.titleInitial:
        sorted.sort((left, right) {
          final leftKey = left.titleSortKey.isEmpty
              ? left.title.toLowerCase()
              : left.titleSortKey;
          final rightKey = right.titleSortKey.isEmpty
              ? right.title.toLowerCase()
              : right.titleSortKey;
          final byKey = leftKey.compareTo(rightKey);
          if (byKey != 0) return byKey;
          return left.libraryOrder.compareTo(right.libraryOrder);
        });
    }
    comics = List.unmodifiable(sorted);
  }

  Future<void> _restoreViewPreferences() async {
    final sourceValue = await localDatabase.preference('library_source_filter');
    sourceFilter = ComicSourceFilter.values.firstWhere(
      (value) => value.name == sourceValue,
      orElse: () => ComicSourceFilter.all,
    );
    final sortValue = await localDatabase.preference('library_sort_mode');
    sortMode = ComicSortMode.values.firstWhere(
      (value) => value.name == sortValue,
      orElse: () => ComicSortMode.original,
    );
    batchScanConcurrency =
        int.tryParse(
          await localDatabase.preference('batch_scan_concurrency'),
        )?.clamp(1, 10) ??
        4;
  }

  Future<bool> useLibraryPath(String selected) async {
    loading = true;
    error = '';
    notifyListeners();
    try {
      final located = await locator.choose(selected);
      if (located == null) return false;
      await database.open(
        located,
        databaseFile: await locator.databaseFileFor(located),
      );
      await refresh(search: '');
      ready = true;
      return true;
    } catch (exception) {
      error = '切换漫画库失败：$exception';
      return false;
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<bool> chooseExternalLibrary() async {
    loading = true;
    error = '';
    operationStatus = '请在系统文件选择器中选择漫画库';
    notifyListeners();
    try {
      final located = await locator.chooseExternal();
      if (located == null) return false;
      _setOperationStatus('正在准备外置漫画库');
      await database.open(
        located,
        databaseFile: await locator.databaseFileFor(
          located,
          onProgress: _setOperationStatus,
        ),
      );
      _setOperationStatus('正在加载漫画列表');
      await refresh(search: '');
      ready = true;
      return true;
    } catch (exception) {
      error = '外置漫画库打开失败：$exception';
      return false;
    } finally {
      loading = false;
      operationStatus = '';
      notifyListeners();
    }
  }

  Future<bool> resetToDefaultLibrary() async {
    loading = true;
    error = '';
    operationStatus = '正在安全关闭外置漫画库';
    notifyListeners();
    try {
      await database.close();
      final located = await locator.resetToDefault();
      _setOperationStatus('正在打开默认漫画库');
      await database.open(
        located,
        databaseFile: await locator.databaseFileFor(
          located,
          onProgress: _setOperationStatus,
        ),
      );
      await refresh(search: '');
      ready = true;
      return true;
    } catch (exception) {
      ready = false;
      error = '恢复默认漫画库失败：$exception';
      return false;
    } finally {
      loading = false;
      operationStatus = '';
      notifyListeners();
    }
  }

  void _setOperationStatus(String value) {
    operationStatus = value;
    notifyListeners();
  }

  String coverPath(Comic comic) {
    if (root == null || comic.coverRelativePath.isEmpty) return '';
    return absoluteLibraryPath(root!.path, comic.coverRelativePath);
  }

  String archivePath(Chapter chapter) {
    if (root == null || chapter.archiveRelativePath.isEmpty) return '';
    return absoluteLibraryPath(root!.path, chapter.archiveRelativePath);
  }

  Future<List<Chapter>> chapters(String comicUuid) {
    return database.loadChapters(comicUuid);
  }

  Future<List<Comic>> copyMangaComics() async {
    final all = await database.loadComics();
    return all
        .where(
          (comic) =>
              (comic.source == ComicSource.copyManga ||
                  comic.source == ComicSource.both) &&
              comic.pathWord.isNotEmpty &&
              !comic.pathWord.startsWith('local-'),
        )
        .toList(growable: false);
  }

  Future<Comic> refreshDetails(Comic source) async {
    final result = await _refreshDetails(
      source,
      updateCoreComic: true,
      cacheCover: true,
    );
    await refresh();
    return result.comic;
  }

  Future<ComicRefreshResult> refreshDetailsForBatch(Comic source) {
    return _refreshDetails(source, updateCoreComic: false, cacheCover: false);
  }

  Future<ComicRefreshResult> _refreshDetails(
    Comic source, {
    required bool updateCoreComic,
    required bool cacheCover,
  }) async {
    if (source.pathWord.startsWith('local-')) {
      return ComicRefreshResult(
        comic: source,
        chapters: await database.loadChapters(source.uuid),
      );
    }
    final details = await client.comicDetails(source.pathWord);
    final merged = details.comic.copyWith(
      uuid: source.uuid.isEmpty ? null : source.uuid,
      comicRelativeDir: source.comicRelativeDir,
      coverRelativePath: source.coverRelativePath,
      downloadedChapters: source.downloadedChapters,
      totalChapters: source.totalChapters,
      isFavorite: source.isFavorite,
      source: source.source,
      libraryOrder: source.libraryOrder,
      titleSortKey: source.titleSortKey,
    );
    if (updateCoreComic || source.uuid.isEmpty) {
      await database.cacheComic(merged, raw: details.rawComic);
    } else {
      await database.cacheComicDetails(merged, raw: details.rawComic);
    }
    for (final group in details.groups) {
      final chapters = await client.groupChapters(comic: merged, group: group);
      await database.cacheChapters(
        merged,
        group.pathWord,
        group.name,
        chapters,
      );
    }
    if (cacheCover) await _cacheCoverIfNeeded(merged);
    return ComicRefreshResult(
      comic: await database.loadComic(merged.uuid) ?? merged,
      chapters: await database.loadChapters(merged.uuid),
    );
  }

  Future<void> _cacheCoverIfNeeded(Comic comic) async {
    final libraryRoot = root;
    if (libraryRoot == null || comic.coverUrl.isEmpty) return;
    if (comic.coverRelativePath.isNotEmpty) {
      final existing = File(
        absoluteLibraryPath(libraryRoot.path, comic.coverRelativePath),
      );
      if (await existing.exists()) return;
    }
    final directoryName = comic.comicRelativeDir.isNotEmpty
        ? comic.comicRelativeDir
        : comicDirectoryName(comic.title, comic.authors);
    final directory = Directory(p.join(libraryRoot.path, directoryName));
    await directory.create(recursive: true);
    final bytes = await client.imageBytes(comic.coverUrl);
    final extension = imageExtensionFromBytes(bytes);
    final file = File(
      p.join(
        directory.path,
        coverFileName(comic.title, comic.authors, extension: extension),
      ),
    );
    await file.writeAsBytes(bytes, flush: true);
    final relative = p.relative(file.path, from: libraryRoot.path);
    await database.setCoverRelativePath(comic.uuid, relative);
  }
}
