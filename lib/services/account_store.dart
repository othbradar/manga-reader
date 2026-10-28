import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sqflite/sqflite.dart';

import '../models/saved_account.dart';
import 'local_app_database.dart';

/// Device-only account metadata; secrets never enter SQLite/portable backups.
class AccountStore {
  AccountStore(this.local, {FlutterSecureStorage? secureStorage})
    : secure =
          secureStorage ??
          const FlutterSecureStorage(
            mOptions: MacOsOptions(usesDataProtectionKeychain: false),
          );
  final LocalAppDatabase local;
  final FlutterSecureStorage secure;
  static const legacyTokenKey = 'copy_manga_token';
  static const legacyUsernameKey = 'copy_manga_username';
  static String tokenKey(String id) =>
      'copy_manga_account_${sha256.convert(utf8.encode(id))}';

  Future<void> initialize({
    required String domain,
    required bool automatic,
  }) async {
    await local.open();
    await local.database.execute('''CREATE TABLE IF NOT EXISTS saved_accounts(
      account_key TEXT PRIMARY KEY, username TEXT NOT NULL, nickname TEXT NOT NULL,
      avatar TEXT NOT NULL, authentication_domain TEXT NOT NULL,
      automatic_domain INTEGER NOT NULL DEFAULT 1)''');
    await local.database.execute('''CREATE TABLE IF NOT EXISTS account_state(
      id INTEGER PRIMARY KEY CHECK(id=1), active_account TEXT NOT NULL DEFAULT '',
      legacy_migrated INTEGER NOT NULL DEFAULT 0)''');
    await local.database.rawInsert(
      'INSERT OR IGNORE INTO account_state(id) VALUES(1)',
    );
    final state = (await local.database.query('account_state')).single;
    if (state['legacy_migrated'] == 1) return;
    final username = await secure.read(key: legacyUsernameKey) ?? '';
    final token = await secure.read(key: legacyTokenKey) ?? '';
    if (username.isNotEmpty && token.isNotEmpty) {
      await save(
        SavedAccount(
          username: username,
          authenticationDomain: domain,
          automaticDomain: automatic,
        ),
        token,
      );
      // Preserve the previous single-account snapshot for its saved owner.
      // Keep the legacy table intact for rollback; never move/delete its rows.
      final id = username.trim().toLowerCase();
      const columns =
          'library_key,comic_uuid,path_word,title,authors,cover_url,'
          'alias,brief,status,last_chapter,source_kind,library_order,title_sort_key,'
          'position,cached_at';
      await local.database.rawInsert(
        '''INSERT OR IGNORE INTO account_comic_favorites
        (account_key,$columns) SELECT ?,$columns FROM favorites_cache''',
        [id],
      );
      if (id != username) {
        const novelColumns =
            'library_key,novel_uuid,path_word,title,authors,alias,brief,cover_url,position';
        await local.database.rawInsert(
          '''INSERT OR IGNORE INTO novel_favorites
          (account_key,$novelColumns) SELECT ?,$novelColumns FROM novel_favorites
          WHERE account_key=?''',
          [id, username],
        );
      }
    }
    await local.database.update('account_state', {'legacy_migrated': 1});
    // Remove legacy keys only after both new stores have committed.
    await secure.delete(key: legacyTokenKey);
    await secure.delete(key: legacyUsernameKey);
  }

  Future<List<SavedAccount>> list() async => (await local.database.query(
    'saved_accounts',
    orderBy: 'rowid',
  )).map(SavedAccount.fromRow).toList(growable: false);
  Future<String> activeId() async =>
      (await local.database.query('account_state')).single['active_account']!
          as String;
  Future<String> token(String id) async =>
      await secure.read(key: tokenKey(id)) ?? '';
  Future<void> activate(String id) async {
    await local.database.update('account_state', {'active_account': id});
  }

  Future<void> save(SavedAccount account, String token) async {
    if (token.isEmpty) throw StateError('登录令牌为空');
    final key = tokenKey(account.id);
    final previous = await secure.read(key: key);
    await secure.write(key: key, value: token);
    try {
      await local.database.transaction((txn) async {
        await txn.insert(
          'saved_accounts',
          account.toRow(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
        await txn.update('account_state', {'active_account': account.id});
      });
    } catch (_) {
      if (previous == null) {
        await secure.delete(key: key);
      } else {
        await secure.write(key: key, value: previous);
      }
      rethrow;
    }
  }

  Future<void> update(SavedAccount account) async {
    await local.database.update(
      'saved_accounts',
      account.toRow(),
      where: 'account_key=?',
      whereArgs: [account.id],
    );
  }

  Future<void> remove(String id) async {
    await secure.delete(key: tokenKey(id));
    await local.database.transaction((txn) async {
      await txn.delete(
        'saved_accounts',
        where: 'account_key=?',
        whereArgs: [id],
      );
      await txn.update(
        'account_state',
        {'active_account': ''},
        where: 'active_account=?',
        whereArgs: [id],
      );
    });
  }
}
