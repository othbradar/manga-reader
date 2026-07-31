import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/file_names.dart';
import 'external_library_access.dart';

class LibraryLocator {
  LibraryLocator({
    FlutterSecureStorage? secureStorage,
    ExternalLibraryAccess? externalAccess,
  }) : _secureStorage =
           secureStorage ??
           const FlutterSecureStorage(
             mOptions: MacOsOptions(usesDataProtectionKeychain: false),
           ),
       _externalAccess = externalAccess ?? const ExternalLibraryAccess();

  static const _rootKey = 'manga_library_root';
  static const _externalKey = 'manga_library_is_external';
  final FlutterSecureStorage _secureStorage;
  final ExternalLibraryAccess _externalAccess;
  bool _usingExternal = false;

  bool get usingExternal => _usingExternal;

  Future<Directory> defaultRoot() async {
    final Directory container;
    if (Platform.isAndroid) {
      container =
          await getExternalStorageDirectory() ??
          await getApplicationDocumentsDirectory();
    } else {
      container = await getApplicationDocumentsDirectory();
    }
    return Directory(p.join(container.path, '漫画'));
  }

  Future<Directory> locate() async {
    final external = await _restoreExternalDirectory();
    if (external != null) return external;

    final saved = await _secureStorage.read(key: _rootKey);
    if (saved != null && saved.trim().isNotEmpty) {
      final found = await discover(Directory(saved));
      if (found != null) {
        _usingExternal = false;
        return found;
      }
    }
    final defaultDirectory = await defaultRoot();
    final found = await discover(defaultDirectory);
    if (found != null) {
      await remember(found, external: false);
      return found;
    }
    await defaultDirectory.create(recursive: true);
    await remember(defaultDirectory, external: false);
    return defaultDirectory;
  }

  Future<Directory?> choose(String selectedPath) async {
    final selected = Directory(selectedPath);
    final found = await discover(selected);
    final root = found ?? selected;
    await root.create(recursive: true);
    _usingExternal = false;
    await remember(root, external: false);
    return root;
  }

  Future<Directory?> chooseExternal() async {
    final selectedPath = await _externalAccess.pickDirectory();
    if (selectedPath == null || selectedPath.trim().isEmpty) return null;
    final root = await discover(Directory(selectedPath));
    if (root == null) {
      await _externalAccess.releaseDirectoryAccess();
      throw const FileSystemException('所选目录及其下一层没有找到拷贝漫画总索引.db');
    }
    _usingExternal = true;
    await remember(root, external: true);
    return root;
  }

  Future<Directory> resetToDefault() async {
    await _externalAccess.releaseDirectoryAccess();
    await _secureStorage.delete(key: _rootKey);
    await _secureStorage.delete(key: _externalKey);
    _usingExternal = false;
    final root = await defaultRoot();
    await root.create(recursive: true);
    await remember(root, external: false);
    return root;
  }

  Future<File> databaseFileFor(
    Directory root, {
    void Function(String message)? onProgress,
  }) async {
    final source = File(p.join(root.path, libraryDatabaseName));
    if (!_usingExternal) return source;
    if (!await source.exists()) {
      throw FileSystemException('外置漫画库索引不存在', source.path);
    }

    onProgress?.call('正在识别外置漫画库');
    final support = await getApplicationSupportDirectory();
    final libraryId = await _stableLibraryId(root.path, source);
    final workingDirectory = Directory(
      p.join(support.path, 'external_libraries', libraryId),
    );
    await workingDirectory.create(recursive: true);
    final working = File(p.join(workingDirectory.path, libraryDatabaseName));
    if (!await working.exists()) {
      await _copyAtomically(
        source,
        working,
        onProgress: (percent) => onProgress?.call('正在把外置索引复制到本机 $percent%'),
      );
      final sourceWal = File('${source.path}-wal');
      if (await sourceWal.exists() && await sourceWal.length() > 0) {
        await _copyAtomically(sourceWal, File('${working.path}-wal'));
      }
    } else {
      onProgress?.call('正在打开已有的本机工作索引');
    }
    return working;
  }

  Future<void> remember(Directory root, {required bool external}) async {
    _usingExternal = external;
    await _secureStorage.write(key: _rootKey, value: root.path);
    await _secureStorage.write(
      key: _externalKey,
      value: external ? 'true' : 'false',
    );
  }

  Future<Directory?> _restoreExternalDirectory() async {
    final wasExternal = await _secureStorage.read(key: _externalKey) == 'true';
    if (!wasExternal) return null;
    final restoredPath = await _externalAccess.restoreDirectoryAccess();
    if (restoredPath == null || restoredPath.trim().isEmpty) return null;
    final root = await discover(Directory(restoredPath));
    if (root == null) return null;
    _usingExternal = true;
    await _secureStorage.write(key: _rootKey, value: root.path);
    return root;
  }

  static Future<String> _stableLibraryId(String rootPath, File database) async {
    final length = await database.length();
    final handle = await database.open();
    try {
      final first = await handle.read(length.clamp(0, 4096));
      final last = <int>[];
      if (length > 4096) {
        await handle.setPosition((length - 4096).clamp(0, length));
        last.addAll(await handle.read(4096));
      }
      return _stableBytesId([
        ...utf8.encode(rootPath),
        0,
        ...utf8.encode(length.toString()),
        0,
        ...first,
        ...last,
      ]);
    } finally {
      await handle.close();
    }
  }

  static String _stableBytesId(Iterable<int> bytes) {
    var hash = 0xcbf29ce484222325;
    for (final byte in bytes) {
      hash ^= byte;
      hash = (hash * 0x100000001b3) & 0xffffffffffffffff;
    }
    return hash.toRadixString(16).padLeft(16, '0');
  }

  static Future<void> _copyAtomically(
    File source,
    File destination, {
    void Function(int percent)? onProgress,
  }) async {
    final partial = File('${destination.path}.partial');
    if (await partial.exists()) await partial.delete();
    final total = await source.length();
    final sink = partial.openWrite();
    var written = 0;
    var lastReported = -1;
    try {
      await for (final chunk in source.openRead()) {
        sink.add(chunk);
        written += chunk.length;
        final percent = total == 0 ? 100 : (written * 100 ~/ total);
        if (percent == 100 || percent >= lastReported + 5) {
          lastReported = percent;
          onProgress?.call(percent);
        }
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
    await partial.rename(destination.path);
  }

  static Future<Directory?> discover(Directory candidate) async {
    try {
      if (!await candidate.exists()) return null;
      if (await File(p.join(candidate.path, libraryDatabaseName)).exists()) {
        return candidate;
      }
      final mangaChild = Directory(p.join(candidate.path, '漫画'));
      if (await File(p.join(mangaChild.path, libraryDatabaseName)).exists()) {
        return mangaChild;
      }
      await for (final child in candidate.list(followLinks: false)) {
        if (child is Directory &&
            await File(p.join(child.path, libraryDatabaseName)).exists()) {
          return child;
        }
      }
    } on FileSystemException {
      return null;
    }
    return null;
  }
}
