import 'dart:async';

import 'package:flutter/material.dart';

/// Shared comic/novel action. Never guess whether a stale cache should toggle.
class FavoriteButton extends StatefulWidget {
  const FavoriteButton({
    super.key,
    required this.scope,
    required this.loggedIn,
    required this.loadSelected,
    required this.setSelected,
    required this.onLogin,
    this.available = true,
    this.blocked = false,
  });

  final Object scope;
  final bool loggedIn, available, blocked;
  final Future<bool> Function() loadSelected;
  final Future<void> Function(bool) setSelected;
  final Future<void> Function() onLogin;

  @override
  State<FavoriteButton> createState() => _FavoriteButtonState();
}

class _FavoriteButtonState extends State<FavoriteButton> {
  bool? _selected;
  bool _busy = false;
  String _error = '';
  int _revision = 0;

  @override
  void initState() {
    super.initState();
    _busy = widget.available && widget.loggedIn;
    unawaited(Future<void>.microtask(_load));
  }

  @override
  void didUpdateWidget(FavoriteButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scope != widget.scope ||
        oldWidget.loggedIn != widget.loggedIn ||
        oldWidget.available != widget.available) {
      unawaited(Future<void>.microtask(_load));
    }
  }

  Future<void> _load() async {
    if (!mounted) return;
    final revision = ++_revision;
    setState(() {
      _selected = null;
      _error = '';
      _busy = widget.available && widget.loggedIn;
    });
    if (!_busy) return;
    try {
      final selected = await widget.loadSelected();
      if (mounted && revision == _revision) _selected = selected;
    } catch (e) {
      if (mounted && revision == _revision) _error = e.toString();
    } finally {
      if (mounted && revision == _revision) setState(() => _busy = false);
    }
  }

  Future<void> _tap() async {
    if (_busy || widget.blocked) return;
    if (!widget.loggedIn) {
      await widget.onLogin();
      return;
    }
    if (_selected == null) {
      await _load();
      return;
    }
    final revision = _revision;
    final desired = !_selected!;
    if (!desired) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('取消收藏'),
          content: const Text('确定取消这部作品的收藏？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('保留'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('取消收藏'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted || revision != _revision) return;
    }
    setState(() => _busy = true);
    try {
      await widget.setSelected(desired);
      if (!mounted || revision != _revision) return;
      _selected = desired;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(desired ? '已加入收藏' : '已取消收藏')));
    } catch (e) {
      if (!mounted || revision != _revision) return;
      // The write may have reached the server. Require a read, not another POST.
      _selected = null;
      _error = e.toString();
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(_error)));
    } finally {
      if (mounted && revision == _revision) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.available) return const SizedBox.shrink();
    return Tooltip(
      message: _error.isNotEmpty
          ? _error
          : _selected == true
          ? '取消收藏'
          : '加入收藏',
      child: TextButton.icon(
        onPressed: _busy || widget.blocked ? null : _tap,
        icon: _busy
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Icon(_selected == true ? Icons.favorite : Icons.favorite_border),
        label: Text(
          _error.isNotEmpty
              ? '重试收藏状态'
              : _selected == true
              ? '已收藏'
              : '收藏',
        ),
      ),
    );
  }
}
