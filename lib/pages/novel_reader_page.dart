import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:sqflite/sqflite.dart';

import '../controllers/novel_controller.dart';
import '../models/novel.dart';
import '../services/novel_text.dart';

class NovelReaderPage extends StatefulWidget {
  const NovelReaderPage({super.key, required this.book, required this.volume});
  final Novel book;
  final NovelVolume volume;
  @override
  State<NovelReaderPage> createState() => _NovelReaderPageState();
}

class _NovelBlock {
  const _NovelBlock(
    this.text,
    this.line, {
    this.imageUrl = '',
    this.imagePath = '',
  });
  final String text, imageUrl, imagePath;
  final int line;
  bool get image => imageUrl.isNotEmpty || imagePath.isNotEmpty;
}

class _NovelReaderPageState extends State<NovelReaderPage> {
  late NovelController _novels;
  late String _libraryKey;
  late NovelVolume _volume;
  final List<_NovelBlock> _blocks = [];
  List<double> _offsets = [];
  ScrollController? _scroll;
  Timer? _saveTimer;
  bool _loading = true, _controls = true, _measuring = false;
  String _error = '';
  double _font = 20, _lineHeight = 1.7, _width = 0;
  int _restoreBlock = 0, _layoutGeneration = 0;
  double _restoreFraction = 0;
  TextStyle get _style => TextStyle(fontSize: _font, height: _lineHeight);

  @override
  void initState() {
    super.initState();
    _novels = context.read<NovelController>();
    _libraryKey = _novels.store.key;
    _volume = widget.volume;
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final local = _novels.store.library.localDatabase;
      _font = (double.tryParse(await local.preference('novel_font_size')) ?? 20)
          .clamp(14, 32);
      _lineHeight =
          (double.tryParse(await local.preference('novel_line_height')) ?? 1.7)
              .clamp(1.2, 2.4);
      final progress = await local.database.query(
        'novel_progress',
        where: 'library_key=? AND novel_uuid=? AND volume_id=?',
        whereArgs: [_libraryKey, widget.book.uuid, _volume.id],
      );
      if (progress.isNotEmpty) {
        _restoreBlock = novelInt(progress.first['block_index']);
        _restoreFraction =
            (progress.first['fraction'] as num?)?.toDouble() ?? 0;
      }
      String text;
      if (_volume.downloaded) {
        _volume = await _novels.store.volume(widget.book.uuid, _volume.id);
        final file = File(_novels.store.absolute(_volume.relativePath));
        if (!await file.exists()) {
          throw const FileSystemException('小说文本不存在，请确认外置盘已连接且目录已授权');
        }
        text = decodeNovelText(
          await file.readAsBytes(),
          encoding: _volume.encoding,
        );
        text = localNovelPlainText(text);
      } else {
        _volume = await _novels.client.content(widget.book, _volume);
        final temp = await getTemporaryDirectory();
        final cache = Directory(p.join(temp.path, 'copy_novel_online_cache'));
        await cache.create(recursive: true);
        final id = sha256
            .convert(
              utf8.encode(
                '${widget.book.uuid}|${_volume.id}|${_volume.textUrl}',
              ),
            )
            .toString();
        final file = File(p.join(cache.path, '$id.txt'));
        if (await file.exists()) {
          text = await file.readAsString();
        } else {
          text = decodeNovelText(
            await _novels.client.bytes(_volume.textUrl),
            encoding: _volume.encoding,
          );
          final part = File(
            '${file.path}.${DateTime.now().microsecondsSinceEpoch}.part',
          );
          await part.writeAsString(text, flush: true);
          await part.rename(file.path);
        }
      }
      final lines = novelLines(text);
      var chunk = StringBuffer(), start = 0;
      void flush() {
        if (chunk.isNotEmpty) {
          _blocks.add(_NovelBlock(chunk.toString(), start));
          chunk = StringBuffer();
        }
      }

      for (var i = 0; i < lines.length; i++) {
        final image = RegExp(r'^【插图：(.+)】$').firstMatch(lines[i].trim());
        if (image != null && _volume.downloaded) {
          flush();
          final imageRelative = p.posix.normalize(
            p.posix.join(
              p.posix.dirname(_volume.relativePath),
              image.group(1)!,
            ),
          );
          final imagePath = _novels.store.absolute(imageRelative);
          _blocks.add(_NovelBlock('', i, imagePath: imagePath));
          start = i + 1;
          continue;
        }
        if (chunk.isEmpty) start = i;
        chunk.writeln(lines[i]);
        if (chunk.length >= 1000) flush();
      }
      flush();
      for (final section in _volume.sections.where((s) => s.isImage)) {
        _blocks.add(
          _NovelBlock(
            section.title,
            lines.length + section.index,
            imageUrl: section.imageUrl,
            imagePath: section.imagePath.isEmpty
                ? ''
                : _novels.store.absolute(section.imagePath),
          ),
        );
      }
      if (_blocks.isEmpty) throw const FormatException('小说文本为空');
    } catch (e) {
      _error = e.toString();
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  (int, double) _position() {
    if (_scroll?.hasClients != true || _offsets.length < 2) {
      return (_restoreBlock, _restoreFraction);
    }
    final offset = _scroll!.offset;
    var low = 0, high = _blocks.length - 1;
    while (low < high) {
      final mid = (low + high + 1) ~/ 2;
      if (_offsets[mid] <= offset) {
        low = mid;
      } else {
        high = mid - 1;
      }
    }
    return (
      low,
      ((offset - _offsets[low]) / (_offsets[low + 1] - _offsets[low])).clamp(
        0,
        1,
      ),
    );
  }

  Future<void> _save() async {
    if (_blocks.isEmpty ||
        _offsets.isEmpty ||
        _libraryKey != _novels.store.key) {
      return;
    }
    final (index, fraction) = _position();
    _restoreBlock = index;
    _restoreFraction = fraction;
    await _novels.store.library.localDatabase.database
        .insert('novel_progress', {
          'library_key': _libraryKey,
          'novel_uuid': widget.book.uuid,
          'volume_id': _volume.id,
          'block_index': index,
          'fraction': fraction,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  void _scrolled() {
    final position = _position();
    _restoreBlock = position.$1;
    _restoreFraction = position.$2;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 400), () {
      unawaited(_save());
    });
  }

  Future<void> _measure(double width) async {
    final generation = ++_layoutGeneration;
    _measuring = true;
    final anchor = _position();
    final offsets = <double>[0];
    final scaler = MediaQuery.textScalerOf(context);
    final style = _style;
    for (var i = 0; i < _blocks.length; i++) {
      final b = _blocks[i];
      double height;
      if (b.image) {
        height = math.min(700, width * 1.45) + 44;
      } else {
        final painter = TextPainter(
          text: TextSpan(text: b.text, style: style),
          textDirection: TextDirection.ltr,
          textScaler: scaler,
        )..layout(maxWidth: width);
        height = painter.height + 8;
        painter.dispose();
      }
      offsets.add(offsets.last + height);
      if (i % 20 == 19) {
        await Future<void>.delayed(Duration.zero);
        if (!mounted || generation != _layoutGeneration) return;
      }
    }
    if (!mounted || generation != _layoutGeneration) return;
    final block = anchor.$1.clamp(0, _blocks.length - 1);
    final offset =
        offsets[block] + anchor.$2 * (offsets[block + 1] - offsets[block]);
    final old = _scroll;
    _scroll = ScrollController(initialScrollOffset: offset)
      ..addListener(_scrolled);
    setState(() {
      _offsets = offsets;
      _width = width;
      _measuring = false;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      old?.dispose();
    });
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    unawaited(_save());
    _layoutGeneration++;
    _scroll?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: _controls
          ? AppBar(
              title: Text('${widget.book.title} · ${_volume.title}'),
              actions: [
                IconButton(
                  tooltip: '目录',
                  onPressed: _blocks.isEmpty ? null : _contents,
                  icon: const Icon(Icons.list),
                ),
                IconButton(
                  tooltip: '阅读设置',
                  onPressed: _readingSettings,
                  icon: const Icon(Icons.text_fields),
                ),
              ],
            )
          : null,
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error.isNotEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(_error),
              ),
            )
          : SafeArea(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 900),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final width = constraints.maxWidth - 32;
                      if (width != _width && !_measuring) {
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          if (mounted) _measure(width);
                        });
                      }
                      if (_offsets.isEmpty || width != _width) {
                        return const Center(child: CircularProgressIndicator());
                      }
                      return GestureDetector(
                        behavior: HitTestBehavior.translucent,
                        onTap: () => setState(() => _controls = !_controls),
                        child: ListView.builder(
                          key: ValueKey((_width, _font, _lineHeight)),
                          controller: _scroll,
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          itemCount: _blocks.length,
                          itemExtentBuilder: (i, _) =>
                              _offsets[i + 1] - _offsets[i],
                          itemBuilder: (_, i) {
                            final b = _blocks[i];
                            if (!b.image) return Text(b.text, style: _style);
                            return Column(
                              children: [
                                Expanded(
                                  child: InteractiveViewer(
                                    minScale: 1,
                                    maxScale: 4,
                                    child: b.imagePath.isNotEmpty
                                        ? Image.file(
                                            File(b.imagePath),
                                            fit: BoxFit.contain,
                                            errorBuilder: (_, e, _) =>
                                                const Center(
                                                  child: Text('插图文件不可用'),
                                                ),
                                          )
                                        : CachedNetworkImage(
                                            imageUrl: b.imageUrl,
                                            fit: BoxFit.contain,
                                            errorWidget: (_, _, _) =>
                                                const Center(
                                                  child: Text('插图暂时无法加载'),
                                                ),
                                          ),
                                  ),
                                ),
                                SizedBox(
                                  height: 44,
                                  child: Center(child: Text(b.text)),
                                ),
                              ],
                            );
                          },
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
    );
  }

  Future<void> _contents() async {
    final index = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (_) => ListView(
        children: [
          ListTile(
            title: const Text('从头阅读'),
            onTap: () => Navigator.of(context).pop(0),
          ),
          for (final s in _volume.sections)
            ListTile(
              title: Text(s.title),
              leading: Icon(s.isImage ? Icons.image_outlined : Icons.subject),
              onTap: () {
                final i = s.isImage
                    ? _blocks.indexWhere(
                        (b) =>
                            b.image &&
                            (b.imageUrl == s.imageUrl ||
                                b.imagePath.endsWith(s.imagePath) &&
                                    s.imagePath.isNotEmpty),
                      )
                    : _blocks.lastIndexWhere(
                        (b) => !b.image && b.line <= s.start,
                      );
                Navigator.of(context).pop(math.max(0, i));
              },
            ),
        ],
      ),
    );
    if (index != null && mounted && _scroll?.hasClients == true) {
      _scroll!.jumpTo(
        _offsets[index].clamp(0, _scroll!.position.maxScrollExtent),
      );
      await _save();
    }
  }

  Future<void> _readingSettings() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => StatefulBuilder(
        builder: (context, setSheet) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('字号 ${_font.round()}'),
                Slider(
                  value: _font,
                  min: 14,
                  max: 32,
                  divisions: 18,
                  onChanged: (v) => setSheet(() => _font = v),
                ),
                Text('行距 ${_lineHeight.toStringAsFixed(1)}'),
                Slider(
                  value: _lineHeight,
                  min: 1.2,
                  max: 2.4,
                  divisions: 12,
                  onChanged: (v) => setSheet(() => _lineHeight = v),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (!mounted) return;
    await _novels.store.library.localDatabase.setPreference(
      'novel_font_size',
      _font.toString(),
    );
    await _novels.store.library.localDatabase.setPreference(
      'novel_line_height',
      _lineHeight.toString(),
    );
    if (mounted) await _measure(_width);
  }
}
