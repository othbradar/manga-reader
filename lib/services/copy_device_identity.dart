import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

import 'copy_api_protocol.dart';

/// 读取当前设备身份，仅用于生成与原版客户端一致的设备请求头。
final class CopyDeviceIdentityService {
  CopyDeviceIdentityService._();

  static const MethodChannel _channel = MethodChannel(
    'com.othbradar.copymangareader/device_identity',
  );

  static Future<CopyDeviceIdentity> load() async {
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
      final digest = sha256.convert(utf8.encode(platformId)).toString();
      return CopyDeviceIdentity(
        device: device,
        deviceInfo: deviceInfo,
        androidId: platformId,
        pseudoId: digest.substring(0, 16),
      );
    } on PlatformException {
      return CopyDeviceIdentity.fallback;
    } on MissingPluginException {
      return CopyDeviceIdentity.fallback;
    }
  }
}
