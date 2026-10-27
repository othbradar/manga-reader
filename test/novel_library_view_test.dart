import 'dart:io';

import 'package:copymanga_reader/controllers/library_controller.dart';
import 'package:copymanga_reader/controllers/novel_controller.dart';
import 'package:copymanga_reader/models/library_view.dart';
import 'package:copymanga_reader/models/novel.dart';
import 'package:copymanga_reader/pages/novel_pages.dart';
import 'package:copymanga_reader/services/chinese_search_normalizer.dart';
import 'package:copymanga_reader/services/copy_api_transport.dart';
import 'package:copymanga_reader/services/copy_client.dart';
import 'package:copymanga_reader/services/copy_novel_client.dart';
import 'package:copymanga_reader/services/library_database.dart';
import 'package:copymanga_reader/services/library_locator.dart';
import 'package:copymanga_reader/services/local_app_database.dart';
import 'package:copymanga_reader/services/novel_store.dart';
import 'package:copymanga_reader/widgets/library_view_options.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  late Directory temp;
  late LocalAppDatabase local;
  late LibraryDatabase database;
  late NovelStore store;
  late NovelController novels;
  late LibraryController library;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('novel-view-test-');
    local = LocalAppDatabase(
      factory: databaseFactoryFfi,
      supportDirectoryProvider: () async => Directory('${temp.path}/state'),
    );
    final normalizer = ChineseSearchNormalizer();
    await normalizer.loadAssets();
    database = LibraryDatabase(localDatabase: local, normalizer: normalizer);
    await database.open(Directory('${temp.path}/漫画'));
    store = NovelStore(database);
    novels = NovelController(
      store: store,
      client: CopyNovelClient(CopyApiTransport(), normalizer),
    );
    library = LibraryController(
      database: database,
      locator: LibraryLocator(),
      client: CopyClient(),
      localDatabase: local,
    )..ready = true;
    await novels.initialize();
    for (final book in const [
      Novel(
        uuid: 'z',
        pathWord: 'z',
        title: '最後之書',
        authors: '共同作者',
        source: 'copy_manga',
      ),
      Novel(
        uuid: 'a',
        pathWord: 'a',
        title: '愛的故事',
        authors: '共同作者',
        source: 'both',
      ),
      Novel(
        uuid: 'h',
        pathWord: 'local-h',
        title: '黑之魔王',
        authors: '其他作者',
        source: 'dmzj',
      ),
    ]) {
      await store.saveBook(book);
    }
    await novels.refresh();
  });

  tearDown(() async {
    await novels.pause();
    novels.dispose();
    library.dispose();
    await database.close();
    await local.close();
    await temp.delete(recursive: true);
  });

  test('来源四选项、简繁搜索和首字母排序可组合，切回原顺序不改索引', () async {
    final before = await database.database.query('novels');
    expect(novels.books.map((b) => b.uuid), ['z', 'a', 'h']);
    await novels.setSortMode(ComicSortMode.titleInitial);
    expect(novels.books.map((b) => b.uuid), ['a', 'h', 'z']);
    for (final (source, expected) in [
      (ComicSourceFilter.dmzj, 'h'),
      (ComicSourceFilter.copyManga, 'z'),
      (ComicSourceFilter.both, 'a'),
    ]) {
      await novels.setSourceFilter(source);
      expect(novels.books.map((b) => b.uuid), [expected]);
    }
    await novels.refresh(search: '爱的');
    expect(novels.books.map((b) => b.uuid), ['a']);
    await novels.setSourceFilter(ComicSourceFilter.dmzj);
    expect(novels.books, isEmpty);
    await novels.setSourceFilter(ComicSourceFilter.all);
    await novels.refresh(search: '共同作者');
    expect(novels.books.map((b) => b.uuid), ['a', 'z']);
    await novels.refresh(search: '');
    await novels.setSortMode(ComicSortMode.original);
    expect(novels.books.map((b) => b.uuid), ['z', 'a', 'h']);
    expect(await database.database.query('novels'), before);
  });

  test('小说设置单独记忆、重启恢复并能随应用数据迁移，不覆盖漫画设置', () async {
    await local.setPreference('library_source_filter', 'copyManga');
    await local.setPreference('library_sort_mode', 'original');
    await novels.setSourceFilter(ComicSourceFilter.dmzj);
    await novels.setSortMode(ComicSortMode.titleInitial);
    final restored = NovelController(store: store, client: novels.client);
    try {
      await restored.initialize();
      expect(restored.sourceFilter, ComicSourceFilter.dmzj);
      expect(restored.sortMode, ComicSortMode.titleInitial);
      expect(restored.books.map((b) => b.uuid), ['h']);
    } finally {
      restored.dispose();
    }
    expect(await local.preference('library_source_filter'), 'copyManga');
    expect(await local.preference('library_sort_mode'), 'original');
    final backup = File('${temp.path}/portable.db');
    await local.exportPortableBackup(backup, libraryKey: store.key);
    await local.setPreference('novel_library_source_filter', 'all');
    await local.setPreference('novel_library_sort_mode', 'original');
    await local.importPortableBackup(backup, libraryKey: store.key);
    await novels.initialize();
    expect(novels.sourceFilter, ComicSourceFilter.dmzj);
    expect(novels.sortMode, ComicSortMode.titleInitial);
  });

  test('旧小说表只补排序字段，保留来源顺序和其他数据，重复打开幂等', () async {
    await database.database.execute(
      'ALTER TABLE novels DROP COLUMN title_sort_key',
    );
    final beforeBooks = await database.database.query('novels');
    final beforeComics = await database.database.query('comics');
    final beforeVolumes = await database.database.query('novel_volumes');
    await store.ensureSchema();
    final migrated = await database.database.query('novels');
    expect(migrated.map((row) => row['title_sort_key']), [
      'zuihouzhishu',
      'aidegushi',
      'heizhimowang',
    ]);
    expect(
      migrated.map((row) => Map.of(row)..remove('title_sort_key')),
      beforeBooks,
    );
    await store.ensureSchema();
    expect(await database.database.query('novels'), migrated);
    expect(await database.database.query('comics'), beforeComics);
    expect(await database.database.query('novel_volumes'), beforeVolumes);
    await store.saveBook(
      const Novel(uuid: 'h', pathWord: 'local-h', title: '黑之魔王', authors: '作者'),
    );
    expect((await store.book('h'))!.source, 'dmzj');
    expect((await store.book('h'))!.titleSortKey, 'heizhimowang');
  });

  test('非法旧设置回退到全部和原先顺序，排序同键时按原顺序稳定排列', () async {
    await local.setPreference('novel_library_source_filter', 'invalid');
    await local.setPreference('novel_library_sort_mode', 'invalid');
    await novels.initialize();
    expect(novels.sourceFilter, ComicSourceFilter.all);
    expect(novels.sortMode, ComicSortMode.original);
    await database.database.update('novels', {'title_sort_key': 'same'});
    await novels.refresh();
    await novels.setSortMode(ComicSortMode.titleInitial);
    expect(novels.books.map((b) => b.uuid), ['z', 'a', 'h']);
  });

  testWidgets('小说筛选入口和漫画共用面板，手机尺寸选择后生效并显示空结果', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: library),
          ChangeNotifierProvider.value(value: novels),
        ],
        child: const MaterialApp(home: Scaffold(body: NovelLibraryPage())),
      ),
    );
    expect(find.byTooltip('筛选与排序'), findsOneWidget);
    await tester.tap(find.byTooltip('筛选与排序'));
    await tester.pumpAndSettle();
    expect(find.byType(LibraryViewOptions), findsOneWidget);
    expect(find.text('小说来源'), findsOneWidget);
    expect(find.text('拷贝漫画独有'), findsOneWidget);
    await tester.tap(find.text('动漫之家独有'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pumpAndSettle();
    expect(novels.books.map((b) => b.uuid), ['h']);
    await tester.tap(find.text('首字母'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pumpAndSettle();
    expect(novels.sortMode, ComicSortMode.titleInitial);
    Navigator.of(tester.element(find.byType(LibraryViewOptions))).pop();
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '不存在');
    await tester.pump(const Duration(milliseconds: 250));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pumpAndSettle();
    expect(find.text('没有匹配的小说'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
