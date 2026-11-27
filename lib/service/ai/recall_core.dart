// FILE PATH: lib/service/ai/recall_core.dart  (NEW file - logic only, no widgets)
//
// "Who is it?" works like a notebook that is kept up to date while you read:
//
//  1. NOTES WITH PROOF. The AI is asked for short facts about the selected
//     name, each with a word-for-word quote from the book. This code then
//     CHECKS that every quote really occurs in the text that was sent, and
//     drops any fact whose quote is not there. Invented details cannot pass.
//  2. WRITING. A second request turns only the verified facts into one fluent
//     paragraph.
//  3. MEMORY. The verified facts and the paragraph are stored on the phone,
//     per book, together with the exact reading position they cover. Next time
//     only the passages AFTER that position are sent; if nothing new was read,
//     the saved paragraph is shown at once. A saved note is never used for a
//     position EARLIER than the one it covers, so it can never spoil anything.
//
// Pure Dart (no Flutter or project imports) so it can be tested on its own.
import 'dart:convert';

import 'reading_assist.dart';

// -----------------------------------------------------------------------------
// Reading position
// -----------------------------------------------------------------------------

/// A place in the book: chapter (section) index and character offset in it.
class TextPosition {
  const TextPosition(this.section, this.offset);

  final int section;
  final int offset;

  int compareTo(TextPosition other) {
    if (section != other.section) return section.compareTo(other.section);
    return offset.compareTo(other.offset);
  }

  bool isAfter(TextPosition other) => compareTo(other) > 0;

  Map<String, Object?> toJson() => {'s': section, 'o': offset};

  static TextPosition? fromJson(Object? json) {
    if (json is! Map) return null;
    final s = json['s'];
    final o = json['o'];
    if (s is! num || o is! num) return null;
    return TextPosition(s.toInt(), o.toInt());
  }

  @override
  bool operator ==(Object other) =>
      other is TextPosition &&
      other.section == section &&
      other.offset == offset;

  @override
  int get hashCode => Object.hash(section, offset);

  @override
  String toString() => 'TextPosition($section, $offset)';
}

// -----------------------------------------------------------------------------
// Facts, snapshots, memory
// -----------------------------------------------------------------------------

class RecallFact {
  const RecallFact({
    required this.fact,
    required this.quote,
    required this.pos,
  });

  final String fact;

  /// Words copied from the book that prove the fact.
  final String quote;

  /// Where in the book the proof is.
  final TextPosition pos;

  Map<String, Object?> toJson() => {'f': fact, 'q': quote, 'p': pos.toJson()};

  static RecallFact? fromJson(Object? json) {
    if (json is! Map) return null;
    final f = json['f'];
    final q = json['q'];
    final p = TextPosition.fromJson(json['p']);
    if (f is! String || q is! String || p == null) return null;
    return RecallFact(fact: f, quote: q, pos: p);
  }
}

/// What was known about one name when the reader had reached [pos].
class RecallSnapshot {
  const RecallSnapshot({
    required this.pos,
    required this.facts,
    required this.summaries,
    required this.updatedMs,
  });

  final TextPosition pos;
  final List<RecallFact> facts;

  /// The written paragraph, by language code.
  final Map<String, String> summaries;
  final int updatedMs;

  Map<String, Object?> toJson() => {
    'p': pos.toJson(),
    'facts': facts.map((f) => f.toJson()).toList(),
    'sum': summaries,
    't': updatedMs,
  };

  static RecallSnapshot? fromJson(Object? json) {
    if (json is! Map) return null;
    final p = TextPosition.fromJson(json['p']);
    if (p == null) return null;
    final facts = <RecallFact>[];
    final rawFacts = json['facts'];
    if (rawFacts is List) {
      for (final f in rawFacts) {
        final fact = RecallFact.fromJson(f);
        if (fact != null) facts.add(fact);
      }
    }
    final summaries = <String, String>{};
    final rawSum = json['sum'];
    if (rawSum is Map) {
      rawSum.forEach((k, v) {
        if (k is String && v is String && v.trim().isNotEmpty) {
          summaries[k] = v;
        }
      });
    }
    return RecallSnapshot(
      pos: p,
      facts: facts,
      summaries: summaries,
      updatedMs: (json['t'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Where a name first appears in the book.
class FirstSeen {
  const FirstSeen({
    required this.section,
    required this.offset,
    this.label = '',
    this.heading = '',
    this.cfi = '',
  });

  final int section;
  final int offset;

  /// Chapter title, nearest sub-heading before it, and a place to jump to.
  final String label;
  final String heading;
  final String cfi;

  TextPosition get pos => TextPosition(section, offset);

  Map<String, Object?> toJson() => {
    's': section,
    'o': offset,
    'l': label,
    'h': heading,
    'c': cfi,
  };

  static FirstSeen? fromJson(Object? json) {
    if (json is! Map) return null;
    final s = json['s'];
    final o = json['o'];
    if (s is! num || o is! num) return null;
    return FirstSeen(
      section: s.toInt(),
      offset: o.toInt(),
      label: json['l'] is String ? json['l'] as String : '',
      heading: json['h'] is String ? json['h'] as String : '',
      cfi: json['c'] is String ? json['c'] as String : '',
    );
  }
}

class RecallEntity {
  RecallEntity({required this.key, required this.display});

  final String key;
  String display;
  final List<RecallSnapshot> snapshots = [];

  /// Where the name first appears (null when not known yet).
  FirstSeen? first;

  /// The newest snapshot that does not go beyond [current]. Snapshots that
  /// cover text the reader has not reached are never returned.
  RecallSnapshot? baseFor(TextPosition current) {
    RecallSnapshot? best;
    for (final s in snapshots) {
      if (s.pos.compareTo(current) <= 0 &&
          (best == null || s.pos.compareTo(best.pos) > 0)) {
        best = s;
      }
    }
    return best;
  }

  int get updatedMs {
    var latest = 0;
    for (final s in snapshots) {
      if (s.updatedMs > latest) latest = s.updatedMs;
    }
    return latest;
  }

  void putSnapshot(RecallSnapshot snapshot, {int max = 5}) {
    snapshots.removeWhere((s) => s.pos == snapshot.pos);
    snapshots.add(snapshot);
    snapshots.sort((a, b) => a.pos.compareTo(b.pos));
    while (snapshots.length > max) {
      snapshots.removeAt(0);
    }
  }
}

class RecallBook {
  RecallBook();

  final Map<String, RecallEntity> entities = {};

  RecallEntity entity(String key, String display) {
    final e = entities.putIfAbsent(
      key,
      () => RecallEntity(key: key, display: display),
    );
    e.display = display;
    return e;
  }

  /// Forgets old or surplus entries so the file stays small.
  void prune({required int nowMs, int ttlDays = 60, int maxEntities = 150}) {
    final limit = nowMs - ttlDays * 24 * 60 * 60 * 1000;
    entities.removeWhere((_, e) => e.snapshots.isEmpty || e.updatedMs < limit);
    if (entities.length > maxEntities) {
      final sorted = entities.values.toList()
        ..sort((a, b) => b.updatedMs.compareTo(a.updatedMs));
      for (final e in sorted.skip(maxEntities)) {
        entities.remove(e.key);
      }
    }
  }

  Map<String, Object?> toJson() => {
    'v': 1,
    'entities': entities.map(
      (k, e) => MapEntry(k, {
        'd': e.display,
        'first': e.first?.toJson(),
        'snaps': e.snapshots.map((s) => s.toJson()).toList(),
      }),
    ),
  };

  static RecallBook fromJson(Object? json) {
    final book = RecallBook();
    if (json is! Map || json['v'] != 1) return book;
    final raw = json['entities'];
    if (raw is! Map) return book;
    raw.forEach((k, v) {
      if (k is! String || v is! Map) return;
      final entity = RecallEntity(
        key: k,
        display: v['d'] is String ? v['d'] as String : k,
      );
      entity.first = FirstSeen.fromJson(v['first']);
      final snaps = v['snaps'];
      if (snaps is List) {
        for (final s in snaps) {
          final snap = RecallSnapshot.fromJson(s);
          if (snap != null) entity.snapshots.add(snap);
        }
        entity.snapshots.sort((a, b) => a.pos.compareTo(b.pos));
      }
      if (entity.snapshots.isNotEmpty) book.entities[k] = entity;
    });
    return book;
  }

  static RecallBook decode(String text) {
    try {
      return fromJson(jsonDecode(text));
    } catch (e) {
      return RecallBook();
    }
  }

  String encode() => jsonEncode(toJson());
}

// -----------------------------------------------------------------------------
// Text helpers
// -----------------------------------------------------------------------------

final RegExp _nonWord = RegExp(r'[^\p{L}\p{N}]+', unicode: true);
final RegExp _possessive = RegExp(r'[\u2019\u0027]s$', caseSensitive: false);

/// Lower case, letters and digits only, single spaces: for comparing a quote
/// with the book text regardless of punctuation, quotes and capitals.
String normalizeForMatch(String text) =>
    text.toLowerCase().replaceAll(_nonWord, ' ').trim();

/// Key under which a name is remembered: "Alexander’s" and "alexander" match.
String entityKey(String selected) {
  var t = selected.replaceAll(RegExp(r'\s+'), ' ').trim();
  t = t.replaceAll(_possessive, '');
  return normalizeForMatch(t);
}

String joinedSource(List<String> passages, String latest) =>
    [...passages, latest].join('\n');

// -----------------------------------------------------------------------------
// Decisions (kept here, as plain functions, so they can be tested)
// -----------------------------------------------------------------------------

enum RecallStep {
  /// Same place as last time and a written paragraph exists: show it.
  showSaved,

  /// Nothing new was read since: show the saved paragraph, move the saved
  /// position forward so the next lookup starts from here.
  advanceSaved,

  /// Nothing new, but no paragraph in this language yet: write one from the
  /// saved facts (no extraction needed).
  writeFromSaved,

  /// New passages (or no memory yet): extract facts first.
  extract,
}

RecallStep planRecall({
  required RecallSnapshot? base,
  required TextPosition now,
  required String languageCode,
  required bool hasNewPassages,
}) {
  if (base == null) return RecallStep.extract;
  final hasSummary = (base.summaries[languageCode] ?? '').trim().isNotEmpty;
  if (base.pos == now && hasSummary) return RecallStep.showSaved;
  if (!hasNewPassages) {
    return hasSummary ? RecallStep.advanceSaved : RecallStep.writeFromSaved;
  }
  return RecallStep.extract;
}

enum RecallOutcome { nothingFound, advanceSaved, write }

/// What to do once the AI's notes have been checked.
RecallOutcome planAfterExtraction({
  required RecallSnapshot? base,
  required List<RecallFact> merged,
  required int newVerified,
  required String languageCode,
}) {
  if (merged.isEmpty) return RecallOutcome.nothingFound;
  final hasSummary =
      base != null && (base.summaries[languageCode] ?? '').trim().isNotEmpty;
  if (newVerified == 0 && hasSummary) return RecallOutcome.advanceSaved;
  return RecallOutcome.write;
}

/// Paragraphs to keep in the new snapshot: the old ones stay only while the
/// facts they were written from are unchanged.
Map<String, String> carrySummaries({
  required RecallSnapshot? base,
  required bool factsChanged,
  required String languageCode,
  required String newText,
}) {
  final out = <String, String>{};
  if (base != null && !factsChanged) out.addAll(base.summaries);
  if (newText.trim().isNotEmpty) out[languageCode] = newText.trim();
  return out;
}

// -----------------------------------------------------------------------------
// Step 1: notes with proof
// -----------------------------------------------------------------------------

/// Asks for facts about [term] with a word-for-word quote for each.
/// The passages are numbered 1..n; the page the reader is on is number n+1.
String buildFactsPrompt({
  required String term,
  required List<String> passages,
  required String latest,
}) {
  final b = StringBuffer();
  b.writeln('You are a careful note-taker for a reader of a book.');
  b.writeln(
    'Below are numbered passages from the book. They are the ONLY text '
    'available. Extract facts about "$term".',
  );
  b.writeln('\nRules:');
  b.writeln(
    '- A fact must be stated or clearly implied by a passage. Never use '
    'outside knowledge, even if you recognise the book or the person.',
  );
  b.writeln(
    '- For every fact copy a SHORT quote (5 to 25 words) word for word '
    'from the passage that proves it.',
  );
  b.writeln(
    '- Useful facts: who or what it is (role, origin, titles), its '
    'relationships (family, allies, enemies, rivals) and what happens to it, '
    'in reading order.',
  );
  b.writeln(
    '- At most 12 facts, each one sentence, written in the same '
    'language as the passage.',
  );
  b.writeln(
    '- If the passages say nothing about "$term", return an empty list.',
  );
  b.writeln('\nReturn ONLY JSON, with no markdown fences and no comments:');
  b.writeln('{"facts":[{"src":1,"fact":"...","quote":"..."}]}');
  b.writeln('("src" is the number of the passage the quote comes from.)');
  b.writeln('\nPassages:');
  for (var i = 0; i < passages.length; i++) {
    b.writeln('[${i + 1}] ${passages[i]}');
  }
  final l = latest.trim();
  if (l.isNotEmpty) {
    b.writeln('[${passages.length + 1}] (the page the reader is on now) $l');
  }
  return b.toString();
}

class FactParse {
  const FactParse({
    required this.jsonOk,
    this.verified = const [],
    this.proposed = 0,
  });

  final bool jsonOk;
  final List<RecallFact> verified;
  final int proposed;

  int get rejected => proposed - verified.length;
}

String? _extractJsonObject(String raw) {
  var t = raw.trim();
  t = t.replaceAll(RegExp(r'```[a-zA-Z]*'), '').replaceAll('```', '');
  final a = t.indexOf('{');
  final b = t.lastIndexOf('}');
  if (a < 0 || b <= a) return null;
  return t.substring(a, b + 1);
}

bool _quoteIsInSource(String quote, String normalizedSource) {
  final pieces = quote
      .split(RegExp(r'\u2026|\.\.\.'))
      .map(normalizeForMatch)
      .where((p) => p.isNotEmpty)
      .toList();
  if (pieces.isEmpty) return false;
  final whole = pieces.join(' ');
  if (whole.length < 12) return false;
  for (final piece in pieces) {
    // Tiny pieces around an ellipsis are not evidence by themselves.
    if (pieces.length > 1 && piece.length < 6) continue;
    if (!normalizedSource.contains(piece)) return false;
  }
  return true;
}

/// Reads the AI's answer and keeps ONLY the facts whose quote really appears
/// in [sourceText] (everything that was sent to the AI).
/// [passagePositions] are the positions of passages 1..n; [fallback] is used
/// for the page the reader is on.
FactParse parseFactsResponse(
  String raw, {
  required String sourceText,
  required List<TextPosition> passagePositions,
  required TextPosition fallback,
}) {
  final json = _extractJsonObject(raw);
  if (json == null) return const FactParse(jsonOk: false);
  Object? decoded;
  try {
    decoded = jsonDecode(json);
  } catch (e) {
    return const FactParse(jsonOk: false);
  }
  if (decoded is! Map || decoded['facts'] is! List) {
    return const FactParse(jsonOk: false);
  }
  final normalizedSource = normalizeForMatch(sourceText);
  final verified = <RecallFact>[];
  final seen = <String>{};
  var proposed = 0;
  for (final item in decoded['facts'] as List) {
    if (item is! Map) continue;
    final fact = item['fact'];
    final quote = item['quote'];
    if (fact is! String || quote is! String) continue;
    proposed++;
    final cleanFact = fact.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (cleanFact.isEmpty || cleanFact.length > 400) continue;
    if (!_quoteIsInSource(quote, normalizedSource)) continue;
    if (!seen.add(normalizeForMatch(quote))) continue;
    final src = item['src'];
    var pos = fallback;
    if (src is num) {
      final i = src.toInt() - 1;
      if (i >= 0 && i < passagePositions.length) pos = passagePositions[i];
    }
    verified.add(
      RecallFact(
        fact: cleanFact,
        quote: quote.replaceAll(RegExp(r'\s+'), ' ').trim(),
        pos: pos,
      ),
    );
  }
  return FactParse(jsonOk: true, verified: verified, proposed: proposed);
}

/// Adds [added] to [base]: no duplicates, reading order, at most [max] facts
/// (the earliest ones are kept because they say who the person is).
List<RecallFact> mergeFacts(
  List<RecallFact> base,
  List<RecallFact> added, {
  int max = 40,
  int keepEarliest = 12,
}) {
  final out = <RecallFact>[...base];
  final seen = base.map((f) => normalizeForMatch(f.quote)).toSet();
  for (final f in added) {
    if (seen.add(normalizeForMatch(f.quote))) out.add(f);
  }
  out.sort((a, b) => a.pos.compareTo(b.pos));
  if (out.length <= max) return out;
  return [
    ...out.take(keepEarliest),
    ...out.skip(out.length - (max - keepEarliest)),
  ];
}

// -----------------------------------------------------------------------------
// Step 2: writing
// -----------------------------------------------------------------------------

/// Turns verified facts into one fluent paragraph in [language].
/// With [wholeBook] the facts may reach past the reader's page, and the
/// paragraph covers the whole story of the name.
String buildComposePrompt({
  required String term,
  required String language,
  required List<RecallFact> facts,
  bool wholeBook = false,
}) {
  final b = StringBuffer();
  b.writeln(
    'Write a short reminder about "$term" for a reader who has '
    'forgotten who or what it is.',
  );
  if (wholeBook) {
    b.writeln(
      'Use ONLY the numbered facts below. They come from the WHOLE book '
      '(including events the reader may not have reached yet) and are in '
      'reading order. Spoilers are allowed. Do not add anything else, do '
      'not use outside knowledge, and do not mention these instructions.',
    );
  } else {
    b.writeln(
      'Use ONLY the numbered facts below. They come from the book up to '
      "the reader's current page and are in reading order. Do not add "
      'anything else, do not use outside knowledge, and do not mention these '
      'instructions.',
    );
  }
  b.writeln('\nStyle:');
  b.writeln(
    '- Write in $language: natural, fluent and well-formed, the way a '
    'well-read friend would remind you. Never translate word by word.',
  );
  b.writeln(
    '- ONE paragraph of 3 to 5 sentences. No headings, no bullet '
    'points, no labels, no bold text.',
  );
  if (wholeBook) {
    b.writeln(
      '- Begin with who or what "$term" is, then the key events in '
      'order, and finish with how the story leaves it.',
    );
  } else {
    b.writeln(
      '- Begin with who or what "$term" is, then the key events in '
      "order, and finish with the latest situation at the reader's current "
      'position.',
    );
  }
  b.writeln(
    '- Write names in $language spelling and give the original '
    'spelling in parentheses only the first time each name appears.',
  );
  b.writeln('- If a detail is not in the facts, leave it out. Do not guess.');
  b.writeln('\nFacts:');
  for (var i = 0; i < facts.length; i++) {
    b.writeln('${i + 1}. ${facts[i].fact}');
  }
  return b.toString();
}

/// A fuller profile from the same verified facts (2-3 short paragraphs).
String buildDetailedPrompt({
  required String term,
  required String language,
  required List<RecallFact> facts,
  bool wholeBook = false,
}) {
  final b = StringBuffer();
  b.writeln('Write a detailed profile of "$term" for a reader.');
  b.writeln(
    wholeBook
        ? 'Use ONLY the numbered facts below. They come from the WHOLE book and '
              'are in reading order. Spoilers are allowed. Do not add anything '
              'else and do not use outside knowledge.'
        : 'Use ONLY the numbered facts below. They come from the book up to the '
              "reader's current page and are in reading order. Do not add anything "
              'else and do not use outside knowledge.',
  );
  b.writeln('\nStyle:');
  b.writeln(
    '- Write in $language: natural, fluent, well-formed. Never '
    'translate word by word.',
  );
  b.writeln(
    '- 2 to 3 short paragraphs, about 120 to 180 words in total. No '
    'headings, no bullet points, no bold text.',
  );
  b.writeln(
    '- First paragraph: who or what "$term" is. Second: relationships '
    'and the key events in order. Third: ${wholeBook ? 'how the story leaves it' : "the latest situation at the reader's current position"}.',
  );
  b.writeln(
    '- Write names in $language spelling and give the original '
    'spelling in parentheses only the first time each name appears.',
  );
  b.writeln('- If a detail is not in the facts, leave it out. Do not guess.');
  b.writeln('\nFacts:');
  for (var i = 0; i < facts.length; i++) {
    b.writeln('${i + 1}. ${facts[i].fact}');
  }
  return b.toString();
}

// -----------------------------------------------------------------------------
// The engine: one complete lookup, with the book and the AI passed in as
// functions so the whole flow can be tested without a phone.
// -----------------------------------------------------------------------------

/// Section number used for notes written in "Whole book" mode. It lies after
/// everything in the book, so such notes are never used when reading without
/// spoilers, while whole-book lookups can still build on any earlier note.
const int wholeBookSection = 1 << 30;

/// What the card should say while waiting.
enum RecallStatus { looking, gathering, extracting, writing }

/// Why no paragraph could be shown.
enum RecallProblem {
  noBook,
  noPosition,
  cannotRead,
  notMentioned,
  noReliableInfo,
  extractFailed,
  emptyAnswer,
  unexpected,
}

class RecallEvent {
  const RecallEvent.status(RecallStatus this.status, {this.facts = 0})
    : problem = null,
      text = null,
      fromMemory = false,
      done = false,
      detail = '',
      first = null,
      factList = const [];

  const RecallEvent.text(
    String this.text, {
    this.facts = 0,
    this.fromMemory = false,
    this.done = false,
    this.first,
    this.factList = const [],
  }) : status = null,
       problem = null,
       detail = '';

  const RecallEvent.problem(RecallProblem this.problem, {this.detail = ''})
    : status = null,
      text = null,
      facts = 0,
      fromMemory = false,
      done = false,
      first = null,
      factList = const [];

  final RecallStatus? status;
  final RecallProblem? problem;

  /// The paragraph so far (the whole text each time, not just the new part).
  final String? text;
  final int facts;
  final bool fromMemory;

  /// True on the last event of a successful lookup.
  final bool done;
  final String detail;

  /// Where the name first appears, only when the reader may be told.
  final FirstSeen? first;

  /// The verified facts behind the paragraph (on the last event).
  final List<RecallFact> factList;
}

/// The outside world the engine needs.
class RecallIO {
  const RecallIO({
    required this.readBook,
    required this.ask,
    required this.write,
    required this.load,
    required this.save,
    this.locateFirst,
  });

  /// Reads the book text up to the end of the page on screen (or, with
  /// [whole], the whole book).
  final Future<ReadingAssistContext> Function({
    required bool scan,
    required bool whole,
    required int first,
    required int last,
    int? sinceSection,
    int? sinceOffset,
  })
  readBook;

  /// Sends a prompt and returns the whole answer.
  final Future<String> Function(String prompt) ask;

  /// Sends a prompt and yields the answer so far, again and again, as it grows.
  final Stream<String> Function(String prompt) write;

  final Future<RecallBook> Function() load;
  final Future<void> Function(RecallBook book) save;

  /// Finds the chapter title, nearest sub-heading and jump place of the first
  /// mention (optional).
  final Future<FirstAppearance> Function({
    required String term,
    required int section,
  })?
  locateFirst;
}

/// One lookup of [term]: finds what is already known, reads only what is new,
/// asks the AI for proven facts, writes the paragraph and remembers it.
/// With [whole] the whole book may be used (spoilers allowed); those notes are
/// filed after the end of the book so they never reach a no-spoiler lookup.
Stream<RecallEvent> recall({
  required String term,
  required String languageCode,
  required String languageName,
  required bool fresh,
  required RecallIO io,
  required int nowMs,
  bool whole = false,
}) async* {
  try {
    final key = entityKey(term);
    if (key.isEmpty) {
      yield const RecallEvent.problem(RecallProblem.noBook);
      return;
    }
    final store = await io.load();
    if (fresh) store.entities.remove(key);
    final entity = store.entities[key];

    yield const RecallEvent.status(RecallStatus.looking);
    final probe = await io.readBook(
      scan: false,
      whole: false,
      first: 3,
      last: 5,
    );
    if (!probe.ok) {
      yield RecallEvent.problem(RecallProblem.noPosition, detail: probe.reason);
      return;
    }
    final reader = TextPosition(probe.positionSection, probe.positionOffset);
    final now = whole ? const TextPosition(wholeBookSection, 0) : reader;
    final base = entity?.baseFor(now);

    var first = entity?.first;
    // Never tell the reader about a place they have not reached yet.
    FirstSeen? shownFirst() {
      final f = first;
      if (f == null) return null;
      return (whole || f.pos.compareTo(reader) <= 0) ? f : null;
    }

    Future<void> remember(
      List<RecallFact> facts,
      Map<String, String> summaries,
    ) async {
      final e = store.entity(key, term);
      if (first != null) e.first = first;
      e.putSnapshot(
        RecallSnapshot(
          pos: now,
          facts: facts,
          summaries: summaries,
          updatedMs: nowMs,
        ),
      );
      await io.save(store);
    }

    var step = RecallStep.extract;
    ReadingAssistContext? scanned;
    if (base != null && base.pos == now) {
      // Same place as last time: no need to look at the book at all.
      step = planRecall(
        base: base,
        now: now,
        languageCode: languageCode,
        hasNewPassages: false,
      );
    } else {
      yield const RecallEvent.status(RecallStatus.gathering);
      scanned = await io.readBook(
        scan: true,
        whole: whole,
        first: base == null ? 4 : 2,
        last: 8,
        sinceSection: base?.pos.section,
        sinceOffset: base?.pos.offset,
      );
      if (!scanned.ok) {
        yield RecallEvent.problem(
          RecallProblem.cannotRead,
          detail: scanned.reason,
        );
        return;
      }
      step = planRecall(
        base: base,
        now: now,
        languageCode: languageCode,
        hasNewPassages: scanned.snippets.isNotEmpty,
      );
    }

    if (step == RecallStep.showSaved) {
      yield RecallEvent.text(
        base!.summaries[languageCode]!,
        facts: base.facts.length,
        fromMemory: true,
        done: true,
        first: shownFirst(),
        factList: base.facts,
      );
      return;
    }
    if (step == RecallStep.advanceSaved) {
      yield RecallEvent.text(
        base!.summaries[languageCode]!,
        facts: base.facts.length,
        fromMemory: true,
        done: true,
        first: shownFirst(),
        factList: base.facts,
      );
      await remember(base.facts, base.summaries);
      return;
    }

    var facts = base?.facts ?? const <RecallFact>[];
    if (step == RecallStep.extract) {
      final ctx = scanned!;
      // The scan covers everything the mode allows, so no passage at all
      // means the name has not appeared: nothing to ask.
      if (ctx.snippets.isEmpty) {
        yield const RecallEvent.problem(RecallProblem.notMentioned);
        return;
      }
      // A search from the very start finds the first mention: remember where.
      if (base == null && first == null) {
        final earliest = ctx.snippets.first;
        var seen = FirstSeen(section: earliest.part, offset: earliest.pos);
        final locate = io.locateFirst;
        if (locate != null) {
          try {
            final info = await locate(term: term, section: earliest.part);
            if (info.ok) {
              seen = FirstSeen(
                section: earliest.part,
                offset: earliest.pos,
                label: info.label,
                heading: info.heading,
                cfi: info.cfi,
              );
            }
          } catch (e) {
            // The card is optional: keep going without it.
          }
        }
        first = seen;
      }
      yield const RecallEvent.status(RecallStatus.extracting);
      final passages = [for (final s in ctx.snippets) s.text];
      final positions = [
        for (final s in ctx.snippets) TextPosition(s.part, s.pos),
      ];
      final raw = await io.ask(
        buildFactsPrompt(term: term, passages: passages, latest: ctx.recent),
      );
      final parsed = parseFactsResponse(
        raw,
        sourceText: joinedSource(passages, ctx.recent),
        passagePositions: positions,
        fallback: reader,
      );
      if (!parsed.jsonOk) {
        yield RecallEvent.problem(
          RecallProblem.extractFailed,
          detail: raw.trim(),
        );
        return;
      }
      final merged = mergeFacts(facts, parsed.verified);
      final outcome = planAfterExtraction(
        base: base,
        merged: merged,
        newVerified: merged.length - facts.length,
        languageCode: languageCode,
      );
      if (outcome == RecallOutcome.nothingFound) {
        yield const RecallEvent.problem(RecallProblem.noReliableInfo);
        return;
      }
      if (outcome == RecallOutcome.advanceSaved) {
        yield RecallEvent.text(
          base!.summaries[languageCode]!,
          facts: base.facts.length,
          fromMemory: true,
          done: true,
          first: shownFirst(),
          factList: base.facts,
        );
        await remember(base.facts, base.summaries);
        return;
      }
      facts = merged;
    }

    yield RecallEvent.status(RecallStatus.writing, facts: facts.length);
    var text = '';
    await for (final chunk in io.write(
      buildComposePrompt(
        term: term,
        language: languageName,
        facts: facts,
        wholeBook: whole,
      ),
    )) {
      text = chunk;
      if (text.trim().isNotEmpty) {
        yield RecallEvent.text(text, facts: facts.length);
      }
    }
    if (text.trim().isEmpty) {
      yield const RecallEvent.problem(RecallProblem.emptyAnswer);
      return;
    }
    final factsChanged = base == null || facts.length != base.facts.length;
    await remember(
      facts,
      carrySummaries(
        base: base,
        factsChanged: factsChanged,
        languageCode: languageCode,
        newText: text,
      ),
    );
    yield RecallEvent.text(
      text,
      facts: facts.length,
      done: true,
      first: shownFirst(),
      factList: facts,
    );
  } catch (e) {
    yield RecallEvent.problem(RecallProblem.unexpected, detail: '$e');
  }
}
