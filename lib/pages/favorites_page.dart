import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../controllers/favorites_controller.dart';
import '../controllers/library_controller.dart';
import '../controllers/session_controller.dart';
import '../models/comic.dart';
import '../widgets/comic_grid.dart';
import 'comic_detail_page.dart';
import 'login_page.dart';

class FavoritesPage extends StatelessWidget {
  const FavoritesPage({super.key});

  @override
  Widget build(BuildContext context) {
    final session = context.watch<SessionController>();
    final favorites = context.watch<FavoritesController>();
    final library = context.watch<LibraryController>();
    if (!session.isLoggedIn) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.favorite_border, size: 58),
              const SizedBox(height: 16),
              Text(
                '登录后同步拷贝漫画收藏',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: () => _openLogin(context),
                icon: const Icon(Icons.login),
                label: const Text('登录拷贝漫画'),
              ),
            ],
          ),
        ),
      );
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '共 ${favorites.comics.length} 部收藏',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              FilledButton.tonalIcon(
                onPressed: favorites.loading ? null : favorites.refresh,
                icon: const Icon(Icons.sync),
                label: const Text('刷新收藏'),
              ),
              PopupMenuButton<String>(
                tooltip: '漫画收藏操作',
                enabled: !favorites.loading,
                onSelected: (_) => favorites.refresh(checkAll: true),
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'all', child: Text('检查全部收藏')),
                ],
              ),
            ],
          ),
        ),
        if (favorites.loading) const LinearProgressIndicator(),
        if (favorites.error.isNotEmpty)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              favorites.error,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        Expanded(
          child: ComicGrid(
            comics: favorites.comics,
            coverPath: library.coverPath,
            onOpen: (comic) => _openComic(context, comic),
            emptyTitle: '还没有缓存收藏',
          ),
        ),
      ],
    );
  }

  Future<void> _openLogin(BuildContext context) async {
    final loggedIn = await Navigator.of(
      context,
    ).push<bool>(MaterialPageRoute<bool>(builder: (_) => const LoginPage()));
    if (loggedIn == true && context.mounted) {
      await context.read<FavoritesController>().refresh();
    }
  }

  void _openComic(BuildContext context, Comic comic) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => ComicDetailPage(comic: comic)),
    );
  }
}
