import 'dart:io';

import 'package:copymanga_reader/models/chapter.dart';
import 'package:copymanga_reader/models/comic.dart';
import 'package:copymanga_reader/services/chinese_search_normalizer.dart';
import 'package:copymanga_reader/services/library_database.dart';
import 'package:copymanga_reader/services/local_app_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

ChineseSearchNormalizer _testNormalizer() {
  return ChineseSearchNormalizer(
    traditionalToSimplified: {
      '領'.runes.single: '领',
      '員'.runes.single: '员',
      '東'.runes.single: '东',
      '屍'.runes.single: '尸',
    },
    simplifiedToTraditional: {
      '领'.runes.single: '領',
      '员'.runes.single: '員',
      '东'.runes.single: '東',
      '尸'.runes.single: '屍',
    },
  );
}

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory temporary;
  late LibraryDatabase library;
  late LocalAppDatabase local;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('comic-library-test-');
    local = LocalAppDatabase(
      factory: databaseFactoryFfi,
      supportDirectoryProvider: () async =>
          Directory('${temporary.path}/app-support'),
    );
    library = LibraryDatabase(
      normalizer: _testNormalizer(),
      localDatabase: local,
    );
    await library.open(temporary);
  });

  tearDown(() async {
    await library.close();
    await local.close();
    await temporary.delete(recursive: true);
  });

  test('漫画索引只保存核心数据，移动端状态保存在独立 SQLite', () async {
    const comic = Comic(
      uuid: 'comic-1',
      pathWord: 'comic-one',
      title: '测试漫画',
      authors: '测试作者',
      coverUrl: 'https://example.invalid/cover.jpg',
      brief: '详情缓存',
      status: '连载中',
    );
    await library.cacheComic(comic);
    await library.cacheChapters(comic, 'default', '默认', const [
      Chapter(
        uuid: 'chapter-1',
        comicUuid: 'comic-1',
        groupPathWord: 'default',
        groupName: '默认',
        title: '第1话',
        order: 1,
        pageCount: 12,
      ),
    ]);

    final comics = await library.loadComics();
    final chapters = await library.loadChapters('comic-1');
    final tables = await library.database.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table'",
    );

    expect(comics.single.title, '测试漫画');
    expect(comics.single.source, ComicSource.copyManga);
    expect(comics.single.libraryOrder, 1);
    expect(comics.single.titleSortKey, 'comic-one');
    expect(comics.single.brief, '详情缓存');
    expect(chapters.single.title, '第1话');
    expect(
      tables.map((row) => row['name']),
      isNot(contains('app_search_index')),
    );
    expect(
      tables.map((row) => row['name']),
      isNot(contains('app_download_tasks')),
    );
    final localTables = await local.database.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table'",
    );
    expect(localTables.map((row) => row['name']), contains('search_index'));
    expect(localTables.map((row) => row['name']), contains('download_tasks'));
    expect(localTables.map((row) => row['name']), contains('recent_views'));
  });

  test('拒绝把没有 UUID 的在线搜索结果写进漫画索引', () async {
    await expectLater(
      library.cacheComic(
        const Comic(
          uuid: '',
          pathWord: 'search-only-result',
          title: '搜索结果',
          authors: '测试作者',
        ),
      ),
      throwsArgumentError,
    );
    expect(await library.loadComics(), isEmpty);
  });

  test('简体和繁体关键词都能匹配原字形漫画名及作者', () async {
    await library.cacheComic(
      const Comic(
        uuid: 'comic-traditional',
        pathWord: 'aria',
        title: '水星領航員',
        authors: '天野こずえ',
      ),
    );
    await library.cacheComic(
      const Comic(
        uuid: 'comic-simplified',
        pathWord: 'tokyo-ghoul',
        title: '东京食尸鬼',
        authors: '石田翠',
      ),
    );

    final simplifiedQuery = await library.loadComics(query: '水星领航员');
    final traditionalQuery = await library.loadComics(query: '東京食屍鬼');

    expect(simplifiedQuery.map((comic) => comic.uuid), ['comic-traditional']);
    expect(traditionalQuery.map((comic) => comic.uuid), ['comic-simplified']);
  });

  test('默认库与外置工作索引可来回切换且不改外部索引', () async {
    await library.close();
    final externalRoot = Directory('${temporary.path}/external/漫画');
    await externalRoot.create(recursive: true);
    final externalIndex = File('${externalRoot.path}/拷贝漫画总索引.db');
    const originalBytes = <int>[9, 8, 7, 6, 5];
    await externalIndex.writeAsBytes(originalBytes);
    final localWorkingIndex = File(
      '${temporary.path}/app-support/external-library/拷贝漫画总索引.db',
    );

    await library.open(externalRoot, databaseFile: localWorkingIndex);
    await library.cacheComic(
      const Comic(
        uuid: 'external-comic',
        pathWord: 'external-comic',
        title: '外置漫画',
        authors: '测试作者',
      ),
    );

    expect(library.root?.path, externalRoot.path);
    expect(library.databasePath, localWorkingIndex.path);
    expect(await localWorkingIndex.exists(), isTrue);
    expect(await externalIndex.readAsBytes(), originalBytes);

    await library.close();
    await library.open(temporary);
    expect(library.databasePath, '${temporary.path}/拷贝漫画总索引.db');
    expect(await library.loadComic('external-comic'), isNull);

    await library.close();
    await library.open(externalRoot, databaseFile: localWorkingIndex);
    expect((await library.loadComic('external-comic'))?.title, '外置漫画');
    expect(await externalIndex.readAsBytes(), originalBytes);
  });

  test('空漫画库可重复打开且不会产生空搜索索引', () async {
    expect(await library.loadComics(), isEmpty);
    await library.close();

    await library.open(temporary);

    expect(await library.loadComics(), isEmpty);
    final searchRows = await local.database.query(
      'search_index',
      where: 'library_key = ?',
      whereArgs: [library.libraryKey],
    );
    expect(searchRows, isEmpty);
  });

  test('旧库中的空漫画标识不会导致启动迁移失败', () async {
    await library.database.insert('comics', {
      'comic_uuid': '',
      'path_word': 'legacy-empty-uuid',
      'title': '旧库异常记录',
      'authors': '测试作者',
    });
    final previousKey = library.libraryKey;
    await local.database.delete(
      'search_index',
      where: 'library_key = ?',
      whereArgs: [previousKey],
    );
    await library.close();
    library = LibraryDatabase(
      normalizer: _testNormalizer(),
      localDatabase: local,
    );

    await library.open(temporary);

    final invalidSearchRows = await local.database.query(
      'search_index',
      where: 'library_key = ? AND comic_uuid = ?',
      whereArgs: [library.libraryKey, ''],
    );
    expect(invalidSearchRows, isEmpty);
  });

  test('仅打开和查询既有漫画库不会改变索引数据库字节', () async {
    await library.cacheComic(
      const Comic(
        uuid: 'immutable-open',
        pathWord: 'immutable-open',
        title: '只读打开校验',
        authors: '测试作者',
      ),
    );
    final index = File(library.databasePath);
    await library.close();
    final before = await index.readAsBytes();
    library = LibraryDatabase(
      normalizer: _testNormalizer(),
      localDatabase: local,
    );

    await library.open(temporary);
    expect((await library.loadComics()).single.title, '只读打开校验');
    await library.close();

    expect(await index.readAsBytes(), before);
  });

  test('旧版应用设置只读导入本机库且不改漫画索引', () async {
    await library.database.execute('''
      CREATE TABLE app_settings(
        setting_key TEXT PRIMARY KEY,
        setting_value TEXT NOT NULL DEFAULT ''
      )
    ''');
    await library.database.insert('app_settings', {
      'setting_key': 'legacy_api_domain',
      'setting_value': 'legacy.example',
    });
    final marker = 'legacy_app_state_imported:${library.libraryKey}';
    await local.database.delete(
      'local_preferences',
      where: 'preference_key = ?',
      whereArgs: [marker],
    );
    final index = File(library.databasePath);
    await library.close();
    final before = await index.readAsBytes();
    library = LibraryDatabase(
      normalizer: _testNormalizer(),
      localDatabase: local,
    );

    await library.open(temporary);
    expect(await local.preference('legacy_api_domain'), 'legacy.example');
    await library.close();

    expect(await index.readAsBytes(), before);
  });
}
