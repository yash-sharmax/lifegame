/// Link previews (v2.11.0, point 8).
///
/// Fetches a URL's page and reads its Open Graph tags
/// (og:title / og:description / og:image), falling back to <title>.
/// [fetchLinkPreview] is the network part; the pure parse lives in
/// messaging_models.dart ([parseOpenGraph]) so tests never touch
/// the network.
library;

import 'package:http/http.dart' as http;

import 'messaging_models.dart';

/// Fetches a link preview. Returns null when the page cannot be
/// fetched or has no usable title/description. Never throws —
/// a missing preview must never break the chat.
Future<LinkPreviewData?> fetchLinkPreview(
  String url, {
  http.Client? client,
  Duration timeout = const Duration(seconds: 8),
}) async {
  final normalized = url.startsWith('www.') ? 'https://$url' : url;
  final uri = Uri.tryParse(normalized);
  if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
    return null;
  }
  final httpClient = client ?? http.Client();
  try {
    final res = await httpClient
        .get(
          uri,
          headers: {
            'User-Agent':
                'Mozilla/5.0 (Life Game link preview; +https://yashx.xyz/lifegame)',
            'Accept': 'text/html',
          },
        )
        .timeout(timeout);
    if (res.statusCode != 200) return null;
    final preview = parseOpenGraph(res.body);
    if (preview.isEmpty) return null;
    return preview;
  } catch (_) {
    return null;
  } finally {
    if (client == null) httpClient.close();
  }
}
