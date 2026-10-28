import 'dart:io';

import 'package:copymanga_reader/controllers/favorites_controller.dart';
import 'package:copymanga_reader/controllers/novel_controller.dart';
import 'package:copymanga_reader/models/comic.dart';
import 'package:copymanga_reader/models/novel.dart';
import 'package:copymanga_reader/services/copy_api_transport.dart';
import 'package:copymanga_reader/services/copy_client.dart';
import 'package:copymanga_reader/services/copy_novel_client.dart';
import 'package:copymanga_reader/services/library_database.dart';
import 'package:copymanga_reader/services/local_app_database.dart';
import 'package:copymanga_reader/services/novel_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const comic = Comic(
  uuid: 'comic-id',
  pathWord: 'comic-one',
  title: '漫画',
  authors: '作者',
);
const novel = Novel(
  uuid: 'novel-id',
  pathWord: 'novel-one',
  title: '小说',
  authors: '作者',
);

class FakeComicClient extends CopyClient {
  List<Comic> remote = [];
  int reads = 0, writes = 0;
  bool failWrite = false;
  @override
  Future<List<Comic>> favorites({
    String ordering = '-datetime_updated',
    Set<String> knownUuids = const {},
  }) async {
    reads++;
    return List.of(remote);
  }

  @override
  Future<void> setFavorite(Comic book, bool selected) async {
    writes++;
    if (failWrite) throw const CopyApiException('服务暂时不可用');
    remote.removeWhere((x) => x.uuid == book.uuid);
    if (selected) remote.add(book);
  }
}

class FakeNovelClient extends CopyNovelClient {
  FakeNovelClient() : super(CopyApiTransport(), null);
  List<Novel> remote = [];
  final writes = <String>[];
  String? failId;
  int reads = 0;
  @override
  Future<List<Novel>> favorites({Set<String> knownUuids = const {}}) async {
    reads++;
    return List.of(remote);
  }

  @override
  Future<void> setFavorite(Novel book, bool selected) async {
    writes.add(book.uuid);
    if (book.uuid == failId) throw const CopyApiException('服务暂时不可用');
    remote.removeWhere((x) => x.uuid == book.uuid);
    if (selected) remote.add(book);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  late Directory temp;
  late LocalAppDatabase local;
  late LibraryDatabase db;
  late NovelStore store;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('favorite-mutation-test-');
    local = LocalAppDatabase(
      factory: databaseFactoryFfi,
      supportDirectoryProvider: () async => Directory('${temp.path}/state'),
    );
    db = LibraryDatabase(localDatabase: local);
    await db.open(Directory('${temp.path}/漫画'));
    store = NovelStore(db);
    await store.ensureSchema();
  });
  tearDown(() async {
    await db.close();
    await local.close();
    await temp.delete(recursive: true);
  });

  test('漫画收藏先读取、写入后核实，已收藏不重复写，支持取消', () async {
    final client = FakeComicClient();
    final controller = FavoritesController(database: db, client: client);
    await controller.setFavorite(comic, true);
    expect(client.reads, 2);
    expect(client.writes, 1);
    expect(await controller.isCollected(comic), isTrue);
    await controller.setFavorite(comic, true);
    expect(client.writes, 1);
    await controller.setFavorite(comic, false);
    expect(client.writes, 2);
    expect(await controller.isCollected(comic), isFalse);
    controller.dispose();
  });
  test('漫画收藏写入失败不自动重试或接着读账号接口', () async {
    final client = FakeComicClient()..failWrite = true;
    final controller = FavoritesController(database: db, client: client);
    await expectLater(
      controller.setFavorite(comic, true),
      throwsA(isA<CopyApiException>()),
    );
    expect(client.writes, 1);
    expect(client.reads, 1);
    expect(controller.comics, isEmpty);
    controller.dispose();
  });
  test('小说详情收藏与取消均验证服务端，已有收藏不重复写', () async {
    final client = FakeNovelClient();
    final controller = NovelController(store: store, client: client);
    await controller.favorite(novel, true, 'account');
    expect(await controller.isCollected(novel, 'account'), isTrue);
    await controller.favorite(novel, true, 'account');
    expect(client.writes, ['novel-id']);
    await controller.favorite(novel, false, 'account');
    expect(await controller.isCollected(novel, 'account'), isFalse);
    controller.dispose();
  });
  for (final fail in [false, true]) {
    test('批量小说收藏跳过已有及纯本地，首错停止=$fail', () async {
      final client = FakeNovelClient()
        ..remote = [novel]
        ..failId = fail ? 'b' : null;
      final controller = NovelController(store: store, client: client);
      for (final book in [
        novel,
        const Novel(uuid: 'b', pathWord: 'book-b', title: 'B', authors: ''),
        const Novel(uuid: 'c', pathWord: 'book-c', title: 'C', authors: ''),
        const Novel(
          uuid: 'local',
          pathWord: 'local-book',
          title: 'D',
          authors: '',
        ),
      ]) {
        await store.saveBook(book);
        await store.db.insert('novel_volumes', {
          'novel_uuid': book.uuid,
          'volume_id': '1',
          'title': '1',
          'is_downloaded': 1,
        });
      }
      if (fail) {
        await expectLater(
          controller.collectLocalBooks('account'),
          throwsA(isA<CopyApiException>()),
        );
        expect(client.writes, ['b']);
        expect(client.reads, 1);
        expect(controller.collectFailures.keys, ['b']);
      } else {
        expect(await controller.collectLocalBooks('account'), 2);
        expect(client.writes, ['b', 'c']);
        expect(client.remote.map((b) => b.uuid), ['novel-id', 'b', 'c']);
        expect(await controller.collectLocalBooks('account'), 0);
        expect(client.writes.length, 2);
      }
      expect(controller.collecting, isFalse);
      controller.dispose();
    });
  }
}
