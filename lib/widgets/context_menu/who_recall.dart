// FILE PATH: lib/widgets/context_menu/who_recall.dart  (NEW file - the "Who is it?" tab)
//
// Reminds you who a character is (or what a place or people is) using only
// what you have read, like a notebook that is kept up to date:
//   1. the AI lists facts WITH word-for-word quotes, and the code checks that
//      every quote really is in the book text (invented facts are dropped);
//   2. a second request writes one fluent paragraph from the verified facts;
//   3. the facts and the paragraph are saved on the phone with your reading
//      position, so next time only the NEW passages are sent, and if nothing
//      new was read the saved paragraph appears at once.
// The decisions are made by the tested functions in recall_core.dart.
import 'dart:async';
import 'dart:io';

import 'package:anx_reader/enums/ai_prompts.dart';
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
  });

  /// The selected text (the name to be recalled).
  final String selected;

  /// Name of the answer language, as written to the AI (e.g. "العربية").
  final String languageName;

  /// Language code the saved paragraph is filed under (e.g. "ar").
  final String languageCode;

  /// Whether the card's own labels are in Arabic.
  final bool arabic;

  @override
  ConsumerState<WhoRecall> createState() => _WhoRecallState();
}

class _WhoRecallState extends ConsumerState<WhoRecall> {
  String _status = '';
  String _answer = '';
  String? _error;
  bool _running = true;
  bool _fromMemory = false;
  int _factCount = 0;
  int _runId = 0;

  String _t(String ar, String en) => widget.arabic ? ar : en;

  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

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
        return _t(
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
    );

    await for (final event in recall(
      term: term,
      languageCode: widget.languageCode,
      languageName: widget.languageName,
      fresh: fresh,
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
        if (event.done) _running = false;
      });
    }
    if (alive() && _running && _error == null) {
      setState(() => _running = false);
    }
  }

  // ---------------------------------------------------------------------------
  // Look
  // ---------------------------------------------------------------------------

  Widget _caption(ColorScheme scheme) {
    final color = scheme.onSurfaceVariant.withValues(alpha: 0.8);
    final text = _fromMemory
        ? _t(
            'من ذاكرة الهاتف · يعتمد على ما قرأتَه فقط',
            'From the phone memory · only what you have read',
          )
        : _factCount > 0
        ? _t(
            'مبني على $_factCount معلومة موثّقة من النص · بلا حرق للأحداث',
            'Built on $_factCount facts proven by the text · no spoilers',
          )
        : _t(
            'يعتمد على ما قرأتَه فقط، بلا حرق للأحداث',
            'Uses only what you have read — no spoilers',
          );
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Icon(
            _fromMemory ? Icons.history : Icons.lock_outline,
            size: 12,
            color: color,
          ),
          const SizedBox(width: 4),
          Flexible(
            child: Text(text, style: TextStyle(fontSize: 11, color: color)),
          ),
        ],
      ),
    );
  }

  Widget _progress(ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              _status,
              style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }

  Widget _actions() {
    return Wrap(
      spacing: 4,
      children: [
        TextButton(
          onPressed: () => unawaited(_run(fresh: true)),
          child: Text(_t('إعادة من الصفر', 'Redo from scratch')),
        ),
        TextButton(
          onPressed: () {
            Clipboard.setData(ClipboardData(text: _answer));
            AnxToast.show(_t('تم النسخ', 'Copied'));
          },
          child: Text(_t('نسخ', 'Copy')),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _caption(scheme),
        if (_error != null) ...[
          Text(
            _error!,
            style: TextStyle(
              fontSize: 13.5,
              height: 1.5,
              color: scheme.onSurfaceVariant,
            ),
          ),
          TextButton(
            onPressed: () => unawaited(_run(fresh: true)),
            child: Text(_t('إعادة المحاولة', 'Try again')),
          ),
        ] else if (_answer.isEmpty)
          _progress(scheme)
        else ...[
          DefaultTextStyle.merge(
            style: const TextStyle(fontSize: 15.5, height: 1.65),
            child: StyledMarkdown(data: _answer),
          ),
          if (_status.isNotEmpty) _progress(scheme),
          if (!_running) _actions(),
        ],
      ],
    );
  }
}
