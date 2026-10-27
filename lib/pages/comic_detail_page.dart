import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../controllers/library_controller.dart';
import '../controllers/favorites_controller.dart';
import '../controllers/session_controller.dart';
import '../models/chapter.dart';
import '../models/comic.dart';
import '../services/copy_client.dart';
import '../widgets/comic_cover.dart';
import '../widgets/favorite_button.dart';
import 'login_page.dart';
import 'chapter_download_page.dart';
import 'reader_page.dart';

class ComicDetailPage extends StatefulWidget {
  const ComicDetailPage({super.key, required this.comic});

  final Comic comic;

  @override
  State<ComicDetailPage> createState() => _ComicDetailPageState();
}

class _ComicDetailPageState extends State<ComicDetailPage> {
  late Comic _comic;
  List<Chapter> _chapters = const [];
  bool _loading = true;
  bool _updating = false;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _comic = widget.comic;
    _loadLocal();
  }

  Future<void> _loadLocal() async {
    final library = context.read<LibraryController>();
    try {
      if (_comic.uuid.isEmpty &&
          _comic.pathWord.isNotEmpty &&
          !_comic.pathWord.startsWith('local-')) {
        _comic = await library.refreshDetails(_comic);
      } else {
        _comic = await library.database.loadComic(_comic.uuid) ?? _comic;
      }
      _chapters = await library.chapters(_comic.uuid);
    } catch (exception) {
      _error = exception.toString();
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _updateOnline() async {
    if (_comic.pathWord.startsWith('local-')) {
      _show('这是从文件夹重建的纯本地漫画，没有拷贝漫画在线标识');
      return;
    }
    setState(() {
      _updating = true;
      _error = '';
    });
    final library = context.read<LibraryController>();
    try {
      _comic = await library.refreshDetails(_comic);
      _chapters = await library.chapters(_comic.uuid);
      _show('漫画详情和章节索引已更新');
    } on CopyApiException catch (exception) {
      _error = exception.message;
    } catch (exception) {
      _error = '更新失败：$exception';
    } finally {
      if (mounted) setState(() => _updating = false);
    }
  }

  Future<void> _openChapter(Chapter chapter) async {
    if (!chapter.isDownloaded) {
      if (_comic.pathWord.isEmpty || _comic.pathWord.startsWith('local-')) {
        _show('这个章节没有拷贝漫画在线标识，无法在线阅读');
        return;
      }
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ReaderPage.online(comic: _comic, chapter: chapter),
        ),
      );
      return;
    }
    final path = context.read<LibraryController>().archivePath(chapter);
    if (!await File(path).exists()) {
      _show('索引中的 ZIP 不存在，请重新复制漫画文件或重新下载');
      return;
    }
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            ReaderPage(comic: _comic, chapter: chapter, archivePath: path),
      ),
    );
  }

  Future<void> _chooseDownloads({
    Iterable<Chapter> initiallySelected = const [],
    bool selectAllMissing = false,
  }) async {
    final missing = _chapters
        .where((chapter) => !chapter.isDownloaded)
        .toList(growable: false);
    if (missing.isEmpty) {
      _show('没有未下载章节');
      return;
    }
    final selectedIds = selectAllMissing
        ? missing.map((chapter) => chapter.uuid).toSet()
        : initiallySelected.map((chapter) => chapter.uuid).toSet();
    final count = await Navigator.of(context).push<int>(
      MaterialPageRoute<int>(
        builder: (_) => ChapterDownloadPage(
          comic: _comic,
          chapters: _chapters,
          initiallySelected: selectedIds,
        ),
      ),
    );
    if (count == null || !mounted) return;
    if (count == 0) {
      _show('所选章节已经在下载队列中');
    } else {
      _show('已加入 $count 个章节；可在“漫画库 → 下载任务”统一管理');
    }
  }

  void _show(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final library = context.watch<LibraryController>();
    final session = context.watch<SessionController>();
    final favorites = context.read<FavoritesController>();
    final grouped = <String, List<Chapter>>{};
    for (final chapter in _chapters) {
      grouped.putIfAbsent(chapter.groupName, () => []).add(chapter);
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(_comic.title),
        actions: [
          IconButton(
            tooltip: '更新详情和章节',
            onPressed: _updating ? null : _updateOnline,
            icon: const Icon(Icons.sync),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _updateOnline,
              child: CustomScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                slivers: [
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: _Header(
                        comic: _comic,
                        coverPath: library.coverPath(_comic),
                        updating: _updating,
                        favoriteButton: FavoriteButton(
                          scope: (
                            session.client.sessionRevision,
                            session.username,
                            library.database.libraryKey,
                            _comic.uuid,
                          ),
                          loggedIn: session.isLoggedIn,
                          available:
                              _comic.uuid.isNotEmpty &&
                              _comic.pathWord.isNotEmpty &&
                              !_comic.pathWord.startsWith('local-'),
                          loadSelected: () => favorites.isCollected(_comic),
                          setSelected: (value) =>
                              favorites.setFavorite(_comic, value),
                          onLogin: () async {
                            await Navigator.of(context).push<bool>(
                              MaterialPageRoute(
                                builder: (_) => const LoginPage(),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                  if (_error.isNotEmpty)
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Card(
                          color: Theme.of(context).colorScheme.errorContainer,
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Text(_error),
                          ),
                        ),
                      ),
                    ),
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              '章节（${_chapters.length}）',
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                          ),
                          FilledButton.tonalIcon(
                            onPressed:
                                _chapters.any(
                                  (chapter) => !chapter.isDownloaded,
                                )
                                ? () => _chooseDownloads(selectAllMissing: true)
                                : null,
                            icon: const Icon(Icons.download_for_offline),
                            label: const Text('下载全部缺章'),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (_chapters.isEmpty)
                    const SliverFillRemaining(
                      hasScrollBody: false,
                      child: Center(
                        child: Padding(
                          padding: EdgeInsets.all(24),
                          child: Text('暂无章节'),
                        ),
                      ),
                    )
                  else
                    SliverList.builder(
                      itemCount: grouped.length,
                      itemBuilder: (context, index) {
                        final entry = grouped.entries.elementAt(index);
                        return _ChapterGroup(
                          name: entry.key,
                          chapters: entry.value,
                          onOpen: _openChapter,
                          onDownloadAll: () => _chooseDownloads(
                            initiallySelected: entry.value.where(
                              (chapter) => !chapter.isDownloaded,
                            ),
                          ),
                        );
                      },
                    ),
                  const SliverToBoxAdapter(child: SizedBox(height: 48)),
                ],
              ),
            ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.comic,
    required this.coverPath,
    required this.updating,
    required this.favoriteButton,
  });

  final Comic comic;
  final String coverPath;
  final bool updating;
  final Widget favoriteButton;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 650;
        final cover = Hero(
          tag: 'comic-cover-${comic.stableIdentity}',
          child: SizedBox(
            width: wide ? 210 : 128,
            height: wide ? 280 : 172,
            child: ComicCover(
              title: comic.title,
              localPath: coverPath,
              networkUrl: comic.coverUrl,
            ),
          ),
        );
        final details = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(comic.title, style: Theme.of(context).textTheme.headlineSmall),
            if (comic.alias.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(comic.alias, style: Theme.of(context).textTheme.bodyMedium),
            ],
            const SizedBox(height: 10),
            Text(comic.authors.isEmpty ? '未知作者' : comic.authors),
            if (comic.status.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text('状态：${comic.status}'),
            ],
            const SizedBox(height: 8),
            Text(
              '本地 ${comic.downloadedChapters} / '
              '${comic.totalChapters} 章',
              style: TextStyle(color: Theme.of(context).colorScheme.primary),
            ),
            favoriteButton,
            if (comic.brief.isNotEmpty) ...[
              const SizedBox(height: 14),
              Text(comic.brief),
            ],
            if (updating) ...[
              const SizedBox(height: 16),
              const LinearProgressIndicator(),
              const SizedBox(height: 4),
              const Text('正在更新章节索引…'),
            ],
          ],
        );
        if (wide) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              cover,
              const SizedBox(width: 24),
              Expanded(child: details),
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            cover,
            const SizedBox(width: 16),
            Expanded(child: details),
          ],
        );
      },
    );
  }
}

class _ChapterGroup extends StatelessWidget {
  const _ChapterGroup({
    required this.name,
    required this.chapters,
    required this.onOpen,
    required this.onDownloadAll,
  });

  final String name;
  final List<Chapter> chapters;
  final ValueChanged<Chapter> onOpen;
  final VoidCallback onDownloadAll;

  @override
  Widget build(BuildContext context) {
    final missing = chapters.where((chapter) => !chapter.isDownloaded).length;
    return ExpansionTile(
      initiallyExpanded: true,
      title: Text(name.isEmpty ? '默认' : name),
      subtitle: Text('${chapters.length} 章 · ${chapters.length - missing} 已下载'),
      trailing: missing == 0
          ? const Icon(Icons.download_done)
          : IconButton(
              tooltip: '下载本组全部缺章',
              onPressed: onDownloadAll,
              icon: const Icon(Icons.download),
            ),
      children: chapters
          .map(
            (chapter) => ListTile(
              leading: Icon(
                chapter.isDownloaded
                    ? Icons.play_circle_fill
                    : Icons.cloud_outlined,
                color: chapter.isDownloaded
                    ? Theme.of(context).colorScheme.primary
                    : null,
              ),
              title: Text(chapter.title),
              subtitle: chapter.pageCount > 0
                  ? Text('${chapter.pageCount} 页')
                  : null,
              onTap: () => onOpen(chapter),
            ),
          )
          .toList(growable: false),
    );
  }
}
