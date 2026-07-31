class AsyncRetryException implements Exception {
  const AsyncRetryException({
    required this.attempts,
    required this.cause,
    required this.cancelled,
  });

  final int attempts;
  final Object? cause;
  final bool cancelled;

  @override
  String toString() {
    if (cancelled) return '操作已停止';
    return '尝试 $attempts 次仍失败：$cause';
  }
}

Future<T> retryAsync<T>(
  Future<T> Function() operation, {
  int maxAttempts = 3,
  Duration baseDelay = const Duration(milliseconds: 500),
  bool Function()? shouldContinue,
}) async {
  if (maxAttempts < 1) {
    throw ArgumentError.value(maxAttempts, 'maxAttempts', '必须至少尝试一次');
  }
  Object? lastError;
  var attempts = 0;
  for (var attempt = 1; attempt <= maxAttempts; attempt++) {
    if (shouldContinue != null && !shouldContinue()) {
      throw AsyncRetryException(
        attempts: attempts,
        cause: lastError,
        cancelled: true,
      );
    }
    attempts = attempt;
    try {
      return await operation();
    } catch (exception) {
      lastError = exception;
      if (attempt < maxAttempts) {
        final delay = Duration(
          microseconds: baseDelay.inMicroseconds * attempt,
        );
        if (delay > Duration.zero) await Future<void>.delayed(delay);
      }
    }
  }
  throw AsyncRetryException(
    attempts: attempts,
    cause: lastError,
    cancelled: false,
  );
}
