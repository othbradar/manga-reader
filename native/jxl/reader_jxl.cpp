// File-only C ABI for Dart worker isolates. Originals are opened read-only.
#include <jxl/decode.h>
#include <zlib.h>
#include <algorithm>
#include <array>
#include <cstdio>
#include <cstdint>
#include <fstream>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

namespace {
constexpr size_t kMaxInput = 128 * 1024 * 1024;
constexpr uint64_t kMaxPixels = 64 * 1024 * 1024;
using Decoder = std::unique_ptr<JxlDecoder, decltype(&JxlDecoderDestroy)>;
void require(bool ok, const char* message) {
  if (!ok) throw std::runtime_error(message);
}
std::vector<uint8_t> read_input(const char* path) {
  std::ifstream file(path, std::ios::binary | std::ios::ate);
  require(file.good(), "Cannot open JXL page");
  const auto size = file.tellg();
  require(size > 0 && static_cast<uint64_t>(size) <= kMaxInput,
          "JXL page is empty or exceeds the 128 MiB limit");
  std::vector<uint8_t> bytes(static_cast<size_t>(size));
  file.seekg(0);
  require(static_cast<bool>(file.read(reinterpret_cast<char*>(bytes.data()), size)),
          "Cannot read JXL page");
  require(JxlSignatureCheck(bytes.data(), bytes.size()) == JXL_SIG_CODESTREAM ||
          JxlSignatureCheck(bytes.data(), bytes.size()) == JXL_SIG_CONTAINER,
          "Invalid JXL signature");
  return bytes;
}
Decoder decoder(const std::vector<uint8_t>& bytes, int events) {
  Decoder dec(JxlDecoderCreate(nullptr), JxlDecoderDestroy);
  require(dec != nullptr, "Cannot allocate JXL decoder");
  require(JxlDecoderSubscribeEvents(dec.get(), events) == JXL_DEC_SUCCESS,
          "Cannot initialize JXL decoder");
  require(JxlDecoderSetInput(dec.get(), bytes.data(), bytes.size()) == JXL_DEC_SUCCESS,
          "Cannot set JXL input");
  JxlDecoderCloseInput(dec.get());
  // No thread pool: Dart limits the number of concurrent page workers.
  return dec;
}
JxlBasicInfo info(JxlDecoder* dec) {
  JxlBasicInfo value{};
  require(JxlDecoderGetBasicInfo(dec, &value) == JXL_DEC_SUCCESS,
          "Cannot read JXL dimensions");
  require(value.xsize && value.ysize &&
          uint64_t(value.xsize) * value.ysize <= kMaxPixels,
          "JXL page dimensions exceed the 64 megapixel limit");
  require(!value.have_animation, "Animated JXL pages are not supported");
  return value;
}
void write(std::ofstream& out, const uint8_t* data, size_t size) {
  require(static_cast<bool>(out.write(reinterpret_cast<const char*>(data), size)),
          "Cannot write temporary decoded page (check free space)");
}
// Reconstruct the original JPEG bytes, including EXIF/ICC, without recompression.
bool reconstruct(const std::vector<uint8_t>& bytes, const char* output) {
  auto dec = decoder(bytes, JXL_DEC_BASIC_INFO | JXL_DEC_JPEG_RECONSTRUCTION |
                            JXL_DEC_FULL_IMAGE);
  std::vector<uint8_t> buffer(65536);
  size_t written = 0;
  std::ofstream out;
  bool jpeg = false;
  bool complete = false;
  for (;;) {
    const auto status = JxlDecoderProcessInput(dec.get());
    if (status == JXL_DEC_BASIC_INFO) {
      info(dec.get());
    } else if (status == JXL_DEC_JPEG_RECONSTRUCTION) {
      out.open(output, std::ios::binary | std::ios::trunc);
      require(out.good(), "Cannot create temporary JPEG");
      jpeg = true;
      require(JxlDecoderSetJPEGBuffer(dec.get(), buffer.data(), buffer.size()) ==
              JXL_DEC_SUCCESS, "Cannot initialize JPEG reconstruction");
    } else if (status == JXL_DEC_JPEG_NEED_MORE_OUTPUT) {
      const auto remaining = JxlDecoderReleaseJPEGBuffer(dec.get());
      const auto used = buffer.size() - remaining;
      written += used;
      require(written <= 2 * kMaxInput, "Reconstructed JPEG exceeds the 256 MiB limit");
      write(out, buffer.data(), used);
      // An indivisible JPEG scan/metadata block can exceed the output buffer.
      // Reusing an equally small buffer after zero progress loops forever.
      if (used == 0) {
        require(buffer.size() < kMaxInput, "JPEG reconstruction block is too large");
        buffer.resize(buffer.size() * 2);
      }
      require(JxlDecoderSetJPEGBuffer(dec.get(), buffer.data(), buffer.size()) ==
              JXL_DEC_SUCCESS, "Cannot continue JPEG reconstruction");
    } else if (status == JXL_DEC_FULL_IMAGE) {
      complete = true;
    } else if (status == JXL_DEC_SUCCESS) {
      if (!jpeg) return false;
      require(complete, "Incomplete JXL image");
      const auto remaining = JxlDecoderReleaseJPEGBuffer(dec.get());
      write(out, buffer.data(), buffer.size() - remaining);
      out.close();
      require(out.good(), "Cannot finish temporary JPEG");
      return true;
    } else if (status == JXL_DEC_NEED_IMAGE_OUT_BUFFER && !jpeg) {
      return false;
    } else {
      throw std::runtime_error("Corrupt or truncated JXL page");
    }
  }
}
void be32(uint8_t* dest, uint32_t n) {
  for (int i = 3; i >= 0; --i) { dest[i] = n & 255; n >>= 8; }
}
void chunk(std::ofstream& out, const char* type, const uint8_t* bytes, size_t size) {
  uint8_t word[4];
  be32(word, static_cast<uint32_t>(size));
  write(out, word, 4);
  write(out, reinterpret_cast<const uint8_t*>(type), 4);
  if (size) write(out, bytes, size);
  auto crc = crc32(0, reinterpret_cast<const Bytef*>(type), 4);
  if (size) crc = crc32(crc, bytes, static_cast<uInt>(size));
  be32(word, static_cast<uint32_t>(crc));
  write(out, word, 4);
}
// Generic still JXL fallback: full-size 8-bit sRGB RGBA, lossless PNG cache.
// Streaming zlib avoids a second full-size filtered image allocation.
void write_png(const char* output, const std::vector<uint8_t>& rgba,
               uint32_t width, uint32_t height) {
  std::ofstream out(output, std::ios::binary | std::ios::trunc);
  require(out.good(), "Cannot create temporary PNG");
  const uint8_t signature[] = {137, 80, 78, 71, 13, 10, 26, 10};
  write(out, signature, 8);
  uint8_t header[13]{};
  be32(header, width); be32(header + 4, height);
  header[8] = 8; header[9] = 6;
  chunk(out, "IHDR", header, sizeof(header));
  const uint8_t intent = 1;
  chunk(out, "sRGB", &intent, 1);
  z_stream stream{};
  require(deflateInit(&stream, 1) == Z_OK, "Cannot initialize PNG compression");
  struct End { z_stream* s; ~End() { deflateEnd(s); } } end{&stream};
  std::array<uint8_t, 65536> compressed{};
  auto feed = [&](const uint8_t* bytes, size_t size, int flush) {
    stream.next_in = const_cast<Bytef*>(bytes);
    stream.avail_in = static_cast<uInt>(size);
    int status;
    do {
      stream.next_out = compressed.data();
      stream.avail_out = compressed.size();
      status = deflate(&stream, flush);
      require(status == Z_OK || status == Z_STREAM_END, "PNG compression failed");
      const auto produced = compressed.size() - stream.avail_out;
      if (produced) chunk(out, "IDAT", compressed.data(), produced);
    } while (stream.avail_in || stream.avail_out == 0 ||
             (flush == Z_FINISH && status != Z_STREAM_END));
  };
  const uint8_t filter = 0;
  for (uint32_t y = 0; y < height; ++y) {
    feed(&filter, 1, Z_NO_FLUSH);
    feed(rgba.data() + size_t(y) * width * 4, size_t(width) * 4, Z_NO_FLUSH);
  }
  feed(nullptr, 0, Z_FINISH);
  chunk(out, "IEND", nullptr, 0);
  out.close();
  require(out.good(), "Cannot finish temporary PNG");
}
void decode_png(const std::vector<uint8_t>& bytes, const char* output) {
  auto dec = decoder(bytes, JXL_DEC_BASIC_INFO | JXL_DEC_COLOR_ENCODING | JXL_DEC_FULL_IMAGE);
  JxlBasicInfo basic{};
  JxlPixelFormat format{4, JXL_TYPE_UINT8, JXL_NATIVE_ENDIAN, 0};
  std::vector<uint8_t> rgba;
  for (;;) {
    const auto status = JxlDecoderProcessInput(dec.get());
    if (status == JXL_DEC_BASIC_INFO) {
      basic = info(dec.get());
    } else if (status == JXL_DEC_COLOR_ENCODING) {
      JxlColorEncoding color{};
      color.color_space = basic.num_color_channels == 1 ? JXL_COLOR_SPACE_GRAY : JXL_COLOR_SPACE_RGB;
      color.white_point = JXL_WHITE_POINT_D65;
      color.primaries = JXL_PRIMARIES_SRGB;
      color.transfer_function = JXL_TRANSFER_FUNCTION_SRGB;
      color.rendering_intent = JXL_RENDERING_INTENT_RELATIVE;
      require(JxlDecoderSetPreferredColorProfile(dec.get(), &color) == JXL_DEC_SUCCESS,
              "Cannot set JXL sRGB output");
    } else if (status == JXL_DEC_NEED_IMAGE_OUT_BUFFER) {
      size_t size = 0;
      require(JxlDecoderImageOutBufferSize(dec.get(), &format, &size) == JXL_DEC_SUCCESS &&
              size == uint64_t(basic.xsize) * basic.ysize * 4,
              "Invalid JXL pixel buffer size");
      rgba.resize(size);
      require(JxlDecoderSetImageOutBuffer(dec.get(), &format, rgba.data(), size) == JXL_DEC_SUCCESS,
              "Cannot initialize JXL pixel output");
    } else if (status == JXL_DEC_FULL_IMAGE) {
      write_png(output, rgba, basic.xsize, basic.ysize);
      return;
    } else {
      throw std::runtime_error("Corrupt or truncated JXL page");
    }
  }
}
void error_text(char* output, size_t size, const char* message) {
  if (output && size) std::snprintf(output, size, "%s", message);
}
}  // namespace

#define READER_EXPORT extern "C" __attribute__((visibility("default")))
READER_EXPORT int reader_jxl_info(const char* input, uint32_t* width,
                                  uint32_t* height, char* error, size_t size) {
  try {
    const auto bytes = read_input(input);
    auto dec = decoder(bytes, JXL_DEC_BASIC_INFO);
    require(JxlDecoderProcessInput(dec.get()) == JXL_DEC_BASIC_INFO, "Cannot read JXL header");
    const auto basic = info(dec.get());
    *width = basic.xsize; *height = basic.ysize;
    return 1;
  } catch (const std::exception& e) { error_text(error, size, e.what()); return -1; }
}
// 1: original JPEG restored; 2: PNG fallback; -1: failure. Caller atomically
// renames the private .part file only on success and removes it on failure.
READER_EXPORT int reader_jxl_convert(const char* input, const char* output,
                                     char* error, size_t size) {
  try {
    const auto bytes = read_input(input);
    if (reconstruct(bytes, output)) return 1;
    decode_png(bytes, output);
    return 2;
  } catch (const std::exception& e) { error_text(error, size, e.what()); return -1; }
}
