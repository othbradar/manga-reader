import 'dart:async';
import 'dart:collection';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

typedef _InfoNative =
    Int32 Function(
      Pointer<Utf8>,
      Pointer<Uint32>,
      Pointer<Uint32>,
      Pointer<Utf8>,
      Size,
    );
typedef _InfoDart =
    int Function(
      Pointer<Utf8>,
      Pointer<Uint32>,
      Pointer<Uint32>,
      Pointer<Utf8>,
      int,
    );
typedef _ConvertNative =
    Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Size);
typedef _ConvertDart =
    int Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, int);

/// Android's system/Flutter image codecs do not decode JPEG XL. Native libjxl
/// works only on private extracted files, never on library ZIPs or indexes.
abstract final class JxlCodec {
  static int _running = 0;
  static final _waiting = Queue<Completer<void>>();

  static bool requiresConversion(String path) =>
      p.extension(path).toLowerCase() == '.jxl' &&
      (Platform.isAndroid ||
          Platform.environment.containsKey('COPYMANGA_JXL_LIBRARY'));

  static Future<T> _worker<T>(Future<T> Function() operation) async {
    if (_running >= 2) {
      final ready = Completer<void>();
      _waiting.add(ready);
      await ready.future;
    } else {
      _running++;
    }
    try {
      return await operation();
    } finally {
      if (_waiting.isEmpty) {
        _running--;
      } else {
        _waiting.removeFirst().complete();
      }
    }
  }

  static Future<double> aspectRatio(String path) =>
      _worker(() => Isolate.run(() => _NativeJxl.instance.aspectRatio(path)));

  /// [outputBase] must be in the book's temporary directory. A partially
  /// decoded file is never returned or displayed; failed conversions retry.
  static Future<String> prepare(String input, String outputBase) => _worker(
    () => Isolate.run(() => _NativeJxl.instance.convert(input, outputBase)),
  );
}

class _NativeJxl {
  _NativeJxl() {
    final library = DynamicLibrary.open(
      Platform.environment['COPYMANGA_JXL_LIBRARY'] ?? 'libreader_jxl.so',
    );
    _info = library.lookupFunction<_InfoNative, _InfoDart>('reader_jxl_info');
    _convert = library.lookupFunction<_ConvertNative, _ConvertDart>(
      'reader_jxl_convert',
    );
  }

  static final instance = _NativeJxl();
  late final _InfoDart _info;
  late final _ConvertDart _convert;
  static const _errorSize = 512;

  double aspectRatio(String path) => using((arena) {
    final width = arena<Uint32>();
    final height = arena<Uint32>();
    final error = arena<Uint8>(_errorSize).cast<Utf8>();
    final status = _info(
      path.toNativeUtf8(allocator: arena),
      width,
      height,
      error,
      _errorSize,
    );
    if (status != 1) {
      throw FormatException('JXL 图片读取失败：${error.toDartString()}');
    }
    return width.value / height.value;
  });

  String convert(String input, String outputBase) {
    final partial = File('$outputBase.part');
    try {
      final kind = using((arena) {
        final error = arena<Uint8>(_errorSize).cast<Utf8>();
        final status = _convert(
          input.toNativeUtf8(allocator: arena),
          partial.path.toNativeUtf8(allocator: arena),
          error,
          _errorSize,
        );
        if (status < 1) {
          throw FormatException('JXL 图片解码失败：${error.toDartString()}');
        }
        return status;
      });
      if (!partial.existsSync() || partial.lengthSync() == 0) {
        throw const FormatException('JXL 解码结果为空');
      }
      final result = '$outputBase.${kind == 1 ? 'jpg' : 'png'}';
      partial.renameSync(result);
      return result;
    } finally {
      if (partial.existsSync()) partial.deleteSync();
    }
  }
}
