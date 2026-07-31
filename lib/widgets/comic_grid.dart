import 'package:flutter/material.dart';

import '../models/comic.dart';
import 'comic_cover.dart';

class ComicGrid extends StatelessWidget {
  const ComicGrid({
    super.key,
    required this.comics,
    required this.coverPath,
    required this.onOpen,
    this.emptyTitle = '这里还没有漫画',
    this.emptySubtitle = '',
    this.scrollController,
    this.showScrollbar = false,
  });

  final List<Comic> comics;
  final String Function(Comic comic) coverPath;
  final ValueChanged<Comic> onOpen;
  final String emptyTitle;
  final String emptySubtitle;
  final ScrollController? scrollController;
  final bool showScrollbar;

  @override
  Widget build(BuildContext context) {
    if (comics.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.menu_book_outlined,
                size: 56,
                color: Theme.of(context).colorScheme.outline,
              ),
              const SizedBox(height: 16),
              Text(emptyTitle, style: Theme.of(context).textTheme.titleMedium),
              if (emptySubtitle.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  emptySubtitle,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ],
            ],
          ),
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final columns = (width / 176).floor().clamp(2, 7);
        final grid = GridView.builder(
          controller: scrollController,
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            childAspectRatio: 0.55,
            crossAxisSpacing: 14,
            mainAxisSpacing: 16,
          ),
          itemCount: comics.length,
          itemBuilder: (context, index) {
            final comic = comics[index];
            return InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: () => onOpen(comic),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Hero(
                      tag: 'comic-cover-${comic.stableIdentity}',
                      child: SizedBox.expand(
                        child: ComicCover(
                          title: comic.title,
                          localPath: coverPath(comic),
                          networkUrl: comic.coverUrl,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    comic.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    comic.authors.isEmpty ? '未知作者' : comic.authors,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 3),
                  Text(
                    comic.downloadedChapters > 0
                        ? '已下载 ${comic.downloadedChapters}'
                        : comic.lastChapter.isNotEmpty
                        ? comic.lastChapter
                        : '尚未下载',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                ],
              ),
            );
          },
        );
        if (!showScrollbar) return grid;
        assert(scrollController != null);
        return Scrollbar(
          controller: scrollController,
          thumbVisibility: true,
          trackVisibility: false,
          interactive: true,
          thickness: 8,
          radius: const Radius.circular(8),
          child: grid,
        );
      },
    );
  }
}
