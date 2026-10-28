import 'dart:async';
import 'dart:io';

import 'package:copymanga_reader/controllers/session_controller.dart';
import 'package:copymanga_reader/controllers/favorites_controller.dart';
import 'package:copymanga_reader/controllers/novel_controller.dart';
import 'package:copymanga_reader/models/comic.dart';
import 'package:copymanga_reader/models/novel.dart';
import 'package:copymanga_reader/pages/accounts_page.dart';
import 'package:copymanga_reader/pages/login_page.dart';
import 'package:copymanga_reader/services/account_store.dart';
import 'package:copymanga_reader/services/copy_client.dart';
import 'package:copymanga_reader/services/copy_novel_client.dart';
import 'package:copymanga_reader/services/copy_api_transport.dart';
import 'package:copymanga_reader/services/library_database.dart';
import 'package:copymanga_reader/services/local_app_database.dart';
import 'package:copymanga_reader/services/novel_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class AccountClient extends CopyClient {
  String activeToken = '';
  String? failure, returnedUsername;
  int logins = 0, profiles = 0;
  int renewals = 0;
  Future<bool> Function()? renewal;
  Completer<void>? renewalHold;
  @override
  void setSessionRenewal(Future<bool> Function()? callback) {
    renewal = callback;
    super.setSessionRenewal(callback);
  }

  @override
  Future<Map<String, dynamic>> authenticateCredentials(
    String username,
    String password,
  ) async {
    renewals++;
    if (renewalHold != null) await renewalHold!.future;
    if (failure != null) throw CopyApiException(failure!);
    return {
      'username': returnedUsername ?? username,
      'token': 'renewed-fixture-$username',
    };
  }

  @override
  void installRenewedToken(String token) {
    activeToken = token;
    super.installRenewedToken(token);
  }

  Completer<void>? hold;
  Completer<List<Comic>>? comicRead;
  @override
  void setToken(String token) {
    activeToken = token;
    super.setToken(token);
  }

  @override
  Future<Map<String, dynamic>> login(String username, String password) async {
    logins++;
    if (hold != null) await hold!.future;
    if (failure != null) throw CopyApiException(failure!);
    setToken('test-token-$username');
    return {
      'username': returnedUsername ?? username,
      'nickname': '昵称-$username',
      'token': 'test-token-$username',
    };
  }

  @override
  Future<Map<String, dynamic>> profile() async {
    profiles++;
    return {'username': returnedUsername ?? '', 'nickname': 'profile'};
  }

  @override
  Future<List<Comic>> favorites({
    String ordering = '-datetime_updated',
    Set<String> knownUuids = const {},
  }) async => comicRead == null ? [] : comicRead!.future;
}

class HeldNovelClient extends CopyNovelClient {
  HeldNovelClient() : super(CopyApiTransport(), null);
  final held = Completer<List<Novel>>();
  @override
  Future<List<Novel>> favorites({Set<String> knownUuids = const {}}) =>
      held.future;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  late Directory temp;
  late LocalAppDatabase local;
  late LibraryDatabase library;
  late AccountStore store;
  late AccountClient client;
  late SessionController session;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({
      AccountStore.legacyUsernameKey: 'original',
      AccountStore.legacyTokenKey: 'original-fixture-token',
    });
    temp = await Directory.systemTemp.createTemp('multi-account-test-');
    local = LocalAppDatabase(
      factory: databaseFactoryFfi,
      supportDirectoryProvider: () async => Directory('${temp.path}/state'),
    );
    library = LibraryDatabase(localDatabase: local);
    await library.open(Directory('${temp.path}/library'));
    store = AccountStore(local);
    client = AccountClient()..setAuthenticationDomain('first.example');
    session = SessionController(client, store: store);
    await session.restore();
  });
  tearDown(() async {
    session.dispose();
    await library.close();
    await local.close();
    await temp.delete(recursive: true);
  });

  test('旧单账号安全迁移，不请求网络、不保存密码，重启保留当前账号', () async {
    expect(session.accountKey, 'original');
    expect(client.activeToken, 'original-fixture-token');
    expect(client.logins + client.profiles, 0);
    expect(await store.secure.read(key: AccountStore.legacyTokenKey), isNull);
    expect(await store.token('original'), 'original-fixture-token');
    expect(await session.login('second', 'fixture-password'), isTrue);
    final restored = SessionController(AccountClient(), store: store);
    await restored.restore();
    expect(restored.accountKey, 'second');
    expect(restored.accounts.map((a) => a.id), ['original', 'second']);
    expect(
      (await local.database.query('saved_accounts')).toString(),
      isNot(contains('fixture-password')),
    );
    expect(
      (await store.secure.readAll()).values,
      isNot(contains('fixture-password')),
    );
    restored.dispose();
  });

  test('升级复制原账号收藏且保留全部旧表，退出和重启不删除收藏', () async {
    FlutterSecureStorage.setMockInitialValues({
      AccountStore.legacyUsernameKey: 'old-user',
      AccountStore.legacyTokenKey: 'old-fixture-token',
    });
    final legacy = LocalAppDatabase(
      factory: databaseFactoryFfi,
      supportDirectoryProvider: () async => Directory('${temp.path}/legacy'),
    );
    await legacy.open();
    try {
      const comic = Comic(
        uuid: 'kept',
        pathWord: 'kept',
        title: '保留的漫画',
        authors: '作者',
      );
      await legacy.replaceFavorites('one-library', [comic]);
      await legacy.replaceFavorites('other-library', [comic]);
      await legacy.database.insert('novel_favorites', {
        'library_key': 'one-library',
        'account_key': 'old-user',
        'novel_uuid': 'kept-novel',
        'path_word': 'kept-novel',
        'title': '保留的小说',
      });
      final oldRows = await legacy.database.query('favorites_cache');
      final oldNovels = await legacy.database.query('novel_favorites');
      final migrated = SessionController(
        AccountClient(),
        store: AccountStore(legacy),
      );
      await migrated.restore();
      expect(
        (await legacy.database.query('account_comic_favorites')).length,
        2,
      );
      expect(await legacy.database.query('favorites_cache'), oldRows);
      expect(await legacy.database.query('novel_favorites'), oldNovels);
      await migrated.logout();
      await migrated.restore();
      expect(await legacy.database.query('favorites_cache'), oldRows);
      expect(await legacy.database.query('novel_favorites'), oldNovels);
      expect(
        (await legacy.database.query('account_comic_favorites')).length,
        2,
      );
      migrated.dispose();
    } finally {
      await legacy.close();
    }
  });

  test('记住密码仅写系统安全存储，续期不改变当前账号或收藏作用域', () async {
    await session.login('second', 'fixture-password', rememberPassword: true);
    expect(await store.password('second'), 'fixture-password');
    expect(session.remembersPassword('second'), isTrue);
    expect(
      (await local.database.query('saved_accounts')).toString(),
      isNot(contains('fixture-password')),
    );
    final revision = client.sessionRevision;
    final id = session.accountKey;
    expect(await client.renewal!(), isTrue);
    expect(client.renewals, 1);
    expect(client.sessionRevision, revision);
    expect(session.accountKey, id);
    expect(await store.token('second'), 'renewed-fixture-second');
    expect(await store.token('original'), 'original-fixture-token');
    expect(await store.activeId(), 'second');
  });

  test('没有保存密码不自动登录；关闭续期和退出删除密码但保留收藏', () async {
    expect(await client.renewal!(), isFalse);
    expect(client.renewals, 0);
    await session.login('second', 'fixture-password', rememberPassword: true);
    await session.forgetPassword('second');
    expect(await store.password('second'), isEmpty);
    expect(await store.token('second'), isNotEmpty);
    expect(await client.renewal!(), isFalse);
    await session.login('second', 'fixture-password', rememberPassword: true);
    await session.removeAccount('second');
    expect(await store.password('second'), isEmpty);
    expect(await store.token('original'), 'original-fixture-token');
  });

  test('自动续期拒绝错误身份，失败保留旧令牌与保存密码', () async {
    await session.login('second', 'fixture-password', rememberPassword: true);
    client.returnedUsername = 'someone-else';
    await expectLater(client.renewal!(), throwsA(isA<CopyApiException>()));
    expect(await store.token('second'), 'test-token-second');
    expect(client.activeToken, 'test-token-second');
    expect(await store.password('second'), 'fixture-password');
    expect(session.renewing, isFalse);
  });

  test('续期期间禁止账号突变，节点改变后旧结果不覆盖安全存储', () async {
    await session.login('second', 'fixture-password', rememberPassword: true);
    client.renewalHold = Completer<void>();
    final renewing = client.renewal!();
    await Future<void>.delayed(Duration.zero);
    expect(session.renewing, isTrue);
    expect(await session.switchAccount('original'), isFalse);
    client.setAuthenticationDomain('changed.example');
    client.renewalHold!.complete();
    expect(await renewing, isFalse);
    expect(await store.token('second'), 'test-token-second');
    expect(session.accountKey, 'second');
  });

  test('切换使用各自令牌与账号节点，不重登，不切换匿名内容线路', () async {
    final contentNode = client.apiDomain;
    await session.login('second', 'fixture-password');
    client.setAuthenticationDomain('second.example');
    await session.saveCurrentNode();
    expect(await session.switchAccount('original'), isTrue);
    expect(client.activeToken, 'original-fixture-token');
    expect(client.authenticationDomain, 'first.example');
    expect(await session.switchAccount('second'), isTrue);
    expect(client.activeToken, 'test-token-second');
    expect(client.authenticationDomain, 'second.example');
    expect(client.apiDomain, contentNode);
    expect(client.logins, 1);
    expect(client.profiles, 0);
  });

  test('添加账号失败或服务端身份不符时恢复原会话', () async {
    client.failure = '密码错误';
    expect(await session.login('second', 'fixture-password'), isFalse);
    expect(session.accountKey, 'original');
    expect(client.activeToken, 'original-fixture-token');
    expect(await store.activeId(), 'original');
    client.failure = null;
    client.returnedUsername = 'someone-else';
    expect(await session.login('second', 'fixture-password'), isFalse);
    expect(client.activeToken, 'original-fixture-token');
    expect(session.accounts, hasLength(1));
  });

  test('令牌丢失不能激活账号，保留当前账号', () async {
    await session.login('second', 'fixture-password');
    await session.switchAccount('original');
    await store.secure.delete(key: AccountStore.tokenKey('second'));
    expect(await session.switchAccount('second'), isFalse);
    expect(session.accountKey, 'original');
    expect(session.error, contains('重新登录'));
  });

  test('重复点击登录/切换不会并发，切换开始立即失效旧会话', () async {
    client.hold = Completer<void>();
    final revision = client.sessionRevision;
    final login = session.login('second', 'fixture-password');
    expect(session.isLoggedIn, isFalse);
    expect(client.sessionRevision, greaterThan(revision));
    expect(await session.login('third', 'fixture-password'), isFalse);
    expect(await session.switchAccount('original'), isFalse);
    client.hold!.complete();
    expect(await login, isTrue);
    expect(client.logins, 1);
  });

  test('移除一个本机账号不影响另一个，退出后不复活旧迁移令牌', () async {
    await session.login('second', 'fixture-password');
    await session.removeAccount('original');
    expect(session.accountKey, 'second');
    expect(await store.token('original'), isEmpty);
    expect(await store.token('second'), isNotEmpty);
    await session.logout();
    expect(session.isLoggedIn, isFalse);
    await session.restore();
    expect(session.accounts, isEmpty);
    expect(client.activeToken, isEmpty);
  });

  test('漫画收藏按账号和漫画库隔离，未知归属旧缓存不冒认', () async {
    const a = Comic(uuid: 'a', pathWord: 'a', title: 'A', authors: '');
    const b = Comic(uuid: 'b', pathWord: 'b', title: 'B', authors: '');
    await library.cacheComic(a);
    await library.cacheComic(b);
    await local.replaceFavorites(library.libraryKey, [b]); // legacy
    await local.replaceFavorites(library.libraryKey, [
      a,
    ], accountKey: 'original');
    await local.replaceFavorites(library.libraryKey, [b], accountKey: 'second');
    final favorites = FavoritesController(database: library, client: client);
    favorites.changeAccount('original');
    await favorites.loadCache();
    expect(favorites.comics.single.uuid, 'a');
    expect((await library.loadComic('a'))!.isFavorite, isTrue);
    expect((await library.loadComic('b'))!.isFavorite, isFalse);
    expect(
      (await library.loadComics()).where((c) => c.isFavorite).single.uuid,
      'a',
    );
    favorites.changeAccount('second');
    expect(favorites.comics, isEmpty);
    await favorites.loadCache();
    expect(favorites.comics.single.uuid, 'b');
    favorites.changeAccount('');
    await favorites.loadCache();
    expect(favorites.comics, isEmpty);
    favorites.dispose();
  });

  test('迟到的旧账号漫画响应不能写入新账号缓存/界面', () async {
    final favorites = FavoritesController(database: library, client: client);
    favorites.changeAccount('original');
    client.comicRead = Completer<List<Comic>>();
    final read = favorites.refresh();
    client.setToken('new-fixture-token');
    favorites.changeAccount('second');
    client.comicRead!.complete([
      const Comic(uuid: 'old', pathWord: 'old', title: 'old', authors: ''),
    ]);
    await read;
    expect(favorites.comics, isEmpty);
    expect(favorites.error, isEmpty);
    expect(await local.database.query('account_comic_favorites'), isEmpty);
    favorites.dispose();
  });

  test('小说旧账号回包丢弃，不影响新账号缓存', () async {
    final novelClient = HeldNovelClient();
    final novels = NovelController(
      store: NovelStore(library),
      client: novelClient,
    );
    novels.changeAccount('original');
    final read = novels.loadFavorites('original', online: true);
    final failure = expectLater(read, throwsA(isA<CopyApiException>()));
    novels.changeAccount('second');
    novelClient.held.complete([
      const Novel(uuid: 'old', pathWord: 'old', title: 'Old', authors: ''),
    ]);
    await failure;
    expect(novels.favorites, isEmpty);
    expect(await local.database.query('novel_favorites'), isEmpty);
    novels.dispose();
  });

  test('跨设备应用备份包含分账号收藏，不包含账号列表/活动账号/令牌', () async {
    await session.login('second', 'fixture-password', rememberPassword: true);
    await local.replaceFavorites(library.libraryKey, [
      const Comic(uuid: 'a', pathWord: 'a', title: 'A', authors: ''),
    ], accountKey: 'original');
    final file = File('${temp.path}/portable.db');
    await local.exportPortableBackup(file, libraryKey: library.libraryKey);
    final backup = await databaseFactoryFfi.openDatabase(file.path);
    final tables = (await backup.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table'",
    )).map((r) => r['name']);
    expect(tables, isNot(contains('saved_accounts')));
    expect(tables, isNot(contains('account_state')));
    expect(
      String.fromCharCodes(await file.readAsBytes()),
      isNot(contains('fixture-password')),
    );
    expect(
      (await backup.query('account_comic_favorites')).single['account_key'],
      'original',
    );
    await backup.close();
  });

  testWidgets('窄屏账号列表显示添加/切换/重新登录/移除入口无溢出', (tester) async {
    await tester.runAsync(() => session.login('second', 'fixture-password'));
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: session,
        child: const MaterialApp(home: AccountsPage()),
      ),
    );
    expect(find.text('添加账号'), findsOneWidget);
    expect(find.text('original'), findsWidgets);
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
    await tester.tap(find.byTooltip('original 账号操作'));
    await tester.pumpAndSettle();
    expect(find.text('重新登录'), findsOneWidget);
    expect(find.text('移除本机账号'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄屏登录页默认记住密码，可取消且不溢出', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: session,
        child: const MaterialApp(home: LoginPage()),
      ),
    );
    final checkbox = find.byType(CheckboxListTile);
    expect(tester.widget<CheckboxListTile>(checkbox).value, isTrue);
    await tester.ensureVisible(checkbox);
    await tester.tap(checkbox);
    await tester.pump();
    expect(tester.widget<CheckboxListTile>(checkbox).value, isFalse);
    expect(tester.takeException(), isNull);
    expect(client.logins, 0);
  });
}
