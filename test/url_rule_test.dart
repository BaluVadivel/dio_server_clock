import 'package:dio_server_clock/src/url_rule.dart';
import 'package:test/test.dart';

bool _matches(String entry, String url) =>
    UrlRule.parse(entry).matches(Uri.parse(url));

void main() {
  group('path entries', () {
    test('match at / boundaries on any host', () {
      expect(_matches('/api/user', 'https://a.example.com/api/user'), isTrue);
      expect(_matches('/api/user', 'http://b.example.org/api/user/1'), isTrue);
      expect(_matches('/api/user', 'https://a.example.com/api/users'), isFalse);
      expect(_matches('/api/user', 'https://a.example.com/api'), isFalse);
    });

    test('ignore a trailing slash on either side', () {
      expect(_matches('/api/user/', 'https://a.example.com/api/user'), isTrue);
      expect(_matches('/api/user', 'https://a.example.com/api/user/'), isTrue);
    });

    test('/ matches every path', () {
      expect(_matches('/', 'https://a.example.com'), isTrue);
      expect(_matches('/', 'https://a.example.com/x/y'), isTrue);
    });

    test('are case-sensitive', () {
      expect(_matches('/Api', 'https://a.example.com/api'), isFalse);
    });

    test('compare encoded paths', () {
      expect(_matches('/a b', 'https://a.example.com/a%20b/c'), isTrue);
    });

    test('ignore the query and fragment of a request', () {
      expect(_matches('/x', 'https://a.example.com/x?y=1#z'), isTrue);
    });
  });

  group('URL entries', () {
    test('a base URL matches every path on that host', () {
      expect(
        _matches('https://a.example.com', 'https://a.example.com'),
        isTrue,
      );
      expect(
        _matches('https://a.example.com/', 'https://a.example.com/x/y'),
        isTrue,
      );
    });

    test('a URL with a path matches that path and below', () {
      const entry = 'https://a.example.com/v1/user';
      expect(_matches(entry, 'https://a.example.com/v1/user/9'), isTrue);
      expect(_matches(entry, 'https://a.example.com/v1/users'), isFalse);
      expect(_matches(entry, 'https://a.example.com/v1'), isFalse);
    });

    test('host is case-insensitive', () {
      expect(
        _matches('https://A.Example.COM', 'https://a.example.com/x'),
        isTrue,
      );
    });

    test('a default port equals no port', () {
      expect(
        _matches('https://a.example.com:443', 'https://a.example.com/x'),
        isTrue,
      );
      expect(
        _matches('https://a.example.com', 'https://a.example.com:443/x'),
        isTrue,
      );
      expect(
        _matches('https://a.example.com', 'https://a.example.com:8443/x'),
        isFalse,
      );
    });

    test('scheme, host and subdomain must match exactly', () {
      const entry = 'https://example.com';
      expect(_matches(entry, 'http://example.com/x'), isFalse);
      expect(_matches(entry, 'https://api.example.com/x'), isFalse);
      expect(_matches(entry, 'https://example.com.evil.net/x'), isFalse);
    });
  });

  test('invalid entries throw ArgumentError', () {
    for (final entry in [
      '',
      ' ',
      'example.com',
      'example.com/x',
      '//example.com',
      'https://',
      'mailto:x@example.com',
      'https://example.com/x?y=1',
      'https://example.com/#top',
      '/x?y=1',
    ]) {
      expect(() => UrlRule.parse(entry), throwsArgumentError, reason: entry);
    }
  });

  test('surrounding whitespace is ignored', () {
    expect(_matches('  /x  ', 'https://a.example.com/x'), isTrue);
  });
}
