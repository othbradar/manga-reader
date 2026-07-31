import 'dart:io';

import 'package:copymanga_reader/controllers/library_controller.dart';
import 'package:copymanga_reader/models/chapter.dart';
import 'package:copymanga_reader/models/comic.dart';
import 'package:copymanga_reader/models/library_view.dart';
import 'package:copymanga_reader/services/copy_client.dart';
import 'package:copymanga_reader/services/library_database.dart';
import 'package:copymanga_reader/services/library_locator.dart';
import 'package:copymanga_reader/services/local_app_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory temporary;
  late LibraryDatabase library;
  late LocalAppDatabase local;
  late LibraryController controller;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('library-view-test-');
    local = LocalAppDatabase(
      factory: databaseFactoryFfi,
      supportDirectoryProvider: () async =>
          Directory('${temporary.path}/support'),
    );
    library = LibraryDatabase(localDatabase: local);
    await local.open();
    await library.open(Directory('${temporary.path}/library'));
    controller = LibraryController(
      database: library,
      locator: LibraryLocator(),
      client: CopyClient(),
      localDatabase: local,
    );
    await library.cacheComic(
      const Comic(
        uuid: 'copy',
        pathWord: 'copy',
        title: '拷贝独有',
        authors: '作者',
        source: ComicSource.copyManga,
        libraryOrder: 1,
        titleSortKey: 'z',
      ),
    );
    await library.cacheComic(
      const Comic(
        uuid: 'both',
        pathWord: 'both',
        title: '两边都有',
        authors: '作者',
        source: ComicSource.both,
        libraryOrder: 2,
        titleSortKey: 'a',
      ),
    );
    await library.cacheComic(
      const Comic(
        uuid: 'dmzj',
        pathWord: 'local-dmzj',
        title: '动漫之家独有',
        authors: '作者',
        source: ComicSource.dmzj,
        libraryOrder: 3,
        titleSortKey: 'm',
      ),
    );
    await controller.refresh();
  });

  tearDown(() async {
    controller.dispose();
    await library.close();
    await local.close();
    await temporary.delete(recursive: true);
  });

  test('原先顺序、来源筛选和首字母排序可以组合', () async {
    expect(controller.comics.map((comic) => comic.uuid), [
      'copy',
      'both',
      'dmzj',
    ]);

    await controller.setSourceFilter(ComicSourceFilter.both);
    expect(controller.comics.map((comic) => comic.uuid), ['both']);

    await controller.setSourceFilter(ComicSourceFilter.all);
    await controller.setSortMode(ComicSortMode.titleInitial);
    expect(controller.comics.map((comic) => comic.uuid), [
      'both',
      'dmzj',
      'copy',
    ]);
  });

  test('补缺范围包含拷贝漫画独有和两边都有但排除动漫之家独有', () async {
    final eligible = await controller.copyMangaComics();

    expect(eligible.map((comic) => comic.uuid), ['copy', 'both']);
  });

  test('批量刷新只缓存简介并保留核心漫画记录和已下载章节', () async {
    await library.cacheChapters(
      const Comic(uuid: 'copy', pathWord: 'copy', title: '拷贝独有', authors: '作者'),
      'default',
      '默认',
      const [
        Chapter(
          uuid: 'downloaded',
          comicUuid: 'copy',
          groupPathWord: 'default',
          groupName: '默认',
          title: '第1话',
          order: 1,
        ),
      ],
    );
    await library.database.update(
      'chapters',
      {'archive_relative_path': '拷贝独有 - 作者/第1话.zip'},
      where: 'chapter_uuid = ?',
      whereArgs: ['downloaded'],
    );
    final batchController = LibraryController(
      database: library,
      locator: LibraryLocator(),
      client: _BatchCopyClient(),
      localDatabase: local,
    );

    final source = await library.loadComic('copy');
    final result = await batchController.refreshDetailsForBatch(source!);
    final stored = await library.loadComic('copy');

    expect(result.comic.uuid, 'copy');
    expect(stored!.title, '拷贝独有');
    expect(stored.brief, '批量缓存的漫画简介');
    expect(result.chapters, hasLength(2));
    expect(
      result.chapters
          .singleWhere((chapter) => chapter.uuid == 'downloaded')
          .isDownloaded,
      isTrue,
    );
    expect(
      result.chapters
          .singleWhere((chapter) => chapter.uuid == 'new')
          .isDownloaded,
      isFalse,
    );
    batchController.dispose();
  });

  test('批量扫描并发设置限制在 1 到 10 并持久保存', () async {
    await controller.setBatchScanConcurrency(20);
    expect(controller.batchScanConcurrency, 10);
    expect(await local.preference('batch_scan_concurrency'), '10');

    await controller.setBatchScanConcurrency(0);
    expect(controller.batchScanConcurrency, 1);
  });
}

final class _BatchCopyClient extends CopyClient {
  @override
  Future<ComicDetailsResult> comicDetails(String pathWord) async {
    return const ComicDetailsResult(
      comic: Comic(
        uuid: 'online-uuid',
        pathWord: 'copy',
        title: '在线名称',
        authors: '在线作者',
        brief: '批量缓存的漫画简介',
      ),
      groups: [ComicGroup(pathWord: 'default', name: '默认', count: 2)],
      rawComic: <String, dynamic>{},
    );
  }

  @override
  Future<List<Chapter>> groupChapters({
    required Comic comic,
    required ComicGroup group,
  }) async {
    return [
      Chapter(
        uuid: 'downloaded',
        comicUuid: comic.uuid,
        groupPathWord: group.pathWord,
        groupName: group.name,
        title: '第1话',
        order: 1,
      ),
      Chapter(
        uuid: 'new',
        comicUuid: comic.uuid,
        groupPathWord: group.pathWord,
        groupName: group.name,
        title: '第2话',
        order: 2,
      ),
    ];
  }
}
