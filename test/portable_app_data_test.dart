import 'dart:io';

import 'package:copymanga_reader/models/comic.dart';
import 'package:copymanga_reader/models/download_task.dart';
import 'package:copymanga_reader/models/recent_view.dart';
import 'package:copymanga_reader/services/local_app_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();

  late Directory temporary;
  late LocalAppDatabase source;
  late LocalAppDatabase destination;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp(
      'reader-portable-data-test-',
    );
    final sourceSupport = Directory(p.join(temporary.path, 'source'));
    final destinationSupport = Directory(p.join(temporary.path, 'destination'));
    source = LocalAppDatabase(
      factory: databaseFactoryFfi,
      supportDirectoryProvider: () async => sourceSupport,
    );
    destination = LocalAppDatabase(
      factory: databaseFactoryFfi,
      supportDirectoryProvider: () async => destinationSupport,
    );
    await source.open();
    await destination.open();
  });

  tearDown(() async {
    await source.close();
    await destination.close();
    await temporary.delete(recursive: true);
  });

  test('独立 SQLite 应用数据可跨设备导出并映射到当前漫画库', () async {
    const comic = Comic(
      uuid: 'comic-1',
      pathWord: 'comic-one',
      title: '异世界叔叔',
      authors: '殆ど死んでいる',
      comicRelativeDir: '异世界叔叔 - 殆ど死んでいる',
      coverUrl: 'https://example.invalid/cover.jpg',
      alias: '異世界おじさん',
      brief: '测试简介',
      status: '连载中',
      lastChapter: '第80话',
      source: ComicSource.both,
      libraryOrder: 12,
      titleSortKey: 'yishijieshushu',
    );
    final viewedAt = DateTime.utc(2026, 7, 31, 8, 30);
    await source.saveReadingState(
      RecentView(
        comic: comic,
        chapterUuid: 'chapter-79',
        chapterTitle: '第79话',
        pageIndex: 8,
        pageCount: 24,
        viewedAt: viewedAt,
      ),
    );
    await source.setPreference('appearance_theme_color', 'cream');
    await source.setPreference(
      'legacy_app_state_imported:/private/source.db',
      'true',
    );
    await source.cacheComicDetails(
      '/source/library.db',
      comic,
      region: '日本',
      themes: '喜剧',
      popular: 99,
    );
    await source.replaceFavorites('/source/library.db', [comic]);
    await source.saveDownloadTask(
      '/source/library.db',
      const DownloadTask(
        chapterUuid: 'chapter-80',
        comicUuid: 'comic-1',
        comicPathWord: 'comic-one',
        comicTitle: '异世界叔叔',
        authors: '殆ど死んでいる',
        groupPathWord: 'default',
        groupName: '默认',
        chapterTitle: '第80话',
        chapterOrder: 80,
        state: DownloadState.queued,
        progress: 0.25,
      ),
    );
    await source.replaceSearchIndex('/source/library.db', [
      {
        'comic_uuid': 'comic-1',
        'title_normalized': 'yishijieshushu',
        'authors_normalized': 'daidousiliao',
        'normalizer_version': 'test',
        'indexed_at': viewedAt.toIso8601String(),
      },
    ]);

    final backup = File(
      p.join(temporary.path, LocalAppDatabase.portableBackupFileName),
    );
    final exported = await source.exportPortableBackup(
      backup,
      libraryKey: '/source/library.db',
    );
    expect(await backup.exists(), isTrue);
    expect(exported.recentViews, 1);
    expect(exported.readProgress, 1);
    expect(exported.preferences, 1);
    expect(exported.comicDetails, 1);
    expect(exported.favorites, 1);
    expect(exported.downloadTasks, 1);
    expect(exported.searchEntries, 1);

    await source.setPreference('appearance_theme_color', 'darkGray');
    await source.exportPortableBackup(backup, libraryKey: '/source/library.db');

    final imported = await destination.importPortableBackup(
      backup,
      libraryKey: '/destination/library.db',
    );
    expect(imported.totalRows, exported.totalRows);
    expect(await destination.preference('appearance_theme_color'), 'darkGray');
    expect(
      await destination.preference(
        'legacy_app_state_imported:/private/source.db',
      ),
      isEmpty,
    );
    expect(await destination.loadReadProgress('chapter-79'), 8);
    expect((await destination.loadRecentViews()).single.viewedAt, viewedAt);

    for (final table in ['comic_details', 'favorites_cache', 'search_index']) {
      final rows = await destination.database.query(
        table,
        where: 'library_key = ?',
        whereArgs: ['/destination/library.db'],
      );
      expect(rows, hasLength(1), reason: table);
      expect(rows.single['library_key'], '/destination/library.db');
    }
    final tasks = await destination.loadDownloadTasks(
      '/destination/library.db',
    );
    expect(tasks, hasLength(1));
    expect(tasks.single.state, DownloadState.paused);
    expect(tasks.single.errorMessage, contains('安全暂停'));
    expect(
      await destination.database.query(
        'comic_details',
        where: 'library_key = ?',
        whereArgs: ['/source/library.db'],
      ),
      isEmpty,
    );
  });

  test('拒绝导入伪装成应用数据备份的非 SQLite 文件', () async {
    final invalid = File(p.join(temporary.path, 'invalid.db'));
    await invalid.writeAsString('not sqlite');

    expect(
      () => destination.importPortableBackup(
        invalid,
        libraryKey: '/destination/library.db',
      ),
      throwsA(isA<FormatException>()),
    );
  });
}
