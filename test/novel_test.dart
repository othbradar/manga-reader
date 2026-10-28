import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:copymanga_reader/controllers/novel_controller.dart';
import 'package:copymanga_reader/models/novel.dart';
import 'package:copymanga_reader/pages/novel_reader_page.dart';
import 'package:copymanga_reader/services/copy_api_transport.dart';
import 'package:copymanga_reader/services/copy_novel_client.dart';
import 'package:copymanga_reader/services/library_database.dart';
import 'package:copymanga_reader/services/local_app_database.dart';
import 'package:copymanga_reader/services/novel_store.dart';
import 'package:copymanga_reader/services/novel_text.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const book = Novel(
  uuid: 'n1',
  pathWord: 'novel-one',
  title: '小说一',
  authors: '作者',
);
const volume = NovelVolume(novelUuid: 'n1', id: '1', title: '第一卷');

class FakeNovels extends CopyNovelClient {
  FakeNovels() : super(CopyApiTransport(), null);
  int failures = 0, imageCalls = 0;
  int favoriteReads = 0, favoriteWrites = 0;
  bool failFavorite = false;
  final collected = <Novel>[];
  @override
  Future<Novel> details(String pathWord) async => book;
  @override
  Future<List<NovelVolume>> volumes(Novel b) async => [volume];
  @override
  Future<NovelVolume> content(Novel b, NovelVolume v) async => NovelVolume(
    novelUuid: b.uuid,
    id: v.id,
    title: v.title,
    textUrl: 'https://example.test/text',
    sections: const [
      NovelSection(
        index: 0,
        title: '插图',
        type: 2,
        imageUrl: 'https://example.test/image',
      ),
    ],
  );
  @override
  Future<Uint8List> bytes(
    String url, {
    CancelToken? cancelToken,
    ProgressCallback? onProgress,
  }) async {
    if (url.endsWith('text')) {
      return Uint8List.fromList(utf8.encode('第一卷\n正文\n'));
    }
    imageCalls++;
    if (failures-- > 0) throw const SocketException('temporary');
    return Uint8List.fromList([255, 216, 255, 217]);
  }

  @override
  Future<List<Novel>> favorites({Set<String> knownUuids = const {}}) async {
    favoriteReads++;
    return List.of(collected);
  }

  @override
  Future<void> setFavorite(Novel b, bool value) async {
    favoriteWrites++;
    if (failFavorite) {
      throw const CopyApiException('账号已被限制', accountRestricted: true);
    }
    if (value && !collected.any((x) => x.uuid == b.uuid)) collected.add(b);
  }
}

Future<void> until(bool Function() check) async {
  for (var i = 0; i < 500 && !check(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(check(), isTrue);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  late Directory temp;
  late LibraryDatabase library;
  late LocalAppDatabase local;
  late NovelStore store;
  late NovelController controller;
  late FakeNovels client;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('novel-test-');
    local = LocalAppDatabase(
      factory: databaseFactoryFfi,
      supportDirectoryProvider: () async => Directory('${temp.path}/state'),
    );
    library = LibraryDatabase(localDatabase: local);
    await library.open(Directory('${temp.path}/漫画'));
    store = NovelStore(library);
    client = FakeNovels();
    controller = NovelController(store: store, client: client);
    await controller.initialize();
  });
  tearDown(() async {
    await controller.pause();
    controller.dispose();
    await library.close();
    await local.close();
    await temp.delete(recursive: true);
  });

  test('小说新表与漫画表隔离，路径可迁移且拒绝越界', () async {
    await library.database.execute(
      "INSERT INTO comics(comic_uuid,title) VALUES('old','原漫画')",
    );
    final before = await library.database.query('comics');
    await store.ensureSchema();
    await store.saveBook(book);
    await store.saveVolumes([volume]);
    expect(await library.database.query('comics'), before);
    expect(store.absolute('小说/小说一/第一卷.txt'), '${temp.path}/小说/小说一/第一卷.txt');
    expect(() => store.absolute('小说/../../secret'), throwsFormatException);
    expect(() => store.absolute('/tmp/other'), throwsFormatException);
    final tables = await library.database.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table'",
    );
    expect(tables.map((r) => r['name']), isNot(contains('novel_tasks')));
    expect(tables.map((r) => r['name']), isNot(contains('novel_progress')));
  });

  test('下载自动重试插图，全部文件完成才标记下载；再次更新不丢下载路径', () async {
    client.failures = 1;
    await controller.enqueue(book, [volume]);
    await until(
      () =>
          controller.tasks.isNotEmpty &&
          controller.tasks.single['state'] == 'completed',
    );
    expect(client.imageCalls, 2);
    var saved = await store.volume(book.uuid, volume.id);
    expect(saved.downloaded, isTrue);
    expect(saved.relativePath, endsWith('小说一 - 作者 - 第一卷.txt'));
    expect(
      await File(store.absolute(saved.relativePath)).readAsString(),
      '第一卷\n正文\n',
    );
    expect(
      await File(store.absolute(saved.sections.single.imagePath)).exists(),
      isTrue,
    );
    await controller.updateBook(book);
    saved = await store.volume(book.uuid, volume.id);
    expect(saved.downloaded, isTrue);
    expect(saved.relativePath, isNotEmpty);
    await controller.pause();
    await controller.clearFinished();
    expect(controller.tasks, isEmpty);
  });

  test('未匹配本地 TXT 也入库，重复扫描不会新增第二本', () async {
    final folder = Directory('${temp.path}/小说/本地小说 - 作者');
    await folder.create(recursive: true);
    await File('${folder.path}/第一卷.txt').writeAsString('第一卷\n正文');
    expect(await store.importLocalFolders(), 1);
    expect(await store.importLocalFolders(), 0);
    final b = (await store.books()).single;
    expect(b.isLocal, isTrue);
    expect(b.title, '本地小说');
    expect((await store.volumes(b.uuid)).single.downloaded, isTrue);
  });

  test('收藏本地已匹配小说只添加缺少的作品，读回验证且不重复', () async {
    await controller.enqueue(book, [volume]);
    await until(
      () =>
          controller.tasks.isNotEmpty &&
          controller.tasks.single['state'] == 'completed',
    );
    expect(await controller.collectLocalBooks('account'), 1);
    expect(await controller.collectLocalBooks('account'), 0);
    expect(client.collected.length, 1);
  });

  test('批量收藏首次失败即停止，保留失败记录且不再次请求账号', () async {
    await controller.enqueue(book, [volume]);
    await until(
      () =>
          controller.tasks.isNotEmpty &&
          controller.tasks.single['state'] == 'completed',
    );
    client.failFavorite = true;
    await expectLater(
      controller.collectLocalBooks('account'),
      throwsA(isA<CopyApiException>()),
    );
    expect(client.favoriteReads, 1);
    expect(client.favoriteWrites, 1);
    expect(controller.collecting, isFalse);
    expect(controller.collectFailures.keys, ['n1']);
    expect(client.collected, isEmpty);
  });

  test('小说进度和队列可移植，旧备份不需要小说新表', () async {
    await local.database.insert('novel_progress', {
      'library_key': store.key,
      'novel_uuid': 'n1',
      'volume_id': '1',
      'block_index': 20,
      'fraction': 0.4,
    });
    await local.database.insert('novel_tasks', {
      'library_key': store.key,
      'novel_uuid': 'n1',
      'volume_id': '1',
      'state': 'downloading',
    });
    final backup = File('${temp.path}/portable.db');
    final exported = await local.exportPortableBackup(
      backup,
      libraryKey: store.key,
    );
    expect(exported.novelRows, 2);
    final other = LocalAppDatabase(
      factory: databaseFactoryFfi,
      supportDirectoryProvider: () async =>
          Directory('${temp.path}/other-state'),
    );
    await other.open();
    try {
      await other.importPortableBackup(backup, libraryKey: 'new-library');
      expect(
        (await other.database.query('novel_tasks')).single['state'],
        'paused',
      );
      expect(
        (await other.database.query('novel_progress')).single['library_key'],
        'new-library',
      );
      final old = await databaseFactoryFfi.openDatabase(backup.path);
      for (final name in ['novel_tasks', 'novel_progress', 'novel_favorites']) {
        await old.execute('DROP TABLE $name');
      }
      await old.close();
      await other.importPortableBackup(backup, libraryKey: 'old-backup');
    } finally {
      await other.close();
    }
  });

  test('UTF8、UTF16、GBK和HTML正文处理', () {
    expect(decodeNovelText(utf8.encode('正文')), '正文');
    expect(decodeNovelText([0xff, 0xfe, 0x63, 0x6b]), '正');
    expect(decodeNovelText([0xd5, 0xfd, 0xce, 0xc4], encoding: 'GBK'), '正文');
    expect(() => decodeNovelText([], encoding: 'GBK'), throwsFormatException);
    expect(() => decodeNovelText([0xff, 0xfe]), throwsFormatException);
    expect(
      () => decodeNovelText(utf8.encode('<html>error</html>'), encoding: 'GBK'),
      throwsFormatException,
    );
    expect(
      () => decodeNovelText(utf8.encode('<html>error</html>')),
      throwsFormatException,
    );
    expect(localNovelPlainText('第一卷&nbsp;<br/>正文'), '第一卷 \n正文');
  });

  testWidgets('小说阅读恢复后可以回到开头，不被旧进度拉回底部', (tester) async {
    late NovelVolume downloaded;
    await tester.runAsync(() async {
      final dir = Directory('${temp.path}/小说/测试');
      await dir.create(recursive: true);
      final file = File('${dir.path}/第一卷.txt');
      await file.writeAsString(
        List.generate(600, (i) => '第 $i 行，这是一段用于测试连续滚动的小说正文。').join('\n'),
      );
      await store.saveBook(book);
      await store.saveVolumes([volume]);
      await store.completeVolume(volume, store.relative(file.path), 'test', {});
      downloaded = await store.volume('n1', '1');
      await local.database.insert('novel_progress', {
        'library_key': store.key,
        'novel_uuid': 'n1',
        'volume_id': '1',
        'block_index': 8,
        'fraction': 0.2,
      });
    });
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: MaterialApp(
          home: NovelReaderPage(book: book, volume: downloaded),
        ),
      ),
    );
    for (var i = 0; i < 100 && find.byType(ListView).evaluate().isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    expect(find.byType(ListView), findsOneWidget);
    final scroll = tester.widget<ListView>(find.byType(ListView)).controller!;
    expect(scroll.offset, greaterThan(100));
    scroll.jumpTo(0);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pump();
    expect(scroll.offset, 0);
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(
        (await local.database.query('novel_progress')).single['block_index'],
        0,
      );
    });
    expect(tester.takeException(), isNull);
  });
}
