import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../services/copy_client.dart';

class SessionController extends ChangeNotifier {
  SessionController(this.client, {FlutterSecureStorage? secureStorage})
    : _secureStorage =
          secureStorage ??
          const FlutterSecureStorage(
            mOptions: MacOsOptions(usesDataProtectionKeychain: false),
          );

  static const _tokenKey = 'copy_manga_token';
  static const _usernameKey = 'copy_manga_username';
  final CopyClient client;
  final FlutterSecureStorage _secureStorage;

  bool loading = false;
  bool ready = false;
  String username = '';
  String nickname = '';
  String avatar = '';
  String error = '';

  bool get isLoggedIn => client.hasToken;

  Future<void> restore() async {
    final values = await Future.wait([
      _secureStorage.read(key: _tokenKey),
      _secureStorage.read(key: _usernameKey),
    ]);
    final token = values[0] ?? '';
    username = values[1] ?? '';
    if (token.isNotEmpty) {
      client.setToken(token);
      try {
        await refreshProfile();
      } on CopyApiException catch (exception) {
        if (exception.code == 401) {
          await logout();
        } else {
          error = exception.message;
        }
      }
    }
    ready = true;
    notifyListeners();
  }

  Future<bool> login(String user, String password) async {
    if (loading) return false;
    if (user.trim().isEmpty || password.isEmpty) {
      error = '请输入账号和密码';
      notifyListeners();
      return false;
    }
    loading = true;
    error = '';
    notifyListeners();
    try {
      final result = await client.login(user.trim(), password);
      username = result['username']?.toString() ?? user.trim();
      nickname = result['nickname']?.toString() ?? username;
      avatar = result['avatar']?.toString() ?? '';
      await _secureStorage.write(
        key: _tokenKey,
        value: result['token']?.toString() ?? '',
      );
      await _secureStorage.write(key: _usernameKey, value: username);
      return true;
    } on CopyApiException catch (exception) {
      error = exception.message;
      return false;
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<void> refreshProfile() async {
    if (!isLoggedIn) return;
    final result = await client.profile();
    username = result['username']?.toString() ?? username;
    nickname = result['nickname']?.toString() ?? username;
    avatar = result['avatar']?.toString() ?? '';
    notifyListeners();
  }

  Future<void> logout() async {
    client.setToken('');
    username = '';
    nickname = '';
    avatar = '';
    error = '';
    await _secureStorage.delete(key: _tokenKey);
    await _secureStorage.delete(key: _usernameKey);
    notifyListeners();
  }
}
