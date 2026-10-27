class CopyDeviceIdentity {
  const CopyDeviceIdentity({
    required this.device,
    required this.deviceInfo,
    required this.androidId,
    required this.pseudoId,
  });

  /// An uninitialized identity is never valid for production API traffic.
  static const fallback = CopyDeviceIdentity(
    device: '',
    deviceInfo: '',
    androidId: '',
    pseudoId: '',
  );

  final String device;
  final String deviceInfo;
  // APK calls this androidId, but the Android value is Build.ID, NOT ANDROID_ID.
  final String androidId;
  final String pseudoId;

  bool get isReady =>
      deviceInfo.isNotEmpty &&
      androidId.isNotEmpty &&
      RegExp(r'^[0-9a-zA-Z]{16}$').hasMatch(pseudoId);
}
