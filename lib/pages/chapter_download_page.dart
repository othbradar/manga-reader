import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../controllers/download_controller.dart';
import '../models/chapter.dart';
import '../models/comic.dart';

class ChapterDownloadPage extends StatefulWidget {
  const ChapterDownloadPage({
    super.key,
    required this.comic,
    required this.chapters,
    this.initiallySelected = const <String>{},
  });

  final Comic comic;
  final List<Chapter> chapters;
  final Set<String> initiallySelected;

  @override
  State<ChapterDownloadPage> createState() => _ChapterDownloadPageState();
}

class _ChapterDownloadPageState extends State<ChapterDownloadPage> {
  late final List<Chapter> _missing;
  late final Set<String> _selected;
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    _missing = widget.chapters
        .where((chapter) => !chapter.isDownloaded)
        .toList(growable: false);
    final available = _missing.map((chapter) => chapter.uuid).toSet();
    _selected = widget.initiallySelected.intersection(available);
  }

  void _selectAll() {
    setState(() {
      _selected
        ..clear()
        ..addAll(_missing.map((chapter) => chapter.uuid));
    });
  }

  void _clearSelection() => setState(_selected.clear);

  void _toggle(Chapter chapter, bool selected) {
    setState(() {
      if (selected) {
        _selected.add(chapter.uuid);
      } else {
        _selected.remove(chapter.uuid);
      }
    });
  }

  Future<void> _submit() async {
    if (_submitting || _selected.isEmpty) return;
    setState(() => _submitting = true);
    try {
      final count = await context.read<DownloadController>().enqueue(
        widget.comic,
        _missing.where((chapter) => _selected.contains(chapter.uuid)),
      );
      if (mounted) Navigator.pop(context, count);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final grouped = <String, List<Chapter>>{};
    for (final chapter in _missing) {
      grouped.putIfAbsent(chapter.groupName, () => []).add(chapter);
    }
    return Scaffold(
      appBar: AppBar(title: const Text('选择下载章节')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '已选 ${_selected.length} / ${_missing.length}',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                TextButton(
                  onPressed: _selected.length == _missing.length
                      ? null
                      : _selectAll,
                  child: const Text('全选缺章'),
                ),
                TextButton(
                  onPressed: _selected.isEmpty ? null : _clearSelection,
                  child: const Text('取消全选'),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: _missing.isEmpty
                ? const Center(child: Text('没有未下载章节'))
                : ListView.builder(
                    padding: const EdgeInsets.only(bottom: 24),
                    itemCount: grouped.length,
                    itemBuilder: (context, index) {
                      final entry = grouped.entries.elementAt(index);
                      return ExpansionTile(
                        initiallyExpanded: true,
                        title: Text(entry.key.isEmpty ? '默认' : entry.key),
                        subtitle: Text('${entry.value.length} 个缺章'),
                        children: entry.value
                            .map(
                              (chapter) => CheckboxListTile(
                                value: _selected.contains(chapter.uuid),
                                onChanged: _submitting
                                    ? null
                                    : (value) =>
                                          _toggle(chapter, value ?? false),
                                title: Text(chapter.title),
                                subtitle: chapter.pageCount > 0
                                    ? Text('${chapter.pageCount} 页')
                                    : null,
                                controlAffinity:
                                    ListTileControlAffinity.leading,
                              ),
                            )
                            .toList(growable: false),
                      );
                    },
                  ),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: FilledButton.icon(
          onPressed: _selected.isEmpty || _submitting ? null : _submit,
          icon: _submitting
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2.5),
                )
              : const Icon(Icons.download_for_offline_outlined),
          label: Text('加入下载（${_selected.length}）'),
        ),
      ),
    );
  }
}
