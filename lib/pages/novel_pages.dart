import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../controllers/library_controller.dart';
import '../controllers/novel_controller.dart';
import '../controllers/session_controller.dart';
import '../models/comic.dart';
import '../models/library_view.dart';
import '../models/novel.dart';
import '../widgets/comic_cover.dart';
import '../widgets/favorite_button.dart';
import '../widgets/comic_grid.dart';
import '../widgets/library_view_options.dart';
import 'login_page.dart';
import 'novel_reader_page.dart';

class MediaTabs extends StatelessWidget {
  const MediaTabs({super.key, required this.comics, required this.novels});
  final Widget comics, novels;
  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: 2,
    child: Column(
      children: [
        const TabBar(
          tabs: [
            Tab(text: '漫画'),
            Tab(text: '小说'),
          ],
        ),
        Expanded(child: TabBarView(children: [comics, novels])),
      ],
    ),
  );
}

class NovelGrid extends StatelessWidget {
  const NovelGrid({
    super.key,
    required this.books,
    this.empty = '这里还没有小说',
    this.scrollController,
  });
  final List<Novel> books;
  final String empty;
  final ScrollController? scrollController;
  @override
  Widget build(BuildContext context) {
    final store = context.read<NovelController>().store;
    final byId = {for (final b in books) 'novel:${b.identity}': b};
    return ComicGrid(
      comics: books
          .map(
            (b) => Comic(
              uuid: 'novel:${b.identity}',
              pathWord: b.pathWord,
              title: b.title,
              authors: b.authors,
              coverUrl: b.coverUrl,
              downloadedChapters: b.downloadedVolumes,
            ),
          )
          .toList(),
      coverPath: (c) {
        final path = byId[c.uuid]!.coverRelativePath;
        return path.isEmpty ? '' : store.absolute(path);
      },
      onOpen: (c) => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => NovelDetailPage(book: byId[c.uuid]!),
        ),
      ),
      emptyTitle: empty,
      scrollController: scrollController,
      showScrollbar: scrollController != null,
    );
  }
}

class NovelLibraryPage extends StatefulWidget {
  const NovelLibraryPage({super.key});
  @override
  State<NovelLibraryPage> createState() => _NovelLibraryPageState();
}

class _NovelLibraryPageState extends State<NovelLibraryPage> {
  final _scroll = ScrollController();
  late final TextEditingController _search;
  Timer? _timer;
  @override
  void initState() {
    super.initState();
    _search = TextEditingController(
      text: context.read<NovelController>().query,
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    _scroll.dispose();
    _search.dispose();
    super.dispose();
  }

  void _resetScroll() {
    if (mounted && _scroll.hasClients) _scroll.jumpTo(0);
  }

  Future<void> _showViewOptions() => showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (_) => Consumer<NovelController>(
      builder: (_, novels, _) => LibraryViewOptions(
        sourceLabel: '小说来源',
        sourceFilter: novels.sourceFilter,
        sortMode: novels.sortMode,
        onSourceChanged: (value) async {
          await novels.setSourceFilter(value);
          _resetScroll();
        },
        onSortChanged: (value) async {
          await novels.setSortMode(value);
          _resetScroll();
        },
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final library = context.watch<LibraryController>();
    final c = context.watch<NovelController>();
    if (!library.ready) return const Center(child: Text('请先打开漫画库索引'));
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: SearchBar(
            controller: _search,
            hintText: '搜索本地小说名或作者',
            leading: const Icon(Icons.search),
            onChanged: (q) {
              _timer?.cancel();
              _timer = Timer(const Duration(milliseconds: 220), () async {
                if (!mounted) return;
                try {
                  await c.refresh(search: q);
                  _resetScroll();
                } catch (e) {
                  if (context.mounted) _message(context, e.toString());
                }
              });
            },
            trailing: [
              IconButton(
                tooltip: '筛选与排序',
                onPressed: _showViewOptions,
                icon: Badge(
                  isLabelVisible:
                      c.sourceFilter != ComicSourceFilter.all ||
                      c.sortMode != ComicSortMode.original,
                  child: const Icon(Icons.tune),
                ),
              ),
              IconButton(
                tooltip: '小说下载任务',
                icon: const Icon(Icons.download_outlined),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const NovelDownloadsPage(),
                  ),
                ),
              ),
              PopupMenuButton<String>(
                tooltip: '小说库操作',
                onSelected: (action) async {
                  try {
                    if (action == 'scan') {
                      await c.scanLocal();
                    } else {
                      await c.refresh();
                    }
                  } catch (e) {
                    if (context.mounted) _message(context, e.toString());
                  }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'scan', child: Text('扫描本地小说')),
                  PopupMenuItem(value: 'refresh', child: Text('刷新小说库')),
                ],
              ),
            ],
          ),
        ),
        if (c.loading) const LinearProgressIndicator(),
        if (c.error.isNotEmpty)
          Padding(padding: const EdgeInsets.all(12), child: Text(c.error)),
        Expanded(
          child: NovelGrid(
            books: c.books,
            scrollController: _scroll,
            empty: c.query.isNotEmpty || c.sourceFilter != ComicSourceFilter.all
                ? '没有匹配的小说'
                : '小说库还是空的',
          ),
        ),
      ],
    );
  }
}

class NovelSearchPage extends StatefulWidget {
  const NovelSearchPage({super.key});
  @override
  State<NovelSearchPage> createState() => _NovelSearchPageState();
}

class _NovelSearchPageState extends State<NovelSearchPage> {
  final _text = TextEditingController();
  List<Novel> _results = [];
  bool _loading = false;
  String _error = '';
  Future<void> _search() async {
    if (_loading || _text.text.trim().isEmpty) return;
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      _results = await context.read<NovelController>().client.search(
        _text.text.trim(),
      );
    } catch (e) {
      _error = e.toString();
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: SearchBar(
          controller: _text,
          hintText: '搜索拷贝小说',
          leading: const Icon(Icons.search),
          onSubmitted: (_) => _search(),
          trailing: [
            IconButton(
              tooltip: '搜索',
              onPressed: _loading ? null : _search,
              icon: const Icon(Icons.search),
            ),
          ],
        ),
      ),
      if (_loading) const LinearProgressIndicator(),
      if (_error.isNotEmpty)
        Padding(padding: const EdgeInsets.all(12), child: Text(_error)),
      Expanded(
        child: NovelGrid(books: _results, empty: '搜索拷贝小说'),
      ),
    ],
  );
}

class NovelFavoritesPage extends StatefulWidget {
  const NovelFavoritesPage({super.key});
  @override
  State<NovelFavoritesPage> createState() => _NovelFavoritesPageState();
}

class _NovelFavoritesPageState extends State<NovelFavoritesPage> {
  bool _loading = false;
  String _error = '';
  (int, String, String, bool)? _cacheScope;
  int _loadRevision = 0;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final s = context.watch<SessionController>();
    final library = context.watch<LibraryController>();
    final scope = (
      s.client.sessionRevision,
      s.accountKey,
      library.ready ? library.database.libraryKey : '',
      library.ready,
    );
    if (scope != _cacheScope) {
      _cacheScope = scope;
      _loadRevision++;
      _loading = false;
      _error = '';
      if (library.ready && s.isLoggedIn) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && scope == _cacheScope) _load(false);
        });
      }
    }
  }

  Future<void> _load(bool online, {bool checkAll = false}) async {
    if (_loading) return;
    final revision = ++_loadRevision;
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      await context.read<NovelController>().loadFavorites(
        context.read<SessionController>().accountKey,
        online: online,
        verify: checkAll,
      );
    } catch (e) {
      if (revision == _loadRevision) _error = e.toString();
    } finally {
      if (mounted && revision == _loadRevision) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _collectLocal({bool retryOnly = false}) async {
    final c = context.read<NovelController>();
    final account = context.read<SessionController>().accountKey;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('收藏已匹配小说'),
        content: Text('添加到账号 $account 的小说收藏；保留已有收藏。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('添加'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      final count = await c.collectLocalBooks(account, retryOnly: retryOnly);
      if (mounted) {
        _message(context, '已确认收藏 $count 部，失败 ${c.collectFailures.length} 部');
      }
    } catch (e) {
      if (mounted) _message(context, e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<SessionController>(),
        c = context.watch<NovelController>();
    if (!s.isLoggedIn) {
      return Center(
        child: FilledButton.icon(
          icon: const Icon(Icons.login),
          label: const Text('登录拷贝漫画'),
          onPressed: () => Navigator.of(
            context,
          ).push(MaterialPageRoute<bool>(builder: (_) => const LoginPage())),
        ),
      );
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Expanded(child: Text('共 ${c.favorites.length} 部小说收藏')),
              FilledButton.tonalIcon(
                onPressed: _loading || c.collecting ? null : () => _load(true),
                icon: const Icon(Icons.sync),
                label: const Text('刷新收藏'),
              ),
              PopupMenuButton<String>(
                tooltip: '小说收藏操作',
                enabled: !_loading && !c.collecting,
                onSelected: (value) => value == 'all'
                    ? _load(true, checkAll: true)
                    : _collectLocal(retryOnly: value == 'retry'),
                itemBuilder: (_) => [
                  const PopupMenuItem(value: 'all', child: Text('检查全部收藏')),
                  const PopupMenuItem(value: 'add', child: Text('收藏本地已匹配小说')),
                  if (c.collectFailures.isNotEmpty)
                    const PopupMenuItem(value: 'retry', child: Text('重试收藏失败')),
                ],
              ),
            ],
          ),
        ),
        if (_loading) const LinearProgressIndicator(),
        if (c.collecting) ...[
          LinearProgressIndicator(
            value: c.collectTotal == 0 ? null : c.collectDone / c.collectTotal,
          ),
          Text(
            '收藏 ${c.collectDone}/${c.collectTotal}，失败 ${c.collectFailures.length}',
          ),
          TextButton(onPressed: c.cancelCollect, child: const Text('停止添加')),
        ],
        if (c.collectFailures.isNotEmpty)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(c.collectFailures.values.first),
          ),
        if (_error.isNotEmpty)
          Padding(padding: const EdgeInsets.all(12), child: Text(_error)),
        Expanded(
          child: NovelGrid(books: c.favorites, empty: '还没有缓存小说收藏'),
        ),
      ],
    );
  }
}

class NovelDetailPage extends StatefulWidget {
  const NovelDetailPage({super.key, required this.book});
  final Novel book;
  @override
  State<NovelDetailPage> createState() => _NovelDetailPageState();
}

class _NovelDetailPageState extends State<NovelDetailPage> {
  late Novel _book;
  List<NovelVolume> _volumes = [];
  bool _loading = true;
  String _error = '';
  @override
  void initState() {
    super.initState();
    _book = widget.book;
    unawaited(_load());
  }

  Future<void> _load({bool update = false}) async {
    setState(() {
      _loading = true;
      _error = '';
    });
    final c = context.read<NovelController>();
    try {
      await c.store.ensureSchema();
      final saved = _book.uuid.isEmpty ? null : await c.store.book(_book.uuid);
      if (saved != null) _book = saved;
      _volumes = _book.uuid.isEmpty ? [] : await c.store.volumes(_book.uuid);
      if (update || _volumes.isEmpty) {
        _book = await c.updateBook(_book);
        _volumes = await c.store.volumes(_book.uuid);
      }
    } catch (e) {
      _error = e.toString();
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<NovelController>();
    final session = context.watch<SessionController>();
    return Scaffold(
      appBar: AppBar(
        title: Text(_book.title),
        actions: [
          if (!_book.isLocal)
            IconButton(
              tooltip: '更新小说目录',
              onPressed: _loading ? null : () => _load(update: true),
              icon: const Icon(Icons.refresh),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 110,
                      height: 145,
                      child: ComicCover(
                        title: _book.title,
                        localPath: _book.coverRelativePath.isEmpty
                            ? ''
                            : c.store.absolute(_book.coverRelativePath),
                        networkUrl: _book.coverUrl,
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _book.title,
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                          const SizedBox(height: 8),
                          Text(_book.authors),
                          const SizedBox(height: 8),
                          Text('${_volumes.length} 卷 / 文件'),
                          FavoriteButton(
                            scope: (
                              session.client.sessionRevision,
                              session.username,
                              c.store.key,
                              _book.uuid,
                            ),
                            loggedIn: session.isLoggedIn,
                            available:
                                !_book.isLocal &&
                                _book.uuid.isNotEmpty &&
                                _book.pathWord.isNotEmpty,
                            blocked: c.collecting,
                            loadSelected: () =>
                                c.isCollected(_book, session.accountKey),
                            setSelected: (value) =>
                                c.favorite(_book, value, session.accountKey),
                            onLogin: () async {
                              await Navigator.of(context).push<bool>(
                                MaterialPageRoute(
                                  builder: (_) => const LoginPage(),
                                ),
                              );
                            },
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                if (_book.brief.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: Text(_book.brief),
                  ),
                if (_error.isNotEmpty)
                  Text(
                    _error,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                if (!_book.isLocal)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Wrap(
                      spacing: 12,
                      runSpacing: 8,
                      children: [
                        FilledButton.tonalIcon(
                          onPressed: _volumes.isEmpty
                              ? null
                              : () => _download(false),
                          icon: const Icon(Icons.checklist),
                          label: const Text('选择下载'),
                        ),
                        OutlinedButton(
                          onPressed: _volumes.isEmpty
                              ? null
                              : () => _download(true),
                          child: const Text('下载全部缺卷'),
                        ),
                      ],
                    ),
                  ),
                for (final v in _volumes)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(v.title),
                    leading: Icon(
                      v.downloaded ? Icons.download_done : Icons.cloud_outlined,
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => NovelReaderPage(book: _book, volume: v),
                      ),
                    ),
                  ),
              ],
            ),
    );
  }

  Future<void> _download(bool all) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => NovelDownloadSelectionPage(
          book: _book,
          volumes: _volumes,
          selectMissing: all,
        ),
      ),
    );
    if (mounted) await _load();
  }
}

class NovelDownloadSelectionPage extends StatefulWidget {
  const NovelDownloadSelectionPage({
    super.key,
    required this.book,
    required this.volumes,
    this.selectMissing = false,
  });
  final Novel book;
  final List<NovelVolume> volumes;
  final bool selectMissing;
  @override
  State<NovelDownloadSelectionPage> createState() =>
      _NovelDownloadSelectionPageState();
}

class _NovelDownloadSelectionPageState
    extends State<NovelDownloadSelectionPage> {
  final _selected = <String>{};
  bool _busy = false;
  @override
  void initState() {
    super.initState();
    if (widget.selectMissing) {
      _selected.addAll(
        widget.volumes.where((v) => !v.downloaded).map((v) => v.id),
      );
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('下载小说'),
      actions: [
        TextButton(
          onPressed: _busy
              ? null
              : () => setState(() {
                  final missing = widget.volumes
                      .where((v) => !v.downloaded)
                      .map((v) => v.id)
                      .toSet();
                  if (_selected.containsAll(missing)) {
                    _selected.clear();
                  } else {
                    _selected.addAll(missing);
                  }
                }),
          child: const Text('全选 / 取消'),
        ),
      ],
    ),
    body: ListView(
      children: [
        for (final v in widget.volumes)
          CheckboxListTile(
            title: Text(v.title),
            subtitle: v.downloaded ? const Text('已下载') : null,
            value: _selected.contains(v.id),
            onChanged: v.downloaded || _busy
                ? null
                : (value) => setState(() {
                    if (value == true) {
                      _selected.add(v.id);
                    } else {
                      _selected.remove(v.id);
                    }
                  }),
          ),
      ],
    ),
    bottomNavigationBar: SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: FilledButton(
          onPressed: _busy || _selected.isEmpty
              ? null
              : () async {
                  setState(() => _busy = true);
                  try {
                    final count = await context.read<NovelController>().enqueue(
                      widget.book,
                      widget.volumes.where((v) => _selected.contains(v.id)),
                    );
                    if (context.mounted) {
                      _message(context, '已加入 $count 卷');
                      Navigator.of(context).pop();
                    }
                  } catch (e) {
                    if (context.mounted) _message(context, e.toString());
                  } finally {
                    if (mounted) setState(() => _busy = false);
                  }
                },
          child: Text('加入下载（${_selected.length}）'),
        ),
      ),
    ),
  );
}

class NovelDownloadsPage extends StatelessWidget {
  const NovelDownloadsPage({super.key});
  @override
  Widget build(BuildContext context) {
    final c = context.watch<NovelController>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('小说下载任务'),
        actions: [
          IconButton(
            tooltip: '重试失败',
            onPressed: c.retryFailures,
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: '清理已完成和失败任务',
            onPressed: c.clearFinished,
            icon: const Icon(Icons.cleaning_services_outlined),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(child: Text('${c.tasks.length} 个任务')),
                FilledButton.tonalIcon(
                  onPressed: c.paused ? c.resume : c.pause,
                  icon: Icon(c.paused ? Icons.play_arrow : Icons.pause),
                  label: Text(c.paused ? '全部继续' : '全部暂停'),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: c.tasks.length,
              itemBuilder: (_, i) {
                final t = c.tasks[i];
                return FutureBuilder<NovelVolume>(
                  future: c.store.volume(
                    novelText(t['novel_uuid']),
                    novelText(t['volume_id']),
                  ),
                  builder: (_, snapshot) {
                    final b = c.books
                        .where((b) => b.uuid == t['novel_uuid'])
                        .firstOrNull;
                    return ListTile(
                      title: Text(
                        '${b?.title ?? '小说'} · ${snapshot.data?.title ?? t['volume_id']}',
                      ),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(_stateLabel(novelText(t['state']))),
                          if (novelText(t['error_message']).isNotEmpty)
                            Text(novelText(t['error_message'])),
                          LinearProgressIndicator(
                            value: (t['progress'] as num?)?.toDouble() ?? 0,
                          ),
                        ],
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  static String _stateLabel(String s) => switch (s) {
    'queued' => '等待中',
    'downloading' => '下载中',
    'paused' => '已暂停',
    'completed' => '已完成',
    'failed' => '失败',
    _ => s,
  };
}

void _message(BuildContext context, String message) => ScaffoldMessenger.of(
  context,
).showSnackBar(SnackBar(content: Text(message)));
