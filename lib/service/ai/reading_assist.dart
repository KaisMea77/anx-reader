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
  bool nameCheck = false,
}) {
  final config = jsonEncode({
    'query': query,
    'scan': scan,
    'nameCheck': nameCheck,
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

/// Result of the "is this selection a proper name?" check.
class NameCheckResult {
  const NameCheckResult({
    required this.ok,
    this.lower = 0,
    this.capMid = 0,
    this.capStart = 0,
  });

  final bool ok;

  /// Times it appears in lower case in the text read so far (a common word).
  final int lower;

  /// Times it appears capitalised in the middle of a sentence.
  final int capMid;

  /// Times it appears capitalised at the start of a sentence.
  final int capStart;

  /// A word that is never written in lower case but is capitalised in the
  /// middle of sentences behaves like a name (character, place, people).
  bool get looksLikeName => ok && lower == 0 && capMid >= 1;
}

NameCheckResult parseNameCheckResult(Object? raw) {
  if (raw is! String || raw.isEmpty) return const NameCheckResult(ok: false);
  try {
    final map = jsonDecode(raw);
    if (map is! Map || map['ok'] != true) {
      return const NameCheckResult(ok: false);
    }
    return NameCheckResult(
      ok: true,
      lower: (map['lower'] as num?)?.toInt() ?? 0,
      capMid: (map['capMid'] as num?)?.toInt() ?? 0,
      capStart: (map['capStart'] as num?)?.toInt() ?? 0,
    );
  } catch (e) {
    return const NameCheckResult(ok: false);
  }
}

/// The sentence and paragraph around the current selection.
class ReadingAssistBlocks {
  const ReadingAssistBlocks({
    required this.ok,
    this.sentence = '',
    this.paragraph = '',
    this.reason = '',
  });

  final bool ok;
  final String sentence;
  final String paragraph;
  final String reason;
}

/// Key of the temporary overlay that colours the translated sentence or
/// paragraph. It starts with "foliate-search:" so taps on it are ignored by
/// the reader and it never turns into a note.
const String assistMarkKey = 'foliate-search:anx-assist-scope';

/// Reads the sentence and paragraph around the current selection.
/// [mark] also colours that part of the page: 0 removes the colour,
/// 1 colours the sentence, 2 colours the paragraph, null leaves it alone.
String buildBlocksScript({
  int maxParagraph = 4000,
  int? mark,
  String markColor = '#FFC107',
}) {
  return _blocksScript.replaceAll(
    '__CONFIG__',
    jsonEncode({
      'maxParagraph': maxParagraph,
      'mark': mark,
      'markKey': assistMarkKey,
      'markColor': markColor,
    }),
  );
}

/// Removes the temporary colour (works even when nothing is selected).
String buildClearMarkScript() {
  return 'const cfg = ${jsonEncode({'markKey': assistMarkKey})};\n'
      '$_clearMarkScript';
}

ReadingAssistBlocks parseBlocksResult(Object? raw) {
  if (raw is! String || raw.isEmpty) {
    return const ReadingAssistBlocks(ok: false, reason: 'no-result');
  }
  try {
    final map = jsonDecode(raw);
    if (map is! Map) {
      return const ReadingAssistBlocks(ok: false, reason: 'bad-result');
    }
    if (map['ok'] != true) {
      return ReadingAssistBlocks(ok: false, reason: '${map['reason']}');
    }
    return ReadingAssistBlocks(
      ok: true,
      sentence: '${map['sentence'] ?? ''}',
      paragraph: '${map['paragraph'] ?? ''}',
    );
  } catch (e) {
    return const ReadingAssistBlocks(ok: false, reason: 'parse-error');
  }
}

/// Which tab the card should open on.
class TabGuess {
  const TabGuess(this.tab, {this.needsNameCheck = false});

  /// 0 = translate, 1 = explain, 2 = who is it.
  final int tab;

  /// The selection is capitalised at a sentence start, so the book text must
  /// be checked before deciding whether it is a name.
  final bool needsNameCheck;
}

final RegExp _arabicScript = RegExp(
  r'[\u0600-\u06FF\u0750-\u077F\u08A0-\u08FF]',
);
final RegExp _edgePunctuation = RegExp(
  r'^[^\p{L}\p{N}]+|[^\p{L}\p{N}]+$',
  unicode: true,
);
const Set<String> _nameConnectors = {
  'of',
  'the',
  'de',
  'del',
  'della',
  'di',
  'da',
  'du',
  'des',
  'le',
  'la',
  'les',
  'el',
  'al',
  'bin',
  'ibn',
  'ben',
  'von',
  'van',
  'der',
  'den',
  'and',
  'y',
  'e',
  'in',
  'on',
  'at',
  'for',
};
const String _quoteChars = '"\'\u201c\u201d\u2018\u2019\u00ab\u00bb()[]';
const String _stopChars = '.!?\u2026\u061f\u06d4';

bool _isCapitalized(String token) {
  if (token.isEmpty) return false;
  final first = String.fromCharCode(token.runes.first);
  return first != first.toLowerCase();
}

bool _looksLikeProperName(List<String> tokens) {
  if (tokens.isEmpty) return false;
  if (tokens.length == 1) {
    return tokens.first.runes.length >= 2 && _isCapitalized(tokens.first);
  }
  if (!_isCapitalized(tokens.first) || !_isCapitalized(tokens.last)) {
    return false;
  }
  for (var i = 1; i < tokens.length - 1; i++) {
    final t = tokens[i];
    if (!_isCapitalized(t) && !_nameConnectors.contains(t.toLowerCase())) {
      return false;
    }
  }
  return true;
}

enum _SentencePosition { middle, start, unknown }

_SentencePosition _positionInContext(String text, String? contextText) {
  final c = (contextText ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();
  if (c.isEmpty) return _SentencePosition.unknown;
  var best = -1;
  var bestDistance = double.infinity;
  var from = 0;
  while (true) {
    final i = c.indexOf(text, from);
    if (i < 0) break;
    final d = (i + text.length / 2 - c.length / 2).abs();
    if (d < bestDistance) {
      best = i;
      bestDistance = d;
    }
    from = i + 1;
  }
  if (best < 0) return _SentencePosition.unknown;
  var i = best - 1;
  while (i >= 0 && (c[i] == ' ' || _quoteChars.contains(c[i]))) {
    i--;
  }
  if (i < 0) return _SentencePosition.unknown;
  return _stopChars.contains(c[i])
      ? _SentencePosition.start
      : _SentencePosition.middle;
}

/// Decides which tab to open first, without any network call.
///  * a capitalised word in the middle of a sentence (Alexander, Babylon,
///    Tower of Babel) is almost always a name -> "Who is it?"
///  * capitalised at a sentence start -> unclear, the book text is checked
///  * Arabic-script selections need no translation into Arabic
///  * everything else (lower case words, phrases, sentences) -> translate
TabGuess guessInitialTab({
  required String selected,
  String? contextText,
  required bool answerIsArabic,
}) {
  final text = selected.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (text.isEmpty || text.length > 60) return const TabGuess(0);
  final tokens = text
      .split(' ')
      .map((t) => t.replaceAll(_edgePunctuation, ''))
      .where((t) => t.isNotEmpty)
      .toList();
  if (tokens.isEmpty || tokens.length > 4) return const TabGuess(0);

  if (answerIsArabic && _arabicScript.hasMatch(text)) {
    return TabGuess(tokens.length <= 3 ? 2 : 1);
  }
  if (!_looksLikeProperName(tokens)) return const TabGuess(0);

  switch (_positionInContext(text, contextText)) {
    case _SentencePosition.middle:
      return const TabGuess(2);
    case _SentencePosition.start:
    case _SentencePosition.unknown:
      return const TabGuess(0, needsNameCheck: true);
  }
}

final RegExp _sentenceBreak = RegExp(
  r'[.!?\u2026\u061f\u06d4]+["\u0027\u201d\u2019\u00bb)\]]*\s+',
);
final RegExp _abbreviationBefore = RegExp(
  r'(?:^|[\s(\u201c"])(?:Mr|Mrs|Ms|Dr|Prof|St|Sr|Jr|Mt|vs|etc|Fig|No|Vol|Inc|Ltd|Co|[A-Z])$',
);

/// Fallback when the page cannot be queried: the sentence around the
/// selection, taken from the short context text (about 240 characters).
String sentenceFromContext(String? contextText, String selected) {
  final sel = selected.replaceAll(RegExp(r'\s+'), ' ').trim();
  final c = (contextText ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();
  if (c.isEmpty || sel.isEmpty) return sel;
  var idx = -1;
  var bestDistance = double.infinity;
  var from = 0;
  while (true) {
    final i = c.indexOf(sel, from);
    if (i < 0) break;
    final d = (i + sel.length / 2 - c.length / 2).abs();
    if (d < bestDistance) {
      idx = i;
      bestDistance = d;
    }
    from = i + 1;
  }
  if (idx < 0) return sel;
  final bounds = <int>[0];
  for (final m in _sentenceBreak.allMatches(c)) {
    if (c[m.start] == '.' &&
        _abbreviationBefore.hasMatch(
          c.substring(m.start < 12 ? 0 : m.start - 12, m.start),
        )) {
      continue;
    }
    if (m.end < c.length) {
      final next = c[m.end];
      if (next == next.toLowerCase() && next != next.toUpperCase()) continue;
    }
    bounds.add(m.end);
  }
  var s = 0;
  for (final b in bounds) {
    if (b <= idx) s = b;
  }
  var e = c.length;
  for (final b in bounds) {
    if (b >= idx + sel.length && b > s) {
      e = b;
      break;
    }
  }
  final result = c.substring(s, e).trim();
  return result.length < sel.length ? sel : result;
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

/// Dictionary-style lookup: only the equivalent word, chosen for the sense it
/// has in its sentence.
String buildDictionaryPrompt({
  required String language,
  required String word,
  String? sentence,
}) {
  final b = StringBuffer();
  b.writeln('You are a bilingual dictionary built into an e-book reader.');
  b.writeln(
    'Give the $language equivalent of the word or phrase below, exactly '
    'as a dictionary entry would, choosing the sense that fits the sentence '
    'it appears in.',
  );
  b.writeln('\nRules:');
  b.writeln(
    '- Output ONLY the $language word or phrase. If one very close '
    'alternative is truly useful, add it after a comma. At most two items.',
  );
  b.writeln(
    '- No explanation, no example, no transliteration, no quotation '
    'marks, no grammar labels, no introduction.',
  );
  b.writeln('- If it is a proper name, give its usual $language spelling.');
  b.writeln('- If it is already in $language, give a close synonym instead.');
  b.writeln('\nWord or phrase:\n<<<\n${_clip(word, 80)}\n>>>');
  final sent = (sentence ?? '').trim();
  if (sent.isNotEmpty && sent != word.trim()) {
    b.writeln('\nThe sentence it appears in:\n<<<\n${_clip(sent, 400)}\n>>>');
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

  const esc = function (s) {
    return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
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
  if (cfg.nameCheck) {
    // Is the selection a proper name? Count, in the text read so far in this
    // chapter, how often it appears in lower case, capitalised mid-sentence,
    // and capitalised at the start of a sentence.
    const term = norm(cfg.query);
    if (!term) return fail('empty');
    const rx = new RegExp(
      '(^|[^\\p{L}\\p{M}\\p{N}_])(' + esc(term) + ')(?![\\p{L}\\p{M}\\p{N}_])',
      'giu'
    );
    const SKIP = '"\'\u201c\u201d\u2018\u2019\u00ab\u00bb()[]';
    const STOP = '.!?\u2026\u061f\u06d4';
    let lower = 0;
    let capMid = 0;
    let capStart = 0;
    let mm;
    while ((mm = rx.exec(currentText)) !== null) {
      const tok = mm[2];
      const first = tok.charAt(0);
      if (first === first.toLowerCase() && first !== first.toUpperCase()) {
        lower++;
      } else if (first !== first.toLowerCase()) {
        let i = mm.index + mm[1].length - 1;
        while (i >= 0 && (currentText[i] === ' ' || SKIP.indexOf(currentText[i]) !== -1)) i--;
        if (i < 0 || STOP.indexOf(currentText[i]) !== -1) capStart++;
        else capMid++;
      }
      if (lower + capMid + capStart >= 2000) break;
    }
    return JSON.stringify({ ok: true, kind: 'name', lower: lower, capMid: capMid, capStart: capStart });
  }
  if (!cfg.scan) return JSON.stringify(out);

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

const String _blocksScript = r'''
const cfg = __CONFIG__;
const fail = function (reason) {
  return JSON.stringify({ ok: false, reason: reason });
};
try {
  const view = reader && reader.view;
  if (!view) return fail('no-view');

  // Find the document that currently holds the selection.
  let doc = null;
  let range = null;
  const contents = view.renderer.getContents();
  for (let i = 0; i < contents.length; i++) {
    const d = contents[i] && contents[i].doc;
    const sel = d && d.getSelection ? d.getSelection() : null;
    if (sel && sel.rangeCount > 0 && !sel.isCollapsed) {
      doc = d;
      range = sel.getRangeAt(0);
      break;
    }
  }
  if (!range) return fail('no-selection');

  // Nearest block-level element around the start of the selection.
  const BLOCK = /^(P|DIV|LI|BLOCKQUOTE|H[1-6]|SECTION|ARTICLE|TD|TH|DD|DT|PRE|FIGCAPTION|ASIDE|BODY)$/i;
  const startNode = range.startContainer;
  let block = startNode.nodeType === 1 ? startNode : startNode.parentElement;
  while (block && !BLOCK.test(block.tagName)) block = block.parentElement;
  if (!block) block = doc.body;

  const text = block.textContent || '';
  const before = doc.createRange();
  before.setStart(block, 0);
  before.setEnd(range.startContainer, range.startOffset);
  const startOff = before.toString().length;
  const endOff = startOff + range.toString().length;

  // Sentence boundaries: end punctuation (+ closing quotes) followed by space.
  const ABBR = /(?:^|[\s(\u201c"'\u2018])(?:Mr|Mrs|Ms|Dr|Prof|St|Sr|Jr|Mt|vs|etc|Fig|No|Vol|Inc|Ltd|Co|[A-Z])$/;
  const bounds = [0];
  const re = /[.!?\u2026\u061f\u06d4]+["'\u201d\u2019\u00bb)\]]*\s+/g;
  let m;
  while ((m = re.exec(text)) !== null) {
    if (m[0].charAt(0) === '.' && ABBR.test(text.slice(Math.max(0, m.index - 12), m.index))) {
      continue;
    }
    // A lower-case letter right after the break means the sentence goes on
    // ("3 p.m. today", "\u201cWhy?\u201d he asked").
    const next = text.charAt(m.index + m[0].length);
    if (next && next === next.toLowerCase() && next !== next.toUpperCase()) continue;
    bounds.push(m.index + m[0].length);
  }
  let s = 0;
  for (let i = 0; i < bounds.length; i++) if (bounds[i] <= startOff) s = bounds[i];
  let e = text.length;
  for (let i = 0; i < bounds.length; i++) {
    if (bounds[i] >= endOff && bounds[i] > s) {
      e = bounds[i];
      break;
    }
  }

  // Optional: colour the sentence / paragraph in the page (temporary overlay).
  // The key starts with "foliate-search:" so taps on it are ignored by the
  // reader and it never turns into a note.
  if (cfg.mark !== null && cfg.mark !== undefined) {
    let overlayer = null;
    for (let i = 0; i < contents.length; i++) {
      if (contents[i] && contents[i].doc === doc) overlayer = contents[i].overlayer;
    }
    if (overlayer) {
      overlayer.remove(cfg.markKey);
      if (cfg.mark === 1 || cfg.mark === 2) {
        const mr = doc.createRange();
        if (cfg.mark === 2) {
          mr.selectNodeContents(block);
        } else {
          let ms = s;
          let me = e;
          while (me > ms && /\s/.test(text.charAt(me - 1))) me--;
          const walker = doc.createTreeWalker(block, 4);
          let acc = 0;
          let node;
          let sNode = null;
          let sOff = 0;
          let eNode = null;
          let eOff = 0;
          while ((node = walker.nextNode())) {
            const len = node.nodeValue.length;
            if (sNode === null && ms < acc + len) {
              sNode = node;
              sOff = ms - acc;
            }
            if (eNode === null && me <= acc + len) {
              eNode = node;
              eOff = me - acc;
            }
            acc += len;
            if (sNode !== null && eNode !== null) break;
          }
          if (sNode && eNode) {
            mr.setStart(sNode, sOff);
            mr.setEnd(eNode, eOff);
          } else {
            mr.selectNodeContents(block);
          }
        }
        overlayer.add(cfg.markKey, mr, overlayer.constructor.highlight, { color: cfg.markColor });
      }
    }
  }

  const norm = function (t) {
    return String(t || '').replace(/\s+/g, ' ').trim();
  };
  let paragraph = norm(text);
  if (paragraph.length > cfg.maxParagraph) {
    const from = Math.max(0, startOff - Math.floor(cfg.maxParagraph / 2));
    paragraph = norm(text.slice(from, from + cfg.maxParagraph));
  }
  return JSON.stringify({
    ok: true,
    sentence: norm(text.slice(s, e)).slice(0, cfg.maxParagraph),
    paragraph: paragraph,
  });
} catch (e) {
  return fail('error:' + String(e && e.message ? e.message : e));
}''';

const String _clearMarkScript = r'''
try {
  const contents = reader.view.renderer.getContents();
  for (let i = 0; i < contents.length; i++) {
    const o = contents[i] && contents[i].overlayer;
    if (o) o.remove(cfg.markKey);
  }
  return JSON.stringify({ ok: true });
} catch (e) {
  return JSON.stringify({ ok: false, reason: String(e && e.message ? e.message : e) });
}''';
