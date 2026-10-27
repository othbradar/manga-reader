import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'copy_device_identity_model.dart';

/// Offline-recovered APK 3.0.9 normal API request transformations.
///
/// Recovered from the loaded MainActivity DEX and Flutter AOT on 2026-10-27.
/// The certificate digest is public APK metadata, not an account credential.
/// Server acceptance and account restriction status need separate validation.
/// Account and logged-out API requests MUST use this same implementation.
/// CDN resources do not use these headers or form extras.
final class CopyRequestProtocol {
  CopyRequestProtocol._();

  // MainActivity.i() -> j(signatures[0].toByteArray()), j() = lowercase MD5.
  // Verified with apksigner against the supplied and installed APK 3.0.9.
  static const certificateMd5 = '3af08590311032efe0660550a0563a53';
  static const version = '3.0.9';
  static const source = 'copyApp';
  static const webp = '1';
  static const buildTime = '2025.05.22';

  /// APK keeps dt from startup, interpreting wall-clock text with -0800.
  /// Do not accidentally turn this into a request timestamp or region value.
  static DateTime startupDate(DateTime wallClock) =>
      DateTime.parse('${wallClock.toIso8601String().substring(0, 19)}-0800');

  static Map<String, dynamic> commonParameters({
    required CopyDeviceIdentity identity,
    required DateTime date,
    required String region,
    String token = '',
  }) => {
    'platform': '3',
    'authorization': 'Token ${token.trim()}',
    'version': version,
    'source': source,
    'region': region,
    'webp': webp,
    'userAgent': 'COPY/$version',
    'isGoogle': false,
    'pseudoID': identity.pseudoId,
    'dt': date,
    'tapString': certificateMd5,
    'umString': umString(certificateMd5),
    'buildTime': buildTime,
    'versionCode': '83',
    'referer': 'com.copymanga.app-$version',
    'androidId': identity.androidId,
    'deviceInfo': identity.deviceInfo,
  };

  static String signature(String timestamp, {required String nativeMaterial}) {
    if (nativeMaterial.isEmpty) {
      throw ArgumentError('原生签名材料尚未核实');
    }
    return Hmac(
      sha256,
      utf8.encode(nativeMaterial),
    ).convert(utf8.encode(timestamp)).toString();
  }

  static String umString(String nativeMaterial) {
    if (nativeMaterial.isEmpty) {
      throw ArgumentError('原生签名材料尚未核实');
    }
    return md5.convert(utf8.encode(nativeMaterial)).toString();
  }

  /// APK's POST wrapper calls data.addAll(options.extra), not JSON encoding.
  /// Keep caller-owned maps unchanged; do not persist or log this result.
  static Map<String, dynamic> formBody({
    required Map<String, dynamic> data,
    required Map<String, dynamic> commonParameters,
  }) => {...data, ...commonParameters};

  /// Only the normal API branch, not the APK's ads / isHot web branch.
  /// Values must come from a verified platform initialization record.
  static Map<String, String> headers({
    required Map<String, dynamic> commonParameters,
    required String nativeMaterial,
    required DateTime now,
  }) {
    final timestamp = (now.microsecondsSinceEpoch ~/ 1000000).toString();
    String value(String key) => commonParameters[key]?.toString() ?? '';
    final date = commonParameters['dt'];
    if (date is! DateTime) throw ArgumentError('原版 dt 需要 DateTime');
    return {
      'Accept': 'application/json',
      for (final key in [
        'platform',
        'source',
        'version',
        'authorization',
        'webp',
        'region',
        'referer',
        'deviceInfo',
        'pseudoID',
        'Accept-Language',
        'versionCode',
      ])
        key: value(key),
      'umString': umString(nativeMaterial),
      'User-Agent': value('userAgent'),
      // Original interceptor maps androidId -> device, not the model name.
      'device': value('androidId'),
      'dt':
          '${date.year.toString().padLeft(4, '0')}.'
          '${date.month.toString().padLeft(2, '0')}.'
          '${date.day.toString().padLeft(2, '0')}',
      'X-Auth-Timestamp': timestamp,
      'X-Auth-Signature': signature(timestamp, nativeMaterial: nativeMaterial),
    };
  }
}
