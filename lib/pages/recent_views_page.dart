import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../controllers/library_controller.dart';
import '../controllers/reading_history_controller.dart';
import '../models/recent_view.dart';
import '../widgets/comic_cover.dart';
import 'comic_detail_page.dart';

class RecentViewsPage extends StatelessWidget {
  const RecentViewsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final history = context.watch<ReadingHistoryController>();
    final library = context.watch<LibraryController>();
    return Scaffold(
      appBar: AppBar(title: const Text('最近观看')),
      body: history.recentViews.isEmpty
          ? const Center(child: Text('暂无最近观看'))
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 32),
              itemCount: history.recentViews.length,
              separatorBuilder: (_, _) => const SizedBox(height: 4),
              itemBuilder: (context, index) {
                final view = history.recentViews[index];
                return Card(
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    leading: SizedBox(
                      width: 48,
                      height: 68,
                      child: ComicCover(
                        title: view.comic.title,
                        localPath: library.coverPath(view.comic),
                        networkUrl: view.comic.coverUrl,
                      ),
                    ),
                    title: Text(
                      view.comic.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(_subtitle(view)),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _open(context, view),
                  ),
                );
              },
            ),
    );
  }

  String _subtitle(RecentView view) {
    final position = view.pageCount > 0
        ? ' · ${view.pageIndex + 1}/${view.pageCount} 页'
        : '';
    final time = view.viewedAt;
    final month = time.month.toString().padLeft(2, '0');
    final day = time.day.toString().padLeft(2, '0');
    final hour = time.hour.toString().padLeft(2, '0');
    final minute = time.minute.toString().padLeft(2, '0');
    return '${view.chapterTitle}$position · $month-$day $hour:$minute';
  }

  Future<void> _open(BuildContext context, RecentView view) async {
    final library = context.read<LibraryController>();
    final comic =
        await library.database.loadComic(view.comic.uuid) ?? view.comic;
    if (!context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => ComicDetailPage(comic: comic)),
    );
  }
}
