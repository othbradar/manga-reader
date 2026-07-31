import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../controllers/download_controller.dart';
import '../controllers/library_controller.dart';
import '../core/async_retry.dart';
import '../models/chapter.dart';
import '../models/comic.dart';
import 'comic_detail_page.dart';

class CopyMangaBatchUpdatePage extends StatefulWidget {
  const CopyMangaBatchUpdatePage({super.key});

  @override
  State<CopyMangaBatchUpdatePage> createState() =>
      _CopyMangaBatchUpdatePageState();
}

class _CopyMangaBatchUpdatePageState extends State<CopyMangaBatchUpdatePage> {
  List<_ScanItem> _items = const [];
  int _completed = 0;
  int _total = 0;
  bool _scanning = false;
  bool _retrying = false;
  bool _enqueueing = false;
  bool _cancelRequested = false;
  int? _enqueuedCount;
  String _error = '';

  int get _failedCount => _items.where((item) => item.error.isNotEmpty).length;
  int get _missingComicCount =>
      _items.where((item) => item.missing.isNotEmpty).length;
  int get _missingChapterCount =>
      _items.fold(0, (sum, item) => sum + item.missing.length);
  int get _briefCount =>
      _items.where((item) => item.comic.brief.isNotEmpty).length;

  @override
  void dispose() {
    _cancelRequested = true;
    super.dispose();
  }

  Future<void> _scan() async {
    if (_scanning || _enqueueing) return;
    final library = context.read<LibraryController>();
    List<Comic> comics;
    try {
      comics = await library.copyMangaComics();
    } catch (exception) {
      if (mounted) setState(() => _error = '读取漫画库失败：$exception');
      return;
    }
    await _runScan(comics, retryingFailures: false);
  }

  Future<void> _retryFailures() async {
    if (_scanning || _enqueueing) return;
    final failed = _items
        .where((item) => item.error.isNotEmpty)
        .map((item) => item.comic)
        .toList(growable: false);
    if (failed.isEmpty) return;
    await _runScan(failed, retryingFailures: true);
  }

  Future<void> _runScan(
    List<Comic> comics, {
    required bool retryingFailures,
  }) async {
    final library = context.read<LibraryController>();
    final concurrency = library.batchScanConcurrency;
    if (!mounted) return;
    setState(() {
      if (!retryingFailures) _items = const [];
      _completed = 0;
      _total = comics.length;
      _scanning = true;
      _retrying = retryingFailures;
      _cancelRequested = false;
      _enqueuedCount = null;
      _error = '';
    });
    if (comics.isEmpty) {
      setState(() => _scanning = false);
      return;
    }

    var nextIndex = 0;
    Future<void> worker() async {
      while (!_cancelRequested) {
        if (nextIndex >= comics.length) return;
        final comic = comics[nextIndex++];
        final item = await _scanComic(library, comic);
        if (!mounted) return;
        setState(() {
          if (retryingFailures) {
            final updated = List<_ScanItem>.of(_items);
            final existingIndex = updated.indexWhere(
              (current) => current.comic.stableIdentity == comic.stableIdentity,
            );
            if (existingIndex >= 0) {
              updated[existingIndex] = item;
            } else {
              updated.add(item);
            }
            _items = updated;
          } else {
            _items = [..._items, item];
          }
          _completed++;
        });
      }
    }

    final workerCount = math.min(concurrency, comics.length);
    try {
      await Future.wait(List.generate(workerCount, (_) => worker()));
      await library.refresh();
    } catch (exception) {
      _error = '刷新漫画列表失败：$exception';
    }
    if (!mounted) return;
    setState(() {
      _scanning = false;
      _items = [..._items]
        ..sort((left, right) {
          final byError = left.error.isNotEmpty == right.error.isNotEmpty
              ? 0
              : left.error.isNotEmpty
              ? 1
              : -1;
          if (byError != 0) return byError;
          final byMissing = right.missing.length.compareTo(left.missing.length);
          return byMissing != 0
              ? byMissing
              : left.comic.title.compareTo(right.comic.title);
        });
    });
  }

  Future<_ScanItem> _scanComic(LibraryController library, Comic comic) async {
    try {
      return await retryAsync(() async {
        final result = await library.refreshDetailsForBatch(comic);
        final missing = result.chapters
            .where((chapter) => !chapter.isDownloaded)
            .toList(growable: false);
        return _ScanItem(
          comic: result.comic,
          chapters: result.chapters,
          missing: missing,
        );
      }, shouldContinue: () => !_cancelRequested);
    } on AsyncRetryException catch (exception) {
      return _ScanItem(
        comic: comic,
        chapters: const [],
        missing: const [],
        error: exception.cancelled
            ? '扫描已停止，可重新重试'
            : '已尝试 ${exception.attempts} 次仍失败：${exception.cause}',
      );
    }
  }

  Future<void> _enqueueAll() async {
    if (_scanning || _enqueueing || _missingChapterCount == 0) return;
    setState(() => _enqueueing = true);
    try {
      final selections = _items
          .where((item) => item.missing.isNotEmpty)
          .map(
            (item) => ComicDownloadSelection(
              comic: item.comic,
              chapters: item.missing,
            ),
          );
      final added = await context.read<DownloadController>().enqueueBatch(
        selections,
      );
      if (!mounted) return;
      setState(() => _enqueuedCount = added);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('已加入 $added 个章节到下载任务')));
    } catch (exception) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('加入下载失败：$exception')));
      }
    } finally {
      if (mounted) setState(() => _enqueueing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final progress = _total == 0 ? 0.0 : _completed / _total;
    return Scaffold(
      appBar: AppBar(title: const Text('拷贝漫画补缺')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            _scanning
                                ? _retrying
                                      ? '正在重试 $_completed / $_total'
                                      : '正在并发扫描 $_completed / $_total'
                                : _items.isEmpty
                                ? '尚未扫描'
                                : _cancelRequested && _completed < _total
                                ? '已停止 $_completed / $_total'
                                : _retrying
                                ? '重试完成 $_completed / $_total'
                                : '扫描完成 $_completed / $_total',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ),
                        if (_scanning)
                          TextButton(
                            onPressed: () =>
                                setState(() => _cancelRequested = true),
                            child: const Text('停止'),
                          )
                        else
                          FilledButton.icon(
                            onPressed: _enqueueing ? null : _scan,
                            icon: const Icon(Icons.manage_search),
                            label: Text(_items.isEmpty ? '开始扫描' : '重新扫描'),
                          ),
                      ],
                    ),
                    if (_scanning) ...[
                      const SizedBox(height: 10),
                      LinearProgressIndicator(value: progress),
                      const SizedBox(height: 6),
                      Text(
                        '${context.read<LibraryController>().batchScanConcurrency} 路并发',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                    if (_items.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 14,
                        runSpacing: 6,
                        children: [
                          Text('有缺章 $_missingComicCount 部'),
                          Text('缺 $_missingChapterCount 章'),
                          Text('已有简介 $_briefCount 部'),
                          Text('失败 $_failedCount 部'),
                        ],
                      ),
                      const SizedBox(height: 12),
                      if (_failedCount > 0) ...[
                        OutlinedButton.icon(
                          onPressed: !_scanning && !_enqueueing
                              ? _retryFailures
                              : null,
                          icon: const Icon(Icons.refresh),
                          label: Text('重试全部失败项（$_failedCount）'),
                        ),
                        const SizedBox(height: 8),
                      ],
                      FilledButton.tonalIcon(
                        onPressed:
                            !_scanning &&
                                !_enqueueing &&
                                _missingChapterCount > 0
                            ? _enqueueAll
                            : null,
                        icon: _enqueueing
                            ? const SizedBox.square(
                                dimension: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.5,
                                ),
                              )
                            : const Icon(Icons.download_for_offline_outlined),
                        label: Text(
                          _enqueuedCount == null
                              ? '全部缺章加入下载'
                              : '已加入 $_enqueuedCount 个任务',
                        ),
                      ),
                    ],
                    if (_error.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Text(
                        _error,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          Expanded(
            child: _items.isEmpty
                ? const Center(child: Text('扫描会同时缓存漫画详情和简介'))
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 48),
                    itemCount: _items.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, index) {
                      final item = _items[index];
                      return _ScanItemCard(
                        item: item,
                        onOpen: item.error.isEmpty
                            ? () => Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                  builder: (_) =>
                                      ComicDetailPage(comic: item.comic),
                                ),
                              )
                            : null,
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _ScanItem {
  const _ScanItem({
    required this.comic,
    required this.chapters,
    required this.missing,
    this.error = '',
  });

  final Comic comic;
  final List<Chapter> chapters;
  final List<Chapter> missing;
  final String error;
}

class _ScanItemCard extends StatelessWidget {
  const _ScanItemCard({required this.item, required this.onOpen});

  final _ScanItem item;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final downloaded = item.chapters.length - item.missing.length;
    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        onTap: onOpen,
        leading: CircleAvatar(
          child: item.error.isEmpty
              ? Text('${item.missing.length}')
              : const Icon(Icons.error_outline),
        ),
        title: Text(item.comic.title),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              item.error.isEmpty
                  ? '已下载 $downloaded / ${item.chapters.length}，缺 ${item.missing.length} 章'
                  : item.error,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            if (item.comic.brief.isNotEmpty)
              Text(
                item.comic.brief,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
          ],
        ),
        isThreeLine: item.comic.brief.isNotEmpty || item.error.isNotEmpty,
        trailing: onOpen == null ? null : const Icon(Icons.chevron_right),
      ),
    );
  }
}
