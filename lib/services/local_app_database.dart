import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../models/comic.dart';
import '../models/download_task.dart';
import '../models/recent_view.dart';

typedef AppSupportDirectoryProvider = Future<Directory> Function();

class PortableAppDataTransferResult {
  const PortableAppDataTransferResult({
    required this.recentViews,
    required this.readProgress,
    required this.preferences,
    required this.comicDetails,
    required this.favorites,
    required this.downloadTasks,
    required this.searchEntries,
    this.novelRows = 0,
  });

  final int recentViews;
  final int readProgress;
  final int preferences;
  final int comicDetails;
  final int favorites;
  final int downloadTasks;
  final int searchEntries;
  final int novelRows;

  int get totalRows =>
      recentViews +
      readProgress +
      preferences +
      comicDetails +
      favorites +
      downloadTasks +
      searchEntries +
      novelRows;
}

class LocalAppDatabase {
  LocalAppDatabase({
    DatabaseFactory? factory,
    AppSupportDirectoryProvider? supportDirectoryProvider,
  }) : _factory = factory ?? databaseFactory,
       _supportDirectoryProvider =
           supportDirectoryProvider ?? getApplicationSupportDirectory;

  static const fileName = 'copy_manga_reader_local.db';
  static const portableBackupFileName = '拷贝漫画阅读器应用数据.db';
  static const _portableBackupFormat = 'copy_manga_reader_app_data';
  static const _portableBackupVersion = 1;
  static const _portableLibraryKey = '__portable_current_library__';
  static const _globalTables = <String>[
    'recent_views',
    'read_progress',
    'local_preferences',
  ];
  static const _libraryTables = <String>[
    'comic_details',
    'favorites_cache',
    'download_tasks',
    'search_index',
  ];
  static const _novelTables = [
    'novel_progress',
    'novel_tasks',
    'novel_favorites',
  ];

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
    // Installation identity is deliberately excluded from portable backups.
    // Never migrate it with a library or another device's app preferences.
    await db.execute('''CREATE TABLE IF NOT EXISTS device_identity(
      identity_key TEXT PRIMARY KEY, identity_value TEXT NOT NULL)''');
    await db.execute(
      '''CREATE TABLE IF NOT EXISTS novel_progress(
      library_key TEXT NOT NULL, novel_uuid TEXT NOT NULL, volume_id TEXT NOT NULL,
      block_index INTEGER NOT NULL DEFAULT 0, fraction REAL NOT NULL DEFAULT 0,
      updated_at TEXT NOT NULL DEFAULT '', PRIMARY KEY(library_key,novel_uuid,volume_id))''',
    );
    await db.execute('''CREATE TABLE IF NOT EXISTS novel_tasks(
      library_key TEXT NOT NULL, novel_uuid TEXT NOT NULL, volume_id TEXT NOT NULL,
      state TEXT NOT NULL DEFAULT 'queued', progress REAL NOT NULL DEFAULT 0,
      error_message TEXT NOT NULL DEFAULT '', queued_at TEXT NOT NULL DEFAULT '',
      PRIMARY KEY(library_key,novel_uuid,volume_id))''');
    await db.execute('''CREATE TABLE IF NOT EXISTS novel_favorites(
      library_key TEXT NOT NULL, account_key TEXT NOT NULL, novel_uuid TEXT NOT NULL,
      path_word TEXT NOT NULL, title TEXT NOT NULL, authors TEXT NOT NULL DEFAULT '',
      alias TEXT NOT NULL DEFAULT '', brief TEXT NOT NULL DEFAULT '', cover_url TEXT NOT NULL DEFAULT '',
      position INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY(library_key,account_key,novel_uuid))''');
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

  /// Writes a portable SQLite snapshot beside the current manga library.
  ///
  /// The shared manga index is not touched. Login tokens, passwords and
  /// platform directory grants are held by secure storage and deliberately
  /// excluded from this file.
  Future<PortableAppDataTransferResult> exportPortableBackup(
    File destination, {
    required String libraryKey,
  }) async {
    if (libraryKey.trim().isEmpty) throw ArgumentError.value(libraryKey);
    await open();
    final sourcePath = p.canonicalize(File(databasePath).absolute.path);
    final destinationPath = p.canonicalize(destination.absolute.path);
    if (sourcePath == destinationPath) {
      throw ArgumentError('应用数据库不能覆盖自身');
    }

    await destination.parent.create(recursive: true);
    final partial = File('${destination.path}.partial');
    await _deleteSqliteFamily(partial);

    Database? backup;
    var completed = false;
    try {
      backup = await _factory.openDatabase(
        partial.path,
        options: OpenDatabaseOptions(
          version: 1,
          singleInstance: false,
          onConfigure: (db) async {
            await db.rawQuery('PRAGMA journal_mode = DELETE');
            await db.rawQuery('PRAGMA busy_timeout = 5000');
          },
          onCreate: (db, _) async {
            await _createSchema(db);
            await _createPortableMetadataSchema(db);
          },
        ),
      );
      await _createSchema(backup);
      await _createPortableMetadataSchema(backup);

      final globalRows = <String, List<Map<String, Object?>>>{
        for (final table in _globalTables)
          table: await _exportableGlobalRows(table),
      };
      final libraryRows = <String, List<Map<String, Object?>>>{
        for (final table in [..._libraryTables, ..._novelTables])
          table: await database.query(
            table,
            where: 'library_key = ?',
            whereArgs: [libraryKey],
          ),
      };

      await backup.transaction((transaction) async {
        for (final table in [
          ..._globalTables,
          ..._libraryTables,
          ..._novelTables,
        ]) {
          await transaction.delete(table);
        }
        await transaction.delete('portable_backup_metadata');
        await transaction.insert('portable_backup_metadata', {
          'format': _portableBackupFormat,
          'format_version': _portableBackupVersion,
          'exported_at': DateTime.now().toUtc().toIso8601String(),
        });
        for (final entry in globalRows.entries) {
          for (final row in entry.value) {
            await transaction.insert(
              entry.key,
              Map<String, Object?>.from(row),
              conflictAlgorithm: ConflictAlgorithm.replace,
            );
          }
        }
        for (final entry in libraryRows.entries) {
          for (final row in entry.value) {
            await transaction.insert(entry.key, {
              ...row,
              'library_key': _portableLibraryKey,
            }, conflictAlgorithm: ConflictAlgorithm.replace);
          }
        }
      });

      final result = _transferResult(globalRows, libraryRows);
      await backup.close();
      backup = null;
      await _deleteSqliteCompanions(destination);
      await partial.rename(destination.path);
      completed = true;
      return result;
    } finally {
      await backup?.close();
      if (!completed) await _deleteSqliteFamily(partial);
    }
  }

  /// Merges a portable snapshot into this device and remaps its library-scoped
  /// rows to the currently opened manga library.
  Future<PortableAppDataTransferResult> importPortableBackup(
    File source, {
    required String libraryKey,
  }) async {
    if (libraryKey.trim().isEmpty) throw ArgumentError.value(libraryKey);
    if (!await source.exists()) {
      throw FileSystemException('找不到应用数据备份', source.path);
    }
    await _verifySQLiteHeader(source);
    await open();

    Database? backup;
    try {
      backup = await _factory.openDatabase(
        source.path,
        options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
      );
      final tableRows = await backup.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table'",
      );
      final tables = tableRows
          .map((row) => row['name']?.toString() ?? '')
          .toSet();
      final requiredTables = {
        'portable_backup_metadata',
        ..._globalTables,
        ..._libraryTables,
      };
      final missing = requiredTables.difference(tables);
      if (missing.isNotEmpty) {
        throw FormatException('应用数据备份缺少必要数据表：${missing.join('、')}');
      }
      final metadata = await backup.query('portable_backup_metadata', limit: 1);
      if (metadata.isEmpty ||
          metadata.first['format']?.toString() != _portableBackupFormat ||
          (metadata.first['format_version'] as num?)?.toInt() !=
              _portableBackupVersion) {
        throw const FormatException('不是受支持的拷贝漫画阅读器应用数据备份');
      }

      final globalRows = <String, List<Map<String, Object?>>>{
        for (final table in _globalTables) table: await backup.query(table),
      };
      final libraryRows = <String, List<Map<String, Object?>>>{
        for (final table in [..._libraryTables, ..._novelTables])
          table: !tables.contains(table)
              ? []
              : await backup.query(
                  table,
                  where: 'library_key = ?',
                  whereArgs: [_portableLibraryKey],
                ),
      };

      await database.transaction((transaction) async {
        for (final entry in globalRows.entries) {
          for (final row in entry.value) {
            await transaction.insert(
              entry.key,
              Map<String, Object?>.from(row),
              conflictAlgorithm: ConflictAlgorithm.replace,
            );
          }
        }
        for (final entry in libraryRows.entries) {
          for (final sourceRow in entry.value) {
            final row = <String, Object?>{
              ...sourceRow,
              'library_key': libraryKey,
            };
            if (entry.key == 'download_tasks' || entry.key == 'novel_tasks') {
              final state = row['state']?.toString();
              if (state == DownloadState.queued.name ||
                  state == DownloadState.downloading.name) {
                row['state'] = DownloadState.paused.name;
                row['error_message'] = '从其他设备导入，任务已安全暂停';
              }
            }
            await transaction.insert(
              entry.key,
              row,
              conflictAlgorithm: ConflictAlgorithm.replace,
            );
          }
        }
      });
      return _transferResult(globalRows, libraryRows);
    } finally {
      await backup?.close();
    }
  }

  Future<List<Map<String, Object?>>> _exportableGlobalRows(String table) async {
    if (table != 'local_preferences') return database.query(table);
    return database.query(
      table,
      where: "preference_key NOT LIKE 'legacy_app_state_imported:%'",
    );
  }

  static PortableAppDataTransferResult _transferResult(
    Map<String, List<Map<String, Object?>>> globalRows,
    Map<String, List<Map<String, Object?>>> libraryRows,
  ) {
    return PortableAppDataTransferResult(
      recentViews: globalRows['recent_views']?.length ?? 0,
      readProgress: globalRows['read_progress']?.length ?? 0,
      preferences: globalRows['local_preferences']?.length ?? 0,
      comicDetails: libraryRows['comic_details']?.length ?? 0,
      favorites: libraryRows['favorites_cache']?.length ?? 0,
      downloadTasks: libraryRows['download_tasks']?.length ?? 0,
      searchEntries: libraryRows['search_index']?.length ?? 0,
      novelRows: _novelTables.fold(
        0,
        (sum, table) => sum + (libraryRows[table]?.length ?? 0),
      ),
    );
  }

  static Future<void> _createPortableMetadataSchema(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS portable_backup_metadata(
        format TEXT PRIMARY KEY,
        format_version INTEGER NOT NULL,
        exported_at TEXT NOT NULL DEFAULT ''
      )
    ''');
  }

  static Future<void> _verifySQLiteHeader(File source) async {
    final handle = await source.open();
    try {
      final header = await handle.read(16);
      const expected = <int>[
        0x53,
        0x51,
        0x4c,
        0x69,
        0x74,
        0x65,
        0x20,
        0x66,
        0x6f,
        0x72,
        0x6d,
        0x61,
        0x74,
        0x20,
        0x33,
        0x00,
      ];
      if (header.length != expected.length ||
          !List<int>.generate(
            expected.length,
            (index) => header[index] ^ expected[index],
          ).every((value) => value == 0)) {
        throw const FormatException('应用数据备份不是有效的 SQLite 文件');
      }
    } finally {
      await handle.close();
    }
  }

  static Future<void> _deleteSqliteFamily(File databaseFile) async {
    for (final path in [
      databaseFile.path,
      '${databaseFile.path}-wal',
      '${databaseFile.path}-shm',
    ]) {
      final file = File(path);
      if (await file.exists()) await file.delete();
    }
  }

  static Future<void> _deleteSqliteCompanions(File databaseFile) async {
    for (final path in [
      '${databaseFile.path}-wal',
      '${databaseFile.path}-shm',
    ]) {
      final file = File(path);
      if (await file.exists()) await file.delete();
    }
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
