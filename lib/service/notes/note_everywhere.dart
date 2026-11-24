// FILE PATH: lib/service/notes/note_everywhere.dart  (logic file - NOT a widget)
//
// Logic for "apply this note to every occurrence of the word in the book".
// Pure Dart (no Flutter or project imports) so it can be tested on its own.
//
// Safety rules implemented here:
//  * Only whole-word, case-insensitive matches are proposed.
//  * Any occurrence that overlaps an EXISTING note or highlight is skipped, so
//    a note you wrote earlier is never overwritten.
//  * The caller shows a confirmation with the number of matches first.
import 'dart:convert';

class EverywhereHit {
  const EverywhereHit({
    required this.cfi,
    required this.match,
    this.pre = '',
    this.post = '',
    this.chapter = '',
  });

  final String cfi;

  /// The text exactly as written in the book (keeps its capitalisation).
  final String match;
  final String pre;
  final String post;
  final String chapter;
}

class EverywhereFind {
  const EverywhereFind({
    required this.ok,
    this.reason = '',
    this.hits = const [],
    this.truncated = false,
  });

  final bool ok;
  final String reason;
  final List<EverywhereHit> hits;

  /// True when the search stopped at the safety limit.
  final bool truncated;
}

/// JavaScript (function body for `callAsyncJavaScript`) that searches the whole
/// book with the reader's own search and returns every match.
String buildFindEverywhereScript({
  required String query,
  int max = 1500,
  bool wholeWords = true,

  /// Keep the reader's search marks (teal outlines) on every match instead of
  /// clearing them, to show all occurrences while reading.
  bool keepMarks = false,
}) {
  final config = jsonEncode({
    'query': query,
    'max': max,
    'wholeWords': wholeWords,
    'keep': keepMarks,
  }).replaceAll('\u2028', r'\u2028').replaceAll('\u2029', r'\u2029');
  return 'const cfg = $config;\n$_findScript';
}

/// Removes the reader's search marks (the teal outlines).
String buildClearSearchMarksScript() => _clearSearchScript;

EverywhereFind parseFindEverywhere(Object? raw) {
  if (raw is! String || raw.isEmpty) {
    return const EverywhereFind(ok: false, reason: 'no-result');
  }
  try {
    final map = jsonDecode(raw);
    if (map is! Map) {
      return const EverywhereFind(ok: false, reason: 'bad-result');
    }
    if (map['ok'] != true) {
      return EverywhereFind(ok: false, reason: '${map['reason'] ?? 'unknown'}');
    }
    final hits = <EverywhereHit>[];
    final rawHits = map['hits'];
    if (rawHits is List) {
      for (final h in rawHits) {
        if (h is Map && '${h['cfi'] ?? ''}'.isNotEmpty) {
          hits.add(
            EverywhereHit(
              cfi: '${h['cfi']}',
              match: '${h['match'] ?? ''}',
              pre: '${h['pre'] ?? ''}',
              post: '${h['post'] ?? ''}',
              chapter: '${h['chapter'] ?? ''}',
            ),
          );
        }
      }
    }
    return EverywhereFind(
      ok: true,
      hits: hits,
      truncated: map['truncated'] == true,
    );
  } catch (e) {
    return const EverywhereFind(ok: false, reason: 'parse-error');
  }
}

// -----------------------------------------------------------------------------
// CFI ranges
// -----------------------------------------------------------------------------

class _Position {
  const _Position(this.path, this.offset);

  final List<int> path;
  final int offset;
}

int _compare(_Position a, _Position b) {
  final n = a.path.length < b.path.length ? a.path.length : b.path.length;
  for (var i = 0; i < n; i++) {
    if (a.path[i] != b.path[i]) return a.path[i].compareTo(b.path[i]);
  }
  if (a.path.length != b.path.length) {
    return a.path.length.compareTo(b.path.length);
  }
  return a.offset.compareTo(b.offset);
}

final RegExp _digits = RegExp(r'\d+');
final RegExp _assertions = RegExp(r'\[[^\]]*\]');
final RegExp _offsetTail = RegExp(r'^(.*?)(?::(\d+))?$');

_Position? _toPosition(String parent, String relative) {
  final m = _offsetTail.firstMatch(relative);
  if (m == null) return null;
  final path = <int>[
    ..._digits.allMatches(parent).map((x) => int.parse(x[0]!)),
    ..._digits.allMatches(m.group(1) ?? '').map((x) => int.parse(x[0]!)),
  ];
  if (path.isEmpty) return null;
  return _Position(path, int.tryParse(m.group(2) ?? '') ?? 0);
}

/// A CFI turned into a comparable [start, end) range.
class CfiRange {
  const CfiRange._(this._start, this._end, this.raw);

  final _Position _start;
  final _Position _end;
  final String raw;

  static CfiRange? tryParse(String cfi) {
    try {
      var s = cfi.trim();
      if (s.startsWith('epubcfi(') && s.endsWith(')')) {
        s = s.substring(8, s.length - 1);
      }
      s = s.replaceAll(_assertions, '');
      final parts = s.split(',');
      if (parts.length == 3) {
        final start = _toPosition(parts[0], parts[1]);
        final end = _toPosition(parts[0], parts[2]);
        if (start == null || end == null) return null;
        return CfiRange._(start, end, cfi);
      }
      if (parts.length == 1) {
        // A single point behaves like a one-character range.
        final p = _toPosition('', parts[0]);
        if (p == null) return null;
        return CfiRange._(p, _Position(p.path, p.offset + 1), cfi);
      }
    } catch (e) {
      return null;
    }
    return null;
  }

  bool overlaps(CfiRange other) {
    return _compare(_start, other._end) < 0 && _compare(other._start, _end) < 0;
  }
}

/// True when the two CFIs cover overlapping text (or are the same string when
/// they cannot be parsed).
bool cfiOverlaps(String a, String b) {
  if (a == b) return true;
  final ra = CfiRange.tryParse(a);
  final rb = CfiRange.tryParse(b);
  if (ra == null || rb == null) return false;
  return ra.overlaps(rb);
}

/// Hits to create: drops anything overlapping an existing note or highlight,
/// and duplicates inside the result itself.
List<EverywhereHit> planNewHits({
  required List<EverywhereHit> hits,
  required Iterable<String> existingCfis,
}) {
  final existingStrings = existingCfis.toSet();
  final existingRanges = <CfiRange>[];
  for (final c in existingStrings) {
    final r = CfiRange.tryParse(c);
    if (r != null) existingRanges.add(r);
  }
  final accepted = <EverywhereHit>[];
  final acceptedRanges = <CfiRange>[];
  final seen = <String>{};
  for (final h in hits) {
    if (!seen.add(h.cfi)) continue;
    if (existingStrings.contains(h.cfi)) continue;
    final range = CfiRange.tryParse(h.cfi);
    if (range != null) {
      if (existingRanges.any(range.overlaps)) continue;
      if (acceptedRanges.any(range.overlaps)) continue;
      acceptedRanges.add(range);
    }
    accepted.add(h);
  }
  return accepted;
}

/// JavaScript that draws the given annotations in the reader (any chapter: the
/// reader keeps them and draws each when its chapter is shown).
String buildAddAnnotationsScript(List<Map<String, Object?>> items) {
  final json = jsonEncode(items)
      .replaceAll('\u2028', r'\u2028')
      .replaceAll('\u2029', r'\u2029');
  return '(function(items){for(var i=0;i<items.length;i++){'
      'try{addAnnotation(items[i]);}catch(e){}}})($json);';
}

String buildRemoveAnnotationsScript(List<String> cfis) {
  final json = jsonEncode(cfis)
      .replaceAll('\u2028', r'\u2028')
      .replaceAll('\u2029', r'\u2029');
  return '(function(c){for(var i=0;i<c.length;i++){'
      'try{removeAnnotation(c[i]);}catch(e){}}})($json);';
}

const String _findScript = r'''
const cleanup = function () {
  if (cfg.keep) return;
  try {
    reader.view.clearSearch();
  } catch (e) {}
};
try {
  const hits = [];
  let truncated = false;
  const iter = reader.view.search({
    query: cfg.query,
    scope: 'book',
    matchCase: false,
    matchDiacritics: false,
    matchWholeWords: cfg.wholeWords,
    index: null,
  });
  for await (const r of iter) {
    if (!r || r === 'done' || 'progress' in r) continue;
    if (r.subitems) {
      for (const s of r.subitems) {
        hits.push({
          cfi: String(s.cfi),
          match: String((s.excerpt && s.excerpt.match) || ''),
          pre: String((s.excerpt && s.excerpt.pre) || ''),
          post: String((s.excerpt && s.excerpt.post) || ''),
          chapter: String(r.label || ''),
        });
        if (hits.length >= cfg.max) {
          truncated = true;
          break;
        }
      }
    }
    if (truncated) break;
  }
  cleanup();
  return JSON.stringify({ ok: true, hits: hits, truncated: truncated });
} catch (e) {
  cleanup();
  return JSON.stringify({ ok: false, reason: String(e && e.message ? e.message : e) });
}''';

const String _clearSearchScript = r'''
try {
  reader.view.clearSearch();
  return JSON.stringify({ ok: true });
} catch (e) {
  return JSON.stringify({ ok: false, reason: String(e && e.message ? e.message : e) });
}''';
