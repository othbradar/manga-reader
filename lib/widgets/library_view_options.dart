import 'package:flutter/material.dart';

import '../models/library_view.dart';

/// Shared layout and labels for the comic and novel library view controls.
class LibraryViewOptions extends StatelessWidget {
  const LibraryViewOptions({
    super.key,
    required this.sourceLabel,
    required this.sourceFilter,
    required this.sortMode,
    required this.onSourceChanged,
    required this.onSortChanged,
  });

  final String sourceLabel;
  final ComicSourceFilter sourceFilter;
  final ComicSortMode sortMode;
  final ValueChanged<ComicSourceFilter> onSourceChanged;
  final ValueChanged<ComicSortMode> onSortChanged;

  @override
  Widget build(BuildContext context) => SafeArea(
    child: SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('筛选与排序', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 20),
          Text(sourceLabel, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: ComicSourceFilter.values
                .map(
                  (value) => ChoiceChip(
                    label: Text(value.label),
                    selected: sourceFilter == value,
                    onSelected: (_) => onSourceChanged(value),
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
                  (value) =>
                      ButtonSegment(value: value, label: Text(value.label)),
                )
                .toList(growable: false),
            selected: {sortMode},
            onSelectionChanged: (selection) => onSortChanged(selection.single),
          ),
        ],
      ),
    ),
  );
}
