/// Validates the locally supplied DSH Web authorization URL before storage or use.
/// This input is a secret. A failed parse must never include it in diagnostics.
Uri? parseRemoteHttpsLaunchUrl(String input) {
  final raw = input.trim();
  if (RegExp(r'[\s\x00-\x1f\x7f\\]|%(?![0-9a-fA-F]{2})').hasMatch(raw)) return null;
  final authority = RegExp(r'^https://([^/?#]+)', caseSensitive: false).firstMatch(raw)?.group(1);
  if (authority == null || authority.contains('@')) return null;
  try {
    final uri = Uri.parse(raw);
    if (uri.scheme != 'https' || uri.host.isEmpty || uri.hasFragment || uri.port <= 0 || uri.port > 65535) {
      return null;
    }
    // Accept one credential only. Otherwise different parsers may pick
    // different tokens, or a proxy-specific query might be silently discarded.
    if (!uri.query.startsWith('token=') || uri.query.contains('&')) return null;
    final token = uri.queryParameters['token'];
    if (token == null || token.trim().isEmpty || RegExp(r'[\x00-\x1f\x7f]').hasMatch(token)) return null;
    return uri;
  } on FormatException {
    return null;
  } on ArgumentError {
    return null;
  }
}
