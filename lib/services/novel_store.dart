import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:lpinyin/lpinyin.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../core/file_names.dart';
import '../models/novel.dart';
import 'library_database.dart';

/// Shared content tables live alongside comics, never in or replacing them.
/// Novel paths are relative to the collection parent (漫画/ and 小说/ siblings).
class NovelStore {
  NovelStore(this.library);
  final LibraryDatabase library;
  Directory get collection => library.root!.parent;
  Directory get root => Directory(p.join(collection.path, '小说'));
  String get key => library.libraryKey;
  Database get db => library.database;

  Future<void> ensureSchema() async {
    final schema = await rootBundle.loadString('assets/sql/novel_library.sql');
    await db.transaction((txn) async {
      for (final statement in schema.split(';')) {
        if (statement.trim().isNotEmpty) await txn.execute(statement);
      }
      final columns = await txn.rawQuery('PRAGMA table_info(novels)');
      if (!columns.any((column) => column['name'] == 'title_sort_key')) {
        await txn.execute(
          "ALTER TABLE novels ADD COLUMN title_sort_key TEXT NOT NULL DEFAULT ''",
        );
      }
      // Keep source/order/sort metadata in the portable index, not in UI code.
      // Existing explicit keys are preserved; imported pre-filter indexes only
      // gain the missing column and keys, without changing books or volumes.
      final missingKeys = await txn.query(
        'novels',
        where: "title_sort_key = ''",
      );
      final batch = txn.batch();
      for (final row in missingKeys) {
        final book = Novel.fromRow(row);
        batch.update(
          'novels',
          {'title_sort_key': _titleSortKey(book)},
          where: 'novel_uuid = ?',
          whereArgs: [book.uuid],
        );
      }
      await batch.commit(noResult: true);
    });
  }

  String absolute(String relative) {
    if (relative.isEmpty) return '';
    if (p.posix.isAbsolute(relative) || relative.contains('\\')) {
      throw const FormatException('小说索引路径必须为相对路径');
    }
    final path = p.normalize(p.join(collection.path, relative));
    if (!p.isWithin(root.path, path)) throw const FormatException('小说路径超出小说目录');
    return path;
  }

  String relative(String path) =>
      p.relative(path, from: collection.path).replaceAll('\\', '/');

  Future<List<Novel>> books({String query = ''}) async {
    final rows = await db.rawQuery('''SELECT n.*,
      (SELECT COUNT(*) FROM novel_volumes v WHERE v.novel_uuid=n.novel_uuid AND v.is_downloaded=1) downloaded_volumes
      FROM novels n ORDER BY library_order,title''');
    final books = rows.map(Novel.fromRow);
    final normalize =
        library.normalizer?.normalize ?? (String s) => s.toLowerCase();
    final needle = normalize(query.trim());
    return books
        .where(
          (b) =>
              needle.isEmpty ||
              normalize('${b.title} ${b.authors} ${b.alias}').contains(needle),
        )
        .toList();
  }

  Future<Novel?> book(String uuid) async {
    final rows = await db.query(
      'novels',
      where: 'novel_uuid=?',
      whereArgs: [uuid],
      limit: 1,
    );
    return rows.isEmpty ? null : Novel.fromRow(rows.first);
  }

  Future<Novel> saveBook(Novel book) async {
    if (book.uuid.isEmpty || book.pathWord.isEmpty) {
      throw const FormatException('小说标识为空');
    }
    final existing = await this.book(book.uuid);
    final saved = book.withFiles(
      directory: existing?.relativeDir.isNotEmpty == true
          ? existing!.relativeDir
          : book.relativeDir,
      cover: existing?.coverRelativePath.isNotEmpty == true
          ? existing!.coverRelativePath
          : book.coverRelativePath,
      source: existing?.source ?? book.source,
      titleSortKey: book.titleSortKey.isNotEmpty
          ? book.titleSortKey
          : existing?.title == book.title &&
                existing?.titleSortKey.isNotEmpty == true
          ? existing!.titleSortKey
          : _titleSortKey(book),
      order:
          existing?.order ??
          (Sqflite.firstIntValue(
                await db.rawQuery('SELECT MAX(library_order)+1 FROM novels'),
              ) ??
              0),
    );
    await db.insert(
      'novels',
      saved.toRow(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    return saved;
  }

  String _titleSortKey(Novel book) {
    if (book.titleSortKey.isNotEmpty) return book.titleSortKey;
    final title = library.normalizer?.normalize(book.title) ?? book.title;
    // Local-only books have no upstream path word. Use the visible title for
    // every source so they participate in the same A–Z ordering too.
    try {
      return PinyinHelper.getPinyin(
        title,
        separator: '',
        format: PinyinFormat.WITHOUT_TONE,
      ).toLowerCase().replaceAll(RegExp(r'\s+'), '');
    } on PinyinException {
      return title.toLowerCase();
    }
  }

  Future<void> saveVolumes(List<NovelVolume> volumes) async {
    await db.transaction((txn) async {
      for (final v in volumes) {
        await txn.rawInsert(
          '''INSERT INTO novel_volumes(novel_uuid,volume_id,title,volume_order,txt_url,txt_encoding)
          VALUES(?,?,?,?,?,?) ON CONFLICT(novel_uuid,volume_id) DO UPDATE SET
          title=excluded.title,volume_order=excluded.volume_order,
          txt_url=CASE WHEN excluded.txt_url<>'' THEN excluded.txt_url ELSE txt_url END''',
          [v.novelUuid, v.id, v.title, v.order, v.textUrl, v.encoding],
        );
      }
    });
  }

  Future<List<NovelVolume>> volumes(String uuid) async => (await db.query(
    'novel_volumes',
    where: 'novel_uuid=?',
    whereArgs: [uuid],
    orderBy: 'volume_order,title',
  )).map((r) => NovelVolume.fromRow(r)).toList();

  Future<NovelVolume> volume(String uuid, String id) async {
    final rows = await db.query(
      'novel_volumes',
      where: 'novel_uuid=? AND volume_id=?',
      whereArgs: [uuid, id],
    );
    if (rows.isEmpty) throw const FormatException('小说卷不在当前库中');
    final sections = await db.query(
      'novel_sections',
      where: 'novel_uuid=? AND volume_id=?',
      whereArgs: [uuid, id],
      orderBy: 'section_index',
    );
    return NovelVolume.fromRow(
      rows.single,
      sections: sections.map(NovelSection.fromRow).toList(),
    );
  }

  Future<void> completeVolume(
    NovelVolume volume,
    String textPath,
    String digest,
    Map<int, String> images,
  ) async {
    // Mark complete only once TXT and all expected images have been atomically saved.
    await db.transaction((txn) async {
      await txn.update(
        'novel_volumes',
        {
          'txt_url': volume.textUrl,
          'txt_encoding': 'UTF-8',
          'txt_relative_path': textPath,
          'text_sha256': digest,
          'is_downloaded': 1,
        },
        where: 'novel_uuid=? AND volume_id=?',
        whereArgs: [volume.novelUuid, volume.id],
      );
      await txn.delete(
        'novel_sections',
        where: 'novel_uuid=? AND volume_id=?',
        whereArgs: [volume.novelUuid, volume.id],
      );
      for (final section in volume.sections) {
        await txn.insert('novel_sections', {
          'novel_uuid': volume.novelUuid,
          'volume_id': volume.id,
          'section_index': section.index,
          'title': section.title,
          'content_type': section.type,
          'start_line': section.start,
          'end_line': section.end,
          'image_url': section.imageUrl,
          'image_relative_path': images[section.index] ?? '',
        });
      }
    });
  }

  Future<int> importLocalFolders() async {
    if (!await root.exists()) return 0;
    final existing = (await books()).map((b) => b.relativeDir).toSet();
    final imported = (await db.query(
      'novel_import_sources',
    )).map((r) => novelText(r['source_dir'])).toSet();
    var count = 0;
    final folders = await root
        .list(followLinks: false)
        .where((e) => e is Directory)
        .cast<Directory>()
        .toList();
    folders.sort((a, b) => naturalCompare(a.path, b.path));
    for (final folder in folders) {
      if (existing.contains(relative(folder.path)) ||
          imported.contains(p.basename(folder.path))) {
        continue;
      }
      final files = await folder
          .list(followLinks: false)
          .where((e) => e is File)
          .cast<File>()
          .toList();
      final texts = files
          .where((f) => p.extension(f.path).toLowerCase() == '.txt')
          .toList();
      if (texts.isEmpty) continue;
      texts.sort((a, b) => naturalCompare(a.path, b.path));
      final directory = p.basename(folder.path);
      final split = directory.lastIndexOf(' - ');
      final title = split < 0 ? directory : directory.substring(0, split);
      final authors = split < 0 ? '' : directory.substring(split + 3);
      final id = 'local-novel-${sha256.convert(utf8.encode(directory))}';
      final covers = files.where((f) => isImageName(f.path)).toList()
        ..sort(
          (a, b) => (p.basename(a.path).contains('汇总') ? 0 : 1).compareTo(
            p.basename(b.path).contains('汇总') ? 0 : 1,
          ),
        );
      await saveBook(
        Novel(
          uuid: id,
          pathWord: id,
          title: title,
          authors: authors,
          relativeDir: relative(folder.path),
          coverRelativePath: covers.isEmpty ? '' : relative(covers.first.path),
          source: 'dmzj',
        ),
      );
      await db.transaction((txn) async {
        for (final (i, file) in texts.indexed) {
          final vid = sha256
              .convert(utf8.encode(p.basename(file.path)))
              .toString();
          var name = p.basenameWithoutExtension(file.path);
          if (name.startsWith('$directory - ')) {
            name = name.substring(directory.length + 3);
          }
          await txn.insert('novel_volumes', {
            'novel_uuid': id,
            'volume_id': vid,
            'title': name,
            'volume_order': i,
            'txt_relative_path': relative(file.path),
            'is_downloaded': 1,
          }, conflictAlgorithm: ConflictAlgorithm.ignore);
        }
      });
      count++;
    }
    return count;
  }
}
