import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../controllers/favorites_controller.dart';
import '../controllers/library_controller.dart';
import '../controllers/reading_history_controller.dart';
import '../controllers/session_controller.dart';
import 'login_page.dart';
import 'recent_views_page.dart';
import 'settings_page.dart';

class AccountPage extends StatelessWidget {
  const AccountPage({super.key});

  @override
  Widget build(BuildContext context) {
    final session = context.watch<SessionController>();
    final library = context.watch<LibraryController>();
    final history = context.watch<ReadingHistoryController>();
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 28,
                  child: Text(
                    (session.nickname.isNotEmpty
                            ? session.nickname
                            : session.username.isNotEmpty
                            ? session.username
                            : '未')
                        .characters
                        .first,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Text(
                    session.isLoggedIn
                        ? session.nickname.isEmpty
                              ? session.username
                              : session.nickname
                        : '尚未登录',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                if (session.isLoggedIn)
                  TextButton(onPressed: session.logout, child: const Text('退出'))
                else
                  FilledButton(
                    onPressed: () => _login(context),
                    child: const Text('登录'),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.history),
                title: const Text('最近观看'),
                subtitle: Text(
                  history.recentViews.isEmpty
                      ? '暂无记录'
                      : '${history.recentViews.length} 部 · '
                            '${history.recentViews.first.comic.title}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const RecentViewsPage(),
                  ),
                ),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.folder_copy_outlined),
                title: const Text('漫画库'),
                subtitle: Text('${library.totalCount} 部漫画'),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.settings_outlined),
                title: const Text('设置与说明'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const SettingsPage()),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _login(BuildContext context) async {
    final result = await Navigator.of(
      context,
    ).push<bool>(MaterialPageRoute<bool>(builder: (_) => const LoginPage()));
    if (result == true && context.mounted) {
      await context.read<FavoritesController>().refresh();
    }
  }
}
