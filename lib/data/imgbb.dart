/// Attachments via imgbb (v2.11.0, point 5).
///
/// imgbb is free: https://api.imgbb.com — the free API key for the
/// app's account (lifegame) is pasted into [imgbbApiKey] below
/// (v2.11.5). It is a free, rate-limited upload key, not a secret
/// that grants account access.
///
/// Uploads are plain HTTPS multipart POSTs; the returned URL is a
/// public image link and the delete URL lets View Once (point 10)
/// actually remove the file after it is seen.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

/// >>> THE FREE IMGBB API KEY (account: lifegame) <<<
///
/// Created at https://api.imgbb.com (sign up → API key). Free tier.
/// The key lives here so image attachments work out of the box —
/// it is a free, rate-limited upload key for this app's account,
/// not a secret that grants account access. If it ever needs
/// rotating, replace this value and rebuild.
const String imgbbApiKey = '2551f296e0f8164c12d49586f7ef9f6b';

bool get isImgbbConfigured =>
    imgbbApiKey != 'YOUR_IMGBB_API_KEY' && imgbbApiKey.isNotEmpty;

/// Thrown when an attachment is attempted before the imgbb key is set.
class ImgbbNotConfigured implements Exception {
  @override
  String toString() =>
      'Image attachments need the free imgbb API key — paste it into '
      'lib/data/imgbb.dart (imgbbApiKey).';
}

class ImgbbUpload {
  const ImgbbUpload({required this.url, this.deleteUrl});

  /// The public image URL stored on the message.
  final String url;

  /// Delete URL — stored on the message so View Once can remove
  /// the file from imgbb after it is seen (point 10).
  final String? deleteUrl;
}

/// Uploads raw image bytes to imgbb. [filename] is only a label
/// (e.g. 'photo.jpg'). [contentType] lets the caller declare the
/// real format (the encrypted PNG carrier uploads as 'image/png').
/// Returns the public URL + delete URL.
Future<ImgbbUpload> uploadImageToImgbb(
  List<int> bytes, {
  String filename = 'photo.jpg',
  String? contentType,
  http.Client? client,
}) async {
  if (!isImgbbConfigured) throw ImgbbNotConfigured();
  final httpClient = client ?? http.Client();
  try {
    final uri = Uri.parse('https://api.imgbb.com/1/upload');
    final request = http.MultipartRequest('POST', uri)
      ..fields['key'] = imgbbApiKey
      ..fields['name'] = filename
      ..files.add(
        http.MultipartFile.fromBytes(
          'image',
          bytes,
          filename: filename,
          contentType: contentType == null
              ? null
              : MediaType.parse(contentType),
        ),
      );
    final streamed = await httpClient.send(request).timeout(
      const Duration(seconds: 60),
    );
    final body = await streamed.stream.bytesToString();
    final json = jsonDecode(body) as Map<String, dynamic>;
    if (streamed.statusCode != 200 || json['success'] != true) {
      throw Exception(
        'imgbb upload failed (${streamed.statusCode}): '
        '${json['error']?['message'] ?? body}',
      );
    }
    final data = json['data'] as Map<String, dynamic>;
    return ImgbbUpload(
      url: data['url'] as String,
      deleteUrl: data['delete_url'] as String?,
    );
  } finally {
    if (client == null) httpClient.close();
  }
}

/// Best-effort delete of an imgbb image via its delete URL
/// (used by View Once after the photo is seen). Never throws.
Future<void> deleteImageFromImgbb(String deleteUrl) async {
  try {
    await http
        .get(Uri.parse(deleteUrl))
        .timeout(const Duration(seconds: 15));
  } catch (_) {
    // The message row is already deleted; a leftover file on imgbb
    // is harmless and not worth surfacing.
  }
}
