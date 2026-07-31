import 'dart:io';

import 'package:path/path.dart' as p;

const libraryDatabaseName = '拷贝漫画总索引.db';

String safeFileName(String value, {String fallback = '未命名'}) {
  final sanitized = value
      .replaceAll(RegExp(r'[\x00-\x1f/:*?"<>|\\]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim()
      .replaceAll(RegExp(r'[. ]+$'), '');
  return sanitized.isEmpty ? fallback : sanitized;
}

String comicDirectoryName(String title, String authors) {
  final safeTitle = safeFileName(title);
  final safeAuthors = safeFileName(authors, fallback: '未知作者');
  return '$safeTitle - $safeAuthors';
}

String chapterArchiveName(String title, String authors, String chapterTitle) {
  return '${comicDirectoryName(title, authors)} - '
      '${safeFileName(chapterTitle, fallback: '未命名章节')}.zip';
}

String coverFileName(String title, String authors, {String extension = 'jpg'}) {
  return '${comicDirectoryName(title, authors)} - 汇总.$extension';
}

String absoluteLibraryPath(String root, String relative) {
  if (relative.trim().isEmpty) return '';
  final normalized = relative.replaceAll('\\', '/');
  return p.normalize(p.joinAll([root, ...p.posix.split(normalized)]));
}

bool isImageName(String name) {
  const extensions = {'.jpg', '.jpeg', '.png', '.webp', '.gif', '.bmp', '.jxl'};
  return extensions.contains(p.extension(name).toLowerCase());
}

int naturalCompare(String left, String right) {
  final token = RegExp(r'(\d+(?:\.\d+)?)|(\D+)');
  final a = token.allMatches(left.toLowerCase()).toList();
  final b = token.allMatches(right.toLowerCase()).toList();
  for (var i = 0; i < a.length && i < b.length; i++) {
    final av = a[i].group(0)!;
    final bv = b[i].group(0)!;
    final an = double.tryParse(av);
    final bn = double.tryParse(bv);
    final comparison = an != null && bn != null
        ? an.compareTo(bn)
        : av.compareTo(bv);
    if (comparison != 0) return comparison;
  }
  return a.length.compareTo(b.length);
}

String imageExtensionFromBytes(List<int> bytes) {
  if (bytes.length >= 3 &&
      bytes[0] == 0xff &&
      bytes[1] == 0xd8 &&
      bytes[2] == 0xff) {
    return 'jpg';
  }
  if (bytes.length >= 8 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4e &&
      bytes[3] == 0x47) {
    return 'png';
  }
  if (bytes.length >= 12 &&
      String.fromCharCodes(bytes.sublist(0, 4)) == 'RIFF' &&
      String.fromCharCodes(bytes.sublist(8, 12)) == 'WEBP') {
    return 'webp';
  }
  return 'jpg';
}

Future<File?> firstCoverInDirectory(Directory directory) async {
  if (!await directory.exists()) return null;
  await for (final entity in directory.list(followLinks: false)) {
    if (entity is File && isImageName(entity.path)) return entity;
  }
  return null;
}
