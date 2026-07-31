import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../controllers/download_controller.dart';
import '../models/download_task.dart';

class DownloadsPage extends StatelessWidget {
  const DownloadsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final downloads = context.watch<DownloadController>();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${downloads.tasks.length} 个任务',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    Text(
                      downloads.globalPaused
                          ? '下载已全局暂停'
                          : '剩余 ${downloads.queuedCount} 个',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              FilledButton.icon(
                onPressed: downloads.globalPaused
                    ? downloads.resumeAll
                    : downloads.pauseAll,
                icon: Icon(
                  downloads.globalPaused ? Icons.play_arrow : Icons.pause,
                ),
                label: Text(downloads.globalPaused ? '全部继续' : '全局暂停'),
              ),
              const SizedBox(width: 8),
              IconButton(
                tooltip: '清空下载任务',
                onPressed: downloads.tasks.isEmpty
                    ? null
                    : () => _confirmClear(context, downloads),
                icon: const Icon(Icons.cleaning_services_outlined),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: downloads.tasks.isEmpty
              ? const _EmptyDownloads()
              : ListView.separated(
                  padding: const EdgeInsets.only(bottom: 96),
                  itemCount: downloads.tasks.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final task = downloads.tasks[index];
                    return _TaskTile(
                      task: task,
                      onRetry: () => downloads.retry(task),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Future<void> _confirmClear(
    BuildContext context,
    DownloadController downloads,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清空下载任务？'),
        content: const Text('任务记录会被清空，已经下载完成的漫画文件不会删除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed == true) await downloads.clearAllTasks();
  }
}

class _TaskTile extends StatelessWidget {
  const _TaskTile({required this.task, required this.onRetry});

  final DownloadTask task;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final percentage = (task.progress.clamp(0.0, 1.0) * 100).round();
    final stateText = switch (task.state) {
      DownloadState.queued => '等待中',
      DownloadState.downloading => '下载中 $percentage%',
      DownloadState.paused => task.progress > 0 ? '已暂停 $percentage%' : '已暂停',
      DownloadState.completed => '已完成',
      DownloadState.failed => task.progress > 0 ? '失败 $percentage%' : '失败',
    };
    final icon = switch (task.state) {
      DownloadState.queued => Icons.schedule,
      DownloadState.downloading => Icons.downloading,
      DownloadState.paused => Icons.pause_circle_outline,
      DownloadState.completed => Icons.check_circle,
      DownloadState.failed => Icons.error_outline,
    };
    final color = switch (task.state) {
      DownloadState.completed => Colors.green,
      DownloadState.failed => Theme.of(context).colorScheme.error,
      _ => Theme.of(context).colorScheme.primary,
    };
    return ListTile(
      leading: Icon(icon, color: color),
      title: Text(
        '${task.comicTitle} · ${task.chapterTitle}',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            task.errorMessage.isEmpty
                ? stateText
                : '$stateText：${task.errorMessage}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          if (task.state == DownloadState.downloading ||
              task.progress > 0 && task.state != DownloadState.completed)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: LinearProgressIndicator(value: task.progress),
            ),
        ],
      ),
      trailing:
          task.state == DownloadState.failed ||
              task.state == DownloadState.paused
          ? IconButton(
              tooltip: '重试',
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
            )
          : null,
    );
  }
}

class _EmptyDownloads extends StatelessWidget {
  const _EmptyDownloads();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.download_done, size: 58),
            const SizedBox(height: 16),
            Text('没有下载任务', style: Theme.of(context).textTheme.titleMedium),
          ],
        ),
      ),
    );
  }
}
