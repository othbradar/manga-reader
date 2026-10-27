import 'dart:math';

import 'package:flutter/services.dart';
import 'package:sqflite/sqflite.dart';

import 'copy_api_protocol.dart';
import 'local_app_database.dart';

/// 读取当前设备身份，仅用于生成与原版客户端一致的设备请求头。
final class CopyDeviceIdentityService {
  CopyDeviceIdentityService._();

  static const MethodChannel _channel = MethodChannel(
    'com.othbradar.copymangareader/device_identity',
  );

  static Future<CopyDeviceIdentity> load(LocalAppDatabase database) async {
    final pseudoId = await _installationPseudoId(database);
    try {
      final values = await _channel.invokeMapMethod<String, dynamic>(
        'getDeviceIdentity',
      );
      final device = values?['device']?.toString().trim() ?? '';
      final deviceInfo = values?['deviceInfo']?.toString().trim() ?? '';
      final platformId = values?['platformId']?.toString().trim() ?? '';
      if (device.isEmpty || deviceInfo.isEmpty || platformId.isEmpty) {
        return CopyDeviceIdentity.fallback;
      }
      return CopyDeviceIdentity(
        device: device,
        deviceInfo: deviceInfo,
        androidId: platformId,
        pseudoId: pseudoId,
      );
    } on PlatformException {
      return CopyDeviceIdentity.fallback;
    } on MissingPluginException {
      return CopyDeviceIdentity.fallback;
    }
  }

  static Future<String> _installationPseudoId(
    LocalAppDatabase database,
  ) => database.database.transaction((txn) async {
    final rows = await txn.query(
      'device_identity',
      where: 'identity_key = ?',
      whereArgs: ['copy_pseudo_id'],
      limit: 1,
    );
    final saved = rows.isEmpty ? '' : rows.first['identity_value'].toString();
    if (RegExp(r'^[0-9a-zA-Z]{16}$').hasMatch(saved)) return saved;
    // APK a0eecc: own install-local random ID, 16 characters from base62.
    // Do not derive it from ANDROID_ID or copy the official app's ID.
    const alphabet =
        '0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ';
    final random = Random.secure();
    final id = List.generate(16, (_) => alphabet[random.nextInt(62)]).join();
    await txn.insert('device_identity', {
      'identity_key': 'copy_pseudo_id',
      'identity_value': id,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    return id;
  });
}
