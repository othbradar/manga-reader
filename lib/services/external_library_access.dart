import 'dart:io';

import 'package:flutter/services.dart';

/// Bridges the system directory picker and persistent directory authorization.
///
/// iOS and macOS keep a security-scoped bookmark for the selected Files
/// location. Android keeps the persisted document-tree grant and resolves
/// removable-volume URIs to their direct filesystem path so SQLite and ZIP
/// readers can use normal file APIs.
class ExternalLibraryAccess {
  const ExternalLibraryAccess();

  static const MethodChannel _channel = MethodChannel(
    'com.othbradar.copymangareader/external_library',
  );

  bool get isSupported =>
      Platform.isIOS || Platform.isAndroid || Platform.isMacOS;

  Future<String?> pickDirectory() async {
    if (!isSupported) return null;
    return _channel.invokeMethod<String>('pickLibraryDirectory');
  }

  Future<String?> restoreDirectoryAccess() async {
    if (!isSupported) return null;
    return _channel.invokeMethod<String>('restoreLibraryDirectoryAccess');
  }

  Future<void> releaseDirectoryAccess() async {
    if (!isSupported) return;
    await _channel.invokeMethod<void>('releaseLibraryDirectoryAccess');
  }
}
