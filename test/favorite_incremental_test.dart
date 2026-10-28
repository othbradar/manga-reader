import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:copymanga_reader/controllers/favorites_controller.dart';
import 'package:copymanga_reader/controllers/novel_controller.dart';
import 'package:copymanga_reader/models/comic.dart';
import 'package:copymanga_reader/models/novel.dart';
import 'package:copymanga_reader/services/copy_api_protocol.dart';
import 'package:copymanga_reader/services/copy_api_transport.dart';
import 'package:copymanga_reader/services/copy_client.dart';
import 'package:copymanga_reader/services/copy_novel_client.dart';
import 'package:copymanga_reader/services/favorite_refresh_window.dart';
import 'package:copymanga_reader/services/library_database.dart';
import 'package:copymanga_reader/services/local_app_database.dart';
import 'package:copymanga_reader/services/novel_store.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'fixtures/copy_request_identity.dart';

class PagesAdapter implements HttpClientAdapter {
  List<String> ids = List.generate(100, (i) => 'old-$i');
  final requests = <RequestOptions>[];
  int? failOffset;
  bool repeat = false;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancelFuture,
  ) async {
    final comic = options.uri.path == CopyApiProtocol.favoritesPath;
    final novel = options.uri.path == CopyApiProtocol.novelFavoritesPath;
    Object result = {'api': []};
    if (comic || novel) {
      requests.add(options);
      final offset = options.queryParameters['offset'] as int;
      if (offset == failOffset) {
        throw DioException(
          requestOptions: options,
          type: DioExceptionType.receiveTimeout,
        );
      }
      result = {
        'total': ids.length,
        'list': [
          for (final id in ids.skip(repeat ? 0 : offset).take(18))
            {
              comic ? 'comic' : 'book': {
                'uuid': id,
                'path_word': id,
                'name': id,
              },
            },
        ],
      };
    }
    return ResponseBody.fromString(
      jsonEncode({'code': 200, 'results': result}),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class CachedComicClient extends CopyClient {
  List<Comic> remote = [];
  Set<String> known = {};
  bool fail = false;
  @override
  Future<List<Comic>> favorites({
    String ordering = '-datetime_updated',
    Set<String> knownUuids = const {},
  }) async {
    known = Set.of(knownUuids);
    if (fail) throw const CopyApiException('network fixture');
    return remote;
  }
}

class CachedNovelClient extends CopyNovelClient {
  CachedNovelClient() : super(CopyApiTransport(), null);
  List<Novel> remote = [];
  Set<String> known = {};
  bool fail = false;
  @override
  Future<List<Novel>> favorites({Set<String> knownUuids = const {}}) async {
    known = Set.of(knownUuids);
    if (fail) throw const CopyApiException('network fixture');
    return remote;
  }
}

Comic comic(String id, {String brief = ''}) =>
    Comic(uuid: id, pathWord: id, title: id, authors: '', brief: brief);
Novel novel(String id) => Novel(uuid: id, pathWord: id, title: id, authors: '');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  test(
    'known overlap must be two consecutive pages and must explain total',
    () {
      final w = FavoriteRefreshWindow({'a', 'b'});
      expect(w.accept(['a'], 3), isFalse);
      expect(w.accept(['b'], 3), isFalse); // count gap: cannot stop
      expect(w.accept(['new'], 3), isFalse);
      expect(w.accept(['a'], 3), isFalse);
      expect(w.accept(['b'], 3), isTrue);
    },
  );

  for (final isNovel in [false, true]) {
    group(isNovel ? 'novel paging' : 'comic paging', () {
      late PagesAdapter adapter;
      late Future<List<String>> Function(Set<String>) fetch;
      setUp(() {
        adapter = PagesAdapter();
        final dio = Dio()..httpClientAdapter = adapter;
        if (isNovel) {
          final transport =
              CopyApiTransport(dio: dio, accountRequestInterval: Duration.zero)
                ..setDeviceIdentity(fixtureDeviceIdentity)
                ..setAuthenticationDomain('account.example')
                ..setToken('fixture');
          final client = CopyNovelClient(transport, null);
          fetch = (known) async => (await client.favorites(
            knownUuids: known,
          )).map((x) => x.uuid).toList();
        } else {
          final client = CopyClient(dio: dio)
            ..setDeviceIdentity(fixtureDeviceIdentity)
            ..setAuthenticationDomain('account.example')
            ..setToken('fixture');
          fetch = (known) async => (await client.favorites(
            knownUuids: known,
          )).map((x) => x.uuid).toList();
        }
      });
      test('unchanged 100-book cache reads 2 pages, not all 6', () async {
        final result = await fetch(adapter.ids.toSet());
        expect(result.length, 36);
        expect(adapter.requests.length, 2);
        expect(
          adapter.requests.every(
            (r) => r.queryParameters['ordering'] == '-datetime_modifier',
          ),
          isTrue,
        );
      });
      test(
        'new favorites ahead of known IDs are collected with overlap',
        () async {
          final known = adapter.ids.toSet();
          adapter.ids.insertAll(0, ['new-1', 'new-2']);
          final result = await fetch(known);
          expect(result.take(2), ['new-1', 'new-2']);
          expect(adapter.requests.length, 3);
        },
      );
      test(
        'cold cache or incomplete import does not prematurely stop',
        () async {
          adapter.ids = List.generate(40, (i) => 'old-$i');
          expect((await fetch(adapter.ids.take(36).toSet())).length, 40);
          expect(adapter.requests.length, 3);
        },
      );
      test(
        'duplicate server page errors instead of committing a false prefix',
        () async {
          adapter.repeat = true;
          await expectLater(
            fetch(adapter.ids.toSet()),
            throwsA(isA<CopyApiException>()),
          );
        },
      );
      test('second page failure rejects entire refresh', () async {
        adapter.failOffset = 18;
        await expectLater(
          fetch(adapter.ids.toSet()),
          throwsA(isA<CopyApiException>()),
        );
        expect(adapter.requests.length, 2);
      });
    });
  }

  group('local historical merge', () {
    late Directory temp;
    late LocalAppDatabase local;
    late LibraryDatabase db;
    late FavoritesController comics;
    late NovelController novels;
    late CachedComicClient cc;
    late CachedNovelClient nc;
    setUp(() async {
      temp = await Directory.systemTemp.createTemp(
        'incremental-favorite-test-',
      );
      local = LocalAppDatabase(
        factory: databaseFactoryFfi,
        supportDirectoryProvider: () async => Directory('${temp.path}/state'),
      );
      db = LibraryDatabase(localDatabase: local);
      await db.open(Directory('${temp.path}/library'));
      cc = CachedComicClient();
      nc = CachedNovelClient();
      comics = FavoritesController(database: db, client: cc)
        ..changeAccount('a');
      final store = NovelStore(db);
      await store.ensureSchema();
      novels = NovelController(store: store, client: nc)..changeAccount('a');
    });
    tearDown(() async {
      comics.dispose();
      novels.dispose();
      await db.close();
      await local.close();
      await temp.delete(recursive: true);
    });
    test(
      'new items prepend; history/order/brief survive sparse and empty refresh',
      () async {
        cc.remote = [comic('old', brief: 'cached synopsis'), comic('history')];
        nc.remote = [novel('old'), novel('history')];
        await comics.refresh();
        await novels.loadFavorites('a', online: true);
        cc.remote = [comic('new'), comic('old')];
        nc.remote = [novel('new'), novel('old')];
        await comics.refresh();
        await novels.loadFavorites('a', online: true);
        expect(cc.known, {'old', 'history'});
        expect(nc.known, {'old', 'history'});
        expect(comics.comics.map((c) => c.uuid), ['new', 'old', 'history']);
        expect(comics.comics[1].brief, 'cached synopsis');
        expect(novels.favorites.map((c) => c.uuid), ['new', 'old', 'history']);
        cc.remote = [];
        nc.remote = [];
        await comics.refresh();
        await novels.loadFavorites('a', online: true);
        expect(comics.comics.length, 3);
        expect(novels.favorites.length, 3);
        // Explicit full check is non-destructive too; historical cache is not proof of server membership.
        await comics.refresh(checkAll: true);
        await novels.loadFavorites('a', online: true, verify: true);
        expect(await comics.isCollected(comic('history')), isFalse);
        expect(await novels.isCollected(novel('history'), 'a'), isFalse);
        expect(comics.comics.length, 3);
        expect(novels.favorites.length, 3);
      },
    );
    test(
      'refresh failure and account switch never discard or cross-write history',
      () async {
        cc.remote = [comic('a')];
        nc.remote = [novel('a')];
        await comics.refresh();
        await novels.loadFavorites('a', online: true);
        cc.fail = true;
        nc.fail = true;
        await comics.refresh();
        await expectLater(
          novels.loadFavorites('a', online: true),
          throwsA(isA<CopyApiException>()),
        );
        expect(comics.comics.single.uuid, 'a');
        expect(novels.favorites.single.uuid, 'a');
        comics.changeAccount('b');
        novels.changeAccount('b');
        cc.fail = false;
        nc.fail = false;
        cc.remote = [comic('b')];
        nc.remote = [novel('b')];
        await comics.refresh();
        await novels.loadFavorites('b', online: true);
        expect(cc.known, isEmpty);
        expect(nc.known, isEmpty);
        comics.changeAccount('a');
        novels.changeAccount('a');
        await comics.loadCache();
        await novels.loadFavorites('a');
        expect(comics.comics.single.uuid, 'a');
        expect(novels.favorites.single.uuid, 'a');
        final tables = await db.database.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table'",
        );
        expect(
          tables.any((r) => r['name'].toString().contains('favorites')),
          isFalse,
        );
      },
    );
  });
}
