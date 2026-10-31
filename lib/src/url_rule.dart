/// One `allow` or `deny` entry of a `ServerClockInterceptor`.
///
/// - A path (`/api/v1/user`) matches that path and everything below it, on
///   any host.
/// - A URL (`https://api.example.com` or `https://api.example.com/v1/user`)
///   matches the same scheme, host and port, and that path and below.
///
/// Paths match at `/` boundaries: `/api/user` matches `/api/user` and
/// `/api/user/42`, not `/api/users`. Hosts are case-insensitive, paths are
/// case-sensitive, a default port equals no port, a trailing `/` is ignored,
/// and a request's query and fragment are ignored.
class UrlRule {
  UrlRule._(this.entry, this._scheme, this._host, this._port, this._path);

  /// Parses [entry]; throws [ArgumentError] when it is neither a path nor an
  /// absolute URL with a host, or has a query or fragment (which would be
  /// ignored).
  factory UrlRule.parse(String entry) {
    final trimmed = entry.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError.value(entry, 'entry', 'must not be empty');
    }
    if (trimmed.startsWith('//')) {
      throw ArgumentError.value(
        entry,
        'entry',
        'needs a scheme (https://host) or must be a path (/path)',
      );
    }
    final Uri uri;
    try {
      uri = Uri.parse(trimmed);
    } on FormatException catch (e) {
      throw ArgumentError.value(entry, 'entry', 'is not a valid URL: $e');
    }
    if (uri.hasQuery || uri.hasFragment) {
      throw ArgumentError.value(
        entry,
        'entry',
        'must not have a query or fragment',
      );
    }
    final path = _normalizePath(uri.path);
    if (trimmed.startsWith('/')) {
      return UrlRule._(entry, null, null, null, path);
    }
    if (!uri.hasScheme || uri.host.isEmpty) {
      throw ArgumentError.value(
        entry,
        'entry',
        'needs a scheme and host (https://host) or must be a path (/path)',
      );
    }
    return UrlRule._(
      entry,
      uri.scheme.toLowerCase(),
      uri.host.toLowerCase(),
      uri.port,
      path,
    );
  }

  /// The entry as given.
  final String entry;

  final String? _scheme;
  final String? _host;
  final int? _port;
  final String _path;

  /// Whether [uri], a request's resolved URL, matches this rule.
  bool matches(Uri uri) {
    if (_host != null) {
      if (uri.scheme.toLowerCase() != _scheme ||
          uri.host.toLowerCase() != _host ||
          uri.port != _port) {
        return false;
      }
    }
    if (_path.isEmpty) return true;
    final path = uri.path;
    return path == _path || path.startsWith('$_path/');
  }

  // '' for the root, otherwise the path without trailing slashes.
  static String _normalizePath(String path) {
    var end = path.length;
    while (end > 0 && path[end - 1] == '/') {
      end--;
    }
    return path.substring(0, end);
  }

  @override
  String toString() => 'UrlRule($entry)';
}
