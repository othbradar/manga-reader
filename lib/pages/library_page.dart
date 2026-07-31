import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../controllers/download_controller.dart';
import '../controllers/library_controller.dart';
import '../models/comic.dart';
import '../models/library_view.dart';
import '../widgets/comic_grid.dart';
import 'comic_detail_page.dart';
import 'copy_manga_batch_update_page.dart';
import 'downloads_page.dart';

enum _LibraryAction { copyMangaBatchUpdate, refresh }

class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key});

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  Timer? _searchTimer;
  final _scrollController = ScrollController();

  @override
  void dispose() {
    _searchTimer?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  void _search(String value) {
    _searchTimer?.cancel();
    _searchTimer = Timer(const Duration(milliseconds: 220), () async {
      if (!mounted) return;
      await context.read<LibraryController>().refresh(search: value);
      _resetScroll();
    });
  }

  void _resetScroll() {
    if (_scrollController.hasClients) _scrollController.jumpTo(0);
  }

  @override
  Widget build(BuildContext context) {
    final library = context.watch<LibraryController>();
    final downloads = context.watch<DownloadController>();
    if (library.loading && !library.ready) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            if (library.operationStatus.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text(library.operationStatus),
            ],
          ],
        ),
      );
    }
    if (!library.ready && library.error.isNotEmpty) {
      return _LibraryError(error: library.error);
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: SearchBar(
            hintText: '搜索本地漫画名或作者',
            leading: const Icon(Icons.search),
            onChanged: _search,
            trailing: [
              IconButton(
                tooltip: '筛选与排序',
                onPressed: () => _showViewOptions(context),
                icon: Badge(
                  isLabelVisible:
                      library.sourceFilter != ComicSourceFilter.all ||
                      library.sortMode != ComicSortMode.original,
                  child: const Icon(Icons.tune),
                ),
              ),
              IconButton(
                tooltip: '下载任务',
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const _DownloadsRoute(),
                  ),
                ),
                icon: Badge(
                  isLabelVisible: downloads.queuedCount > 0,
                  label: Text('${downloads.queuedCount}'),
                  child: const Icon(Icons.download_outlined),
                ),
              ),
              PopupMenuButton<_LibraryAction>(
                tooltip: '漫画库操作',
                enabled: !library.loading,
                icon: const Icon(Icons.more_vert),
                onSelected: (action) {
                  switch (action) {
                    case _LibraryAction.copyMangaBatchUpdate:
                      Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const CopyMangaBatchUpdatePage(),
                        ),
                      );
                      break;
                    case _LibraryAction.refresh:
                      library.refresh();
                      break;
                  }
                },
                itemBuilder: (context) => const [
                  PopupMenuItem(
                    value: _LibraryAction.copyMangaBatchUpdate,
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.manage_search),
                      title: Text('拷贝漫画补缺'),
                    ),
                  ),
                  PopupMenuItem(
                    value: _LibraryAction.refresh,
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.refresh),
                      title: Text('刷新本地索引'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        if (library.error.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Text(
              library.error,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        Expanded(
          child: ComicGrid(
            comics: library.comics,
            coverPath: library.coverPath,
            onOpen: (comic) => _openComic(context, comic),
            emptyTitle: library.query.isEmpty ? '漫画库还是空的' : '没有匹配的漫画',
            scrollController: _scrollController,
            showScrollbar: true,
          ),
        ),
      ],
    );
  }

  void _openComic(BuildContext context, Comic comic) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => ComicDetailPage(comic: comic)),
    );
  }

  Future<void> _showViewOptions(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        return SafeArea(
          child: Consumer<LibraryController>(
            builder: (context, library, _) {
              return Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '筛选与排序',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 20),
                    Text('漫画来源', style: Theme.of(context).textTheme.titleSmall),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: ComicSourceFilter.values
                          .map(
                            (value) => ChoiceChip(
                              label: Text(value.label),
                              selected: library.sourceFilter == value,
                              onSelected: (_) async {
                                await library.setSourceFilter(value);
                                _resetScroll();
                              },
                            ),
                          )
                          .toList(growable: false),
                    ),
                    const SizedBox(height: 20),
                    Text('排序', style: Theme.of(context).textTheme.titleSmall),
                    const SizedBox(height: 10),
                    SegmentedButton<ComicSortMode>(
                      segments: ComicSortMode.values
                          .map(
                            (value) => ButtonSegment<ComicSortMode>(
                              value: value,
                              label: Text(value.label),
                            ),
                          )
                          .toList(growable: false),
                      selected: {library.sortMode},
                      onSelectionChanged: (selection) async {
                        await library.setSortMode(selection.single);
                        _resetScroll();
                      },
                    ),
                  ],
                ),
              );
            },
          ),
        );
      },
    );
  }
}

class _DownloadsRoute extends StatelessWidget {
  const _DownloadsRoute();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('下载任务')),
      body: const DownloadsPage(),
    );
  }
}

class _LibraryError extends StatelessWidget {
  const _LibraryError({required this.error});

  final String error;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 56),
            const SizedBox(height: 16),
            Text(error, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: context.read<LibraryController>().initialize,
              child: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }
}
