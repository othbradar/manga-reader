import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:copymanga_reader/services/copy_api_protocol.dart';
import 'package:copymanga_reader/services/copy_api_transport.dart';
import 'fixtures/copy_request_identity.dart';

class RenewalAdapter implements HttpClientAdapter {
  final calls = <RequestOptions>[];
  int loginCount = 0;
  int? failureStatus;
  String failureMessage = '';
  bool timeout = false, rejectRenewed = false, sameToken = false;
  Completer<void>? loginHold;
  String get newToken => sameToken ? 'old-fixture' : 'renewed-fixture';
  @override
  Future<ResponseBody> fetch(
    RequestOptions r,
    Stream<Uint8List>? body,
    Future<void>? cancel,
  ) async {
    if (r.path.contains('network2')) return json({'api': []});
    calls.add(r);
    if (r.uri.path == CopyApiProtocol.loginPath) {
      loginCount++;
      if (loginHold != null) await loginHold!.future;
      expect(r.headers['authorization'], 'Token ');
      return json({'token': newToken});
    }
    if (!CopyApiProtocol.requiresAuthentication(r.uri.path)) {
      expect(r.headers['authorization'], 'Token ');
      return json({'list': [], 'total': 0});
    }
    if (timeout) {
      throw DioException(
        requestOptions: r,
        type: DioExceptionType.receiveTimeout,
      );
    }
    if (failureStatus != null) {
      return json({}, status: failureStatus!, message: failureMessage);
    }
    if (!rejectRenewed &&
        loginCount > 0 &&
        r.headers['authorization'] == 'Token $newToken') {
      return json({'username': 'fixture-user', 'list': [], 'total': 0});
    }
    return json({}, status: 401);
  }

  ResponseBody json(Object results, {int status = 200, String message = ''}) =>
      ResponseBody.fromString(
        jsonEncode({'code': status, 'message': message, 'results': results}),
        status,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
  @override
  void close({bool force = false}) {}
}

void main() {
  late RenewalAdapter adapter;
  late CopyApiTransport transport;
  late int attempts;
  setUp(() {
    attempts = 0;
    adapter = RenewalAdapter();
    transport =
        CopyApiTransport(
            dio: Dio()..httpClientAdapter = adapter,
            accountRequestInterval: Duration.zero,
          )
          ..setDeviceIdentity(fixtureDeviceIdentity)
          ..setAuthenticationDomain('account.example')
          ..setToken('old-fixture');
    transport.renewExpiredSession = () async {
      attempts++;
      final result =
          await transport.requestResults(
                CopyApiProtocol.loginPath,
                method: 'POST',
                formEncoded: true,
                data: CopyApiProtocol.loginBody(
                  'fixture-user',
                  'fixture-password',
                ),
              )
              as Map;
      final token = result['token'] as String;
      final profile =
          await transport.requestResults(
                CopyApiProtocol.profilePath,
                authenticated: true,
                candidateToken: token,
              )
              as Map;
      expect(profile['username'], 'fixture-user');
      transport.installRenewedToken(token);
      return true;
    };
  });
  Future<dynamic> read([String path = CopyApiProtocol.favoritesPath]) =>
      transport.requestResults(path, authenticated: true);
  test(
    'expired GET renews via serialized login/profile then retries once without deadlock',
    () async {
      final revision = transport.sessionRevision;
      await read().timeout(const Duration(seconds: 3));
      expect(attempts, 1);
      expect(adapter.loginCount, 1);
      expect(transport.sessionRevision, revision);
      expect(
        adapter.calls.last.headers['authorization'],
        'Token renewed-fixture',
      );
      expect(
        adapter.calls.every((r) => r.uri.host == 'account.example'),
        isTrue,
      );
    },
  );
  test(
    'comic/novel concurrent expiration shares one renewal and identical GETs coalesce',
    () async {
      adapter.loginHold = Completer<void>();
      final a = read();
      final duplicate = read();
      final b = read(CopyApiProtocol.novelFavoritesPath);
      expect(identical(a, duplicate), isTrue);
      for (var i = 0; i < 100 && adapter.loginCount == 0; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      expect(adapter.loginCount, 1);
      adapter.loginHold!.complete();
      await Future.wait([a, duplicate, b]).timeout(const Duration(seconds: 3));
      expect(attempts, 1);
      expect(adapter.loginCount, 1);
    },
  );
  test(
    'successful reauthentication may return the same opaque token',
    () async {
      adapter.sameToken = true;
      await read();
      expect(attempts, 1);
      expect(adapter.loginCount, 1);
    },
  );
  test('a favorite POST is never replayed after renewal', () async {
    await expectLater(
      transport.requestResults(
        CopyApiProtocol.comicCollectPath,
        method: 'POST',
        authenticated: true,
        formEncoded: true,
        data: {'comic_id': 'fixture-id', 'is_collect': 1},
      ),
      throwsA(
        isA<CopyApiException>().having(
          (e) => e.message,
          'message',
          contains('登录已自动续期'),
        ),
      ),
    );
    expect(
      adapter.calls.where(
        (r) => r.uri.path == CopyApiProtocol.comicCollectPath,
      ),
      hasLength(1),
    );
    expect(adapter.loginCount, 1);
  });
  for (final code in [403, 429, 503]) {
    test('$code never triggers saved-password login', () async {
      adapter.failureStatus = code;
      await expectLater(read(), throwsA(isA<CopyApiException>()));
      expect(attempts, 0);
      expect(adapter.loginCount, 0);
    });
  }
  test(
    'network error, anonymous request and account restriction never renew',
    () async {
      adapter.timeout = true;
      await expectLater(read(), throwsA(isA<CopyApiException>()));
      expect(attempts, 0);
      await transport.requestResults(CopyApiProtocol.searchPath);
      expect(attempts, 0);
      adapter.timeout = false;
      adapter.failureStatus = 401;
      adapter.failureMessage = '账号已被限制，请解封';
      await expectLater(
        read(),
        throwsA(
          isA<CopyApiException>().having(
            (e) => e.accountRestricted,
            'restricted',
            isTrue,
          ),
        ),
      );
      expect(attempts, 0);
    },
  );
  test('missing saved password attempts callback once, never loops', () async {
    transport.renewExpiredSession = () async {
      attempts++;
      return false;
    };
    await expectLater(read(), throwsA(isA<CopyApiException>()));
    await expectLater(read(), throwsA(isA<CopyApiException>()));
    expect(attempts, 1);
    expect(adapter.loginCount, 0);
  });
  test('failed candidate profile does not recursively re-login', () async {
    adapter.rejectRenewed = true;
    await expectLater(read(), throwsA(isA<CopyApiException>()));
    await expectLater(read(), throwsA(isA<CopyApiException>()));
    expect(attempts, 1);
    expect(adapter.loginCount, 1);
  });
  test(
    'candidate token cannot be used for favorites or anonymous content',
    () async {
      await expectLater(
        transport.requestResults(
          CopyApiProtocol.favoritesPath,
          authenticated: true,
          candidateToken: 'candidate',
        ),
        throwsA(isA<CopyApiException>()),
      );
      await expectLater(
        transport.requestResults(
          CopyApiProtocol.searchPath,
          candidateToken: 'candidate',
        ),
        throwsA(isA<CopyApiException>()),
      );
      expect(adapter.calls, isEmpty);
    },
  );
}
