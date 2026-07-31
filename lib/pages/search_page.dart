import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../controllers/library_controller.dart';
import '../models/comic.dart';
import '../services/copy_client.dart';
import '../widgets/comic_grid.dart';
import 'comic_detail_page.dart';

class SearchPage extends StatefulWidget {
  const SearchPage({super.key});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final _controller = TextEditingController();
  List<Comic> _results = const [];
  bool _loading = false;
  bool _opening = false;
  String _error = '';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final keyword = _controller.text.trim();
    if (keyword.isEmpty) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      _results = await context.read<CopyClient>().search(keyword);
    } on CopyApiException catch (exception) {
      _error = exception.message;
    } catch (exception) {
      _error = '搜索失败：$exception';
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _open(Comic comic) async {
    if (_opening) return;
    final library = context.read<LibraryController>();
    setState(() {
      _opening = true;
      _error = '';
    });
    try {
      if (comic.pathWord.isEmpty) {
        throw const CopyApiException('搜索结果缺少漫画标识');
      }
      final resolved = await library.refreshDetails(comic);
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ComicDetailPage(comic: resolved),
        ),
      );
      await library.refresh();
    } on CopyApiException catch (exception) {
      _error = exception.message;
    } catch (exception) {
      _error = '打开漫画详情失败：$exception';
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final library = context.watch<LibraryController>();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: SearchBar(
            controller: _controller,
            hintText: '搜索拷贝漫画',
            leading: const Icon(Icons.travel_explore),
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
        if (_loading || _opening) const LinearProgressIndicator(),
        if (_error.isNotEmpty)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              _error,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        Expanded(
          child: ComicGrid(
            comics: _results,
            coverPath: library.coverPath,
            onOpen: _open,
            emptyTitle: '搜索拷贝漫画',
          ),
        ),
      ],
    );
  }
}
