import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../core/file_names.dart';
import '../models/chapter.dart';
import '../models/comic.dart';
import '../models/download_task.dart';
import 'chinese_search_normalizer.dart';
import 'local_app_database.dart';

class LibraryDatabase {
  LibraryDatabase({this.normalizer, required this.localDatabase});

  final ChineseSearchNormalizer? normalizer;
  final LocalAppDatabase localDatabase;
  Database? _database;
  Directory? _root;
  File? _databaseFile;
  String _libraryKey = '';

  Directory? get root => _root;
  Database get database {
    final value = _database;
    if (value == null) throw StateError('漫画库尚未初始化');
    return value;
  }

  String get databasePath =>
      _databaseFile?.path ?? p.join(_root?.path ?? '', libraryDatabaseName);

  String get libraryKey {
    if (_libraryKey.isEmpty) throw StateError('漫画库尚未初始化');
    return _libraryKey;
  }

  Future<void> open(Directory root, {File? databaseFile}) async {
    await close();
    await localDatabase.open();
    if (!await root.exists()) {
      await root.create(recursive: true);
    }
    _root = root;
    _databaseFile =
        databaseFile ?? File(p.join(root.path, libraryDatabaseName));
    await _databaseFile!.parent.create(recursive: true);
    final existing =
        await _databaseFile!.exists() && await _databaseFile!.length() > 0;
    _libraryKey = p.canonicalize(_databaseFile!.absolute.path);
    _database = await openDatabase(
      _databaseFile!.path,
      singleInstance: false,
      onConfigure: (db) async {
        await db.execute('PRAGMA foreign_keys = ON');
        await db.rawQuery('PRAGMA busy_timeout = 5000');
      },
    );
    await database.execute('ATTACH DATABASE ? AS app_local', [
      localDatabase.databasePath,
    ]);
    if (existing) {
      await _validateCoreSchema();
    } else {
      await _createSchema();
    }
    await _importLegacyAppState();
    await _refreshSearchIndex();
    await _recoverInterruptedTasks();
    final count =
        Sqflite.firstIntValue(
          await database.rawQuery('SELECT COUNT(*) FROM comics'),
        ) ??
        0;
    if (count == 0) await rebuildFromFolders();
  }

  Future<void> close() async {
    final current = _database;
    if (current != null) {
      await current.close();
    }
    _database = null;
    _root = null;
    _databaseFile = null;
    _libraryKey = '';
  }

  Future<void> _createSchema() async {
    final statements = <String>[
      '''
      CREATE TABLE IF NOT EXISTS comics(
        comic_uuid TEXT PRIMARY KEY,
        path_word TEXT UNIQUE,
        title TEXT NOT NULL DEFAULT '',
        authors TEXT NOT NULL DEFAULT '',
        comic_relative_dir TEXT NOT NULL DEFAULT '',
        cover_url TEXT NOT NULL DEFAULT '',
        cover_relative_path TEXT NOT NULL DEFAULT '',
        metadata_blob TEXT NOT NULL DEFAULT '',
        source_kind TEXT NOT NULL DEFAULT 'copy_manga',
        library_order INTEGER NOT NULL DEFAULT 0,
        title_sort_key TEXT NOT NULL DEFAULT '',
        updated_at TEXT NOT NULL DEFAULT ''
      )
      ''',
      '''
      CREATE TABLE IF NOT EXISTS chapter_groups(
        comic_uuid TEXT NOT NULL,
        group_path_word TEXT NOT NULL,
        group_name TEXT NOT NULL DEFAULT '',
        PRIMARY KEY(comic_uuid, group_path_word)
      )
      ''',
      '''
      CREATE TABLE IF NOT EXISTS chapters(
        chapter_uuid TEXT PRIMARY KEY,
        comic_uuid TEXT NOT NULL,
        group_path_word TEXT NOT NULL DEFAULT 'default',
        group_name TEXT NOT NULL DEFAULT '',
        chapter_title TEXT NOT NULL DEFAULT '',
        chapter_order REAL NOT NULL DEFAULT 0,
        page_count INTEGER NOT NULL DEFAULT 0,
        archive_relative_path TEXT NOT NULL DEFAULT '',
        is_pdf_exported INTEGER NOT NULL DEFAULT 0,
        is_cbz_exported INTEGER NOT NULL DEFAULT 0,
        metadata_blob TEXT NOT NULL DEFAULT '',
        updated_at TEXT NOT NULL DEFAULT ''
      )
      ''',
      '''
      CREATE TABLE IF NOT EXISTS download_queue(
        chapter_uuid TEXT PRIMARY KEY,
        comic_uuid TEXT NOT NULL,
        comic_path_word TEXT NOT NULL,
        queued_at TEXT NOT NULL DEFAULT ''
      )
      ''',
      'CREATE INDEX IF NOT EXISTS idx_chapters_comic ON chapters(comic_uuid)',
      '''
      CREATE INDEX IF NOT EXISTS idx_chapters_group
      ON chapters(comic_uuid, group_path_word, chapter_order)
      ''',
    ];
    final batch = database.batch();
    for (final statement in statements) {
      batch.execute(statement);
    }
    await batch.commit(noResult: true);
  }

  Future<void> _validateCoreSchema() async {
    const requiredTables = {
      'comics',
      'chapter_groups',
      'chapters',
      'download_queue',
    };
    final tableRows = await database.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table'",
    );
    final tables = tableRows
        .map((row) => row['name']?.toString() ?? '')
        .toSet();
    final missingTables = requiredTables.difference(tables);
    if (missingTables.isNotEmpty) {
      throw FormatException('漫画索引缺少必要数据表：${missingTables.join('、')}');
    }
    const requiredComicColumns = {
      'comic_uuid',
      'path_word',
      'title',
      'authors',
      'comic_relative_dir',
      'cover_url',
      'cover_relative_path',
      'source_kind',
      'library_order',
      'title_sort_key',
    };
    final columnRows = await database.rawQuery('PRAGMA table_info(comics)');
    final columns = columnRows
        .map((row) => row['name']?.toString() ?? '')
        .toSet();
    final missingColumns = requiredComicColumns.difference(columns);
    if (missingColumns.isNotEmpty) {
      throw FormatException('漫画索引缺少必要字段：${missingColumns.join('、')}');
    }
  }

  Future<void> _importLegacyAppState() async {
    final marker = 'legacy_app_state_imported:$libraryKey';
    if (await localDatabase.preference(marker) == 'true') return;
    final tableRows = await database.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'app_%'",
    );
    final tables = tableRows
        .map((row) => row['name']?.toString() ?? '')
        .toSet();

    if (tables.contains('app_comic_details')) {
      final rows = await database.query('app_comic_details');
      final batch = localDatabase.database.batch();
      for (final row in rows) {
        final comicUuid = row['comic_uuid']?.toString() ?? '';
        if (comicUuid.isEmpty) continue;
        batch.insert('comic_details', {
          'library_key': libraryKey,
          'comic_uuid': comicUuid,
          'alias': row['alias']?.toString() ?? '',
          'brief': row['brief']?.toString() ?? '',
          'status': row['status']?.toString() ?? '',
          'region': row['region']?.toString() ?? '',
          'themes': row['themes']?.toString() ?? '',
          'last_chapter': row['last_chapter']?.toString() ?? '',
          'popular': (row['popular'] as num?)?.toInt() ?? 0,
          'cached_at': row['cached_at']?.toString() ?? '',
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
      }
      await batch.commit(noResult: true);
    }

    if (tables.contains('app_favorites_cache')) {
      final existingFavorites =
          Sqflite.firstIntValue(
            await localDatabase.database.rawQuery(
              'SELECT COUNT(*) FROM favorites_cache WHERE library_key = ?',
              [libraryKey],
            ),
          ) ??
          0;
      if (existingFavorites == 0) {
        final hasDetails = tables.contains('app_comic_details');
        final rows = await database.rawQuery('''
          SELECT
            c.*,
            f.comic_uuid AS favorite_comic_uuid,
            f.position AS favorite_position,
            f.last_chapter AS favorite_last_chapter,
            ${hasDetails ? "COALESCE(d.alias, '')" : "''"} AS alias,
            ${hasDetails ? "COALESCE(d.brief, '')" : "''"} AS brief,
            ${hasDetails ? "COALESCE(d.status, '')" : "''"} AS status
          FROM app_favorites_cache f
          LEFT JOIN comics c ON c.comic_uuid = f.comic_uuid
          ${hasDetails ? 'LEFT JOIN app_comic_details d ON d.comic_uuid = f.comic_uuid' : ''}
          ORDER BY f.position
          ''');
        final favorites = rows
            .map((row) {
              return Comic.fromDatabase({
                ...row,
                'comic_uuid':
                    row['comic_uuid']?.toString() ??
                    row['favorite_comic_uuid']?.toString() ??
                    '',
                'last_chapter': row['favorite_last_chapter'],
                'is_favorite': 1,
              });
            })
            .where((comic) => comic.uuid.isNotEmpty)
            .toList(growable: false);
        await localDatabase.replaceFavorites(libraryKey, favorites);
      }
    }

    if (tables.contains('app_download_tasks')) {
      final existingTasks =
          Sqflite.firstIntValue(
            await localDatabase.database.rawQuery(
              'SELECT COUNT(*) FROM download_tasks WHERE library_key = ?',
              [libraryKey],
            ),
          ) ??
          0;
      if (existingTasks == 0) {
        final rows = await database.query('app_download_tasks');
        final batch = localDatabase.database.batch();
        for (final row in rows) {
          final chapterUuid = row['chapter_uuid']?.toString() ?? '';
          if (chapterUuid.isEmpty) continue;
          batch.insert('download_tasks', {
            'library_key': libraryKey,
            'chapter_uuid': chapterUuid,
            'comic_uuid': row['comic_uuid']?.toString() ?? '',
            'comic_path_word': row['comic_path_word']?.toString() ?? '',
            'comic_title': row['comic_title']?.toString() ?? '',
            'authors': row['authors']?.toString() ?? '',
            'group_path_word': row['group_path_word']?.toString() ?? 'default',
            'group_name': row['group_name']?.toString() ?? '',
            'chapter_title': row['chapter_title']?.toString() ?? '',
            'chapter_order': (row['chapter_order'] as num?)?.toDouble() ?? 0,
            'state': row['state']?.toString() ?? DownloadState.paused.name,
            'progress': (row['progress'] as num?)?.toDouble() ?? 0,
            'error_message': row['error_message']?.toString() ?? '',
            'queued_at': row['queued_at']?.toString() ?? '',
            'updated_at': row['updated_at']?.toString() ?? '',
          }, conflictAlgorithm: ConflictAlgorithm.ignore);
        }
        await batch.commit(noResult: true);
      }
    }

    if (tables.contains('app_read_progress')) {
      final rows = await database.query('app_read_progress');
      final batch = localDatabase.database.batch();
      for (final row in rows) {
        final chapterUuid = row['chapter_uuid']?.toString() ?? '';
        if (chapterUuid.isEmpty) continue;
        batch.insert('read_progress', {
          'chapter_uuid': chapterUuid,
          'comic_uuid': row['comic_uuid']?.toString() ?? '',
          'page_index': (row['page_index'] as num?)?.toInt() ?? 0,
          'page_count': (row['page_count'] as num?)?.toInt() ?? 0,
          'updated_at': row['updated_at']?.toString() ?? '',
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
      }
      await batch.commit(noResult: true);
    }

    if (tables.contains('app_settings')) {
      final rows = await database.query('app_settings');
      for (final row in rows) {
        final key = row['setting_key']?.toString() ?? '';
        if (key.isEmpty || await localDatabase.preference(key) != '') continue;
        await localDatabase.setPreference(
          key,
          row['setting_value']?.toString() ?? '',
        );
      }
    }
    await localDatabase.setPreference(marker, 'true');
  }

  Future<void> _refreshSearchIndex() async {
    final converter = normalizer;
    if (converter == null || !converter.isLoaded) return;
    final rows = await database.query(
      'comics',
      columns: ['comic_uuid', 'title', 'authors'],
    );
    final now = DateTime.now().toIso8601String();
    final searchRows = <Map<String, Object?>>[];
    for (final row in rows) {
      final searchValues = _searchIndexValues(
        row['comic_uuid']?.toString() ?? '',
        row['title']?.toString() ?? '',
        row['authors']?.toString() ?? '',
        indexedAt: now,
      );
      if (searchValues.isEmpty) continue;
      searchRows.add(searchValues);
    }
    await localDatabase.replaceSearchIndex(libraryKey, searchRows);
  }

  Future<void> _recoverInterruptedTasks() async {
    await localDatabase.recoverInterruptedTasks(libraryKey);
  }

  Future<List<Comic>> loadComics({String query = ''}) async {
    final keyword = query.trim();
    final normalizedKeyword = normalizer?.normalize(keyword) ?? keyword;
    final rows = await database.rawQuery(
      '''
      SELECT
        c.*,
        COALESCE(d.alias, '') AS alias,
        COALESCE(d.brief, '') AS brief,
        COALESCE(d.status, '') AS status,
        COALESCE(d.last_chapter, '') AS last_chapter,
        CASE WHEN f.comic_uuid IS NULL THEN 0 ELSE 1 END AS is_favorite,
        COALESCE((
          SELECT COUNT(*) FROM chapters ch
          WHERE ch.comic_uuid = c.comic_uuid
        ), 0) AS total_chapters,
        COALESCE((
          SELECT COUNT(*) FROM chapters ch
          WHERE ch.comic_uuid = c.comic_uuid
            AND ch.archive_relative_path <> ''
        ), 0) AS downloaded_chapters
      FROM comics c
      LEFT JOIN app_local.comic_details d
        ON d.library_key = ? AND d.comic_uuid = c.comic_uuid
      LEFT JOIN app_local.$_favoritesTable f
        ON f.library_key = ? AND f.comic_uuid = c.comic_uuid $_favoritesAccountFilter
      LEFT JOIN app_local.search_index s
        ON s.library_key = ? AND s.comic_uuid = c.comic_uuid
      WHERE (
        ? = ''
        OR c.title LIKE ?
        OR c.authors LIKE ?
        OR s.title_normalized LIKE ?
        OR s.authors_normalized LIKE ?
      )
      ORDER BY c.library_order, c.rowid
      ''',
      [
        libraryKey,
        libraryKey,
        if (favoritesAccountKey != null) favoritesAccountKey,
        libraryKey,
        normalizedKeyword,
        '%$keyword%',
        '%$keyword%',
        '%$normalizedKeyword%',
        '%$normalizedKeyword%',
      ],
    );
    return rows.map(Comic.fromDatabase).toList(growable: false);
  }

  // null reads legacy, unowned caches only for migrations/compatibility.
  // The application always sets an explicit account key (empty = signed out).
  String? favoritesAccountKey;
  String get _favoritesTable => favoritesAccountKey == null
      ? 'favorites_cache'
      : 'account_comic_favorites';
  String get _favoritesAccountFilter =>
      favoritesAccountKey == null ? '' : ' AND f.account_key = ?';

  Future<List<Comic>> loadFavorites({String? accountKey}) async {
    final key = accountKey ?? favoritesAccountKey;
    final table = key == null ? 'favorites_cache' : 'account_comic_favorites';
    final rows = await database.rawQuery(
      '''
      SELECT
        COALESCE(c.comic_uuid, f.comic_uuid) AS comic_uuid,
        COALESCE(NULLIF(c.path_word, ''), f.path_word, '') AS path_word,
        COALESCE(NULLIF(c.title, ''), f.title, '') AS title,
        COALESCE(NULLIF(c.authors, ''), f.authors, '') AS authors,
        COALESCE(c.comic_relative_dir, '') AS comic_relative_dir,
        COALESCE(NULLIF(c.cover_url, ''), f.cover_url, '') AS cover_url,
        COALESCE(c.cover_relative_path, '') AS cover_relative_path,
        COALESCE(NULLIF(d.alias, ''), f.alias, '') AS alias,
        COALESCE(NULLIF(d.brief, ''), f.brief, '') AS brief,
        COALESCE(NULLIF(d.status, ''), f.status, '') AS status,
        COALESCE(NULLIF(f.last_chapter, ''), d.last_chapter, '') AS last_chapter,
        1 AS is_favorite,
        COALESCE(c.source_kind, f.source_kind, 'copy_manga') AS source_kind,
        COALESCE(c.library_order, f.library_order, 0) AS library_order,
        COALESCE(NULLIF(c.title_sort_key, ''), f.title_sort_key, '') AS title_sort_key,
        COALESCE((
          SELECT COUNT(*) FROM chapters ch
          WHERE ch.comic_uuid = f.comic_uuid
        ), 0) AS total_chapters,
        COALESCE((
          SELECT COUNT(*) FROM chapters ch
          WHERE ch.comic_uuid = f.comic_uuid
            AND ch.archive_relative_path <> ''
        ), 0) AS downloaded_chapters
      FROM app_local.$table f
      LEFT JOIN comics c ON c.comic_uuid = f.comic_uuid
      LEFT JOIN app_local.comic_details d
        ON d.library_key = f.library_key AND d.comic_uuid = f.comic_uuid
      WHERE f.library_key = ? ${key == null ? '' : 'AND f.account_key = ?'}
      ORDER BY f.position
      ''',
      [libraryKey, ?key],
    );
    return rows.map(Comic.fromDatabase).toList(growable: false);
  }

  Future<Comic?> loadComic(String comicUuid) async {
    final rows = await database.rawQuery(
      '''
      SELECT
        c.*,
        COALESCE(d.alias, '') AS alias,
        COALESCE(d.brief, '') AS brief,
        COALESCE(d.status, '') AS status,
        COALESCE(d.last_chapter, '') AS last_chapter,
        CASE WHEN f.comic_uuid IS NULL THEN 0 ELSE 1 END AS is_favorite,
        COALESCE((
          SELECT COUNT(*) FROM chapters ch
          WHERE ch.comic_uuid = c.comic_uuid
        ), 0) AS total_chapters,
        COALESCE((
          SELECT COUNT(*) FROM chapters ch
          WHERE ch.comic_uuid = c.comic_uuid
            AND ch.archive_relative_path <> ''
        ), 0) AS downloaded_chapters
      FROM comics c
      LEFT JOIN app_local.comic_details d
        ON d.library_key = ? AND d.comic_uuid = c.comic_uuid
      LEFT JOIN app_local.$_favoritesTable f
        ON f.library_key = ? AND f.comic_uuid = c.comic_uuid $_favoritesAccountFilter
      WHERE c.comic_uuid = ?
      LIMIT 1
      ''',
      [
        libraryKey,
        libraryKey,
        if (favoritesAccountKey != null) favoritesAccountKey,
        comicUuid,
      ],
    );
    return rows.isEmpty ? null : Comic.fromDatabase(rows.first);
  }

  Future<List<Chapter>> loadChapters(String comicUuid) async {
    final rows = await database.query(
      'chapters',
      where: 'comic_uuid = ?',
      whereArgs: [comicUuid],
      orderBy: 'group_name, chapter_order, chapter_title',
    );
    return rows.map(Chapter.fromDatabase).toList(growable: false);
  }

  Future<void> cacheComic(Comic comic, {Map<String, dynamic>? raw}) async {
    if (comic.uuid.trim().isEmpty) {
      throw ArgumentError.value(
        comic.uuid,
        'comic.uuid',
        '不能把没有 UUID 的搜索结果写入漫画索引',
      );
    }
    final now = DateTime.now().toIso8601String();
    final relativeDir = comic.comicRelativeDir.isNotEmpty
        ? comic.comicRelativeDir
        : comicDirectoryName(comic.title, comic.authors);
    final libraryOrder = comic.libraryOrder > 0
        ? comic.libraryOrder
        : await _nextLibraryOrder();
    await database.rawInsert(
      '''
      INSERT INTO comics(
        comic_uuid, path_word, title, authors, comic_relative_dir,
        cover_url, cover_relative_path, metadata_blob, source_kind,
        library_order, title_sort_key, updated_at
      ) VALUES(?, ?, ?, ?, ?, ?, ?, '', ?, ?, ?, ?)
      ON CONFLICT(comic_uuid) DO UPDATE SET
        path_word = excluded.path_word,
        title = excluded.title,
        authors = excluded.authors,
        comic_relative_dir = CASE
          WHEN comics.comic_relative_dir = '' THEN excluded.comic_relative_dir
          ELSE comics.comic_relative_dir
        END,
        cover_url = excluded.cover_url,
        updated_at = excluded.updated_at
      ''',
      [
        comic.uuid,
        comic.pathWord,
        comic.title,
        comic.authors,
        relativeDir,
        comic.coverUrl,
        comic.coverRelativePath,
        comic.source.databaseValue,
        libraryOrder,
        _titleSortKey(comic),
        now,
      ],
    );
    await _upsertSearchIndex(comic.uuid, comic.title, comic.authors);
    await cacheComicDetails(comic, raw: raw);
  }

  Future<void> cacheComicDetails(
    Comic comic, {
    Map<String, dynamic>? raw,
  }) async {
    await localDatabase.cacheComicDetails(
      libraryKey,
      comic,
      region: _display(raw?['region']),
      themes: _names(raw?['theme']),
      popular: (raw?['popular'] as num?)?.toInt() ?? 0,
    );
  }

  Future<void> replaceFavorites(
    List<Comic> favorites, {
    String? accountKey,
  }) async {
    await localDatabase.replaceFavorites(
      libraryKey,
      favorites,
      accountKey: accountKey ?? favoritesAccountKey,
    );
  }

  Future<void> cacheChapters(
    Comic comic,
    String groupPathWord,
    String groupName,
    List<Chapter> chapters,
  ) async {
    final now = DateTime.now().toIso8601String();
    final batch = database.batch();
    batch.insert('chapter_groups', {
      'comic_uuid': comic.uuid,
      'group_path_word': groupPathWord,
      'group_name': groupName,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    for (final chapter in chapters) {
      batch.rawInsert(
        '''
        INSERT INTO chapters(
          chapter_uuid, comic_uuid, group_path_word, group_name,
          chapter_title, chapter_order, page_count, archive_relative_path,
          metadata_blob, updated_at
        ) VALUES(?, ?, ?, ?, ?, ?, ?, '', '', ?)
        ON CONFLICT(chapter_uuid) DO UPDATE SET
          group_path_word = excluded.group_path_word,
          group_name = excluded.group_name,
          chapter_title = excluded.chapter_title,
          chapter_order = excluded.chapter_order,
          page_count = CASE
            WHEN excluded.page_count > 0 THEN excluded.page_count
            ELSE chapters.page_count
          END,
          updated_at = excluded.updated_at
        ''',
        [
          chapter.uuid,
          comic.uuid,
          chapter.groupPathWord,
          chapter.groupName,
          chapter.title,
          chapter.order,
          chapter.pageCount,
          now,
        ],
      );
    }
    await batch.commit(noResult: true);
  }

  Future<void> saveReadProgress(
    String comicUuid,
    String chapterUuid,
    int pageIndex,
    int pageCount,
  ) async {
    await localDatabase.saveReadProgress(
      comicUuid,
      chapterUuid,
      pageIndex,
      pageCount,
    );
  }

  Future<int> loadReadProgress(String chapterUuid) async {
    return localDatabase.loadReadProgress(chapterUuid);
  }

  Future<List<DownloadTask>> loadDownloadTasks() async {
    return localDatabase.loadDownloadTasks(libraryKey);
  }

  Future<void> saveDownloadTask(DownloadTask task) async {
    await localDatabase.saveDownloadTask(libraryKey, task);
  }

  Future<void> updateDownloadTask(DownloadTask task) async {
    await localDatabase.updateDownloadTask(libraryKey, task);
  }

  Future<void> markChapterDownloaded(
    DownloadTask task,
    String archiveRelativePath,
    int pageCount,
  ) async {
    await database.transaction((txn) async {
      await txn.update(
        'chapters',
        {
          'archive_relative_path': archiveRelativePath,
          'page_count': pageCount,
          'updated_at': DateTime.now().toIso8601String(),
        },
        where: 'chapter_uuid = ?',
        whereArgs: [task.chapterUuid],
      );
      await txn.delete(
        'download_queue',
        where: 'chapter_uuid = ?',
        whereArgs: [task.chapterUuid],
      );
    });
  }

  Future<void> clearCompletedTasks() async {
    await localDatabase.clearCompletedTasks(libraryKey);
  }

  Future<void> clearDownloadTasks() async {
    await localDatabase.clearDownloadTasks(libraryKey);
  }

  Future<void> setCoverRelativePath(
    String comicUuid,
    String relativePath,
  ) async {
    await database.update(
      'comics',
      {'cover_relative_path': relativePath},
      where: 'comic_uuid = ?',
      whereArgs: [comicUuid],
    );
  }

  Future<String> setting(String key) async {
    return localDatabase.preference(key);
  }

  Future<void> setSetting(String key, String value) async {
    await localDatabase.setPreference(key, value);
  }

  Future<void> rebuildFromFolders() async {
    final libraryRoot = _root;
    if (libraryRoot == null || !await libraryRoot.exists()) return;
    final batch = database.batch();
    final now = DateTime.now().toIso8601String();
    var nextLibraryOrder = await _nextLibraryOrder();
    await for (final entity in libraryRoot.list(followLinks: false)) {
      if (entity is! Directory || p.basename(entity.path).startsWith('.')) {
        continue;
      }
      final zipFiles = <File>[];
      File? cover;
      await for (final child in entity.list(followLinks: false)) {
        if (child is File && p.extension(child.path).toLowerCase() == '.zip') {
          zipFiles.add(child);
        } else if (child is File && isImageName(child.path)) {
          cover ??= child;
        }
      }
      if (zipFiles.isEmpty && cover == null) continue;
      final folder = p.basename(entity.path);
      final split = folder.lastIndexOf(' - ');
      final title = split > 0 ? folder.substring(0, split) : folder;
      final authors = split > 0 ? folder.substring(split + 3) : '未知作者';
      final stable = base64Url.encode(utf8.encode(folder)).replaceAll('=', '');
      final comicUuid = 'local-$stable';
      batch.insert('comics', {
        'comic_uuid': comicUuid,
        'path_word': 'local-$stable',
        'title': title,
        'authors': authors,
        'comic_relative_dir': folder,
        'cover_relative_path': cover == null
            ? ''
            : p.relative(cover.path, from: libraryRoot.path),
        'source_kind': ComicSource.dmzj.databaseValue,
        'library_order': nextLibraryOrder++,
        'title_sort_key': normalizer?.normalize(title) ?? title.toLowerCase(),
        'updated_at': now,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
      for (var index = 0; index < zipFiles.length; index++) {
        final zip = zipFiles[index];
        final archiveStem = p.basenameWithoutExtension(zip.path);
        final prefix = '$folder - ';
        final chapterTitle = archiveStem.startsWith(prefix)
            ? archiveStem.substring(prefix.length)
            : archiveStem;
        final chapterStable = base64Url
            .encode(utf8.encode('$folder/${p.basename(zip.path)}'))
            .replaceAll('=', '');
        batch.insert('chapters', {
          'chapter_uuid': 'local-$chapterStable',
          'comic_uuid': comicUuid,
          'group_path_word': 'local',
          'group_name': '本地章节',
          'chapter_title': chapterTitle,
          'chapter_order': index.toDouble(),
          'archive_relative_path': p.relative(zip.path, from: libraryRoot.path),
          'updated_at': now,
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
      }
    }
    await batch.commit(noResult: true);
    await _refreshSearchIndex();
  }

  Future<void> _upsertSearchIndex(
    String comicUuid,
    String title,
    String authors,
  ) async {
    final values = _searchIndexValues(comicUuid, title, authors);
    if (values.isEmpty) return;
    await localDatabase.upsertSearchIndex(libraryKey, values);
  }

  Future<int> _nextLibraryOrder() async {
    final maximum =
        Sqflite.firstIntValue(
          await database.rawQuery(
            'SELECT COALESCE(MAX(library_order), 0) FROM comics',
          ),
        ) ??
        0;
    return maximum + 1;
  }

  String _titleSortKey(Comic comic) {
    if (comic.titleSortKey.isNotEmpty) return comic.titleSortKey;
    if (comic.pathWord.isNotEmpty && !comic.pathWord.startsWith('local-')) {
      return comic.pathWord.toLowerCase();
    }
    return normalizer?.normalize(comic.title) ?? comic.title.toLowerCase();
  }

  Map<String, Object?> _searchIndexValues(
    String comicUuid,
    String title,
    String authors, {
    String? indexedAt,
  }) {
    final converter = normalizer;
    if (converter == null || !converter.isLoaded || comicUuid.isEmpty) {
      return const {};
    }
    return {
      'comic_uuid': comicUuid,
      'title_normalized': converter.normalize(title),
      'authors_normalized': converter.normalize(authors),
      'normalizer_version': ChineseSearchNormalizer.dictionaryVersion,
      'indexed_at': indexedAt ?? DateTime.now().toIso8601String(),
    };
  }

  static String _display(Object? value) {
    if (value is Map) return value['display']?.toString() ?? '';
    return value?.toString() ?? '';
  }

  static String _names(Object? value) {
    if (value is! List) return '';
    return value
        .map((item) => item is Map ? item['name']?.toString() ?? '' : '$item')
        .where((item) => item.isNotEmpty)
        .join('、');
  }
}
