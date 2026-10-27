import 'fixtures/copy_request_identity.dart';
import 'dart:convert';
import 'dart:typed_data';
import 'package:copymanga_reader/models/novel.dart';
import 'package:copymanga_reader/services/copy_api_protocol.dart';
import 'package:copymanga_reader/services/copy_api_transport.dart';
import 'package:copymanga_reader/services/copy_novel_client.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

class Adapter implements HttpClientAdapter {
  final calls = <RequestOptions>[];
  bool repeatPages = false;
  int collectStatus = 200;
  final book = {
    'uuid': 'book-uuid',
    'path_word': 'book-one',
    'name': '测试小说',
    'author': [
      {'name': '作者'},
    ],
  };
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancelFuture,
  ) async {
    calls.add(options);
    final path = options.uri.path;
    if (path == CopyApiProtocol.novelCollectPath && collectStatus != 200) {
      return ResponseBody.fromString(
        '{"message":"service unavailable"}',
        collectStatus,
      );
    }
    dynamic result = {};
    if (path == CopyApiProtocol.novelSearchPath ||
        path == CopyApiProtocol.novelFavoritesPath) {
      result = {
        'list': [
          path == CopyApiProtocol.novelFavoritesPath ? {'book': book} : book,
        ],
        'total': 1,
      };
    } else if (path.endsWith('/volumes')) {
      result = {
        'list': [
          {'id': 123, 'name': '第一卷', 'sort': 10, 'book_path_word': 'book-one'},
        ],
        'total': repeatPages ? 3 : 1,
      };
    } else if (path.endsWith('/volume/123')) {
      result = {
        'volume': {
          'id': 123,
          'name': '第一卷',
          'book_path_word': 'book-one',
          'txt_addr': 'https://cdn.example/text.txt',
          'txt_encoding': 'UTF-8',
          'contents': [
            {
              'content_type': 1,
              'name': '第一章',
              'start_lines': 12,
              'end_lines': 50,
            },
          ],
        },
      };
    } else if (path.endsWith('/book/book-one')) {
      result = {'book': book};
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

void main() {
  late Adapter adapter;
  late CopyNovelClient client;
  setUp(() {
    adapter = Adapter();
    final dio = Dio()..httpClientAdapter = adapter;
    final transport = CopyApiTransport(dio: dio)
      ..setApiDomain('content.example')
      ..setDeviceIdentity(fixtureDeviceIdentity)
      ..setAuthenticationDomain('account.example')
      ..setToken('test-token');
    client = CopyNovelClient(transport, null);
  });
  test('小说搜索详情分卷和正文使用原版未登录签名，不携带登录token', () async {
    final result = await client.search('小说');
    final book = await client.details(result.single.pathWord);
    final volumes = await client.volumes(book);
    final content = await client.content(book, volumes.single);
    expect(book.uuid, 'book-uuid');
    expect(content.id, '123');
    expect(content.sections.single.start, 12);
    for (final c in adapter.calls) {
      expect(c.headers['authorization'], 'Token ');
      expect(c.headers['X-Auth-Signature'], isNotEmpty);
    }
  });
  test('小说收藏只使用账号节点与token，收藏表单与漫画接口分离', () async {
    final favorites = await client.favorites();
    final book = favorites.single;
    await client.setFavorite(book, true);
    final request = adapter.calls.last;
    expect(request.uri.host, 'account.example');
    expect(request.uri.path, CopyApiProtocol.novelCollectPath);
    expect(request.headers['authorization'], 'Token test-token');
    expect(request.contentType, Headers.formUrlEncodedContentType);
    expect(request.data['book_id'], 'book-uuid');
    expect(request.data['is_collect'], 1);
    expect(request.data['authorization'], request.headers['authorization']);
    expect(request.data['source'], 'copyApp');
    expect(request.data['version'], '3.0.9');
  });
  test('重复分页不被当作完整目录；本地小说不能错误收藏到上游', () async {
    adapter.repeatPages = true;
    const book = Novel(
      uuid: 'book-uuid',
      pathWord: 'book-one',
      title: '小说',
      authors: '作者',
    );
    await expectLater(client.volumes(book), throwsA(isA<CopyApiException>()));
    await expectLater(
      client.setFavorite(
        const Novel(
          uuid: 'local-novel-1',
          pathWord: 'local-novel-1',
          title: '旧藏',
          authors: '作者',
        ),
        true,
      ),
      throwsA(isA<CopyApiException>()),
    );
  });
  test('收藏服务故障保留状态码，不跨节点重复执行写操作', () async {
    adapter.collectStatus = 503;
    final book = Novel.fromApi(adapter.book);
    await expectLater(
      client.setFavorite(book, true),
      throwsA(isA<CopyApiException>().having((e) => e.code, 'status', 503)),
    );
    // Node discovery uses anonymous GETs; only count the favorite mutation.
    final mutations = adapter.calls.where(
      (request) => request.uri.path == CopyApiProtocol.novelCollectPath,
    );
    expect(mutations, hasLength(1));
    expect(mutations.single.method, 'POST');
    expect(mutations.single.uri.host, 'account.example');
  });
}
