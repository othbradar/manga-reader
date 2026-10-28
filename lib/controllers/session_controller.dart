import 'package:flutter/foundation.dart';

import '../models/saved_account.dart';
import '../services/account_store.dart';
import '../services/copy_client.dart';

class SessionController extends ChangeNotifier {
  SessionController(this.client, {required this.store}) {
    client.setSessionRenewal(_renewSavedSession);
  }
  final CopyClient client;
  final AccountStore store;
  bool loading = false, ready = false;
  bool renewing = false;
  bool _disposed = false;
  final Set<String> _rememberedPasswords = {};
  bool remembersPassword(String id) => _rememberedPasswords.contains(id);
  String error = '';
  List<SavedAccount> accounts = const [];
  SavedAccount? _active;
  String _activeToken = '';
  bool get isLoggedIn => !loading && _active != null && client.hasToken;
  String get accountKey => isLoggedIn ? _active!.id : '';
  String get username => _active?.username ?? '';
  String get nickname => _active?.nickname ?? '';
  String get avatar => _active?.avatar ?? '';

  Future<void> restore() async {
    if (loading) return;
    loading = true;
    try {
      await store.initialize(
        domain: client.authenticationDomain,
        automatic: client.usesAutomaticAuthenticationDomain,
      );
      accounts = await store.list();
      _rememberedPasswords.clear();
      for (final account in accounts) {
        if (await store.remembersPassword(account.id)) {
          _rememberedPasswords.add(account.id);
        }
      }
      final id = await store.activeId();
      final matches = accounts.where((a) => a.id == id);
      if (matches.isNotEmpty) {
        final token = await store.token(id);
        _active = matches.first;
        _activeToken = token;
        _applyActive();
      }
    } catch (_) {
      error = '读取本机账号失败，请重试；未修改已有账号';
    } finally {
      loading = false;
      ready = true;
      notifyListeners();
    }
  }

  void _applyActive() {
    final a = _active;
    if (a != null && a.authenticationDomain.isNotEmpty) {
      client.setAuthenticationDomain(
        a.authenticationDomain,
        manual: !a.automaticDomain,
      );
    }
    client.setToken(_activeToken);
  }

  Future<bool> _change(Future<void> Function() operation) async {
    if (loading || renewing || !ready) return false;
    loading = true;
    error = '';
    // Invalidate old in-flight/queued member requests before any async work.
    client.setToken('');
    notifyListeners();
    try {
      await operation();
      return true;
    } on CopyApiException catch (e) {
      error = e.message;
      return false;
    } catch (_) {
      error = '账号切换未完成，已保留原账号；请检查系统安全存储后重试';
      return false;
    } finally {
      _applyActive();
      loading = false;
      notifyListeners();
    }
  }

  Future<bool> login(
    String user,
    String password, {
    bool rememberPassword = false,
  }) async {
    if (user.trim().isEmpty || password.isEmpty) {
      error = '请输入账号和密码';
      notifyListeners();
      return false;
    }
    return _change(() async {
      await saveCurrentNode();
      final result = await client.login(user.trim(), password);
      final returnedUser = result['username']?.toString() ?? '';
      if (returnedUser.toLowerCase() != user.trim().toLowerCase()) {
        throw const CopyApiException('服务器返回的账号不匹配，未保存登录状态');
      }
      final account = _fromProfile(result, returnedUser);
      final token = result['token']?.toString() ?? '';
      await store.save(
        account,
        token,
        password: password,
        rememberPassword: rememberPassword,
      );
      if (rememberPassword) {
        _rememberedPasswords.add(account.id);
      } else {
        _rememberedPasswords.remove(account.id);
      }
      _active = account;
      _activeToken = token;
      accounts = await store.list();
    });
  }

  Future<bool> switchAccount(String id) async {
    if (accountKey == id) return true;
    return _change(() async {
      await saveCurrentNode();
      final account = accounts.where((a) => a.id == id).firstOrNull;
      if (account == null) throw const CopyApiException('找不到该本机账号');
      final token = await store.token(id);
      if (token.isEmpty) throw const CopyApiException('该账号登录已失效，请重新登录');
      await store.activate(id);
      _active = account;
      _activeToken = token;
    });
  }

  Future<bool> removeAccount(String id) => _change(() async {
    await store.remove(id);
    _rememberedPasswords.remove(id);
    if (_active?.id == id) {
      _active = null;
      _activeToken = '';
    }
    accounts = await store.list();
  });

  Future<void> logout() async {
    final id = _active?.id;
    if (id != null) await removeAccount(id);
  }

  Future<void> saveCurrentNode() async {
    if (renewing) throw const CopyApiException('正在自动续期，请稍后再切换账号节点');
    final a = _active;
    if (a == null) return;
    final updated = SavedAccount(
      username: a.username,
      nickname: a.nickname,
      avatar: a.avatar,
      authenticationDomain: client.authenticationDomain,
      automaticDomain: client.usesAutomaticAuthenticationDomain,
    );
    await store.update(updated);
    _active = updated;
    accounts = accounts.map((a) => a.id == updated.id ? updated : a).toList();
  }

  SavedAccount _fromProfile(Map<String, dynamic> result, String user) =>
      SavedAccount(
        username: user,
        nickname: result['nickname']?.toString() ?? user,
        avatar: result['avatar']?.toString() ?? '',
        authenticationDomain: client.authenticationDomain,
        automaticDomain: client.usesAutomaticAuthenticationDomain,
      );

  Future<void> refreshProfile() async {
    if (!isLoggedIn) return;
    final revision = client.sessionRevision;
    final id = accountKey;
    final result = await client.profile();
    if (revision != client.sessionRevision || id != accountKey) return;
    final user = result['username']?.toString() ?? '';
    if (user.toLowerCase() != id) throw const CopyApiException('服务器返回的账号不匹配');
    final updated = _fromProfile(result, user);
    await store.update(updated);
    if (revision != client.sessionRevision || id != accountKey) return;
    _active = updated;
    accounts = accounts.map((a) => a.id == id ? updated : a).toList();
    notifyListeners();
  }

  Future<void> forgetPassword(String id) async {
    if (loading || renewing) return;
    await store.forgetPassword(id);
    _rememberedPasswords.remove(id);
    if (!_disposed) notifyListeners();
  }

  Future<bool> _renewSavedSession() async {
    final account = _active;
    if (_disposed ||
        loading ||
        renewing ||
        account == null ||
        _activeToken.isEmpty) {
      return false;
    }
    final revision = client.sessionRevision;
    final domain = client.authenticationDomain;
    final oldToken = _activeToken;
    bool unchanged() =>
        !_disposed &&
        _active?.id == account.id &&
        client.sessionRevision == revision &&
        client.authenticationDomain == domain;
    renewing = true;
    notifyListeners();
    try {
      final password = await store.password(account.id);
      if (password.isEmpty || !unchanged()) return false;
      final result = await client.authenticateCredentials(
        account.username,
        password,
      );
      if (!unchanged()) return false;
      final returnedUser = result['username']?.toString().toLowerCase() ?? '';
      final token = result['token']?.toString() ?? '';
      if (returnedUser != account.id || token.isEmpty) {
        throw const CopyApiException('自动续期返回的账号不匹配，未替换原凭证');
      }
      await store.saveRenewedToken(account.id, token);
      if (!unchanged()) {
        await store.saveRenewedToken(account.id, oldToken);
        return false;
      }
      client.installRenewedToken(token);
      _activeToken = token;
      error = '';
      return true;
    } on CopyApiException catch (e) {
      error = '自动续期失败：${e.message}';
      rethrow;
    } catch (_) {
      error = '自动续期未完成，已保留原账号和收藏；请检查安全存储后重新登录';
      throw CopyApiException(error);
    } finally {
      renewing = false;
      if (!_disposed) notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    client.setSessionRenewal(null);
    super.dispose();
  }
}
