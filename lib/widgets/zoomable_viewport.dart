import 'dart:math' as math;

import 'package:flutter/material.dart';

typedef ZoomableChildBuilder =
    Widget Function(BuildContext context, bool zoomed, bool scrollLocked);
typedef ZoomableVerticalScrollCallback = double Function(double delta);

class ZoomableViewport extends StatefulWidget {
  const ZoomableViewport({
    super.key,
    required this.builder,
    required this.onTap,
    this.onVerticalScroll,
  });

  final ZoomableChildBuilder builder;
  final VoidCallback onTap;
  final ZoomableVerticalScrollCallback? onVerticalScroll;

  @override
  State<ZoomableViewport> createState() => ZoomableViewportState();
}

class ZoomableViewportState extends State<ZoomableViewport> {
  final _transformation = TransformationController();
  final _pointers = <int, Offset>{};
  TapDownDetails? _doubleTapDetails;
  (int, int)? _pinchPointers;
  Offset? _pinchSceneFocalPoint;
  Offset? _pinchStartFocalPoint;
  int? _panPointer;
  Offset? _lastPanPosition;
  double _pinchStartDistance = 0;
  double _pinchStartScale = 1;
  double _pinchAppliedVerticalScroll = 0;
  Size _viewportSize = Size.zero;
  bool _zoomed = false;
  bool _pinching = false;

  double get scale => _transformation.value.getMaxScaleOnAxis();
  Offset get translation => Offset(
    _transformation.value.storage[12],
    _transformation.value.storage[13],
  );

  @override
  void initState() {
    super.initState();
    _transformation.addListener(_handleTransformation);
  }

  @override
  void dispose() {
    _transformation
      ..removeListener(_handleTransformation)
      ..dispose();
    super.dispose();
  }

  void zoomIn() => _setScale((scale * 1.5).clamp(1.0, 5.0));

  void zoomOut() => _setScale((scale / 1.5).clamp(1.0, 5.0));

  void reset() => _setScale(1);

  void _handleTransformation() {
    final zoomed = scale > 1.01;
    if (zoomed != _zoomed && mounted) setState(() => _zoomed = zoomed);
  }

  void _toggleDoubleTap() {
    if (_zoomed) {
      reset();
      return;
    }
    _setScale(2.5, focalPoint: _doubleTapDetails?.localPosition);
  }

  void _setScale(double targetScale, {Offset? focalPoint}) {
    final size = _viewportSize;
    if (size.isEmpty) return;
    final focal = focalPoint ?? size.center(Offset.zero);
    final previousScale = scale;
    final sceneFocal = _transformation.toScene(focal);
    final effectiveScale = targetScale.clamp(1.0, 5.0).toDouble();
    if (widget.onVerticalScroll != null) {
      widget.onVerticalScroll!(
        focal.dy / previousScale - focal.dy / effectiveScale,
      );
    }
    _applyScale(
      targetScale: effectiveScale,
      focalPoint: focal,
      sceneFocalPoint: sceneFocal,
      viewportSize: size,
    );
  }

  void _handlePointerDown(PointerDownEvent event) {
    _pointers[event.pointer] = event.localPosition;
    if (_pointers.length == 1) {
      _panPointer = event.pointer;
      _lastPanPosition = event.localPosition;
      return;
    }
    if (_pointers.length != 2) return;

    _panPointer = null;
    _lastPanPosition = null;
    final ids = _pointers.keys.take(2).toList(growable: false);
    final first = _pointers[ids[0]]!;
    final second = _pointers[ids[1]]!;
    final distance = (second - first).distance;
    if (distance <= 0) return;

    _pinchPointers = (ids[0], ids[1]);
    _pinchStartDistance = distance;
    _pinchStartScale = scale;
    _pinchAppliedVerticalScroll = 0;
    _pinchStartFocalPoint = Offset(
      (first.dx + second.dx) / 2,
      (first.dy + second.dy) / 2,
    );
    _pinchSceneFocalPoint = _transformation.toScene(_pinchStartFocalPoint!);
    if (!_pinching) setState(() => _pinching = true);
  }

  void _handlePointerMove(PointerMoveEvent event) {
    if (!_pointers.containsKey(event.pointer)) return;
    _pointers[event.pointer] = event.localPosition;

    final ids = _pinchPointers;
    if (ids == null) {
      _handlePanMove(event);
      return;
    }
    final sceneFocal = _pinchSceneFocalPoint;
    final startFocal = _pinchStartFocalPoint;
    final size = _viewportSize;
    if (sceneFocal == null || startFocal == null || size.isEmpty) {
      return;
    }
    final first = _pointers[ids.$1];
    final second = _pointers[ids.$2];
    if (first == null || second == null) return;

    final distance = (second - first).distance;
    if (distance <= 0 || _pinchStartDistance <= 0) return;
    final targetScale = (_pinchStartScale * distance / _pinchStartDistance)
        .clamp(1.0, 5.0);
    final focal = Offset(
      (first.dx + second.dx) / 2,
      (first.dy + second.dy) / 2,
    );
    if (widget.onVerticalScroll != null) {
      final totalVerticalScroll =
          startFocal.dy / _pinchStartScale - focal.dy / targetScale;
      final consumed = widget.onVerticalScroll!(
        totalVerticalScroll - _pinchAppliedVerticalScroll,
      );
      _pinchAppliedVerticalScroll += consumed;
    }
    _applyScale(
      targetScale: targetScale,
      focalPoint: focal,
      sceneFocalPoint: sceneFocal,
      viewportSize: size,
    );
  }

  void _handlePanMove(PointerMoveEvent event) {
    if (!_zoomed || event.pointer != _panPointer) return;
    final previous = _lastPanPosition;
    _lastPanPosition = event.localPosition;
    if (previous == null) return;

    final delta = event.localPosition - previous;
    final currentScale = scale;
    final currentTranslation = translation;
    final minimumX = _viewportSize.width * (1 - currentScale);
    final minimumY = _viewportSize.height * (1 - currentScale);
    final translationX = (currentTranslation.dx + delta.dx)
        .clamp(math.min(minimumX, 0), math.max(minimumX, 0))
        .toDouble();
    late final double translationY;
    if (widget.onVerticalScroll != null) {
      widget.onVerticalScroll!(-delta.dy / currentScale);
      translationY = 0;
    } else {
      translationY = (currentTranslation.dy + delta.dy)
          .clamp(math.min(minimumY, 0), math.max(minimumY, 0))
          .toDouble();
    }
    _transformation.value = Matrix4.identity()
      ..translateByDouble(translationX, translationY, 0, 1)
      ..scaleByDouble(currentScale, currentScale, 1, 1);
  }

  void _handlePointerEnd(PointerEvent event) {
    _pointers.remove(event.pointer);
    final ids = _pinchPointers;
    if (ids == null) {
      if (event.pointer == _panPointer) {
        _panPointer = null;
        _lastPanPosition = null;
      }
      return;
    }
    if (event.pointer != ids.$1 && event.pointer != ids.$2) {
      return;
    }
    _pinchPointers = null;
    _pinchSceneFocalPoint = null;
    _pinchStartFocalPoint = null;
    if (_pinching) setState(() => _pinching = false);
    if (_pointers.length == 1) {
      _panPointer = _pointers.keys.single;
      _lastPanPosition = _pointers.values.single;
    }
  }

  void _applyScale({
    required double targetScale,
    required Offset focalPoint,
    required Offset sceneFocalPoint,
    required Size viewportSize,
  }) {
    final effectiveScale = targetScale.clamp(1.0, 5.0).toDouble();
    final minimumX = viewportSize.width * (1 - effectiveScale);
    final minimumY = viewportSize.height * (1 - effectiveScale);
    final translationX = (focalPoint.dx - sceneFocalPoint.dx * effectiveScale)
        .clamp(math.min(minimumX, 0), math.max(minimumX, 0))
        .toDouble();
    final translationY = widget.onVerticalScroll != null
        ? 0.0
        : (focalPoint.dy - sceneFocalPoint.dy * effectiveScale)
              .clamp(math.min(minimumY, 0), math.max(minimumY, 0))
              .toDouble();
    _transformation.value = Matrix4.identity()
      ..translateByDouble(translationX, translationY, 0, 1)
      ..scaleByDouble(effectiveScale, effectiveScale, 1, 1);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _viewportSize = constraints.biggest;
        return Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: _handlePointerDown,
          onPointerMove: _handlePointerMove,
          onPointerUp: _handlePointerEnd,
          onPointerCancel: _handlePointerEnd,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onTap,
            onDoubleTapDown: (details) => _doubleTapDetails = details,
            onDoubleTap: _toggleDoubleTap,
            child: InteractiveViewer(
              transformationController: _transformation,
              minScale: 1,
              maxScale: 5,
              panEnabled: false,
              scaleEnabled: false,
              clipBehavior: Clip.hardEdge,
              child: widget.builder(context, _zoomed, _zoomed || _pinching),
            ),
          ),
        );
      },
    );
  }
}
