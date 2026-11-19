/// PNG carrier for encrypted image bytes (v2.11.1, image E2EE).
///
/// Why this exists: imgbb only accepts real image files (JPEG, PNG,
/// GIF, BMP, WEBP). Uploading raw ciphertext bytes would be rejected
/// as "not an image", so the ciphertext rides inside a valid PNG:
/// its bytes become the image's pixels (RGB, filter 0, stored
/// DEFLATE blocks — no compression, so the bytes survive
/// byte-for-byte). imgbb serves the original file back at the
/// direct URL, and the app unpacks and decrypts it. To anyone else
/// the PNG looks like noise — that is the point: the real photo is
/// encrypted inside it.
///
/// Pure Dart, no new dependency, works on web: the encoder writes
/// stored (uncompressed) DEFLATE blocks by hand, with hand-rolled
/// CRC-32 and Adler-32. The decoder only accepts PNGs this encoder
/// could have written (8-bit RGB, filter 0, stored blocks) and
/// returns null for anything else — including a real photo, which
/// is exactly what an unencrypted image looks like.
///
/// Payload layout: 4-byte big-endian length, then the data. The
/// length is needed because the last row is padded to full width.
library;

import 'dart:typed_data';

// ---------------------------------------------------------------------------
// Checksums (standard CRC-32 / Adler-32).
// ---------------------------------------------------------------------------

final List<int> _crcTable = List<int>.generate(256, (n) {
  var c = n;
  for (var k = 0; k < 8; k++) {
    c = (c & 1) != 0 ? 0xedb88320 ^ (c >> 1) : c >> 1;
  }
  return c;
});

int _crc32(List<int> bytes) {
  var crc = 0xffffffff;
  for (final b in bytes) {
    crc = _crcTable[(crc ^ b) & 0xff] ^ (crc >> 8);
  }
  return (crc ^ 0xffffffff) & 0xffffffff;
}

int _adler32(List<int> bytes) {
  var a = 1;
  var b = 0;
  for (final byte in bytes) {
    a = (a + byte) % 65521;
    b = (b + a) % 65521;
  }
  return ((b << 16) | a) & 0xffffffff;
}

void _writeUint32(List<int> out, int value) {
  out.addAll([
    (value >> 24) & 0xff,
    (value >> 16) & 0xff,
    (value >> 8) & 0xff,
    value & 0xff,
  ]);
}

void _writeChunk(List<int> out, String type, List<int> data) {
  final typeBytes = type.codeUnits;
  _writeUint32(out, data.length);
  out.addAll(typeBytes);
  out.addAll(data);
  _writeUint32(out, _crc32([...typeBytes, ...data]));
}

/// Packs [data] into a valid PNG whose pixels carry the bytes.
/// The PNG is 256 pixels wide (768 RGB bytes per row); the height
/// grows with the data. Returns the PNG file bytes.
List<int> packBytesAsPng(List<int> data) {
  const width = 256;
  const rowBytes = width * 3;
  // 4-byte length prefix + the data itself.
  final payload = Uint8List(4 + data.length);
  final length = data.length;
  payload[0] = (length >> 24) & 0xff;
  payload[1] = (length >> 16) & 0xff;
  payload[2] = (length >> 8) & 0xff;
  payload[3] = length & 0xff;
  payload.setAll(4, data);

  final height = (payload.length / rowBytes).ceil().clamp(1, 1 << 24);
  // Scanlines: one filter byte (0 = none) + rowBytes of pixels.
  final raw = Uint8List(height * (rowBytes + 1));
  for (var row = 0; row < height; row++) {
    final srcStart = row * rowBytes;
    final dstStart = row * (rowBytes + 1);
    raw[dstStart] = 0;
    final take = (payload.length - srcStart).clamp(0, rowBytes);
    if (take > 0) {
      raw.setRange(dstStart + 1, dstStart + 1 + take, payload, srcStart);
    }
  }

  // zlib stream: header 0x78 0x01 (no compression) + stored
  // DEFLATE blocks + Adler-32 of the raw scanlines.
  final zlib = <int>[0x78, 0x01];
  var offset = 0;
  while (true) {
    final remaining = raw.length - offset;
    final chunk = remaining > 65535 ? 65535 : remaining;
    final isLast = offset + chunk >= raw.length;
    zlib.add(isLast ? 0x01 : 0x00);
    zlib.addAll([chunk & 0xff, (chunk >> 8) & 0xff]);
    final nlen = (~chunk) & 0xffff;
    zlib.addAll([nlen & 0xff, (nlen >> 8) & 0xff]);
    zlib.addAll(raw.sublist(offset, offset + chunk));
    offset += chunk;
    if (isLast) break;
  }
  _writeUint32(zlib, _adler32(raw));

  final png = <int>[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
  final ihdr = Uint8List(13);
  final ihdrView = ByteData.view(ihdr.buffer);
  ihdrView.setUint32(0, width);
  ihdrView.setUint32(4, height);
  ihdr[8] = 8; // bit depth
  ihdr[9] = 2; // color type: RGB
  ihdr[10] = 0; // compression
  ihdr[11] = 0; // filter
  ihdr[12] = 0; // interlace
  _writeChunk(png, 'IHDR', ihdr);
  _writeChunk(png, 'IDAT', zlib);
  _writeChunk(png, 'IEND', const []);
  return png;
}

/// Unpacks bytes previously packed with [packBytesAsPng]. Returns
/// null for anything that is not one of our carrier PNGs (wrong
/// signature, wrong colour type, filtered rows, compressed blocks,
/// bad checksums, truncated data) — including ordinary photos.
List<int>? unpackBytesFromPng(List<int> png) {
  try {
    if (png.length < 8) return null;
    const signature = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
    for (var i = 0; i < 8; i++) {
      if (png[i] != signature[i]) return null;
    }
    var pos = 8;
    var width = 0;
    var height = 0;
    final idat = <int>[];
    var sawIhdr = false;
    var sawIend = false;
    while (pos + 8 <= png.length) {
      final length =
          (png[pos] << 24) |
          (png[pos + 1] << 16) |
          (png[pos + 2] << 8) |
          png[pos + 3];
      final type = String.fromCharCodes(png.sublist(pos + 4, pos + 8));
      final dataStart = pos + 8;
      final dataEnd = dataStart + length;
      if (dataEnd + 4 > png.length) return null;
      final data = png.sublist(dataStart, dataEnd);
      if (type == 'IHDR') {
        if (length != 13) return null;
        width =
            (data[0] << 24) | (data[1] << 16) | (data[2] << 8) | data[3];
        height =
            (data[4] << 24) | (data[5] << 16) | (data[6] << 8) | data[7];
        if (data[8] != 8 || data[9] != 2) return null; // 8-bit RGB only
        sawIhdr = true;
      } else if (type == 'IDAT') {
        idat.addAll(data);
      } else if (type == 'IEND') {
        sawIend = true;
        break;
      }
      pos = dataEnd + 4;
    }
    if (!sawIhdr || !sawIend || width != 256 || height <= 0) return null;

    // Parse the zlib stream: header + stored DEFLATE blocks.
    if (idat.length < 2 || idat[0] != 0x78) return null;
    var p = 2;
    final raw = <int>[];
    while (true) {
      if (p >= idat.length) return null;
      final header = idat[p];
      p++;
      final isLast = (header & 1) == 1;
      final btype = (header >> 1) & 3;
      if (btype != 0) return null; // stored blocks only
      if (p + 4 > idat.length) return null;
      final len = idat[p] | (idat[p + 1] << 8);
      final nlen = idat[p + 2] | (idat[p + 3] << 8);
      if (nlen != ((~len) & 0xffff)) return null;
      p += 4;
      if (p + len > idat.length) return null;
      raw.addAll(idat.sublist(p, p + len));
      p += len;
      if (isLast) break;
    }
    if (p + 4 > idat.length) return null;
    final adler =
        (idat[p] << 24) |
        (idat[p + 1] << 16) |
        (idat[p + 2] << 8) |
        idat[p + 3];
    if (adler != _adler32(raw)) return null;

    // Unfilter (filter 0 only) and read the length-prefixed payload.
    const rowBytes = 256 * 3;
    if (raw.length != height * (rowBytes + 1)) return null;
    final payload = <int>[];
    for (var row = 0; row < height; row++) {
      final start = row * (rowBytes + 1);
      if (raw[start] != 0) return null;
      payload.addAll(raw.sublist(start + 1, start + 1 + rowBytes));
    }
    if (payload.length < 4) return null;
    final dataLength =
        (payload[0] << 24) |
        (payload[1] << 16) |
        (payload[2] << 8) |
        payload[3];
    if (dataLength < 0 || 4 + dataLength > payload.length) return null;
    return payload.sublist(4, 4 + dataLength);
  } catch (_) {
    return null;
  }
}
