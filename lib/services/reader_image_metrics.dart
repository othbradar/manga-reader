import 'dart:ui' as ui;

const readerPlaceholderAspectRatio = 2 / 3;

/// Read encoded image dimensions without decoding or retaining a full bitmap.
/// The reader retains only the ratio, independently of Flutter's image cache.
Future<double> readReaderImageAspectRatio(String path) async {
  ui.ImmutableBuffer? buffer;
  ui.ImageDescriptor? descriptor;
  try {
    buffer = await ui.ImmutableBuffer.fromFilePath(path);
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    if (descriptor.width > 0 && descriptor.height > 0) {
      return descriptor.width / descriptor.height;
    }
    return readerPlaceholderAspectRatio;
  } catch (_) {
    // A damaged/unsupported page must keep a nonzero error tile, not collapse
    // the scroll geometry or prevent the rest of the chapter from opening.
    return readerPlaceholderAspectRatio;
  } finally {
    descriptor?.dispose();
    buffer?.dispose();
  }
}
