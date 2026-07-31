import 'package:copymanga_reader/core/async_retry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('失败操作自动重试三次后成功', () async {
    var attempts = 0;

    final result = await retryAsync(() async {
      attempts++;
      if (attempts < 3) throw StateError('暂时失败');
      return '成功';
    }, baseDelay: Duration.zero);

    expect(result, '成功');
    expect(attempts, 3);
  });

  test('三次都失败时保留尝试次数和最后错误', () async {
    var attempts = 0;

    await expectLater(
      retryAsync<void>(() async {
        attempts++;
        throw StateError('持续失败');
      }, baseDelay: Duration.zero),
      throwsA(
        isA<AsyncRetryException>()
            .having((error) => error.attempts, 'attempts', 3)
            .having((error) => error.cancelled, 'cancelled', isFalse)
            .having(
              (error) => error.cause.toString(),
              'cause',
              contains('持续失败'),
            ),
      ),
    );
    expect(attempts, 3);
  });
}
