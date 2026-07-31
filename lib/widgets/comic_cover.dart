import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

class ComicCover extends StatelessWidget {
  const ComicCover({
    super.key,
    required this.title,
    this.localPath = '',
    this.networkUrl = '',
    this.borderRadius = const BorderRadius.all(Radius.circular(12)),
  });

  final String title;
  final String localPath;
  final String networkUrl;
  final BorderRadius borderRadius;

  @override
  Widget build(BuildContext context) {
    final placeholder = ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Text(
            title,
            maxLines: 3,
            textAlign: TextAlign.center,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.labelMedium,
          ),
        ),
      ),
    );
    Widget image;
    if (localPath.isNotEmpty && File(localPath).existsSync()) {
      image = Image.file(
        File(localPath),
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => placeholder,
      );
    } else if (networkUrl.isNotEmpty) {
      image = CachedNetworkImage(
        imageUrl: networkUrl,
        fit: BoxFit.cover,
        placeholder: (_, _) => placeholder,
        errorWidget: (_, _, _) => placeholder,
      );
    } else {
      image = placeholder;
    }
    return ClipRRect(borderRadius: borderRadius, child: image);
  }
}
