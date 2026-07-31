import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../controllers/reader_controller.dart';
import '../controllers/reading_history_controller.dart';
import '../core/continuous_reader_layout.dart';
import '../models/chapter.dart';
import '../models/comic.dart';
import '../services/copy_client.dart';
import '../widgets/zoomable_viewport.dart';

class ReaderPage extends StatefulWidget {
  const ReaderPage({
    super.key,
    required this.comic,
    required this.chapter,
    required this.archivePath,
  }) : online = false;

  const ReaderPage.online({
    super.key,
    required this.comic,
    required this.chapter,
  }) : archivePath = null,
       online = true;

  final Comic comic;
  final Chapter chapter;
  final String? archivePath;
  final bool online;

  @override
  State<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends State<ReaderPage> {
  late final ReaderController _controller;
  final _zoomKey = GlobalKey<ZoomableViewportState>();
  final _verticalViewportKey = GlobalKey();
  final _verticalCenterKey = GlobalKey();
  ScrollController _verticalController = ScrollController(
    keepScrollOffset: false,
  );
  PageController? _pageController;
  List<GlobalKey> _verticalPageKeys = const [];
  bool _visiblePageUpdateScheduled = false;
  int _verticalAnchorPage = 0;

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _controller =
        (widget.online
              ? ReaderController.online(
                  history: context.read<ReadingHistoryController>(),
                  comic: widget.comic,
                  chapter: widget.chapter,
                  client: context.read<CopyClient>(),
                )
              : ReaderController(
                  history: context.read<ReadingHistoryController>(),
                  comic: widget.comic,
                  chapter: widget.chapter,
                  archivePath: widget.archivePath!,
                ))
          ..initialize().then((_) {
            if (!mounted || _controller.error.isNotEmpty) return;
            setState(() {
              _verticalPageKeys = List.generate(
                _controller.pageCount,
                (_) => GlobalKey(),
              );
              _verticalAnchorPage = _controller.currentPage;
              _pageController = PageController(
                initialPage: _controller.currentPage,
              );
            });
          });
  }

  @override
  void dispose() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _pageController?.dispose();
    _verticalController.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider.value(
      value: _controller,
      child: Consumer<ReaderController>(
        builder: (context, reader, _) {
          return Scaffold(
            backgroundColor: Colors.black,
            appBar: reader.chromeVisible
                ? AppBar(
                    backgroundColor: Colors.black.withValues(alpha: 0.82),
                    foregroundColor: Colors.white,
                    title: Text(
                      widget.chapter.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    actions: [
                      IconButton(
                        tooltip: '缩小',
                        onPressed: () => _zoomKey.currentState?.zoomOut(),
                        icon: const Icon(Icons.zoom_out),
                      ),
                      IconButton(
                        tooltip: '放大',
                        onPressed: () => _zoomKey.currentState?.zoomIn(),
                        icon: const Icon(Icons.zoom_in),
                      ),
                      IconButton(
                        tooltip: reader.direction == ReaderDirection.horizontal
                            ? '切换为上下阅读'
                            : '切换为左右阅读',
                        onPressed: () => _toggleDirection(reader),
                        icon: Icon(
                          reader.direction == ReaderDirection.horizontal
                              ? Icons.swap_vert
                              : Icons.swap_horiz,
                        ),
                      ),
                    ],
                  )
                : null,
            body: _buildBody(reader),
            bottomNavigationBar: reader.chromeVisible && reader.pageCount > 0
                ? SafeArea(
                    child: Container(
                      color: Colors.black.withValues(alpha: 0.82),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      child: Text(
                        '${reader.currentPage + 1} / ${reader.pageCount}',
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white),
                      ),
                    ),
                  )
                : null,
          );
        },
      ),
    );
  }

  Widget _buildBody(ReaderController reader) {
    if (reader.error.isNotEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            '章节打开失败\n${reader.error}',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white),
          ),
        ),
      );
    }
    if (reader.loading || _pageController == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return ZoomableViewport(
      key: _zoomKey,
      onTap: reader.toggleChrome,
      onVerticalScroll: reader.direction == ReaderDirection.vertical
          ? _scrollZoomedVertical
          : null,
      builder: (context, zoomed, scrollLocked) {
        if (reader.direction == ReaderDirection.vertical) {
          return _buildContinuousReader(reader, zoomed, scrollLocked);
        }
        return _buildHorizontalReader(reader, zoomed, scrollLocked);
      },
    );
  }

  Widget _buildHorizontalReader(
    ReaderController reader,
    bool zoomed,
    bool scrollLocked,
  ) {
    return PageView.builder(
      key: const ValueKey(ReaderDirection.horizontal),
      controller: _pageController,
      physics: scrollLocked ? const NeverScrollableScrollPhysics() : null,
      itemCount: reader.pageCount,
      onPageChanged: reader.changePage,
      itemBuilder: (context, index) {
        return Center(
          child: _pageImage(
            reader,
            index,
            fitWidth: false,
            fullResolution: zoomed,
          ),
        );
      },
    );
  }

  Widget _buildContinuousReader(
    ReaderController reader,
    bool zoomed,
    bool scrollLocked,
  ) {
    if (_verticalPageKeys.length != reader.pageCount) {
      _verticalPageKeys = List.generate(reader.pageCount, (_) => GlobalKey());
    }
    final layout = ContinuousReaderLayout(
      pageCount: reader.pageCount,
      anchorPage: _verticalAnchorPage,
    );
    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification is ScrollEndNotification) {
          _scheduleVisiblePageUpdate(reader);
        }
        return false;
      },
      child: CustomScrollView(
        key: _verticalViewportKey,
        center: _verticalCenterKey,
        controller: _verticalController,
        scrollCacheExtent: const ScrollCacheExtent.viewport(2),
        physics: scrollLocked
            ? const NeverScrollableScrollPhysics()
            : const ClampingScrollPhysics(),
        slivers: [
          SliverList.builder(
            itemCount: layout.beforeAnchorCount,
            itemBuilder: (context, index) {
              return _verticalPage(
                reader,
                layout.pageBeforeAnchor(index),
                zoomed,
              );
            },
          ),
          SliverList.builder(
            key: _verticalCenterKey,
            itemCount: layout.fromAnchorCount,
            itemBuilder: (context, index) {
              return _verticalPage(
                reader,
                layout.pageFromAnchor(index),
                zoomed,
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _verticalPage(ReaderController reader, int pageIndex, bool zoomed) {
    return KeyedSubtree(
      key: _verticalPageKeys[pageIndex],
      child: _pageImage(
        reader,
        pageIndex,
        fitWidth: true,
        fullResolution: zoomed,
      ),
    );
  }

  Widget _pageImage(
    ReaderController reader,
    int index, {
    required bool fitWidth,
    required bool fullResolution,
  }) {
    try {
      final mediaQuery = MediaQuery.of(context);
      final viewportPixelWidth =
          (mediaQuery.size.width * mediaQuery.devicePixelRatio).round();
      Widget image(String path) => Image.file(
        File(path),
        width: fitWidth ? double.infinity : null,
        fit: fitWidth ? BoxFit.fitWidth : BoxFit.contain,
        alignment: Alignment.topCenter,
        gaplessPlayback: true,
        cacheWidth: fullResolution ? null : viewportPixelWidth,
        filterQuality: fullResolution
            ? FilterQuality.medium
            : FilterQuality.low,
        errorBuilder: (_, error, _) =>
            _pageError(reader, index, error, fitWidth),
      );
      final cached = reader.cachedPagePath(index);
      if (cached != null) return image(cached);
      return FutureBuilder<String>(
        future: reader.ensurePagePath(index),
        builder: (context, snapshot) {
          final path = snapshot.data;
          if (path != null) return image(path);
          if (snapshot.hasError) {
            return _pageError(reader, index, snapshot.error!, fitWidth);
          }
          return SizedBox(
            width: double.infinity,
            height: fitWidth ? 240 : null,
            child: const Center(child: CircularProgressIndicator()),
          );
        },
      );
    } catch (error) {
      return _pageError(reader, index, error, fitWidth);
    }
  }

  Widget _pageError(
    ReaderController reader,
    int index,
    Object error,
    bool fitWidth,
  ) {
    return SizedBox(
      width: double.infinity,
      height: fitWidth ? 240 : null,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '第 ${index + 1} 页读取失败\n$error',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70),
            ),
            if (reader.isOnline) ...[
              const SizedBox(height: 8),
              TextButton(
                onPressed: () {
                  reader.retryPage(index);
                  setState(() {});
                },
                child: const Text('重试'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  void _toggleDirection(ReaderController reader) {
    final page = reader.currentPage;
    _zoomKey.currentState?.reset();
    reader.toggleDirection();
    if (reader.direction == ReaderDirection.horizontal) {
      _pageController?.dispose();
      _pageController = PageController(initialPage: page);
    } else {
      reader.setChromeVisible(false);
      _verticalController.dispose();
      _verticalController = ScrollController(keepScrollOffset: false);
      _verticalAnchorPage = page;
    }
    setState(() {});
  }

  void _scheduleVisiblePageUpdate(ReaderController reader) {
    if (_visiblePageUpdateScheduled) return;
    _visiblePageUpdateScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _visiblePageUpdateScheduled = false;
      if (!mounted) return;
      final viewport =
          _verticalViewportKey.currentContext?.findRenderObject() as RenderBox?;
      if (viewport == null || !viewport.hasSize) return;
      final viewportTop = viewport.localToGlobal(Offset.zero).dy;
      final reference = viewportTop + viewport.size.height * 0.35;
      var bestIndex = reader.currentPage;
      var bestDistance = double.infinity;
      for (var index = 0; index < _verticalPageKeys.length; index++) {
        final box =
            _verticalPageKeys[index].currentContext?.findRenderObject()
                as RenderBox?;
        if (box == null || !box.hasSize) continue;
        final top = box.localToGlobal(Offset.zero).dy;
        final bottom = top + box.size.height;
        final distance = reference >= top && reference <= bottom
            ? 0.0
            : ((top + bottom) / 2 - reference).abs();
        if (distance < bestDistance) {
          bestDistance = distance;
          bestIndex = index;
        }
      }
      if (bestIndex != reader.currentPage) reader.changePage(bestIndex);
    });
  }

  double _scrollZoomedVertical(double delta) {
    if (!_verticalController.hasClients || delta == 0) return 0;
    final position = _verticalController.position;
    final before = position.pixels;
    final target = (before + delta).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if (target != before) _verticalController.jumpTo(target);
    return target - before;
  }
}
