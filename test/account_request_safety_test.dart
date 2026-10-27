import 'fixtures/copy_request_identity.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:copymanga_reader/services/copy_request_protocol.dart';
import 'package:copymanga_reader/services/copy_api_protocol.dart';
import 'package:copymanga_reader/services/copy_api_transport.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

class AccountAdapter implements HttpClientAdapter {
  final calls = <RequestOptions>[];
  final bodies = <String, String>{};
  int status = 200;
  int? code;
  String message = '';
  String? retryAfter;
  bool timeout = false;
  bool nonJson = false;
  int active = 0, maxActive = 0;
  Completer<void>? hold;
  final entered = Completer<void>();
  final starts = <DateTime>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancelFuture,
  ) async {
    final path = options.uri.path;
    final account =
        path.contains('/member/') || path == CopyApiProtocol.loginPath;
    if (!account) {
      expect(options.headers['authorization'], 'Token ');
      return json({
        'code': 200,
        'results': {'list': [], 'api': []},
      });
    }
    calls.add(options);
    if (stream != null) {
      bodies[path] = utf8.decode(
        await stream.expand((bytes) => bytes).toList(),
      );
    }
    starts.add(DateTime.now());
    active++;
    if (active > maxActive) maxActive = active;
    if (!entered.isCompleted) entered.complete();
    try {
      if (hold != null) await hold!.future;
      if (timeout) {
        throw DioException(
          requestOptions: options,
          type: DioExceptionType.receiveTimeout,
        );
      }
      if (nonJson) {
        return ResponseBody.fromString('<html>unavailable</html>', status);
      }
      return json(
        {
          'code': code ?? status,
          'message': message,
          'results': {'list': [], 'total': 0},
        },
        status: status,
        retryAfter: retryAfter,
      );
    } finally {
      active--;
    }
  }

  static ResponseBody json(
    Object body, {
    int status = 200,
    String? retryAfter,
  }) => ResponseBody.fromString(
    jsonEncode(body),
    status,
    headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
      if (retryAfter != null) 'retry-after': [retryAfter],
    },
  );

  @override
  void close({bool force = false}) {}
}

void main() {
  late AccountAdapter adapter;
  late CopyApiTransport transport;
  setUp(() {
    adapter = AccountAdapter();
    transport =
        CopyApiTransport(
            dio: Dio()..httpClientAdapter = adapter,
            accountRequestInterval: Duration.zero,
          )
          ..setDeviceIdentity(fixtureDeviceIdentity)
          ..setAuthenticationDomain('account.example')
          ..setToken('fixture-token');
  });

  test(
    'APK certificate-derived signatures match independent OpenSSL vectors',
    () {
      expect(
        CopyRequestProtocol.umString(CopyRequestProtocol.certificateMd5),
        'b4c89ca4104ea9a97750314d791520ac',
      );
      expect(
        CopyRequestProtocol.signature(
          '1785328496',
          nativeMaterial: CopyRequestProtocol.certificateMd5,
        ),
        '48f772e76c034d8281f1cab1bc52f5d25597ad1c6ed44642780b5d7e94954471',
      );
      expect(
        CopyRequestProtocol.startupDate(DateTime(2026, 10, 27, 20, 30)),
        DateTime.utc(2026, 10, 28, 4, 30),
      );
    },
  );

  test(
    'login uses recovered headers and form extras without the existing token',
    () async {
      final data = CopyApiProtocol.loginBody(
        'fixture-user',
        'fixture-password',
        salt: 4321,
      );
      await transport.requestResults(
        CopyApiProtocol.loginPath,
        method: 'POST',
        data: data,
        formEncoded: true,
      );
      final request = adapter.calls.single;
      final body = Uri.splitQueryString(
        adapter.bodies[CopyApiProtocol.loginPath]!,
      );
      expect(
        body['password'],
        base64Encode(utf8.encode('fixture-password-4321')),
      );
      expect(body['salt'], '4321');
      expect(body['authorization'], 'Token ');
      expect(request.headers['authorization'], 'Token ');
      expect(body['tapString'], CopyRequestProtocol.certificateMd5);
      expect(body['umString'], 'b4c89ca4104ea9a97750314d791520ac');
      expect(body['version'], '3.0.9');
      expect(body['source'], 'copyApp');
      expect(body['webp'], '1');
      expect(body['isGoogle'], 'false');
      expect(body['region'], '0');
      expect(body['dt'], isNotEmpty);
      expect(body.values, isNot(contains('fixture-token')));
      expect(data.keys, ['username', 'password', 'salt']);
    },
  );

  Future<dynamic> read([String path = CopyApiProtocol.profilePath]) =>
      transport.requestResults(path, authenticated: true);
  Future<dynamic> write() => transport.requestResults(
    CopyApiProtocol.novelCollectPath,
    method: 'POST',
    authenticated: true,
    formEncoded: true,
    data: {'book_id': 'fixture-book', 'is_collect': 1},
  );

  test(
    'account requests serialize, identical GETs coalesce, content stays anonymous',
    () async {
      adapter.hold = Completer<void>();
      final a = read();
      final duplicate = read();
      final b = read(CopyApiProtocol.novelFavoritesPath);
      await adapter.entered.future;
      expect(identical(a, duplicate), isTrue);
      expect(adapter.calls, hasLength(1));
      await transport.requestResults(CopyApiProtocol.searchPath);
      adapter.hold!.complete();
      await Future.wait([a, duplicate, b]);
      expect(adapter.maxActive, 1);
      expect(adapter.calls, hasLength(2));
      expect(adapter.calls.map((r) => r.headers['region']), everyElement('0'));
      expect(adapter.calls.every((r) => !r.followRedirects), isTrue);
    },
  );

  test(
    'production account lane enforces a gap between completed requests',
    () async {
      transport =
          CopyApiTransport(
              dio: Dio()..httpClientAdapter = adapter,
              accountRequestInterval: const Duration(milliseconds: 30),
            )
            ..setDeviceIdentity(fixtureDeviceIdentity)
            ..setAuthenticationDomain('account.example')
            ..setToken('fixture-token');
      await read();
      await read(CopyApiProtocol.novelFavoritesPath);
      expect(
        adapter.starts[1].difference(adapter.starts[0]).inMilliseconds,
        greaterThanOrEqualTo(30),
      );
    },
  );

  for (final failure in ['timeout', 'invalid-json', '404', '503', '302']) {
    test('favorite $failure is not replayed on another node', () async {
      adapter.timeout = failure == 'timeout';
      adapter.nonJson = failure == 'invalid-json';
      adapter.status = int.tryParse(failure) ?? 200;
      await expectLater(write(), throwsA(isA<CopyApiException>()));
      expect(adapter.calls, hasLength(1));
      expect(adapter.calls.single.uri.host, 'account.example');
    });
  }

  test(
    'explicit account restriction stops queued reads and writes, not content',
    () async {
      adapter.code = 210;
      adapter.message = '账号已被限制，请登录原版应用解除限制';
      final a = read();
      final b = write();
      final restricted = throwsA(
        isA<CopyApiException>().having(
          (e) => e.accountRestricted,
          'restricted',
          isTrue,
        ),
      );
      await Future.wait([
        expectLater(a, restricted),
        expectLater(b, restricted),
      ]);
      expect(adapter.calls, hasLength(1));
      await transport.requestResults(CopyApiProtocol.searchPath);
      expect(adapter.calls, hasLength(1));
    },
  );

  test(
    'HTTP and business 429 obey Retry-After without extending on local failures',
    () async {
      adapter.code = 429;
      adapter.message = 'too many requests';
      adapter.retryAfter = '120';
      await expectLater(
        read(),
        throwsA(
          isA<CopyApiException>().having(
            (e) => e.retryAfter,
            'retry',
            const Duration(seconds: 120),
          ),
        ),
      );
      adapter.code = 200;
      await expectLater(
        write(),
        throwsA(isA<CopyApiException>().having((e) => e.code, 'status', 429)),
      );
      expect(adapter.calls, hasLength(1));
    },
  );

  test('HTTP date Retry-After and non-JSON 429 are respected', () async {
    adapter.status = 429;
    adapter.retryAfter = HttpDate.format(
      DateTime.now().add(const Duration(minutes: 2)),
    );
    await expectLater(
      read(),
      throwsA(
        isA<CopyApiException>().having(
          (e) => e.retryAfter!.inSeconds,
          'seconds',
          inInclusiveRange(118, 120),
        ),
      ),
    );
    adapter.nonJson = true;
    await expectLater(write(), throwsA(isA<CopyApiException>()));
    expect(adapter.calls, hasLength(1));
  });

  test(
    'wrong password is not labelled restricted, and does not poison the lane',
    () async {
      adapter.code = 210;
      adapter.message = '錯誤的密碼.';
      await expectLater(
        read(),
        throwsA(
          isA<CopyApiException>().having(
            (e) => e.accountRestricted,
            'restricted',
            isFalse,
          ),
        ),
      );
      adapter.code = 200;
      await read();
      expect(adapter.calls, hasLength(2));
    },
  );

  test(
    'queued account operation cannot migrate to another user token',
    () async {
      adapter.hold = Completer<void>();
      final a = read();
      await adapter.entered.future;
      final b = write();
      final cancelled = expectLater(
        b,
        throwsA(
          isA<CopyApiException>().having(
            (e) => e.message,
            'message',
            contains('账号已切换'),
          ),
        ),
      );
      transport.setToken('different-user-token');
      adapter.hold!.complete();
      await a;
      await cancelled;
      expect(adapter.calls, hasLength(1));
    },
  );

  test(
    'offline recovered transforms use native material, not timestamp as key',
    () {
      const material = 'offline-fixture-key';
      expect(
        CopyRequestProtocol.signature('1785328496', nativeMaterial: material),
        'bace332f45807b786f27974fdbead991a0be7cc45a450179d93411e706a501cd',
      );
      expect(
        CopyRequestProtocol.umString(material),
        '4015ce0c7902256bd7d3a9f6a38de4eb',
      );
      expect(
        () => CopyRequestProtocol.signature('1785328496', nativeMaterial: ''),
        throwsArgumentError,
      );
      final common = <String, dynamic>{
        'platform': '3',
        'version': '3.0.0',
        'authorization': 'Token ',
        'androidId': 'fixture-id',
        'userAgent': 'COPY/3.0.9',
        'dt': DateTime(2026, 10, 27),
        'tapString': material,
      };
      final data = {'username': 'fixture-user', 'platform': 'old'};
      final form = CopyRequestProtocol.formBody(
        data: data,
        commonParameters: common,
      );
      expect(form['platform'], '3');
      expect(data['platform'], 'old');
      expect(common, isNot(contains('username')));
      final headers = CopyRequestProtocol.headers(
        commonParameters: common,
        nativeMaterial: material,
        now: DateTime.utc(2026, 7, 29, 12, 34, 56),
      );
      expect(headers['device'], 'fixture-id');
      expect(headers['dt'], '2026.10.27');
      expect(headers['User-Agent'], 'COPY/3.0.9');
      expect(
        headers['X-Auth-Signature'],
        'bace332f45807b786f27974fdbead991a0be7cc45a450179d93411e706a501cd',
      );
      expect(headers, isNot(contains('tapString')));
    },
  );
}
