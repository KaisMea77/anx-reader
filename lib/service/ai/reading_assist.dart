// FILE PATH: lib/service/ai/reading_assist.dart  (logic file - NOT the menu)
// Reading assistant core: spoiler-safe context extraction + prompt builders.
//
// Pure Dart (no Flutter imports) so it can be unit-tested on its own.
//
// How the "knows the book only up to your page" guarantee works:
//  * The JavaScript below runs inside the reader WebView and returns ONLY text
//    that comes before the end of the page currently on screen: earlier
//    chapters, plus the current chapter up to the last visible line.
//  * If the position cannot be determined, it returns an error instead of
//    guessing, and nothing is sent to the AI.
//  * The book title and author are never added to the prompt.
import 'dart:convert';

class ReadingAssistSnippet {
  const ReadingAssistSnippet({required this.part, required this.text});

  /// Zero-based index of the book section (chapter file) the snippet is from.
  final int part;
  final String text;
}

class ReadingAssistContext {
  const ReadingAssistContext({
    required this.ok,
    this.reason = '',
    this.recent = '',
    this.snippets = const [],
    this.mentions = 0,
    this.skipped = 0,
    this.partsScanned = 0,
  });

  const ReadingAssistContext.failed(String reason)
    : this(ok: false, reason: reason);

  final bool ok;
  final String reason;

  /// Text read just before (and including) the end of the current page.
  final String recent;

  /// Earlier passages mentioning the selected word (reading order).
  final List<ReadingAssistSnippet> snippets;
  final int mentions;
  final int skipped;
  final int partsScanned;
}

/// Builds the JavaScript function body passed to `callAsyncJavaScript`.
String buildContextScript({
  required String query,
  required bool scan,
  int recentChars = 2500,
}) {
  final config = jsonEncode({
    'query': query,
    'scan': scan,
    'recentChars': recentChars,
    'window': 220,
    'first': 3,
    'last': 5,
  }).replaceAll('\u2028', r'\u2028').replaceAll('\u2029', r'\u2029');
  return _contextScript.replaceAll('__CONFIG__', config);
}

ReadingAssistContext parseContextResult(Object? raw) {
  if (raw is! String || raw.isEmpty) {
    return const ReadingAssistContext.failed('no-result');
  }
  try {
    final map = jsonDecode(raw);
    if (map is! Map) return const ReadingAssistContext.failed('bad-result');
    if (map['ok'] != true) {
      return ReadingAssistContext.failed('${map['reason'] ?? 'unknown'}');
    }
    final snippets = <ReadingAssistSnippet>[];
    final rawSnippets = map['snippets'];
    if (rawSnippets is List) {
      for (final s in rawSnippets) {
        if (s is Map) {
          snippets.add(
            ReadingAssistSnippet(
              part: (s['part'] as num?)?.toInt() ?? 0,
              text: '${s['text'] ?? ''}',
            ),
          );
        }
      }
    }
    return ReadingAssistContext(
      ok: true,
      recent: '${map['recent'] ?? ''}',
      snippets: snippets,
      mentions: (map['mentions'] as num?)?.toInt() ?? 0,
      skipped: (map['skipped'] as num?)?.toInt() ?? 0,
      partsScanned: (map['partsScanned'] as num?)?.toInt() ?? 0,
    );
  } catch (e) {
    return ReadingAssistContext.failed('parse-error');
  }
}

String _clip(String text, int max) {
  final t = text.trim();
  return t.length <= max ? t : '${t.substring(0, max)}…';
}

const String _rules = '''
You are a spoiler-safe reading companion inside an e-book reader.
The reader is part-way through a book. The excerpts below are text the reader has ALREADY read. Nothing after their current page is provided, and you are deliberately not told the book's title or author.

Rules:
1. Base every statement about the story (plot, characters, places, relationships) ONLY on the provided excerpts. Do not use any memory you may have of this book, its sequels or adaptations, and never hint at what might happen later.
2. You may use general knowledge about language, idioms, history, culture and literary allusions to explain meaning.
3. If the excerpts do not contain enough information, say so briefly instead of guessing.
4. Write the answer in {LANG}. Be concise and use plain words. No preamble and no closing remarks.
5. If the book is in a different language from {LANG}, keep character and place names recognisable: write them in {LANG} and give the original spelling in parentheses the first time.''';

String buildExplainPrompt({
  required String language,
  required String selected,
  String? contextSentence,
  required String recent,
}) {
  final b = StringBuffer(_rules.replaceAll('{LANG}', language));
  b.writeln('\n');
  b.writeln(
    'Task: The reader selected the passage below and finds it hard to '
    'understand. Explain what it means in this context, in simple words '
    '(3-6 short sentences). If it contains an idiom, old-fashioned or '
    'figurative wording, or an allusion, name it and say what it means.',
  );
  b.writeln('\nSelected passage:\n<<<\n${_clip(selected, 1500)}\n>>>');
  final sentence = contextSentence?.trim() ?? '';
  if (sentence.isNotEmpty) {
    b.writeln('\nSurrounding sentence:\n<<<\n${_clip(sentence, 700)}\n>>>');
  }
  final r = recent.trim();
  if (r.isNotEmpty) {
    b.writeln(
      '\nText the reader has just read, up to the end of their current '
      'page (most recent last):\n<<<\n$r\n>>>',
    );
  }
  return b.toString();
}

String buildWhoPrompt({
  required String language,
  required String selected,
  required ReadingAssistContext context,
}) {
  final label = _clip(selected, 80);
  final b = StringBuffer(_rules.replaceAll('{LANG}', language));
  b.writeln('\n');
  b.writeln(
    'Task: The reader selected "$label" and wants a reminder of who or '
    'what it is. Using ONLY the excerpts below, answer with:\n'
    '- **Who / what**: one or two sentences.\n'
    '- **Connections**: how it relates to other characters or places '
    'mentioned.\n'
    '- **So far**: up to 4 short bullets of what has happened to or around '
    'it, in reading order.\n'
    'If "$label" does not look like a character, place or story-specific '
    'term, say that in one sentence and briefly explain the word instead.',
  );
  if (context.snippets.isEmpty) {
    b.writeln(
      '\nNo earlier mention of "$label" was found in the text read so '
      'far.',
    );
  } else {
    b.writeln(
      '\nIt is mentioned ${context.mentions} time(s) in the text read '
      'so far.'
      '${context.skipped > 0 ? ' The earliest and the most recent mentions '
                'are shown; ${context.skipped} in between are omitted.' : ''}',
    );
    b.writeln('\nExcerpts in reading order (Part = position in the book):');
    for (final s in context.snippets) {
      b.writeln('[Part ${s.part + 1}] ${s.text}');
    }
  }
  final r = context.recent.trim();
  if (r.isNotEmpty) {
    final tail = r.length > 1200 ? r.substring(r.length - 1200) : r;
    b.writeln(
      '\nText just before the reader\'s current position:\n<<<\n$tail\n>>>',
    );
  }
  return b.toString();
}

const String _contextScript = r'''
const cfg = __CONFIG__;
const fail = function (reason) {
  return JSON.stringify({ ok: false, reason: reason });
};
try {
  const view = reader && reader.view;
  const loc = view && view.lastLocation;
  if (!view || !loc || !loc.range) return fail('no-location');

  const idx = reader.index;
  const contents = view.renderer.getContents();
  const cur =
    contents.find(function (c) {
      return c.index === idx;
    }) || contents[0];
  if (!cur || !cur.doc || !cur.doc.body) return fail('no-document');
  const doc = cur.doc;

  // The visible page range. If it does not belong to the document we are
  // reading from, stop: never guess a position (this is the spoiler guard).
  const vr = loc.range;
  if (!vr.endContainer || vr.endContainer.ownerDocument !== doc) {
    return fail('range-mismatch');
  }

  const norm = function (s) {
    return String(s || '').replace(/\s+/g, ' ').trim();
  };

  // Text of the current chapter from its start to the END OF THE VISIBLE PAGE.
  const upTo = doc.createRange();
  upTo.setStart(doc.body, 0);
  upTo.setEnd(vr.endContainer, vr.endOffset);
  const currentText = norm(upTo.toString());

  const out = {
    ok: true,
    recent: currentText.slice(-cfg.recentChars),
    snippets: [],
    mentions: 0,
    skipped: 0,
    partsScanned: 1,
  };
  if (!cfg.scan) return JSON.stringify(out);

  const esc = function (s) {
    return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  };

  // Search terms: the whole selection, plus capitalised words (names) or
  // words of caseless scripts when several words were selected.
  const raw = norm(cfg.query);
  const terms = [];
  if (raw && raw.length <= 80) terms.push(raw);
  raw.split(/[\s,.;:!?()\[\]"\u201c\u201d\u00ab\u00bb'\u2019\-\u2013\u2014]+/).forEach(function (w) {
    if (w.length < 3 || terms.indexOf(w) !== -1) return;
    const isNameLike = w[0] !== w[0].toLowerCase();
    const isCaseless = w === w.toLowerCase() && w === w.toUpperCase();
    if (isNameLike || isCaseless || raw === w) terms.push(w);
  });
  if (!terms.length) return JSON.stringify(out);
  terms.sort(function (a, b) {
    return b.length - a.length;
  });
  const re = new RegExp(terms.map(esc).join('|'), 'giu');

  // Text of earlier chapters only (index < current), cached per book.
  const sections = (view.book && view.book.sections) || [];
  const cache = reader.__anxAssistCache || (reader.__anxAssistCache = new Map());
  const sectionText = async function (i) {
    if (cache.has(i)) return cache.get(i);
    const s = sections[i];
    let t = '';
    if (s && s.linear !== 'no' && typeof s.createDocument === 'function') {
      try {
        const d = await s.createDocument();
        t = norm(d && d.body && d.body.textContent);
      } catch (e) {
        t = '';
      }
    }
    cache.set(i, t);
    return t;
  };

  const parts = [];
  for (let i = 0; i < idx; i++) {
    const t = await sectionText(i);
    if (t) parts.push({ part: i, text: t });
  }
  parts.push({ part: idx, text: currentText });
  out.partsScanned = parts.length;

  const W = cfg.window;
  const hits = [];
  for (let k = 0; k < parts.length; k++) {
    const p = parts[k];
    re.lastIndex = 0;
    let m;
    let lastEnd = -1;
    while ((m = re.exec(p.text)) !== null) {
      if (m[0].length === 0) {
        re.lastIndex++;
        continue;
      }
      out.mentions++;
      if (m.index >= lastEnd) {
        const s = Math.max(0, m.index - W);
        const e = Math.min(p.text.length, m.index + m[0].length + W);
        hits.push({
          part: p.part,
          text:
            (s > 0 ? '\u2026' : '') +
            p.text.slice(s, e) +
            (e < p.text.length ? '\u2026' : ''),
        });
        lastEnd = e;
      }
      if (out.mentions >= 5000) break;
    }
    if (out.mentions >= 5000) break;
  }

  let chosen = hits;
  if (hits.length > cfg.first + cfg.last) {
    chosen = hits.slice(0, cfg.first).concat(hits.slice(hits.length - cfg.last));
    out.skipped = hits.length - chosen.length;
  }
  out.snippets = chosen;
  return JSON.stringify(out);
} catch (e) {
  return fail('error:' + String(e && e.message ? e.message : e));
}''';
