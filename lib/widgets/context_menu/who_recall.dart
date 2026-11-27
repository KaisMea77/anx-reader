// FILE PATH: lib/widgets/context_menu/who_recall.dart  (the "Who's this?" tab)
//
// Reminds you who a character is (or what a place or people is) using only
// what you have read, like a notebook that is kept up to date:
//   1. the AI lists facts WITH word-for-word quotes, and the code checks that
//      every quote really is in the book text (invented facts are dropped);
//   2. a second request writes one fluent paragraph from the verified facts;
//   3. the facts and the paragraph are saved on the phone with your reading
//      position, so next time only the NEW passages are sent, and if nothing
//      new was read the saved paragraph appears at once.
// "Whole book" mode lets it use the entire book (spoilers allowed); those
// notes are kept apart and never shown in "No spoilers" mode.
// The decisions are made by the tested functions in recall_core.dart.
import 'dart:async';
import 'dart:io';

import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/dao/book_note.dart';
import 'package:anx_reader/enums/ai_prompts.dart';
import 'package:anx_reader/models/book_note.dart';
import 'package:anx_reader/page/reading_page.dart';
import 'package:anx_reader/service/ai/index.dart';
import 'package:anx_reader/service/ai/prompt_generate.dart';
import 'package:anx_reader/service/ai/reading_assist.dart';
import 'package:anx_reader/service/ai/recall_core.dart';
import 'package:anx_reader/utils/ai_reasoning_parser.dart';
import 'package:anx_reader/utils/toast/common.dart';
import 'package:anx_reader/widgets/markdown/styled_markdown.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:langchain_core/prompts.dart'
    show ChatPromptTemplate, HumanChatMessagePromptTemplate;
import 'package:path_provider/path_provider.dart';

/// Colours of the white bottom sheet (soft grey fields on white, like the
/// design), with a dark counterpart.
class AssistPalette {
  const AssistPalette({
    required this.sheet,
    required this.track,
    required this.raised,
    required this.text,
    required this.muted,
    required this.card,
    required this.accent,
  });

  final Color sheet;
  final Color track;
  final Color raised;
  final Color text;
  final Color muted;
  final Color card;
  final Color accent;

  static AssistPalette of(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    if (theme.brightness == Brightness.dark) {
      return AssistPalette(
        sheet: scheme.surfaceContainerHigh,
        track: scheme.surfaceContainerHighest,
        raised: scheme.surfaceContainer,
        text: scheme.onSurface,
        muted: scheme.onSurfaceVariant,
        card: scheme.surfaceContainerHighest,
        accent: const Color(0xFFE08A73),
      );
    }
    return const AssistPalette(
      sheet: Color(0xFFFFFFFF),
      track: Color(0xFFF1EFEA),
      raised: Color(0xFFFFFFFF),
      text: Color(0xFF1F1F1F),
      muted: Color(0xFF6E6B66),
      card: Color(0xFFF1EFEA),
      accent: Color(0xFFC4604B),
    );
  }
}

/// Saves the notebook of one book as a small JSON file in the app's private
/// storage (never synced, never sent anywhere).
class RecallStore {
  static Future<File> _file(int bookId) async {
    final dir = await getApplicationSupportDirectory();
    final folder = Directory(
      '${dir.path}${Platform.pathSeparator}anx_assist_memory',
    );
    if (!await folder.exists()) await folder.create(recursive: true);
    return File('${folder.path}${Platform.pathSeparator}$bookId.json');
  }

  static Future<RecallBook> load(int bookId) async {
    try {
      final file = await _file(bookId);
      if (!await file.exists()) return RecallBook();
      final book = RecallBook.decode(await file.readAsString());
      book.prune(nowMs: DateTime.now().millisecondsSinceEpoch);
      return book;
    } catch (e) {
      return RecallBook();
    }
  }

  static Future<void> save(int bookId, RecallBook book) async {
    try {
      book.prune(nowMs: DateTime.now().millisecondsSinceEpoch);
      final file = await _file(bookId);
      await file.writeAsString(book.encode());
    } catch (e) {
      // The notebook is a convenience: never block the answer because of it.
    }
  }
}

class WhoRecall extends ConsumerStatefulWidget {
  const WhoRecall({
    super.key,
    required this.selected,
    required this.languageName,
    required this.languageCode,
    required this.arabic,
    this.wholeBook = false,
    this.annoCfi = '',
    this.onJump,
  });

  /// The selected text (the name to be recalled).
  final String selected;

  /// Name of the answer language, as written to the AI (e.g. "العربية").
  final String languageName;

  /// Language code the saved paragraph is filed under (e.g. "ar").
  final String languageCode;

  /// Whether the card's own labels are in Arabic.
  final bool arabic;

  /// Use the whole book (spoilers allowed) instead of only what was read.
  final bool wholeBook;

  /// Place of the selection, used by "Save to notes".
  final String annoCfi;

  /// Called after jumping to the first appearance.
  final VoidCallback? onJump;

  @override
  ConsumerState<WhoRecall> createState() => WhoRecallState();
}

class WhoRecallState extends ConsumerState<WhoRecall> {
  String _status = '';
  String _answer = '';
  String? _error;
  bool _running = true;
  bool _fromMemory = false;
  int _factCount = 0;
  int _runId = 0;

  FirstSeen? _first;
  List<RecallFact> _facts = const [];
  String _detailed = '';
  bool _detailing = false;

  String _t(String ar, String en) => widget.arabic ? ar : en;

  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  /// Forgets what was saved about this name and starts again.
  void redo() => unawaited(_run(fresh: true));

  // ---------------------------------------------------------------------------
  // Talking to the AI and to the reader page
  // ---------------------------------------------------------------------------

  PromptTemplatePayload _payload(String prompt) {
    final template = ChatPromptTemplate.fromPromptMessages([
      HumanChatMessagePromptTemplate.fromTemplate('{assist_prompt}'),
    ]);
    return PromptTemplatePayload(
      template: template,
      variables: {'assist_prompt': prompt},
      identifier: AiPrompts.translate,
    );
  }

  Stream<String> _stream(String prompt) {
    return aiGenerateStream(
      _payload(prompt).buildMessages(),
      regenerate: true,
      ref: ref,
    );
  }

  /// The answer part only (the AI's "thinking" is not shown).
  String _answerText(String data) {
    final parsed = parseReasoningContent(data);
    final buffer = StringBuffer();
    for (final entry in parsed.answerTimeline) {
      final text = (entry.text ?? '').trim();
      if (entry.type == ParsedReasoningEntryType.reply && text.isNotEmpty) {
        if (buffer.isNotEmpty) buffer.write('\n\n');
        buffer.write(text);
      }
    }
    return buffer.toString();
  }

  Future<String> _askOnce(String prompt) async {
    var last = '';
    await for (final chunk in _stream(prompt)) {
      if (!mounted) break;
      last = chunk;
    }
    final answer = _answerText(last);
    return answer.isNotEmpty ? answer : last;
  }

  Future<Object?> _runScript(String script) async {
    try {
      final controller = epubPlayerKey.currentState?.webViewController;
      if (controller == null) return null;
      final result = await controller
          .callAsyncJavaScript(functionBody: script)
          .timeout(const Duration(seconds: 40));
      return result.value;
    } catch (e) {
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // The notebook (all decisions are made by the tested engine in recall_core)
  // ---------------------------------------------------------------------------

  void _fail(String message) {
    if (!mounted) return;
    setState(() {
      _error = message;
      _running = false;
      _status = '';
    });
  }

  String _statusText(RecallStatus status) {
    switch (status) {
      case RecallStatus.looking:
        return _t(
          'أبحث عن ذِكره فيما قرأتَ…',
          'Looking for it in what you have read…',
        );
      case RecallStatus.gathering:
        return _t(
          'أجمع ما ورد عنه في النص…',
          'Gathering what the text says about it…',
        );
      case RecallStatus.extracting:
        return _t(
          'أستخرج المعلومات الموثّقة من النص…',
          'Extracting verified facts from the text…',
        );
      case RecallStatus.writing:
        return _t('أكتب الخلاصة…', 'Writing the summary…');
    }
  }

  String _problemText(RecallProblem problem, String detail) {
    switch (problem) {
      case RecallProblem.noBook:
        return _t(
          'تعذّر الوصول إلى الكتاب المفتوح.',
          'Cannot reach the open book.',
        );
      case RecallProblem.noPosition:
        return _t(
          'تعذّر تحديد موضعك في الكتاب، فلم يُرسَل أي نص إلى الذكاء الاصطناعي '
              'حتى لا تنكشف لك أحداث لم تقرأها. تعمل الميزة مع الكتب النصية '
              '(مثل EPUB) وليس PDF.  [$detail]',
          'Could not determine where you are in the book, so no text was '
              'sent to the AI (to avoid spoilers). This works with text books '
              'such as EPUB, not PDF.  [$detail]',
        );
      case RecallProblem.cannotRead:
        return _t(
          'تعذّر قراءة النص من الكتاب.  [$detail]',
          'Could not read the text from the book.  [$detail]',
        );
      case RecallProblem.notMentioned:
        return widget.wholeBook
            ? _t(
                'لا يرد ذِكر هذه الكلمة في الكتاب كله.',
                'This word does not appear anywhere in the book.',
              )
            : _t(
                'لم يرد ذِكر هذه الكلمة فيما قرأتَه حتى الآن.',
                'This word has not appeared in what you have read so far.',
              );
      case RecallProblem.noReliableInfo:
        return _t(
          'لم أجد في النص الذي قرأتَه معلومات موثوقة عنه بعد. جرّب تبويب «شرح».',
          'The text you have read has no reliable information about it yet. '
              'Try the "Explain" tab.',
        );
      case RecallProblem.extractFailed:
        // Usually a message from the AI service (for example not configured).
        return detail.isNotEmpty && detail.length < 300
            ? detail
            : _t(
                'تعذّر استخراج المعلومات. جرّب مرة أخرى.',
                'Could not extract the facts. Please try again.',
              );
      case RecallProblem.emptyAnswer:
        return _t(
          'لم يصل رد من الذكاء الاصطناعي. جرّب مرة أخرى.',
          'The AI sent no answer. Please try again.',
        );
      case RecallProblem.unexpected:
        return _t(
          'حدث خطأ أثناء تجهيز الخلاصة. جرّب مرة أخرى.',
          'Something went wrong while preparing the summary. Please try again.',
        );
    }
  }

  Future<void> _run({bool fresh = false}) async {
    final run = ++_runId;
    bool alive() => mounted && run == _runId;
    final term = widget.selected.trim();

    setState(() {
      _running = true;
      _error = null;
      _answer = '';
      _fromMemory = false;
      _factCount = 0;
      _first = null;
      _facts = const [];
      _detailed = '';
      _detailing = false;
      _status = _statusText(RecallStatus.looking);
    });

    final player = epubPlayerKey.currentState;
    if (player == null) {
      _fail(_problemText(RecallProblem.noBook, ''));
      return;
    }
    final bookId = player.widget.book.id;

    final io = RecallIO(
      readBook:
          ({
            required bool scan,
            required bool whole,
            required int first,
            required int last,
            int? sinceSection,
            int? sinceOffset,
          }) async {
            return parseContextResult(
              await _runScript(
                buildContextScript(
                  query: term,
                  scan: scan,
                  recentChars: 1200,
                  first: first,
                  last: last,
                  whole: whole,
                  sinceSection: sinceSection,
                  sinceOffset: sinceOffset,
                ),
              ),
            );
          },
      ask: _askOnce,
      write: (prompt) => _stream(prompt).map(_answerText),
      load: () => RecallStore.load(bookId),
      save: (book) => RecallStore.save(bookId, book),
      locateFirst: ({required String term, required int section}) async {
        return parseFirstAppearance(
          await _runScript(
            buildFirstAppearanceScript(query: term, section: section),
          ),
        );
      },
    );

    await for (final event in recall(
      term: term,
      languageCode: widget.languageCode,
      languageName: widget.languageName,
      fresh: fresh,
      whole: widget.wholeBook,
      io: io,
      nowMs: DateTime.now().millisecondsSinceEpoch,
    )) {
      if (!alive()) return;
      final problem = event.problem;
      if (problem != null) {
        _fail(_problemText(problem, event.detail));
        return;
      }
      final status = event.status;
      if (status != null) {
        setState(() {
          _status = _statusText(status);
          if (event.facts > 0) _factCount = event.facts;
        });
        continue;
      }
      setState(() {
        _answer = event.text ?? '';
        _factCount = event.facts;
        _fromMemory = event.fromMemory;
        _status = '';
        if (event.first != null) _first = event.first;
        if (event.factList.isNotEmpty) _facts = event.factList;
        if (event.done) _running = false;
      });
    }
    if (alive() && _running && _error == null) {
      setState(() => _running = false);
    }
  }

  // ---------------------------------------------------------------------------
  // Actions under the answer
  // ---------------------------------------------------------------------------

  String get _detailedPrompt => buildDetailedPrompt(
    term: widget.selected.trim(),
    language: widget.languageName,
    facts: _facts,
    wholeBook: widget.wholeBook,
  );

  Future<void> _requestDetailed() async {
    if (_detailing || _facts.isEmpty) return;
    final run = _runId;
    setState(() {
      _detailing = true;
      _detailed = '';
    });
    var text = '';
    try {
      await for (final chunk in _stream(_detailedPrompt)) {
        if (!mounted || run != _runId) return;
        text = _answerText(chunk);
        if (text.isNotEmpty) setState(() => _detailed = text);
      }
    } catch (e) {
      // Reported below.
    }
    if (!mounted || run != _runId) return;
    setState(() => _detailing = false);
    if (text.trim().isEmpty) {
      AnxToast.show(
        _t('لم يصل رد من الذكاء الاصطناعي.', 'The AI sent no answer.'),
      );
    }
  }

  /// Saves the selection as a highlight whose note is this answer.
  Future<void> _saveToNotes() async {
    final player = epubPlayerKey.currentState;
    final cfi = widget.annoCfi;
    final body = [
      _answer.trim(),
      _detailed.trim(),
    ].where((t) => t.isNotEmpty).join('\n\n');
    if (player == null || cfi.isEmpty || body.isEmpty) {
      AnxToast.show(_t('تعذّر الحفظ في الملاحظات', 'Cannot save to notes'));
      return;
    }
    try {
      final bookId = player.widget.book.id;
      final existing = await bookNoteDao.selectBookNoteByCfiAndBookId(
        cfi,
        bookId,
      );
      final now = DateTime.now();
      final BookNote note;
      if (existing.isNotEmpty) {
        note = existing.last;
        final old = (note.readerNote ?? '').trim();
        note.readerNote = old.isEmpty ? body : '$old\n\n$body';
        note.updateTime = now;
        await bookNoteDao.updateBookNoteById(note);
      } else {
        note = BookNote(
          bookId: bookId,
          content: widget.selected.trim(),
          cfi: cfi,
          chapter: player.chapterTitle,
          type: Prefs().annotationType,
          color: Prefs().annotationColor,
          readerNote: body,
          createTime: now,
          updateTime: now,
        );
        final id = await bookNoteDao.save(note);
        note.setId(id);
      }
      player.addAnnotation(note);
      AnxToast.show(_t('تم الحفظ في الملاحظات', 'Saved to notes'));
    } catch (e) {
      AnxToast.show(_t('تعذّر الحفظ في الملاحظات', 'Cannot save to notes'));
    }
  }

  void _jumpToFirst() {
    final player = epubPlayerKey.currentState;
    final first = _first;
    if (player == null || first == null || first.cfi.isEmpty) {
      AnxToast.show(_t('تعذّر الانتقال', 'Cannot jump there'));
      return;
    }
    player.goToCfi(first.cfi);
    widget.onJump?.call();
  }

  // ---------------------------------------------------------------------------
  // Look
  // ---------------------------------------------------------------------------

  Widget _caption(AssistPalette p) {
    final color = p.muted.withValues(alpha: 0.9);
    final text = _fromMemory
        ? _t('من ذاكرة الهاتف', 'From the phone memory')
        : _factCount > 0
        ? _t(
            'مبني على $_factCount معلومة موثّقة من النص',
            'Built on $_factCount facts proven by the text',
          )
        : '';
    if (text.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Row(
        children: [
          Icon(
            _fromMemory ? Icons.history : Icons.verified_outlined,
            size: 12,
            color: color,
          ),
          const SizedBox(width: 5),
          Flexible(
            child: Text(text, style: TextStyle(fontSize: 11, color: color)),
          ),
        ],
      ),
    );
  }

  Widget _progress(AssistPalette p, String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 10),
          Flexible(
            child: Text(text, style: TextStyle(fontSize: 13, color: p.muted)),
          ),
        ],
      ),
    );
  }

  Widget _firstCard(AssistPalette p) {
    final first = _first!;
    final rtl = Directionality.of(context) == TextDirection.rtl;
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Material(
        color: p.card,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: _jumpToFirst,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(
                              text: _t('أول ظهور', 'First appearance'),
                              style: TextStyle(
                                fontWeight: FontWeight.w700,
                                color: p.text,
                              ),
                            ),
                            if (first.label.isNotEmpty)
                              TextSpan(
                                text: '  ·  ${first.label}',
                                style: TextStyle(color: p.muted),
                              ),
                          ],
                        ),
                        style: const TextStyle(fontSize: 15),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (first.heading.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 3),
                          child: Text(
                            first.heading,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 14, color: p.muted),
                          ),
                        ),
                    ],
                  ),
                ),
                Icon(
                  rtl ? Icons.chevron_left : Icons.chevron_right,
                  color: p.muted,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _pillButton(
    AssistPalette p, {
    required IconData icon,
    required String label,
    required VoidCallback? onTap,
    Widget? trailing,
  }) {
    return Material(
      color: p.card,
      borderRadius: BorderRadius.circular(22),
      child: InkWell(
        borderRadius: BorderRadius.circular(22),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 19, color: p.accent),
              const SizedBox(width: 9),
              Text(
                label,
                style: TextStyle(
                  fontSize: 14.5,
                  fontWeight: FontWeight.w500,
                  color: p.text,
                ),
              ),
              if (trailing != null) ...[const SizedBox(width: 9), trailing],
            ],
          ),
        ),
      ),
    );
  }

  Widget _actions(AssistPalette p) {
    final tokens = _facts.isEmpty ? 0 : estimateTokens(_detailedPrompt);
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [
          _pillButton(
            p,
            icon: Icons.edit_note,
            label: _t('حفظ في الملاحظات', 'Save to notes'),
            onTap: _saveToNotes,
          ),
          if (_facts.isNotEmpty && _detailed.isEmpty && !_detailing)
            _pillButton(
              p,
              icon: Icons.auto_awesome,
              label: _t('إجابة مفصّلة', 'Detailed answer'),
              onTap: _requestDetailed,
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '≈ $tokens',
                    style: TextStyle(fontSize: 13.5, color: p.muted),
                  ),
                  const SizedBox(width: 2),
                  Icon(Icons.bolt, size: 17, color: p.accent),
                ],
              ),
            ),
          _pillButton(
            p,
            icon: Icons.copy_all_outlined,
            label: _t('نسخ', 'Copy'),
            onTap: () {
              final body = [
                _answer.trim(),
                _detailed.trim(),
              ].where((t) => t.isNotEmpty).join('\n\n');
              Clipboard.setData(ClipboardData(text: body));
              AnxToast.show(_t('تم النسخ', 'Copied'));
            },
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = AssistPalette.of(context);
    final body = TextStyle(fontSize: 16, height: 1.7, color: p.text);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_error != null) ...[
          Text(
            _error!,
            style: TextStyle(fontSize: 14, height: 1.55, color: p.muted),
          ),
          TextButton(
            onPressed: redo,
            child: Text(_t('إعادة المحاولة', 'Try again')),
          ),
        ] else if (_answer.isEmpty)
          _progress(p, _status)
        else ...[
          DefaultTextStyle.merge(
            style: body,
            child: StyledMarkdown(data: _answer),
          ),
          if (_status.isNotEmpty) _progress(p, _status),
          if (!_running) ...[
            if (_first != null &&
                (_first!.label.isNotEmpty || _first!.heading.isNotEmpty))
              _firstCard(p),
            if (_detailed.isNotEmpty || _detailing) ...[
              const SizedBox(height: 14),
              Divider(height: 1, color: p.track),
              const SizedBox(height: 12),
              DefaultTextStyle.merge(
                style: body,
                child: StyledMarkdown(data: _detailed),
              ),
              if (_detailing)
                _progress(
                  p,
                  _t('أكتب الإجابة المفصّلة…', 'Writing the detailed answer…'),
                ),
            ],
            _actions(p),
            _caption(p),
          ],
        ],
      ],
    );
  }
}
