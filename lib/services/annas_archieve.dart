// Flutter imports:
import 'package:flutter/foundation.dart';

// Package imports:
import 'package:dio/dio.dart';
import 'package:html/parser.dart' show parse;
import 'package:html/dom.dart' as dom;

// ============================================================
// MAINTENANCE NOTES (update when you fix things)
// ============================================================
// v2  2026-06  - Added multi-domain fallback list (.gl/.pk/.gd/.se)
//              - Full browser-impersonation headers (Sec-Fetch-*, CH-UA)
//              - Cloudflare-challenge / 403 detection & typed error enum
//              - Two-strategy HTML parser: primary CSS → generic fallback
//              - Response-body sniffing to detect CF challenge pages
//              - Explicit timeout + followRedirects configuration
//              - Debug logging gated behind kDebugMode
//              - bookInfo remaps stale mirror URLs to the active mirror
// ============================================================

// ====================================================================
// DOMAIN LIST  ← Update THIS first when Anna's Archive moves again
// ====================================================================
//
// As of June 2026 the .org and .se domains are geo-blocked / down in
// many regions.  Active mirrors (priority order):
//   https://annas-archive.gl   ← primary
//   https://annas-archive.pk
//   https://annas-archive.gd
//   https://annas-archive.se   ← regional fallback, may still work
//
// To add a new mirror: append to this list, no other changes needed.
const List<String> _kMirrors = [
  'https://annas-archive.gl',
  'https://annas-archive.pk',
  'https://annas-archive.gd',
  'https://annas-archive.se',
];

// ====================================================================
// TYPED ERROR ENUM  — gives the UI real information to show
// ====================================================================
enum AnnasErrorType {
  /// Plain network failure / DNS / timeout
  network,

  /// HTTP 403 or 429 from Cloudflare / the site
  cloudflareBlocked,

  /// Got a 200 but CF sent a JS-challenge page (needs WebView)
  cloudflareCaptcha,

  /// All mirrors tried and all failed
  allMirrorsDown,

  /// Got a 200 real page but HTML structure changed; parser found nothing
  htmlStructureChanged,

  /// Any other unexpected error
  unknown,
}

class AnnasException implements Exception {
  final AnnasErrorType type;
  final String message;
  final int? statusCode;

  const AnnasException(this.type, this.message, {this.statusCode});

  @override
  String toString() => message; // surface-friendly for the error widget
}

// ====================================================================
// DATA MODELS
// ====================================================================

class BookData {
  final String title;
  final String? author;
  final String? thumbnail;
  final String link;
  final String md5;
  final String? publisher;
  final String? info;

  const BookData({
    required this.title,
    this.author,
    this.thumbnail,
    required this.link,
    required this.md5,
    this.publisher,
    this.info,
  });
}

class BookInfoData extends BookData {
  String? mirror;
  final String? description;
  final String? format;

  BookInfoData({
    required super.title,
    required super.author,
    required super.thumbnail,
    required super.publisher,
    required super.info,
    required super.link,
    required super.md5,
    required this.format,
    required this.mirror,
    required this.description,
  });
}

// ====================================================================
// ANNA'S ARCHIVE SERVICE
// ====================================================================

class AnnasArchieve {
  late final Dio _dio;

  /// The mirror that last succeeded (reused for detail-page fetches).
  String _activeBase = _kMirrors.first;

  /// Expose the currently active base URL.
  String get baseUrl => _activeBase;

  AnnasArchieve() {
    _dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 20),
        receiveTimeout: const Duration(seconds: 30),
        sendTimeout: const Duration(seconds: 15),
        followRedirects: true,
        maxRedirects: 5,
        responseType: ResponseType.plain,
        // Do NOT throw on 4xx/5xx; we inspect statusCode ourselves.
        validateStatus: (_) => true,
      ),
    );
  }

  // ── Full browser-impersonation headers ───────────────────────────
  // Cloudflare inspects Accept, all Sec-* headers, and their ordering.
  // Keep the UA string current (latest Chrome stable is a safe choice).
  Map<String, String> _browserHeaders({String? referer}) => {
    'User-Agent':
        'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36',
    'Accept':
        'text/html,application/xhtml+xml,application/xml;q=0.9,'
        'image/avif,image/webp,image/apng,*/*;q=0.8',
    'Accept-Language': 'en-US,en;q=0.9',
    'Accept-Encoding': 'gzip, deflate, br',
    if (referer != null) 'Referer': referer,
    'Sec-Fetch-Dest': 'document',
    'Sec-Fetch-Mode': 'navigate',
    'Sec-Fetch-Site': referer != null ? 'same-origin' : 'none',
    'Sec-Fetch-User': '?1',
    'Upgrade-Insecure-Requests': '1',
    'Sec-CH-UA':
        '"Chromium";v="124", "Google Chrome";v="124", "Not-A.Brand";v="99"',
    'Sec-CH-UA-Mobile': '?1',
    'Sec-CH-UA-Platform': '"Android"',
    'Cache-Control': 'no-cache',
    'Pragma': 'no-cache',
  };

  // ── Helpers ──────────────────────────────────────────────────────

  String getMd5(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return '';
    final segs = uri.pathSegments;
    return segs.isNotEmpty ? segs.last : '';
  }

  String getFormat(String info) {
    final lower = info.toLowerCase();
    if (lower.contains('pdf')) return 'pdf';
    if (lower.contains('cbr')) return 'cbr';
    if (lower.contains('cbz')) return 'cbz';
    if (lower.contains('mobi') || lower.contains('azw')) return 'mobi';
    if (lower.contains('djvu')) return 'djvu';
    return 'epub';
  }

  void _debugLog(String msg) {
    if (kDebugMode) debugPrint('[AnnasArchieve] $msg');
  }

  // ── Cloudflare challenge detection ───────────────────────────────
  bool _isCloudflareChallenge(String body) {
    if (body.length > 50000) return false; // real page is usually large
    final lower = body.toLowerCase();
    return lower.contains('cf-browser-verification') ||
        lower.contains('checking your browser') ||
        lower.contains('just a moment') ||
        lower.contains('enable javascript and cookies') ||
        lower.contains('_cf_chl_opt') ||
        (lower.contains('cloudflare') && lower.contains('challenge'));
  }

  AnnasException _statusToException(int status, String url) {
    switch (status) {
      case 403:
        return AnnasException(
          AnnasErrorType.cloudflareBlocked,
          'Access blocked (HTTP 403) by Cloudflare on $url.\n'
          'Try again in a few minutes or use a VPN.',
          statusCode: status,
        );
      case 429:
        return AnnasException(
          AnnasErrorType.cloudflareBlocked,
          'Rate-limited (HTTP 429). Wait a few minutes and try again.',
          statusCode: status,
        );
      case 503:
      case 502:
        return AnnasException(
          AnnasErrorType.network,
          'Mirror returned HTTP $status (server unavailable): $url',
          statusCode: status,
        );
      default:
        return AnnasException(
          AnnasErrorType.unknown,
          'Unexpected HTTP $status from $url',
          statusCode: status,
        );
    }
  }

  // ====================================================================
  // URL BUILDER
  // ====================================================================

  String _buildSearchUrl({
    required String base,
    required String searchQuery,
    required String content,
    required String sort,
    required String fileType,
    required bool enableFilters,
  }) {
    // Uri.encodeQueryComponent handles spaces, '&', '#', etc. correctly.
    final encoded = Uri.encodeQueryComponent(searchQuery);
    if (!enableFilters) {
      return '$base/search?q=$encoded';
    }
    return '$base/search?index=&q=$encoded&content=$content&ext=$fileType&sort=$sort';
  }

  // ====================================================================
  // MULTI-MIRROR FETCH  (tries each mirror in sequence)
  // ====================================================================

  Future<({Response<dynamic> response, String base})> _fetchWithFallback(
    String Function(String base) urlBuilder,
  ) async {
    final errors = <String>[];

    for (final base in _kMirrors) {
      final url = urlBuilder(base);
      _debugLog('Trying $url');

      try {
        final response = await _dio.get(
          url,
          options: Options(headers: _browserHeaders(referer: '$base/')),
        );

        final status = response.statusCode ?? 0;
        _debugLog('HTTP $status from $url');

        if (status == 200) {
          final body = response.data?.toString() ?? '';
          if (_isCloudflareChallenge(body)) {
            _debugLog('CF challenge on $base – skipping to next mirror');
            errors.add('$base: Cloudflare JS challenge');
            continue;
          }
          _activeBase = base;
          return (response: response, base: base);
        }

        errors.add('$base: HTTP $status');

      } on DioException catch (e) {
        final reason = switch (e.type) {
          DioExceptionType.connectionTimeout => 'connection timeout',
          DioExceptionType.receiveTimeout    => 'receive timeout',
          DioExceptionType.connectionError   => 'connection error',
          DioExceptionType.unknown           => 'network error',
          _                                  => e.type.name,
        };
        _debugLog('Dio error on $base: $reason');
        errors.add('$base: $reason');
      }
    }

    throw AnnasException(
      AnnasErrorType.allMirrorsDown,
      'All mirrors are unreachable. Please check your internet '
      'connection or try a VPN.\n\nDetails:\n${errors.join("\n")}',
    );
  }

  // ====================================================================
  // SEARCH RESULTS PARSER
  // ====================================================================
  // Strategy 1 (primary):  known CSS selectors.
  // Strategy 2 (fallback): attribute-based selectors — fires when the
  //                         site updates its CSS class names.

  List<BookData> _parser(String html, String fileType, String base) {
    final document = parse(html);

    // Guard: empty / totally wrong page
    if ((document.body?.text.trim() ?? '').isEmpty) {
      throw AnnasException(
        AnnasErrorType.htmlStructureChanged,
        'Received an empty page. The site may be down.',
      );
    }

    // ── Strategy 1 ───────────────────────────────────────────────────
    var containers = document.querySelectorAll('div.flex.pt-3.pb-3.border-b');
    bool usedFallback = false;

    if (containers.isEmpty) {
      // ── Strategy 2 ─────────────────────────────────────────────────
      _debugLog('Primary selectors found 0 containers; using fallback');
      usedFallback = true;

      // Every result card contains an /md5/ anchor – climb to its wrapper.
      final md5Anchors = document.querySelectorAll('a[href^="/md5/"]');
      final Set<dom.Element> seen = {};
      for (final a in md5Anchors) {
        dom.Element? el = a.parent;
        while (el != null &&
            el.localName != 'div' &&
            el.localName != 'article' &&
            el.localName != 'li') {
          el = el.parent;
        }
        if (el != null) seen.add(el);
      }
      containers = seen.toList();
      _debugLog('Fallback found ${containers.length} containers');
    }

    if (containers.isEmpty) {
      // Distinguish genuine "no results" from parser failure
      final isEmptyResult =
          document.querySelector('[class*="no-result"]') != null ||
          document.querySelector('[class*="empty"]') != null ||
          html.toLowerCase().contains('no files found') ||
          html.toLowerCase().contains('no results');

      if (isEmptyResult) return []; // legitimate empty search

      throw AnnasException(
        AnnasErrorType.htmlStructureChanged,
        'The search results page structure has changed and the scraper '
        'could not find any book containers.'
        '${usedFallback ? " (Both primary and fallback selectors failed.)" : ""}\n'
        'Please report this as a bug so the selectors can be updated.',
      );
    }

    final List<BookData> bookList = [];
    for (final container in containers) {
      try {
        bookList.addAll(_parseContainer(container, fileType, base));
      } catch (e) {
        _debugLog('Skipping container – parse error: $e');
      }
    }
    return bookList;
  }

  /// Parse one search-result card into 0 or 1 BookData.
  List<BookData> _parseContainer(
      dom.Element container, String fileType, String base) {

    // ── Title link ───────────────────────────────────────────────────
    dom.Element? mainLink =
        // Primary selector (the title link on Anna's Archive)
        container.querySelector('a.line-clamp-\\[3\\].js-vim-focus') ??
        // Fallback: first /md5/ link with non-empty text
        container
            .querySelectorAll('a[href^="/md5/"]')
            .where((a) => a.text.trim().isNotEmpty)
            .firstOrNull;

    if (mainLink == null) return [];
    final href = mainLink.attributes['href'];
    if (href == null || href.isEmpty) return [];

    final title = mainLink.text.trim();
    if (title.isEmpty) return [];

    final link = base + href;
    final md5 = getMd5(href);

    // ── Thumbnail ────────────────────────────────────────────────────
    final thumbImg =
        container.querySelector('a[href^="/md5/"] img') ??
        container.querySelector('img[src*="covers"]') ??
        container.querySelector('img');
    final thumbnail = thumbImg?.attributes['src'];

    // ── Author / Publisher (siblings of the title link) ──────────────
    String? author;
    String? publisher;
    dom.Element? sib = mainLink.nextElementSibling;
    int sibCount = 0;
    while (sib != null && sibCount < 3) {
      final sibHref = sib.attributes['href'] ?? '';
      if (sibHref.startsWith('/search?q=')) {
        final raw = sib.text.trim();
        // Strip icon text that may bleed in
        final clean = raw.contains('icon-')
            ? raw.split(' ').skip(1).join(' ').trim()
            : raw;
        if (author == null) {
          author = clean.isEmpty ? null : clean;
        } else {
          publisher = clean.isEmpty ? null : clean;
          break;
        }
      }
      sib = sib.nextElementSibling;
      sibCount++;
    }

    // ── Info line (format, size, language …) ─────────────────────────
    String? info =
        container.querySelector('div.text-gray-800')?.text.trim() ??
        container
            .querySelectorAll('div')
            .where((d) =>
                d.text.contains(
                    RegExp(r'\d+\s*(KB|MB|GB)', caseSensitive: false)) ||
                d.text.contains(
                    RegExp(r'\b(PDF|EPUB|CBZ|CBR|DJVU|MOBI)\b',
                        caseSensitive: false)))
            .map((d) => d.text.trim())
            .firstOrNull;

    // ── File-type filter ─────────────────────────────────────────────
    final hasMatch = fileType.isEmpty
        ? (info?.contains(RegExp(
                r'\b(PDF|EPUB|CBR|CBZ|DJVU|MOBI)\b',
                caseSensitive: false)) ==
            true)
        : (info?.toLowerCase().contains(fileType.toLowerCase()) == true);

    if (!hasMatch) return [];

    return [
      BookData(
        title: title,
        author: (author?.isEmpty ?? true) ? 'unknown' : author,
        thumbnail: thumbnail,
        link: link,
        md5: md5,
        publisher: (publisher?.isEmpty ?? true) ? 'unknown' : publisher,
        info: info,
      )
    ];
  }

  // ====================================================================
  // BOOK DETAIL PAGE PARSER
  // ====================================================================

  Future<BookInfoData?> _bookInfoParser(
      String html, String url, String base) async {
    final document = parse(html);

    dom.Element? main =
        document.querySelector('div.main-inner') ??
        document.querySelector('main') ??
        document.querySelector('article') ??
        document.querySelector('section');

    if (main == null) return null;

    // ── Download / mirror link ───────────────────────────────────────
    String? mirror;
    final slowLinks = main.querySelectorAll('a[href*="/slow_download/"]');
    if (slowLinks.isNotEmpty) {
      mirror = base + slowLinks.first.attributes['href']!;
    }
    mirror ??= main
        .querySelectorAll('ul a[href*="download"]')
        .map((a) {
          final h = a.attributes['href'] ?? '';
          return h.startsWith('http') ? h : base + h;
        })
        .firstOrNull;

    // ── Title ────────────────────────────────────────────────────────
    dom.Element? titleEl =
        main.querySelector('div.font-semibold.text-2xl') ??
        main.querySelector('h1') ??
        main.querySelector('[class*="title"]');
    if (titleEl == null) return null;

    String title = titleEl.text.trim();
    if (title.contains('<span')) title = title.split('<span')[0].trim();
    if (title.isEmpty) return null;

    // ── Author ───────────────────────────────────────────────────────
    final authorEl =
        main.querySelector('a[href^="/search?q="].text-base') ??
        main.querySelector('a[href^="/search?q="]');
    final author = authorEl?.text.trim() ?? 'unknown';

    // ── Publisher ────────────────────────────────────────────────────
    dom.Element? publisherEl = authorEl?.nextElementSibling;
    if (publisherEl?.localName != 'a' ||
        publisherEl?.attributes['href']?.startsWith('/search?q=') != true) {
      publisherEl = null;
    }
    final publisher = publisherEl?.text.trim() ?? 'unknown';

    // ── Thumbnail ────────────────────────────────────────────────────
    final thumbEl =
        main.querySelector('div[id^="list_cover_"] img') ??
        main.querySelector('img[src*="cover"]') ??
        main.querySelector('img');
    final thumbnail = thumbEl?.attributes['src'];

    // ── Info line ────────────────────────────────────────────────────
    final infoEl =
        main.querySelector('div.text-gray-800') ??
        main
            .querySelectorAll('div')
            .where((d) => d.text
                .contains(RegExp(r'\b(PDF|EPUB|CBZ|CBR)\b', caseSensitive: false)))
            .firstOrNull;
    final info = infoEl?.text.trim() ?? '';

    // ── Description ──────────────────────────────────────────────────
    String description = ' ';
    final descLabel = main.querySelector(
        'div.js-md5-top-box-description div.text-xs.text-gray-500.uppercase');
    if (descLabel?.text.trim().toLowerCase() == 'description') {
      description = descLabel?.nextElementSibling?.text.trim() ?? ' ';
    }
    if (description.trim().isEmpty) {
      description = main
              .querySelectorAll('p')
              .where((p) => p.text.trim().length > 80)
              .map((p) => p.text.trim())
              .firstOrNull ??
          ' ';
    }

    return BookInfoData(
      title: title,
      author: author,
      thumbnail: thumbnail,
      publisher: publisher,
      info: info,
      link: url,
      md5: getMd5(url),
      format: getFormat(info),
      mirror: mirror,
      description: description,
    );
  }

  // ====================================================================
  // PUBLIC API
  // ====================================================================

  /// Search books.  Tries every mirror before giving up.
  /// Throws [AnnasException] with a user-readable [message] on failure.
  Future<List<BookData>> searchBooks({
    required String searchQuery,
    String content = '',
    String sort = '',
    String fileType = '',
    bool enableFilters = true,
  }) async {
    try {
      final result = await _fetchWithFallback((base) => _buildSearchUrl(
            base: base,
            searchQuery: searchQuery,
            content: content,
            sort: sort,
            fileType: fileType,
            enableFilters: enableFilters,
          ));

      final status = result.response.statusCode ?? 0;
      if (status != 200) throw _statusToException(status, result.response.realUri.toString());

      final html = result.response.data?.toString() ?? '';
      if (_isCloudflareChallenge(html)) {
        throw AnnasException(
          AnnasErrorType.cloudflareCaptcha,
          'Cloudflare is showing a browser-verification challenge.\n'
          'Go to Settings → "Solve Captcha", complete the challenge, '
          'then search again.',
        );
      }

      return _parser(html, fileType, result.base);
    } on AnnasException {
      rethrow;
    } on DioException catch (e) {
      if (e.type == DioExceptionType.connectionError ||
          e.type == DioExceptionType.unknown) {
        // Keep the legacy "socketException" token so the existing
        // error_widget.dart "Unable to access internet" branch still fires.
        throw const AnnasException(AnnasErrorType.network, 'socketException');
      }
      throw AnnasException(
          AnnasErrorType.network, 'Network error: ${e.message ?? e.type.name}');
    } catch (e) {
      if (e is AnnasException) rethrow;
      throw AnnasException(AnnasErrorType.unknown, e.toString());
    }
  }

  /// Fetch book detail.  Remaps stale mirror URLs to the active mirror.
  Future<BookInfoData> bookInfo({required String url}) async {
    final remapped = _remapToActiveMirror(url);
    try {
      final result = await _fetchWithFallback((_) => remapped);

      final status = result.response.statusCode ?? 0;
      if (status != 200) throw _statusToException(status, remapped);

      final html = result.response.data?.toString() ?? '';
      if (_isCloudflareChallenge(html)) {
        throw AnnasException(
          AnnasErrorType.cloudflareCaptcha,
          'Cloudflare challenge on book detail page.\n'
          'Go to Settings → "Solve Captcha", then try again.',
        );
      }

      final data = await _bookInfoParser(html, url, result.base);
      if (data == null) {
        throw AnnasException(
          AnnasErrorType.htmlStructureChanged,
          'Could not parse the book detail page – the page structure '
          'may have changed. Please report this as a bug.',
        );
      }
      return data;
    } on AnnasException {
      rethrow;
    } on DioException catch (e) {
      if (e.type == DioExceptionType.connectionError ||
          e.type == DioExceptionType.unknown) {
        throw const AnnasException(AnnasErrorType.network, 'socketException');
      }
      throw AnnasException(
          AnnasErrorType.network, 'Network error: ${e.message ?? e.type.name}');
    } catch (e) {
      if (e is AnnasException) rethrow;
      throw AnnasException(AnnasErrorType.unknown, e.toString());
    }
  }

  // ── Remap a link's host to the currently active mirror ────────────
  String _remapToActiveMirror(String url) {
    for (final mirror in _kMirrors) {
      if (url.startsWith(mirror)) return url;
    }
    final uri = Uri.tryParse(url);
    final activeUri = Uri.tryParse(_activeBase);
    if (uri == null || activeUri == null) return url;
    return uri.replace(host: activeUri.host, scheme: activeUri.scheme).toString();
  }
}
