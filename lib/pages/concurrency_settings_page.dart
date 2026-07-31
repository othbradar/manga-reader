import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../controllers/download_controller.dart';
import '../controllers/library_controller.dart';

class ConcurrencySettingsPage extends StatelessWidget {
  const ConcurrencySettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final library = context.watch<LibraryController>();
    final downloads = context.watch<DownloadController>();
    return Scaffold(
      appBar: AppBar(title: const Text('并发设置')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 48),
        children: [
          _ConcurrencyCard(
            title: '批量详情扫描',
            value: library.batchScanConcurrency,
            onChanged: library.setBatchScanConcurrency,
          ),
          const SizedBox(height: 12),
          _ConcurrencyCard(
            title: '漫画图片下载',
            value: downloads.imageDownloadConcurrency,
            onChanged: downloads.setImageDownloadConcurrency,
          ),
        ],
      ),
    );
  }
}

class _ConcurrencyCard extends StatelessWidget {
  const _ConcurrencyCard({
    required this.title,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                Text('$value', style: Theme.of(context).textTheme.titleLarge),
              ],
            ),
            Slider(
              value: value.toDouble(),
              min: 1,
              max: 10,
              divisions: 9,
              label: '$value',
              onChanged: (next) => onChanged(next.round()),
            ),
          ],
        ),
      ),
    );
  }
}
