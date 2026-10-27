import 'fixtures/copy_request_identity.dart';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:copymanga_reader/models/comic.dart';
import 'package:copymanga_reader/services/copy_api_protocol.dart';
import 'package:copymanga_reader/services/copy_request_protocol.dart';
import 'package:copymanga_reader/services/copy_client.dart';

void main() {
  group('CopyApiProtocol', () {
    test('uses one recovered APK profile for all normal API requests', () {
      final headers = CopyApiProtocol.headers(
        identity: fixtureDeviceIdentity,
        token: 'member-token',
        now: DateTime.utc(2026, 7, 29, 12, 34, 56),
      );

      expect(headers['version'], '3.0.9');
      expect(headers['versionCode'], '83');
      expect(headers['platform'], '3');
      expect(headers['source'], 'copyApp');
      expect(headers['webp'], '1');
      expect(headers['region'], CopyApiRoute.overseas.region);
      expect(headers['authorization'], 'Token member-token');
      expect(headers['X-Auth-Timestamp'], '1785328496');
      expect(
        headers['X-Auth-Signature'],
        '48f772e76c034d8281f1cab1bc52f5d25597ad1c6ed44642780b5d7e94954471',
      );
      expect(headers['umString'], 'b4c89ca4104ea9a97750314d791520ac');
    });

    test('anonymous signature matches certificate-derived OpenSSL vector', () {
      expect(
        CopyApiProtocol.authSignature('1785328496'),
        '48f772e76c034d8281f1cab1bc52f5d25597ad1c6ed44642780b5d7e94954471',
      );
    });

    test(
      'anonymous profile has only empty authorization, never an account token',
      () {
        final headers = CopyApiProtocol.headers(
          identity: fixtureDeviceIdentity,
          now: DateTime.utc(2026, 7, 29, 12, 34, 56),
        );

        expect(headers['authorization'], 'Token ');
      },
    );

    test('encodes login password with the original per-request salt', () {
      expect(
        CopyApiProtocol.loginBody('member', 'secret', salt: 4321),
        <String, dynamic>{
          'username': 'member',
          'password': base64Encode(utf8.encode('secret-4321')),
          'salt': '4321',
        },
      );
    });

    test('login generates string salts in the original range', () {
      final salts = <String>{};
      for (var i = 0; i < 32; i++) {
        final body = CopyApiProtocol.loginBody('member', 'secret');
        final salt = body['salt'] as String;
        salts.add(salt);
        expect(int.parse(salt), inInclusiveRange(0, 9998));
        expect(body['password'], base64Encode(utf8.encode('secret-$salt')));
      }
      expect(salts.length, greaterThan(1));
      expect(
        () => CopyApiProtocol.loginBody('m', 'p', salt: 9999),
        throwsRangeError,
      );
      expect(
        () => CopyApiProtocol.loginBody('m', 'p', salt: -1),
        throwsRangeError,
      );
    });

    test(
      'defaults to overseas and switches route domain and region together',
      () {
        final client = CopyClient();

        expect(client.apiRoute, CopyApiRoute.overseas);
        expect(client.apiDomain, CopyApiRoute.overseas.primaryDomain);

        client.setApiRoute(CopyApiRoute.mainland);

        expect(client.apiRoute, CopyApiRoute.mainland);
        expect(client.apiDomain, CopyApiRoute.mainland.primaryDomain);
        expect(
          CopyApiProtocol.headers(
            identity: fixtureDeviceIdentity,
            region: client.apiRoute.region,
          )['region'],
          '0',
        );
      },
    );

    test(
      'keeps active original discovery domains and migrates retired ones',
      () {
        expect(
          CopyApiProtocol.normalizeDomain('https://api.copy202601.com/'),
          'api.copy202601.com',
        );
        expect(
          CopyApiProtocol.normalizeDomain('https://api.copy202602.com/'),
          'api.copy202602.com',
        );
        expect(
          CopyApiProtocol.normalizeDomain('https://api.copy-manga.com/'),
          CopyApiProtocol.defaultDomain,
        );
        expect(
          CopyApiProtocol.extractApiDomains(<String, dynamic>{
            'api': <Object>[
              <String>['https://node-a.example/path', 'node-b.example'],
              <String>['node-a.example'],
            ],
          }),
          <String>['node-a.example', 'node-b.example'],
        );
      },
    );
  });

  test('empty chapter lists fail over to a healthy node', () async {
    final adapter = _CopyApiAdapter();
    final dio = Dio()..httpClientAdapter = adapter;
    final client = (CopyClient(dio: dio)
      ..setDeviceIdentity(fixtureDeviceIdentity));

    final chapters = await client.groupChapters(
      comic: const Comic(
        uuid: 'comic-1',
        pathWord: 'demo',
        title: 'Demo',
        authors: 'Author',
      ),
      group: const ComicGroup(pathWord: 'default', name: '默认', count: 1),
    );

    expect(chapters.single.uuid, 'chapter-1');
    expect(adapter.groupHosts, <String>['node-a.example', 'node-b.example']);
    expect(client.apiDomain, 'node-b.example');
  });

  test('mainland route discovers the current original API node', () async {
    final adapter = _CopyApiAdapter();
    final dio = Dio()..httpClientAdapter = adapter;
    final client =
        (CopyClient(dio: dio)..setDeviceIdentity(fixtureDeviceIdentity))
          ..setApiRoute(CopyApiRoute.mainland);

    final results = await client.search('Demo');

    expect(results, hasLength(1));
    expect(client.apiDomain, 'api.copy202601.com');
    expect(client.apiUrl, 'https://api.copy202601.com');
    expect(client.discoveredApiDomains, <String>['api.copy202601.com']);
    expect(adapter.searchHosts, <String>['api.copy202601.com']);
  });

  test(
    'automatic route changes region and in_mainland with the actual node',
    () async {
      final adapter = _CopyApiAdapter(failOverseasDetails: true);
      final dio = Dio()..httpClientAdapter = adapter;
      final client =
          (CopyClient(dio: dio)..setDeviceIdentity(fixtureDeviceIdentity))
            ..setApiRoute(CopyApiRoute.automatic)
            // 固定首个候选以验证跨区节点参数，避免并行测试
            // 负载让毫秒级模拟测速偶发颠倒。自动选最低延迟由独立用例验证。
            ..setApiDomain('node-a.example');

      final details = await client.comicDetails('demo');

      expect(details.comic.uuid, 'comic-real-uuid');
      expect(client.apiDomain, 'api.copy202601.com');
      expect(adapter.detailHosts, <String>[
        'node-a.example',
        'api.copy202601.com',
      ]);
      expect(adapter.detailInMainlandValues, <Object?>[false, true]);
      expect(adapter.detailRegions, <String?>['1', '0']);
    },
  );

  test(
    'uses the lowest-latency node by default and allows manual lock',
    () async {
      final adapter = _CopyApiAdapter(nodeBIsFastest: true);
      final dio = Dio()..httpClientAdapter = adapter;
      final client = (CopyClient(dio: dio)
        ..setDeviceIdentity(fixtureDeviceIdentity));

      final nodes = await client.refreshApiDomains();

      expect(nodes.map((node) => node.domain), <String>[
        'node-b.example',
        'node-a.example',
      ]);
      expect(nodes.every((node) => node.latencyMs != null), isTrue);
      expect(client.apiDomain, 'node-b.example');
      expect(client.usesAutomaticApiDomain, isTrue);

      client.setApiDomain('node-a.example');
      await client.refreshApiDomains();
      expect(client.apiDomain, 'node-a.example');
      expect(client.usesAutomaticApiDomain, isFalse);

      client.useFastestApiDomain();
      expect(client.apiDomain, 'node-b.example');
      expect(client.usesAutomaticApiDomain, isTrue);
    },
  );

  test(
    'account API exposes domestic nodes and allows an independent lock',
    () async {
      final adapter = _CopyApiAdapter();
      final dio = Dio()..httpClientAdapter = adapter;
      final client = (CopyClient(dio: dio)
        ..setDeviceIdentity(fixtureDeviceIdentity));

      final nodes = await client.refreshAuthenticationDomains();

      expect(
        nodes.map((node) => node.domain),
        containsAll(<String>[
          'api.copy202601.com',
          'api.copy202602.com',
          'mapi.mangacopy.com',
        ]),
      );
      expect(client.usesAutomaticAuthenticationDomain, isTrue);

      client.setAuthenticationDomain('api.copy202602.com');
      expect(client.authenticationUrl, 'https://api.copy202602.com');
      expect(client.usesAutomaticAuthenticationDomain, isFalse);

      client.useFastestAuthenticationDomain();
      expect(client.authenticationUrl, 'https://api.copy202601.com');
      expect(client.usesAutomaticAuthenticationDomain, isTrue);
      final probeHeaders = adapter.authorizationFor(
        CopyApiProtocol.networkPath,
      );
      expect(probeHeaders, isNotEmpty);
      expect(probeHeaders, everyElement('Token '));
      expect(adapter.authorizationFor(CopyApiProtocol.searchPath), isEmpty);
    },
  );

  test(
    'saved ZIP and online reading share anonymous images even while signed in',
    () async {
      final adapter = _CopyApiAdapter(serveCurrentChapter: true);
      final client = CopyClient(dio: Dio()..httpClientAdapter = adapter)
        ..setDeviceIdentity(fixtureDeviceIdentity)
        ..setToken('fixture-member-token');
      final content = await client.chapterContent(
        comicPathWord: 'demo',
        chapterUuid: 'chapter-1',
      );
      expect(content.pageCount, 1);
      expect(adapter.chapterRequests, ['node-a.example/chapter2']);
      expect(adapter.authorizations, everyElement('Token '));
      expect(
        adapter.requests.any((r) => r.path.contains('chapter2download')),
        isFalse,
      );
    },
  );

  test('current chapter API returns images without a member token', () async {
    final adapter = _CopyApiAdapter(serveCurrentChapter: true);
    final dio = Dio()..httpClientAdapter = adapter;
    final client = (CopyClient(dio: dio)
      ..setDeviceIdentity(fixtureDeviceIdentity));

    final content = await client.chapterContent(
      comicPathWord: 'demo',
      chapterUuid: 'chapter-1',
    );

    expect(content.urls, <String>['https://img.example/current.jpg']);
    expect(adapter.chapterRequests, <String>['node-a.example/chapter2']);
    expect(adapter.platformValues, <Object?>[3]);
    expect(adapter.authorizations, everyElement('Token '));
  });

  test(
    'anonymous chapter request skips a node that incorrectly requires auth',
    () async {
      final adapter = _CopyApiAdapter(anonymousAuthFailureOnNodeA: true);
      final dio = Dio()..httpClientAdapter = adapter;
      final client = (CopyClient(dio: dio)
        ..setDeviceIdentity(fixtureDeviceIdentity));

      final content = await client.chapterContent(
        comicPathWord: 'demo',
        chapterUuid: 'chapter-1',
      );

      expect(content.urls, <String>[
        'https://img.example/1.jpg',
        'https://img.example/2.jpg',
      ]);
      expect(adapter.chapterRequests, contains('node-a.example/chapter2'));
      expect(adapter.chapterRequests, contains('node-b.example/chapter2'));
      expect(adapter.authorizations, everyElement('Token '));
    },
  );

  test('only member endpoints carry the stored login token', () async {
    final adapter = _CopyApiAdapter();
    final dio = Dio()..httpClientAdapter = adapter;
    final client = (CopyClient(
      dio: dio,
    )..setDeviceIdentity(fixtureDeviceIdentity))..setToken('member-token');

    await client.search('Demo');
    await client.profile();
    await client.imageBytes('https://img.example/cover.jpg');

    expect(
      adapter.authorizationFor(CopyApiProtocol.searchPath),
      everyElement('Token '),
    );
    expect(
      adapter.authorizationFor(CopyApiProtocol.profilePath),
      everyElement('Token member-token'),
    );
    expect(adapter.authorizationFor('/cover.jpg'), everyElement(isNull));
    final imageHeaderNames = adapter.imageRequest!.headers.keys
        .map((name) => name.toLowerCase())
        .toSet();
    expect(imageHeaderNames, isNot(contains('authorization')));
    expect(imageHeaderNames, isNot(contains('x-auth-signature')));
    expect(imageHeaderNames, isNot(contains('version')));
    expect(imageHeaderNames, isNot(contains('platform')));
    expect(imageHeaderNames, isNot(contains('region')));
    expect(
      adapter.authorizationFor(CopyApiProtocol.networkPath),
      everyElement('Token '),
    );
  });

  test('search path_word resolves to the matching real comic UUID', () async {
    final adapter = _CopyApiAdapter();
    final dio = Dio()..httpClientAdapter = adapter;
    final client = (CopyClient(dio: dio)
      ..setDeviceIdentity(fixtureDeviceIdentity));

    final searchResult = (await client.search('异世界叔叔')).single;
    expect(searchResult.uuid, isEmpty);
    expect(searchResult.pathWord, 'demo');

    final details = await client.comicDetails(searchResult.pathWord);

    expect(details.comic.uuid, 'comic-real-uuid');
    expect(details.comic.pathWord, searchResult.pathWord);
    expect(adapter.detailHosts, <String>['node-a.example', 'node-b.example']);
  });

  test(
    'server code 210 keeps its real message instead of claiming risk',
    () async {
      final adapter = _CopyApiAdapter();
      final dio = Dio()..httpClientAdapter = adapter;
      final client =
          (CopyClient(dio: dio)..setDeviceIdentity(fixtureDeviceIdentity))
            ..setToken('old-member-token');

      await expectLater(
        client.login('invalid-user', 'invalid-password'),
        throwsA(
          isA<CopyApiException>()
              .having((error) => error.code, 'code', 210)
              .having((error) => error.message, 'message', '錯誤的密碼.'),
        ),
      );
      expect(
        adapter.authorizationFor(CopyApiProtocol.loginPath),
        everyElement('Token '),
      );
      expect(adapter.loginHosts, <String>['api.copy202601.com']);
      final request = adapter.loginRequest!;
      expect(request.uri.host, 'api.copy202601.com');
      expect(request.contentType, Headers.formUrlEncodedContentType);
      expect(request.headers['version'], '3.0.9');
      expect(request.headers['platform'], '3');
      expect(request.headers['region'], '0');
      expect(request.headers['webp'], '1');
      expect(request.headers['source'], 'copyApp');
      expect(request.queryParameters['platform'], 3);
      expect(
        request.headers['X-Auth-Signature'],
        CopyRequestProtocol.signature(
          request.headers['X-Auth-Timestamp'],
          nativeMaterial: CopyRequestProtocol.certificateMd5,
        ),
      );
      expect(
        (request.data as Map).keys,
        containsAll(<String>[
          'username',
          'password',
          'salt',
          'tapString',
          'umString',
          'authorization',
          'version',
          'source',
        ]),
      );
    },
  );

  test(
    'login never replays credentials after an ambiguous network failure',
    () async {
      final adapter = _CopyApiAdapter(
        loginSucceeds: true,
        failPrimaryLoginTransport: true,
      );
      final dio = Dio()..httpClientAdapter = adapter;
      final client = (CopyClient(dio: dio)
        ..setDeviceIdentity(fixtureDeviceIdentity));

      await expectLater(
        client.login('member', 'secret'),
        throwsA(isA<CopyApiException>()),
      );
      expect(adapter.loginHosts, <String>['api.copy202601.com']);
      expect(client.hasToken, isFalse);
    },
  );

  test(
    'login only succeeds after the returned token passes profile check',
    () async {
      final adapter = _CopyApiAdapter(loginSucceeds: true);
      final dio = Dio()..httpClientAdapter = adapter;
      final client = (CopyClient(dio: dio)
        ..setDeviceIdentity(fixtureDeviceIdentity));

      final result = await client.login('member', 'secret');

      expect(result['token'], 'verified-member-token');
      expect(result['username'], 'verified-member');
      expect(client.hasToken, isTrue);
      expect(client.authenticationUrl, 'https://api.copy202601.com');
      await client.search('Demo');
      expect(client.apiDomain, 'node-a.example');
      expect(adapter.loginHosts, <String>['api.copy202601.com']);
      expect(adapter.profileHosts, <String>['api.copy202601.com']);
      expect(adapter.searchHosts, <String>['node-a.example']);
      expect(
        adapter.authorizationFor(CopyApiProtocol.profilePath),
        everyElement('Token verified-member-token'),
      );
    },
  );
}

final class _CopyApiAdapter implements HttpClientAdapter {
  _CopyApiAdapter({
    this.serveCurrentChapter = false,
    this.loginSucceeds = false,
    this.failPrimaryLoginTransport = false,
    this.failOverseasDetails = false,
    this.nodeBIsFastest = false,
    this.anonymousAuthFailureOnNodeA = false,
  });

  final bool serveCurrentChapter;
  final bool loginSucceeds;
  final bool failPrimaryLoginTransport;
  final bool failOverseasDetails;
  final bool nodeBIsFastest;
  final bool anonymousAuthFailureOnNodeA;
  final List<String> chapterRequests = <String>[];
  final List<String> groupHosts = <String>[];
  final List<String> detailHosts = <String>[];
  final List<Object?> detailInMainlandValues = <Object?>[];
  final List<String?> detailRegions = <String?>[];
  final List<String> loginHosts = <String>[];
  final List<String> profileHosts = <String>[];
  final List<String> searchHosts = <String>[];
  final List<Object?> inMainlandValues = <Object?>[];
  final List<Object?> platformValues = <Object?>[];
  final List<({String path, String? authorization})> requests =
      <({String path, String? authorization})>[];
  RequestOptions? loginRequest;
  RequestOptions? imageRequest;

  Iterable<String?> authorizationFor(String path) sync* {
    for (final request in requests) {
      if (request.path == path) yield request.authorization;
    }
  }

  Iterable<String?> get authorizations =>
      requests.map((request) => request.authorization);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final uri = options.uri;
    String? authorization;
    for (final entry in options.headers.entries) {
      if (entry.key.toLowerCase() == 'authorization') {
        authorization = entry.value?.toString();
        break;
      }
    }
    requests.add((path: uri.path, authorization: authorization));
    if (uri.host == 'img.example') imageRequest = options;
    if (uri.path == CopyApiProtocol.loginPath) {
      loginHosts.add(uri.host);
      loginRequest = options;
    }

    if (uri.path == CopyApiProtocol.networkPath) {
      final fast =
          uri.host.startsWith('api.copy') || uri.host == 'mapi.mangacopy.com'
          ? 'api.copy202601.com'
          : nodeBIsFastest
          ? 'node-b.example'
          : 'node-a.example';
      await Future<void>.delayed(
        Duration(
          milliseconds: uri.host == fast
              ? 2
              : uri.host == 'mapi.mangacopy.com'
              ? 45
              : 25,
        ),
      );

      if (uri.host == CopyApiRoute.mainland.primaryDomain) {
        return _json(<String, dynamic>{
          'code': 200,
          'results': <String, dynamic>{
            'in_mainland': true,
            'api': <List<String>>[
              <String>['api.copy202601.com'],
              <String>['api.copy202601.com'],
            ],
          },
        });
      }
      if (uri.host != CopyApiProtocol.defaultDomain) {
        return _json(<String, dynamic>{
          'code': 200,
          'results': <String, dynamic>{'api': <Object>[]},
        });
      }
      return _json(<String, dynamic>{
        'code': 200,
        'results': <String, dynamic>{
          'in_mainland': false,
          'api': <List<String>>[
            <String>['node-a.example', 'node-b.example'],
          ],
        },
      });
    }

    if (uri.path.endsWith('/chapters')) {
      groupHosts.add(uri.host);
      if (uri.host == 'node-a.example') {
        return _json(<String, dynamic>{
          'code': 200,
          'results': <String, dynamic>{'list': <Object>[], 'total': 1},
        });
      }
      if (uri.host == 'node-b.example') {
        return _json(<String, dynamic>{
          'code': 200,
          'results': <String, dynamic>{
            'list': <Object>[
              <String, dynamic>{
                'uuid': 'chapter-1',
                'name': '第1话',
                'ordered': 1,
                'size': 2,
              },
            ],
            'total': 1,
          },
        });
      }
      return _maintenance();
    }

    if (uri.path == CopyApiProtocol.searchPath) {
      searchHosts.add(uri.host);
      return _json(<String, dynamic>{
        'code': 200,
        'results': <String, dynamic>{
          'list': <Object>[
            <String, dynamic>{
              'name': 'Demo',
              'path_word': 'demo',
              'cover': 'https://img.example/cover.jpg',
              'author': <Object>[
                <String, dynamic>{'name': 'Author'},
              ],
            },
          ],
          'total': 1,
        },
      });
    }

    if (uri.path == CopyApiProtocol.comicDetailsPath('demo')) {
      detailHosts.add(uri.host);
      detailInMainlandValues.add(options.queryParameters['in_mainland']);
      detailRegions.add(options.headers['region']?.toString());
      if (uri.host == 'node-a.example') {
        return _json(<String, dynamic>{
          'code': 200,
          'results': <String, dynamic>{
            'comic': <String, dynamic>{
              'uuid': 'wrong-comic-uuid',
              'path_word': 'wrong-comic',
              'name': 'Wrong',
            },
            'groups': <String, dynamic>{},
          },
        });
      }
      if (uri.host == 'node-b.example') {
        if (failOverseasDetails) return _maintenance();
        return _json(<String, dynamic>{
          'code': 200,
          'results': <String, dynamic>{
            'comic': <String, dynamic>{
              'uuid': 'comic-real-uuid',
              'path_word': 'demo',
              'name': 'Demo',
            },
            'groups': <String, dynamic>{},
          },
        });
      }
      if (uri.host == 'api.copy202601.com') {
        return _json(<String, dynamic>{
          'code': 200,
          'results': <String, dynamic>{
            'comic': <String, dynamic>{
              'uuid': 'comic-real-uuid',
              'path_word': 'demo',
              'name': 'Demo',
            },
            'groups': <String, dynamic>{},
          },
        });
      }
      return _maintenance();
    }

    if (uri.path == CopyApiProtocol.profilePath) {
      profileHosts.add(uri.host);
      return _json(<String, dynamic>{
        'code': 200,
        'results': <String, dynamic>{
          'username': loginSucceeds ? 'verified-member' : 'member',
        },
      });
    }

    if (uri.path == CopyApiProtocol.loginPath) {
      if (failPrimaryLoginTransport && uri.host == 'api.copy202601.com') {
        return _maintenance();
      }
      if (loginSucceeds) {
        return _json(<String, dynamic>{
          'code': 200,
          'results': <String, dynamic>{
            'token': 'verified-member-token',
            'username': 'unverified-member',
          },
        });
      }
      return _json(<String, dynamic>{'code': 210, 'message': '錯誤的密碼.'});
    }

    if (uri.host == 'img.example') {
      return ResponseBody.fromBytes(
        <int>[0xff, 0xd8, 0xff, 0xd9],
        200,
        headers: <String, List<String>>{
          Headers.contentTypeHeader: <String>['image/jpeg'],
        },
      );
    }

    if (uri.path.contains('/chapter2/')) {
      chapterRequests.add('${uri.host}/chapter2');
      inMainlandValues.add(options.queryParameters['in_mainland']);
      platformValues.add(options.queryParameters['platform']);
      if (anonymousAuthFailureOnNodeA && uri.host == 'node-a.example') {
        return _json({'code': 401, 'message': '身份认证信息未提供。'}, status: 401);
      }
      return _json({
        'code': 200,
        'results': {
          'chapter': {
            'size': serveCurrentChapter ? 1 : 2,
            'contents': serveCurrentChapter
                ? [
                    {'url': 'https://img.example/current.jpg'},
                  ]
                : uri.host == 'node-b.example'
                ? [
                    {'url': 'https://img.example/1.jpg'},
                    'https://img.example/2.jpg',
                  ]
                : [],
          },
        },
      });
    }

    return _maintenance();
  }

  ResponseBody _json(Map<String, dynamic> value, {int status = 200}) {
    return ResponseBody.fromString(
      jsonEncode(value),
      status,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>['application/json'],
      },
    );
  }

  ResponseBody _maintenance() {
    return ResponseBody.fromString(
      '<html>maintenance</html>',
      404,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>['text/html'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
