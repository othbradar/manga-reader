import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../models/comic.dart';
import '../models/download_task.dart';
import '../models/recent_view.dart';

typedef AppSupportDirectoryProvider = Future<Directory> Function();

class LocalAppDatabase {
  LocalAppDatabase({
    DatabaseFactory? factory,
    AppSupportDirectoryProvider? supportDirectoryProvider,
  }) : _factory = factory ?? databaseFactory,
       _supportDirectoryProvider =
           supportDirectoryProvider ?? getApplicationSupportDirectory;

  static const fileName = 'copy_manga_reader_local.db';

  final DatabaseFactory _factory;
  final AppSupportDirectoryProvider _supportDirectoryProvider;
  Database? _database;
  File? _databaseFile;

  Database get database {
    final value = _database;
    if (value == null) throw StateError('应用本机数据库尚未初始化');
    return value;
  }

  String get databasePath {
    final value = _databaseFile;
    if (value == null) throw StateError('应用本机数据库尚未初始化');
    return value.path;
  }

  Future<void> open() async {
    if (_database != null) return;
    final support = await _supportDirectoryProvider();
    await support.create(recursive: true);
    _databaseFile = File(p.join(support.path, fileName));
    _database = await _factory.openDatabase(
      _databaseFile!.path,
      options: OpenDatabaseOptions(
        version: 1,
        onConfigure: (db) async {
          await db.rawQuery('PRAGMA journal_mode = WAL');
          await db.rawQuery('PRAGMA busy_timeout = 5000');
        },
        onCreate: (db, _) => _createSchema(db),
      ),
    );
    await _createSchema(database);
  }

  Future<void> _createSchema(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS recent_views(
        comic_uuid TEXT PRIMARY KEY,
        path_word TEXT NOT NULL DEFAULT '',
        title TEXT NOT NULL DEFAULT '',
        authors TEXT NOT NULL DEFAULT '',
        comic_relative_dir TEXT NOT NULL DEFAULT '',
        cover_url TEXT NOT NULL DEFAULT '',
        cover_relative_path TEXT NOT NULL DEFAULT '',
        source_kind TEXT NOT NULL DEFAULT 'copy_manga',
        library_order INTEGER NOT NULL DEFAULT 0,
        title_sort_key TEXT NOT NULL DEFAULT '',
        chapter_uuid TEXT NOT NULL DEFAULT '',
        chapter_title TEXT NOT NULL DEFAULT '',
        page_index INTEGER NOT NULL DEFAULT 0,
        page_count INTEGER NOT NULL DEFAULT 0,
        viewed_at TEXT NOT NULL DEFAULT ''
      )
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_recent_views_time
      ON recent_views(viewed_at DESC)
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS read_progress(
        chapter_uuid TEXT PRIMARY KEY,
        comic_uuid TEXT NOT NULL,
        page_index INTEGER NOT NULL DEFAULT 0,
        page_count INTEGER NOT NULL DEFAULT 0,
        updated_at TEXT NOT NULL DEFAULT ''
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS local_preferences(
        preference_key TEXT PRIMARY KEY,
        preference_value TEXT NOT NULL DEFAULT ''
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS comic_details(
        library_key TEXT NOT NULL,
        comic_uuid TEXT NOT NULL,
        alias TEXT NOT NULL DEFAULT '',
        brief TEXT NOT NULL DEFAULT '',
        status TEXT NOT NULL DEFAULT '',
        region TEXT NOT NULL DEFAULT '',
        themes TEXT NOT NULL DEFAULT '',
        last_chapter TEXT NOT NULL DEFAULT '',
        popular INTEGER NOT NULL DEFAULT 0,
        cached_at TEXT NOT NULL DEFAULT '',
        PRIMARY KEY(library_key, comic_uuid)
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS favorites_cache(
        library_key TEXT NOT NULL,
        comic_uuid TEXT NOT NULL,
        path_word TEXT NOT NULL DEFAULT '',
        title TEXT NOT NULL DEFAULT '',
        authors TEXT NOT NULL DEFAULT '',
        cover_url TEXT NOT NULL DEFAULT '',
        alias TEXT NOT NULL DEFAULT '',
        brief TEXT NOT NULL DEFAULT '',
        status TEXT NOT NULL DEFAULT '',
        last_chapter TEXT NOT NULL DEFAULT '',
        source_kind TEXT NOT NULL DEFAULT 'copy_manga',
        library_order INTEGER NOT NULL DEFAULT 0,
        title_sort_key TEXT NOT NULL DEFAULT '',
        position INTEGER NOT NULL DEFAULT 0,
        cached_at TEXT NOT NULL DEFAULT '',
        PRIMARY KEY(library_key, comic_uuid)
      )
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_favorites_library_position
      ON favorites_cache(library_key, position)
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS download_tasks(
        library_key TEXT NOT NULL,
        chapter_uuid TEXT NOT NULL,
        comic_uuid TEXT NOT NULL,
        comic_path_word TEXT NOT NULL,
        comic_title TEXT NOT NULL,
        authors TEXT NOT NULL DEFAULT '',
        group_path_word TEXT NOT NULL DEFAULT 'default',
        group_name TEXT NOT NULL DEFAULT '',
        chapter_title TEXT NOT NULL,
        chapter_order REAL NOT NULL DEFAULT 0,
        state TEXT NOT NULL DEFAULT 'queued',
        progress REAL NOT NULL DEFAULT 0,
        error_message TEXT NOT NULL DEFAULT '',
        queued_at TEXT NOT NULL DEFAULT '',
        updated_at TEXT NOT NULL DEFAULT '',
        PRIMARY KEY(library_key, chapter_uuid)
      )
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_download_tasks_library_state
      ON download_tasks(library_key, state, queued_at)
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS search_index(
        library_key TEXT NOT NULL,
        comic_uuid TEXT NOT NULL,
        title_normalized TEXT NOT NULL DEFAULT '',
        authors_normalized TEXT NOT NULL DEFAULT '',
        normalizer_version TEXT NOT NULL DEFAULT '',
        indexed_at TEXT NOT NULL DEFAULT '',
        PRIMARY KEY(library_key, comic_uuid)
      )
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_search_index_library_title
      ON search_index(library_key, title_normalized)
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_search_index_library_authors
      ON search_index(library_key, authors_normalized)
    ''');
  }

  Future<List<RecentView>> loadRecentViews({int limit = 100}) async {
    final rows = await database.query(
      'recent_views',
      orderBy: 'viewed_at DESC',
      limit: limit,
    );
    return rows.map(RecentView.fromDatabase).toList(growable: false);
  }

  Future<int> loadReadProgress(String chapterUuid) async {
    final rows = await database.query(
      'read_progress',
      columns: ['page_index'],
      where: 'chapter_uuid = ?',
      whereArgs: [chapterUuid],
      limit: 1,
    );
    return rows.isEmpty ? 0 : (rows.first['page_index'] as num?)?.toInt() ?? 0;
  }

  Future<void> saveReadProgress(
    String comicUuid,
    String chapterUuid,
    int pageIndex,
    int pageCount,
  ) async {
    await database.insert('read_progress', {
      'chapter_uuid': chapterUuid,
      'comic_uuid': comicUuid,
      'page_index': pageIndex,
      'page_count': pageCount,
      'updated_at': DateTime.now().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> saveReadingState(RecentView view) async {
    final timestamp = view.viewedAt.toIso8601String();
    await database.transaction((transaction) async {
      await transaction.insert('read_progress', {
        'chapter_uuid': view.chapterUuid,
        'comic_uuid': view.comic.uuid,
        'page_index': view.pageIndex,
        'page_count': view.pageCount,
        'updated_at': timestamp,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      await transaction.insert('recent_views', {
        'comic_uuid': view.comic.uuid,
        'path_word': view.comic.pathWord,
        'title': view.comic.title,
        'authors': view.comic.authors,
        'comic_relative_dir': view.comic.comicRelativeDir,
        'cover_url': view.comic.coverUrl,
        'cover_relative_path': view.comic.coverRelativePath,
        'source_kind': view.comic.source.databaseValue,
        'library_order': view.comic.libraryOrder,
        'title_sort_key': view.comic.titleSortKey,
        'chapter_uuid': view.chapterUuid,
        'chapter_title': view.chapterTitle,
        'page_index': view.pageIndex,
        'page_count': view.pageCount,
        'viewed_at': timestamp,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });
  }

  Future<String> preference(String key) async {
    final rows = await database.query(
      'local_preferences',
      columns: ['preference_value'],
      where: 'preference_key = ?',
      whereArgs: [key],
      limit: 1,
    );
    return rows.isEmpty ? '' : rows.first['preference_value']?.toString() ?? '';
  }

  Future<void> setPreference(String key, String value) async {
    await database.insert('local_preferences', {
      'preference_key': key,
      'preference_value': value,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> replaceSearchIndex(
    String libraryKey,
    Iterable<Map<String, Object?>> rows,
  ) async {
    await database.transaction((transaction) async {
      await transaction.delete(
        'search_index',
        where: 'library_key = ?',
        whereArgs: [libraryKey],
      );
      for (final row in rows) {
        final comicUuid = row['comic_uuid']?.toString() ?? '';
        if (comicUuid.isEmpty) continue;
        await transaction.insert('search_index', {
          'library_key': libraryKey,
          ...row,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
  }

  Future<void> upsertSearchIndex(
    String libraryKey,
    Map<String, Object?> row,
  ) async {
    if ((row['comic_uuid']?.toString() ?? '').isEmpty) return;
    await database.insert('search_index', {
      'library_key': libraryKey,
      ...row,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> cacheComicDetails(
    String libraryKey,
    Comic comic, {
    String region = '',
    String themes = '',
    int popular = 0,
  }) async {
    await database.insert('comic_details', {
      'library_key': libraryKey,
      'comic_uuid': comic.uuid,
      'alias': comic.alias,
      'brief': comic.brief,
      'status': comic.status,
      'region': region,
      'themes': themes,
      'last_chapter': comic.lastChapter,
      'popular': popular,
      'cached_at': DateTime.now().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> replaceFavorites(
    String libraryKey,
    List<Comic> favorites,
  ) async {
    final now = DateTime.now().toIso8601String();
    await database.transaction((transaction) async {
      await transaction.delete(
        'favorites_cache',
        where: 'library_key = ?',
        whereArgs: [libraryKey],
      );
      for (var index = 0; index < favorites.length; index++) {
        final comic = favorites[index];
        if (comic.uuid.isEmpty) continue;
        await transaction.insert('favorites_cache', {
          'library_key': libraryKey,
          'comic_uuid': comic.uuid,
          'path_word': comic.pathWord,
          'title': comic.title,
          'authors': comic.authors,
          'cover_url': comic.coverUrl,
          'alias': comic.alias,
          'brief': comic.brief,
          'status': comic.status,
          'last_chapter': comic.lastChapter,
          'source_kind': comic.source.databaseValue,
          'library_order': comic.libraryOrder,
          'title_sort_key': comic.titleSortKey,
          'position': index,
          'cached_at': now,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
  }

  Future<List<DownloadTask>> loadDownloadTasks(String libraryKey) async {
    final rows = await database.query(
      'download_tasks',
      where: 'library_key = ?',
      whereArgs: [libraryKey],
      orderBy:
          "CASE state WHEN 'downloading' THEN 0 WHEN 'queued' THEN 1 "
          "WHEN 'paused' THEN 2 WHEN 'failed' THEN 3 ELSE 4 END, queued_at",
    );
    return rows.map(DownloadTask.fromDatabase).toList(growable: false);
  }

  Future<void> saveDownloadTask(String libraryKey, DownloadTask task) async {
    final now = DateTime.now().toIso8601String();
    await database.insert('download_tasks', {
      'library_key': libraryKey,
      'chapter_uuid': task.chapterUuid,
      'comic_uuid': task.comicUuid,
      'comic_path_word': task.comicPathWord,
      'comic_title': task.comicTitle,
      'authors': task.authors,
      'group_path_word': task.groupPathWord,
      'group_name': task.groupName,
      'chapter_title': task.chapterTitle,
      'chapter_order': task.chapterOrder,
      'state': task.state.name,
      'progress': task.progress,
      'error_message': task.errorMessage,
      'queued_at': now,
      'updated_at': now,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> updateDownloadTask(String libraryKey, DownloadTask task) async {
    await database.update(
      'download_tasks',
      {
        'state': task.state.name,
        'progress': task.progress,
        'error_message': task.errorMessage,
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'library_key = ? AND chapter_uuid = ?',
      whereArgs: [libraryKey, task.chapterUuid],
    );
  }

  Future<void> recoverInterruptedTasks(String libraryKey) async {
    await database.update(
      'download_tasks',
      {'state': DownloadState.paused.name, 'error_message': '应用上次退出，任务已安全暂停'},
      where: 'library_key = ? AND state = ?',
      whereArgs: [libraryKey, DownloadState.downloading.name],
    );
  }

  Future<void> clearCompletedTasks(String libraryKey) async {
    await database.delete(
      'download_tasks',
      where: 'library_key = ? AND state = ?',
      whereArgs: [libraryKey, DownloadState.completed.name],
    );
  }

  Future<void> clearDownloadTasks(String libraryKey) async {
    await database.delete(
      'download_tasks',
      where: 'library_key = ?',
      whereArgs: [libraryKey],
    );
  }

  Future<void> close() async {
    final current = _database;
    _database = null;
    _databaseFile = null;
    if (current == null) return;
    try {
      await current.rawQuery('PRAGMA wal_checkpoint(TRUNCATE)');
    } catch (_) {
      // Closing local UI state should remain best effort.
    }
    await current.close();
  }
}
