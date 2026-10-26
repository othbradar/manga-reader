import 'dart:io';
import 'dart:ui' as ui;

import 'package:archive/archive.dart';
import 'package:copymanga_reader/services/jxl_codec.dart';
import 'package:copymanga_reader/services/reader_image_metrics.dart';
import 'package:copymanga_reader/services/zip_book.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final nativeLibrary = Platform.environment['COPYMANGA_JXL_LIBRARY'];
  const fixtures = 'test/fixtures/jxl';
  late Directory temp;

  setUp(() async => temp = await Directory.systemTemp.createTemp('jxl-test-'));
  tearDown(() async => temp.delete(recursive: true));

  group(
    'bundled native JXL decoder',
    () {
      test(
        'large JPEG scan grows the output buffer without stalling',
        () async {
          final original = await File('$fixtures/large-scan.jpg').readAsBytes();
          expect(original.length, greaterThan(65536));
          final output = await JxlCodec.prepare(
            '$fixtures/large-scan.jxl',
            '${temp.path}/large',
          ).timeout(const Duration(seconds: 5));
          expect(await File(output).readAsBytes(), original);
        },
      );
      test(
        'reconstructs exactly the original JPEG, preserving source bytes',
        () async {
          final source = File('$fixtures/reversible.jxl');
          final before = sha256.convert(await source.readAsBytes());
          final ratio = await readReaderImageAspectRatio(source.path);
          expect(ratio, closeTo(32 / 48, 0.00001));
          final output = await JxlCodec.prepare(
            source.path,
            '${temp.path}/decoded',
          );
          expect(output, endsWith('.jpg'));
          expect(
            await File(output).readAsBytes(),
            await File('$fixtures/original.jpg').readAsBytes(),
          );
          expect(sha256.convert(await source.readAsBytes()), before);
          expect(File('${temp.path}/decoded.part').existsSync(), isFalse);
        },
      );

      test('generic RGBA JXL falls back to readable lossless PNG', () async {
        final output = await JxlCodec.prepare(
          '$fixtures/rgba.jxl',
          '${temp.path}/rgba',
        );
        expect(output, endsWith('.png'));
        Future<List<int>> pixels(String path) async {
          final codec = await ui.instantiateImageCodec(
            await File(path).readAsBytes(),
          );
          final frame = await codec.getNextFrame();
          expect(frame.image.width, 32);
          expect(frame.image.height, 48);
          final bytes = await frame.image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          );
          frame.image.dispose();
          codec.dispose();
          return bytes!.buffer.asUint8List();
        }

        expect(await pixels(output), await pixels('$fixtures/original.png'));
      });

      test(
        'bad and truncated pages fail without leaving a partial result',
        () async {
          final valid = await File('$fixtures/reversible.jxl').readAsBytes();
          for (final bytes in [
            [0, 1, 2],
            valid.sublist(0, valid.length ~/ 2),
          ]) {
            final source = await File(
              '${temp.path}/bad.jxl',
            ).writeAsBytes(bytes);
            await expectLater(
              JxlCodec.prepare(source.path, '${temp.path}/bad-out'),
              throwsFormatException,
            );
            expect(File('${temp.path}/bad-out.part').existsSync(), isFalse);
          }
        },
      );

      test(
        'mixed ZIP preparation is cached and temporary data is cleaned',
        () async {
          final archive = Archive();
          for (final (name, fixture) in [
            ('0.jxl', 'reversible.jxl'),
            ('1.jxl', 'rgba.jxl'),
            ('2.jpg', 'original.jpg'),
          ]) {
            final data = await File('$fixtures/$fixture').readAsBytes();
            archive.addFile(ArchiveFile(name, data.length, data));
          }
          final zip = await File(
            '${temp.path}/chapter.zip',
          ).writeAsBytes(ZipEncoder().encode(archive));
          final before = sha256.convert(await zip.readAsBytes());
          final book = await ZipBook.open(zip.path);
          expect(book.cachedDisplayPath(0), isNull);
          final pending = book.preparePagePath(0);
          expect(identical(pending, book.preparePagePath(0)), isTrue);
          final paths = await Future.wait([
            pending,
            book.preparePagePath(1),
            book.preparePagePath(2),
          ]);
          expect(paths.map((p) => File(p).existsSync()), everyElement(isTrue));
          expect(book.cachedDisplayPath(0), paths[0]);
          await book.close();
          expect(paths.map((p) => File(p).existsSync()), everyElement(isFalse));
          expect(sha256.convert(await zip.readAsBytes()), before);
        },
      );

      test(
        'closing while decoding waits for workers and removes their files',
        () async {
          final bytes = await File('$fixtures/reversible.jxl').readAsBytes();
          final archive = Archive()
            ..addFile(ArchiveFile('0.jxl', bytes.length, bytes));
          final zip = await File(
            '${temp.path}/close.zip',
          ).writeAsBytes(ZipEncoder().encode(archive));
          final book = await ZipBook.open(zip.path);
          final extracted = book.pagePath(0);
          final pending = book.preparePagePath(0);
          final assertion = expectLater(pending, throwsStateError);
          await book.close();
          await assertion;
          expect(File(extracted).parent.existsSync(), isFalse);
        },
      );
    },
    skip: nativeLibrary == null ? '设置 COPYMANGA_JXL_LIBRARY 运行打包解码器测试' : false,
  );
}
