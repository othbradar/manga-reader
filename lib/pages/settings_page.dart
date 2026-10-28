import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../controllers/appearance_controller.dart';
import '../controllers/download_controller.dart';
import '../controllers/favorites_controller.dart';
import '../controllers/library_controller.dart';
import '../controllers/reading_history_controller.dart';
import '../controllers/session_controller.dart';
import '../controllers/novel_controller.dart';
import '../services/copy_api_protocol.dart';
import '../services/copy_client.dart';
import 'concurrency_settings_page.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool _refreshingApiDomains = false;
  bool _refreshingAuthenticationDomains = false;
  bool _transferringAppData = false;

  @override
  Widget build(BuildContext context) {
    final library = context.watch<LibraryController>();
    final appearance = context.watch<AppearanceController>();
    return Scaffold(
      appBar: AppBar(title: const Text('设置与说明')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 48),
        children: [
          if (library.loading && library.operationStatus.isNotEmpty) ...[
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    const SizedBox.square(
                      dimension: 24,
                      child: CircularProgressIndicator(strokeWidth: 3),
                    ),
                    const SizedBox(width: 14),
                    Expanded(child: Text(library.operationStatus)),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
          ],
          _Section(
            title: '外观',
            children: [
              ListTile(
                leading: CircleAvatar(
                  backgroundColor: appearance.themeColor.surface(
                    Theme.of(context).brightness,
                  ),
                  child: const Icon(Icons.palette_outlined),
                ),
                title: const Text('主题颜色'),
                subtitle: Text(appearance.themeColor.label),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _chooseThemeColor(context, appearance),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.dark_mode_outlined),
                title: const Text('深色模式'),
                subtitle: Text(appearance.brightnessMode.label),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _chooseBrightnessMode(context, appearance),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _Section(
            title: '漫画库',
            children: [
              ListTile(
                leading: const Icon(Icons.folder_open),
                title: const Text('保存位置'),
                subtitle: SelectableText(library.rootPath),
                trailing: const Icon(Icons.chevron_right),
                onTap: library.loading
                    ? null
                    : () => _chooseExternalLibrary(context, library),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.storage_outlined),
                title: Text(
                  library.usingExternal ? '本机 SQLite 工作索引' : 'SQLite 总索引',
                ),
                subtitle: SelectableText(library.database.databasePath),
              ),
              const Divider(height: 1),
              ListTile(
                enabled: library.usingExternal && !library.loading,
                leading: const Icon(Icons.usb_off_outlined),
                title: const Text('恢复默认位置'),
                subtitle: const Text('关闭外置库并切回应用目录，拔盘前使用'),
                onTap: library.usingExternal && !library.loading
                    ? () => _restoreDefaultLibrary(context, library)
                    : null,
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.manage_search),
                title: const Text('补建本地索引'),
                subtitle: const Text('扫描文件夹和 ZIP，只补充缺失记录'),
                onTap: () => _rebuild(context, library),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _Section(
            title: '应用数据迁移',
            children: [
              ListTile(
                enabled:
                    library.ready && !library.loading && !_transferringAppData,
                leading: const Icon(Icons.upload_file_outlined),
                title: const Text('导出到当前漫画库'),
                subtitle: const Text('生成“拷贝漫画阅读器应用数据.db”，可随漫画库复制到其他设备'),
                trailing: _transferringAppData
                    ? const SizedBox.square(
                        dimension: 22,
                        child: CircularProgressIndicator(strokeWidth: 2.5),
                      )
                    : const Icon(Icons.chevron_right),
                onTap:
                    library.ready && !library.loading && !_transferringAppData
                    ? () => _exportAppData(context, library)
                    : null,
              ),
              const Divider(height: 1),
              ListTile(
                enabled:
                    library.ready && !library.loading && !_transferringAppData,
                leading: const Icon(Icons.download_for_offline_outlined),
                title: const Text('从当前漫画库导入'),
                subtitle: const Text('合并阅读记录、设置、详情与收藏缓存、下载任务'),
                trailing: const Icon(Icons.chevron_right),
                onTap:
                    library.ready && !library.loading && !_transferringAppData
                    ? () => _importAppData(context, library)
                    : null,
              ),
              const Divider(height: 1),
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  '应用数据使用独立 SQLite 文件迁移，不修改“拷贝漫画总索引.db”。'
                  '登录令牌、密码和系统目录授权不会导出，需要在新设备重新登录并选择漫画库。',
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _Section(
            title: '拷贝漫画',
            children: [
              ListTile(
                leading: const Icon(Icons.route_outlined),
                title: const Text('接口线路'),
                subtitle: Text(context.read<CopyClient>().apiRoute.label),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _chooseApiRoute(context),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.cloud_outlined),
                title: const Text('当前 API 节点'),
                subtitle: Text(_currentApiNodeText(context.read<CopyClient>())),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _chooseApiDomain(context),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.cloud_sync_outlined),
                title: const Text('上游动态节点'),
                subtitle: Text(_apiNodesSummary(context.read<CopyClient>())),
                trailing: _refreshingApiDomains
                    ? const SizedBox.square(
                        dimension: 22,
                        child: CircularProgressIndicator(strokeWidth: 2.5),
                      )
                    : IconButton(
                        tooltip: '从原版上游重新获取',
                        icon: const Icon(Icons.refresh),
                        onPressed: _refreshApiDomains,
                      ),
                onTap: _refreshingApiDomains
                    ? null
                    : () => _chooseApiDomain(context),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.account_circle_outlined),
                title: const Text('账号 API 节点'),
                subtitle: Text(
                  _currentAuthenticationNodeText(context.read<CopyClient>()),
                ),
                trailing: _refreshingAuthenticationDomains
                    ? const SizedBox.square(
                        dimension: 22,
                        child: CircularProgressIndicator(strokeWidth: 2.5),
                      )
                    : const Icon(Icons.chevron_right),
                onTap: _refreshingAuthenticationDomains
                    ? null
                    : () => _chooseAuthenticationDomain(context),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.verified_user_outlined),
                title: const Text('账号存储'),
                subtitle: Text(
                  '勾选“记住密码并自动续期”后，密码与令牌分别保存在系统安全存储，'
                  '不写入 SQLite、漫画库或导出文件。明确过期时自动重新登录一次；'
                  '网络故障、风控和限流不会触发反复登录。'
                  '账号菜单可关闭自动续期并忘记密码。'
                  '账号列表与收藏缓存保存在本机数据库，按账号隔离；'
                  '切换账号不改变本地书库、下载任务和阅读记录。'
                  '应用数据导出不包含登录凭据，其他设备需重新登录。',
                ),
              ),
              const Divider(height: 1),
              const ListTile(
                leading: Icon(Icons.sync),
                title: Text('收藏刷新'),
                subtitle: Text(
                  '漫画和小说收藏先显示本机历史。刷新按收藏时间检查新增，合并保存，'
                  '不清空旧列表；首次无缓存时读取全部。新增显示在前，历史相对顺序保留。'
                  '菜单中的“检查全部收藏”可重新核对全部条目。网络失败不会清空历史，'
                  '服务器已取消或暂不可见的条目也保留；本机明确取消并确认后才移除。'
                  '收藏写入另行核实服务器状态，不把历史缓存当作写入成功的证明。',
                ),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.tune_outlined),
                title: const Text('并发设置'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const ConcurrencySettingsPage(),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _Section(
            title: '文件搬运',
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  Platform.isIOS
                      ? '点“保存位置”可直接选择 iPhone、iPad 或外置盘上的“漫画”文件夹。'
                            '外部总索引首次选择时复制到本机操作，外置索引保持不变。'
                      : Platform.isMacOS
                      ? '点“保存位置”可选择 Mac 内置盘或外置盘上的“漫画”文件夹。'
                            '系统会保存长期访问授权；外部总索引复制到本机操作，原索引保持不变。'
                      : '点“保存位置”可选择安卓内部存储或 USB 外置盘上的“漫画”文件夹。'
                            '外部总索引首次选择时复制到本机操作，外置索引保持不变。',
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          const _Section(
            title: '命名与索引',
            children: [
              Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  '每部漫画一个“漫画名 - 作者”文件夹；每章或单行本一个 ZIP；'
                  '封面使用“漫画名 - 作者 - 汇总”命名。详情、收藏缓存、'
                  '下载任务和阅读进度保存在应用本机的独立 SQLite 数据库，'
                  '漫画旧表不变，小说、分卷和插图索引使用共享总索引中的独立新表。'
                  '小说按每本一个文件夹保存卷或章节 TXT、封面和插图，位于“漫画”旁的“小说”文件夹。'
                  '外置库若要同时访问漫画和小说，请在保存位置选择包含这两个文件夹的上一级目录，授权范围需要包含二者。'
                  '网络响应只作解析，不使用 JSON 文件保存索引。',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _exportAppData(
    BuildContext context,
    LibraryController library,
  ) async {
    if (_transferringAppData) return;
    final downloads = context.read<DownloadController>();
    final wasPaused = downloads.globalPaused;
    final novels = context.read<NovelController>();
    final novelsWerePaused = novels.paused;
    setState(() => _transferringAppData = true);
    try {
      await downloads.pauseAll();
      await novels.pause();
      final result = await library.exportPortableAppData();
      if (!wasPaused) await downloads.resumeAll();
      if (!novelsWerePaused) await novels.resume();
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '已导出 ${result.totalRows} 条应用数据到\n'
            '${library.portableAppDataBackupFile.path}',
          ),
        ),
      );
    } catch (exception) {
      if (!wasPaused) await downloads.resumeAll();
      if (!novelsWerePaused) await novels.resume();
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('应用数据导出失败：$exception')));
    } finally {
      if (mounted) setState(() => _transferringAppData = false);
    }
  }

  Future<void> _importAppData(
    BuildContext context,
    LibraryController library,
  ) async {
    if (_transferringAppData) return;
    final backup = library.portableAppDataBackupFile;
    if (!await backup.exists()) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('当前漫画库中没有 ${backup.uri.pathSegments.last}')),
      );
      return;
    }
    if (!context.mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('导入应用数据'),
        content: const Text(
          '备份会合并到本机独立数据库；相同记录以备份为准。'
          '下载中的任务会转为暂停，不会自动开始。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('导入'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;

    final downloads = context.read<DownloadController>();
    final novels = context.read<NovelController>();
    setState(() => _transferringAppData = true);
    try {
      await downloads.pauseAll();
      await novels.pause();
      final result = await library.importPortableAppData();
      if (!context.mounted) return;
      await Future.wait([
        context.read<AppearanceController>().initialize(),
        context.read<ReadingHistoryController>().initialize(),
        library.reloadLocalState(),
        context.read<FavoritesController>().loadCache(),
        downloads.initialize(),
        novels.initialize(),
      ]);
      if (!context.mounted) return;
      await _restoreClientPreferences(context, library);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已导入 ${result.totalRows} 条应用数据，下载任务保持暂停')),
      );
    } catch (exception) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('应用数据导入失败：$exception')));
    } finally {
      if (mounted) setState(() => _transferringAppData = false);
    }
  }

  Future<void> _restoreClientPreferences(
    BuildContext context,
    LibraryController library,
  ) async {
    final client = context.read<CopyClient>();
    client.setApiRoute(
      CopyApiRoute.fromSetting(await library.database.setting('api_route')),
    );
    final apiDomain = await library.database.setting('api_domain');
    final apiMode = await library.database.setting('api_domain_mode');
    if (apiMode == 'manual' &&
        apiDomain.isNotEmpty &&
        !CopyApiProtocol.isPresetDomain(apiDomain)) {
      client.setApiDomain(apiDomain);
    }
    final authenticationDomain = await library.database.setting(
      'authentication_domain',
    );
    final authenticationMode = await library.database.setting(
      'authentication_domain_mode',
    );
    if (authenticationMode == 'manual' && authenticationDomain.isNotEmpty) {
      client.setAuthenticationDomain(authenticationDomain);
    }
  }

  Future<void> _chooseExternalLibrary(
    BuildContext context,
    LibraryController library,
  ) async {
    final downloads = context.read<DownloadController>();
    final novels = context.read<NovelController>();
    final favorites = context.read<FavoritesController>();
    if (library.ready) {
      await novels.pause();
      await downloads.pauseAll();
    }
    if (!context.mounted) return;
    final changed = await library.chooseExternalLibrary();
    if (!context.mounted) return;
    if (changed) {
      // Regranting the same directory can make previously denied covers readable.
      // Do not keep a failed ImageProvider result until the next app launch.
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
      await Future.wait([
        favorites.loadCache(),
        downloads.initialize(),
        novels.initialize(),
      ]);
    }
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          changed
              ? '已切换外置漫画库，SQLite 工作索引保存在本机'
              : library.error.isEmpty
              ? '未更改漫画库'
              : library.error,
        ),
      ),
    );
  }

  Future<void> _chooseThemeColor(
    BuildContext context,
    AppearanceController appearance,
  ) async {
    final selected = await showDialog<AppThemeColor>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('主题颜色'),
        children: [
          for (final value in AppThemeColor.values)
            ListTile(
              leading: CircleAvatar(
                backgroundColor: value.surface(Theme.of(context).brightness),
                child: Icon(
                  value == appearance.themeColor
                      ? Icons.check
                      : Icons.circle_outlined,
                ),
              ),
              title: Text(value.label),
              onTap: () => Navigator.pop(context, value),
            ),
        ],
      ),
    );
    if (selected != null) await appearance.setThemeColor(selected);
  }

  Future<void> _chooseBrightnessMode(
    BuildContext context,
    AppearanceController appearance,
  ) async {
    final selected = await showDialog<AppBrightnessMode>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('深色模式'),
        children: [
          for (final value in AppBrightnessMode.values)
            ListTile(
              leading: Icon(
                value == appearance.brightnessMode
                    ? Icons.radio_button_checked
                    : Icons.radio_button_off,
              ),
              title: Text(value.label),
              onTap: () => Navigator.pop(context, value),
            ),
        ],
      ),
    );
    if (selected != null) await appearance.setBrightnessMode(selected);
  }

  Future<void> _restoreDefaultLibrary(
    BuildContext context,
    LibraryController library,
  ) async {
    final downloads = context.read<DownloadController>();
    final novels = context.read<NovelController>();
    final favorites = context.read<FavoritesController>();
    await novels.pause();
    await downloads.pauseAll();
    if (!context.mounted) return;
    final changed = await library.resetToDefaultLibrary();
    if (!context.mounted) return;
    if (changed) {
      await Future.wait([
        favorites.loadCache(),
        downloads.initialize(),
        novels.initialize(),
      ]);
    }
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(changed ? '已安全关闭外置库并恢复默认位置，现在可以拔盘' : library.error),
      ),
    );
  }

  Future<void> _rebuild(BuildContext context, LibraryController library) async {
    await library.database.rebuildFromFolders();
    await library.refresh();
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('扫描完成')));
  }

  String _currentApiNodeText(CopyClient client) {
    final latency = client.apiNodes
        .where((node) => node.current)
        .map((node) => node.latencyMs)
        .firstOrNull;
    final mode = client.usesAutomaticApiDomain ? '自动选择' : '手动选择';
    final latencyText = latency == null ? '' : ' · $latency ms';
    return '${client.apiUrl}\n$mode$latencyText';
  }

  String _apiNodesSummary(CopyClient client) {
    final nodes = client.apiNodes;
    if (nodes.isEmpty) return '尚未取得节点';
    final reachable = nodes.where((node) => node.reachable).toList();
    if (reachable.isEmpty) return '已取得 ${nodes.length} 个节点，测速均不可用';
    return '已取得 ${nodes.length} 个节点，最低延迟 ${reachable.first.latencyMs} ms';
  }

  String _currentAuthenticationNodeText(CopyClient client) {
    final latency = client.authenticationNodes
        .where((node) => node.current)
        .map((node) => node.latencyMs)
        .firstOrNull;
    final mode = client.usesAutomaticAuthenticationDomain ? '自动选择' : '手动选择';
    final latencyText = latency == null ? '' : ' · $latency ms';
    return '${client.authenticationUrl}\n$mode$latencyText';
  }

  Future<void> _chooseApiDomain(BuildContext context) async {
    final client = context.read<CopyClient>();
    final library = context.read<LibraryController>();
    final selected = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('选择 API 节点'),
        children: [
          ListTile(
            leading: Icon(
              client.usesAutomaticApiDomain
                  ? Icons.radio_button_checked
                  : Icons.radio_button_off,
            ),
            title: const Text('自动选择'),
            subtitle: const Text('使用测速结果中延迟最低的可用节点'),
            onTap: () => Navigator.pop(context, '__automatic__'),
          ),
          for (final node in client.apiNodes)
            ListTile(
              leading: Icon(
                !client.usesAutomaticApiDomain && node.current
                    ? Icons.radio_button_checked
                    : Icons.radio_button_off,
              ),
              title: Text(node.url),
              subtitle: Text(
                node.latencyMs == null ? '测速不可用' : '${node.latencyMs} ms',
              ),
              onTap: () => Navigator.pop(context, node.domain),
            ),
          ListTile(
            leading: const Icon(Icons.edit_outlined),
            title: const Text('自定义节点'),
            onTap: () => Navigator.pop(context, '__custom__'),
          ),
        ],
      ),
    );
    if (selected == null || !context.mounted) return;
    if (selected == '__custom__') {
      await _editCustomApiDomain(context);
      return;
    }
    if (selected == '__automatic__') {
      client.useFastestApiDomain();
      await library.database.setSetting('api_domain_mode', 'automatic');
    } else {
      client.setApiDomain(selected);
      await library.database.setSetting('api_domain_mode', 'manual');
    }
    await library.database.setSetting('api_domain', client.apiDomain);
    if (!context.mounted) return;
    setState(() {});
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('当前节点：${client.apiUrl}')));
  }

  Future<void> _editCustomApiDomain(BuildContext context) async {
    final client = context.read<CopyClient>();
    final library = context.read<LibraryController>();
    final controller = TextEditingController(text: client.apiDomain);
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('自定义 API 节点'),
        content: TextField(
          controller: controller,
          autocorrect: false,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(hintText: 'api.example.com'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (value == null || value.trim().isEmpty || !context.mounted) return;
    try {
      client.setApiDomain(value);
      await Future.wait([
        library.database.setSetting('api_domain', client.apiDomain),
        library.database.setSetting('api_domain_mode', 'manual'),
      ]);
      if (context.mounted) {
        setState(() {});
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('API 节点已更新')));
      }
    } on CopyApiException catch (exception) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(exception.message)));
      }
    }
  }

  Future<void> _chooseAuthenticationDomain(BuildContext context) async {
    final client = context.read<CopyClient>();
    final library = context.read<LibraryController>();
    final selected = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('选择账号 API 节点'),
        children: [
          ListTile(
            leading: Icon(
              client.usesAutomaticAuthenticationDomain
                  ? Icons.radio_button_checked
                  : Icons.radio_button_off,
            ),
            title: const Text('自动选择'),
            subtitle: const Text('只测速国内节点，不发送账号或登录令牌'),
            onTap: () => Navigator.pop(context, '__automatic__'),
          ),
          for (final node in client.authenticationNodes)
            ListTile(
              leading: Icon(
                !client.usesAutomaticAuthenticationDomain && node.current
                    ? Icons.radio_button_checked
                    : Icons.radio_button_off,
              ),
              title: Text(node.url),
              subtitle: Text(
                node.latencyMs == null ? '尚未测速或不可用' : '${node.latencyMs} ms',
              ),
              onTap: () => Navigator.pop(context, node.domain),
            ),
          ListTile(
            leading: const Icon(Icons.speed_outlined),
            title: const Text('重新获取并测速国内节点'),
            onTap: () => Navigator.pop(context, '__refresh__'),
          ),
          ListTile(
            leading: const Icon(Icons.edit_outlined),
            title: const Text('自定义账号节点'),
            onTap: () => Navigator.pop(context, '__custom__'),
          ),
        ],
      ),
    );
    if (selected == null || !context.mounted) return;
    if (selected == '__refresh__') {
      await _refreshAuthenticationDomains();
      if (context.mounted) await _chooseAuthenticationDomain(context);
      return;
    }
    if (selected == '__custom__') {
      await _editCustomAuthenticationDomain(context);
      return;
    }
    if (selected == '__automatic__') {
      client.useFastestAuthenticationDomain();
      await library.database.setSetting(
        'authentication_domain_mode',
        'automatic',
      );
    } else {
      client.setAuthenticationDomain(selected);
      await library.database.setSetting('authentication_domain_mode', 'manual');
    }
    await library.database.setSetting(
      'authentication_domain',
      client.authenticationDomain,
    );
    if (context.mounted) {
      await context.read<SessionController>().saveCurrentNode();
    }
    if (!context.mounted) return;
    setState(() {});
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('账号节点：${client.authenticationUrl}')));
  }

  Future<void> _editCustomAuthenticationDomain(BuildContext context) async {
    final client = context.read<CopyClient>();
    final library = context.read<LibraryController>();
    final controller = TextEditingController(text: client.authenticationDomain);
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('自定义账号 API 节点'),
        content: TextField(
          controller: controller,
          autocorrect: false,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(hintText: 'api.example.com'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (value == null || value.trim().isEmpty || !context.mounted) return;
    try {
      client.setAuthenticationDomain(value);
      await Future.wait([
        library.database.setSetting(
          'authentication_domain',
          client.authenticationDomain,
        ),
        library.database.setSetting('authentication_domain_mode', 'manual'),
      ]);
      if (context.mounted) {
        await context.read<SessionController>().saveCurrentNode();
      }
      if (!context.mounted) return;
      setState(() {});
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('账号 API 节点已更新')));
    } on CopyApiException catch (exception) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(exception.message)));
      }
    }
  }

  Future<void> _refreshAuthenticationDomains() async {
    if (_refreshingAuthenticationDomains) return;
    final client = context.read<CopyClient>();
    final library = context.read<LibraryController>();
    setState(() => _refreshingAuthenticationDomains = true);
    try {
      final nodes = await client.refreshAuthenticationDomains();
      await library.database.setSetting(
        'authentication_domain',
        client.authenticationDomain,
      );
      if (mounted) await context.read<SessionController>().saveCurrentNode();
      if (!mounted) return;
      setState(() {});
      final reachable = nodes.where((node) => node.reachable).length;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已取得 ${nodes.length} 个国内节点，$reachable 个可用')),
      );
    } on CopyApiException catch (exception) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(exception.message)));
      }
    } finally {
      if (mounted) setState(() => _refreshingAuthenticationDomains = false);
    }
  }

  Future<void> _chooseApiRoute(BuildContext context) async {
    final client = context.read<CopyClient>();
    final library = context.read<LibraryController>();
    final selected = await showDialog<CopyApiRoute>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('接口线路'),
        children: [
          for (final route in CopyApiRoute.values)
            ListTile(
              leading: Icon(
                route == client.apiRoute
                    ? Icons.radio_button_checked
                    : Icons.radio_button_off,
              ),
              title: Text(
                route == CopyApiRoute.overseas
                    ? '${route.label}（默认）'
                    : route.label,
              ),
              onTap: () => Navigator.pop(context, route),
            ),
        ],
      ),
    );
    if (selected == null || !context.mounted) return;
    client.setApiRoute(selected);
    await library.database.setSetting('api_route', selected.settingValue);
    await library.database.setSetting('api_domain_mode', 'automatic');
    if (!mounted) return;
    await _refreshApiDomains(showResult: false);
    await library.database.setSetting('api_domain', client.apiDomain);
    if (!context.mounted) return;
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已切换到${selected.label}：${client.apiUrl}')),
    );
  }

  Future<void> _refreshApiDomains({bool showResult = true}) async {
    if (_refreshingApiDomains) return;
    final client = context.read<CopyClient>();
    final library = context.read<LibraryController>();
    setState(() => _refreshingApiDomains = true);
    try {
      final domains = await client.refreshApiDomains();
      await library.database.setSetting('api_domain', client.apiDomain);
      if (!mounted || !showResult) return;
      final message = domains.isEmpty
          ? '上游暂未返回节点，继续使用 ${client.apiUrl}'
          : '已取得 ${domains.length} 个节点，当前使用 ${client.apiUrl}';
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } on CopyApiException catch (exception) {
      if (mounted && showResult) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(exception.message)));
      }
    } finally {
      if (mounted) setState(() => _refreshingApiDomains = false);
    }
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 6),
          child: Text(title, style: Theme.of(context).textTheme.titleMedium),
        ),
        Card(child: Column(children: children)),
      ],
    );
  }
}
