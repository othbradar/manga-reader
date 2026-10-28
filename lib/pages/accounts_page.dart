import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../controllers/session_controller.dart';
import '../models/saved_account.dart';
import 'login_page.dart';

class AccountsPage extends StatelessWidget {
  const AccountsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final session = context.watch<SessionController>();
    final busy = session.loading || session.renewing || !session.ready;
    return Scaffold(
      appBar: AppBar(title: const Text('切换账号')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (busy) const LinearProgressIndicator(),
          for (final account in session.accounts)
            Card(
              child: ListTile(
                leading: CircleAvatar(
                  child: Text(account.label.characters.first),
                ),
                title: Text(
                  account.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  account.username,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                selected: session.accountKey == account.id,
                onTap: busy
                    ? null
                    : () async {
                        final ok = await session.switchAccount(account.id);
                        if (ok && context.mounted) Navigator.pop(context);
                      },
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (session.accountKey == account.id)
                      Icon(
                        Icons.check_circle,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    PopupMenuButton<String>(
                      tooltip: '${account.username} 账号操作',
                      enabled: !busy,
                      onSelected: (action) async {
                        if (action == 'login') {
                          await Navigator.of(context).push(
                            MaterialPageRoute<bool>(
                              builder: (_) =>
                                  LoginPage(username: account.username),
                            ),
                          );
                        } else if (action == 'forget-password') {
                          await session.forgetPassword(account.id);
                        } else {
                          await _remove(context, session, account);
                        }
                      },
                      itemBuilder: (_) => [
                        const PopupMenuItem(
                          value: 'login',
                          child: Text('重新登录'),
                        ),
                        if (session.remembersPassword(account.id))
                          const PopupMenuItem(
                            value: 'forget-password',
                            child: Text('关闭自动续期并忘记密码'),
                          ),
                        const PopupMenuItem(
                          value: 'remove',
                          child: Text('移除本机账号'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          if (session.error.isNotEmpty)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                session.error,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: busy
                ? null
                : () => Navigator.of(context).push(
                    MaterialPageRoute<bool>(builder: (_) => const LoginPage()),
                  ),
            icon: const Icon(Icons.person_add_alt),
            label: const Text('添加账号'),
          ),
        ],
      ),
    );
  }

  Future<void> _remove(
    BuildContext context,
    SessionController session,
    SavedAccount account,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('移除本机账号'),
        content: Text('移除 ${account.username} 的本机登录状态？不会删除服务器收藏和本地书库。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    if (confirmed == true) await session.removeAccount(account.id);
  }
}
