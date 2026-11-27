// FILE PATH: lib/widgets/context_menu/reading_assist_menu.dart  (menu/UI file)
import 'dart:async';

import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/enums/ai_prompts.dart';
import 'package:anx_reader/enums/lang_list.dart';
import 'package:anx_reader/page/reading_page.dart';
import 'package:anx_reader/service/ai/prompt_generate.dart';
import 'package:anx_reader/service/ai/reading_assist.dart';
import 'package:anx_reader/service/translate/index.dart';
import 'package:anx_reader/widgets/ai/ai_stream.dart';
import 'package:anx_reader/widgets/context_menu/translation_menu.dart';
import 'package:anx_reader/widgets/context_menu/who_recall.dart';
import 'package:flutter/material.dart';
import 'package:langchain_core/prompts.dart'
    show ChatPromptTemplate, HumanChatMessagePromptTemplate;
import 'package:pointer_interceptor/pointer_interceptor.dart';

/// The selection assistant. This widget takes no space in the menu: it opens
/// a white bottom sheet (in its own overlay layer, above the page) and removes
/// it when the menu closes. The sheet has three tabs:
///  * Translation: a word or short phrase gets a dictionary-style answer; a
///    sentence or paragraph is translated in full and coloured in the book
///    while the sheet is open.
///  * Who's this?: a notebook-style reminder of a character or place, built
///    only from what you have read ("No spoilers") or the whole book.
///  * Explain: explains a hard passage, knowing the book only up to your page.
///
/// The sheet opens on the most useful tab by itself: a name opens "Who's
/// this?", anything else opens "Translation". The AI tabs are loaded lazily so
/// nothing is sent to an AI provider unless the tab is shown.
class ReadingAssistMenu extends StatefulWidget {
  const ReadingAssistMenu({
    super.key,
    required this.content,
    required this.decoration,
    required this.axis,
    this.contextText,
    this.annoCfi = '',
    this.selectionRect,
    this.onClose,
  });

  final String content;
  final BoxDecoration decoration;
  final Axis axis;
  final String? contextText;

  /// Place of the selection (used by "Save to notes").
  final String annoCfi;

  /// The selection's rectangle inside the reader, to keep it uncovered.
  final Rect? selectionRect;

  /// Closes the whole selection menu.
  final VoidCallback? onClose;

  @override
  State<ReadingAssistMenu> createState() => _ReadingAssistMenuState();
}

class _ReadingAssistMenuState extends State<ReadingAssistMenu> {
  OverlayEntry? _entry;

  @override
  void initState() {
    super.initState();
    if (widget.axis == Axis.horizontal) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _open());
    }
  }

  void _open() {
    if (!mounted || _entry != null) return;
    final overlay = Overlay.maybeOf(context);
    if (overlay == null) return;
    _entry = OverlayEntry(
      builder: (_) => AssistSheet(
        content: widget.content,
        contextText: widget.contextText,
        annoCfi: widget.annoCfi,
        selectionRect: widget.selectionRect,
        onDismiss: _close,
        onJump: widget.onClose,
      ),
    );
    overlay.insert(_entry!);
  }

  void _close() {
    final entry = _entry;
    _entry = null;
    entry?.remove();
  }

  @override
  void dispose() {
    _close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Vertical writing modes: keep the original translation card.
    if (widget.axis == Axis.vertical) {
      return TranslationMenu(
        content: widget.content,
        decoration: widget.decoration,
        axis: widget.axis,
        contextText: widget.contextText,
      );
    }
    return const SizedBox.shrink();
  }
}

/// The bottom sheet itself.
class AssistSheet extends StatefulWidget {
  const AssistSheet({
    super.key,
    required this.content,
    required this.onDismiss,
    this.contextText,
    this.annoCfi = '',
    this.selectionRect,
    this.onJump,
  });

  final String content;
  final String? contextText;
  final String annoCfi;
  final Rect? selectionRect;
  final VoidCallback onDismiss;
  final VoidCallback? onJump;

  @override
  State<AssistSheet> createState() => _AssistSheetState();
}

class _AssistSheetState extends State<AssistSheet> {
  late int _tab;
  final Set<int> _opened = <int>{};

  /// Changes with the language: re-creates the AI tabs.
  int _version = 0;

  /// Changes every time the translation is rebuilt.
  int _translationVersion = 0;

  /// Becomes true as soon as the reader touches the card, so the automatic
  /// tab choice never overrides a manual one.
  bool _userInteracted = false;

  /// What the translation covers: 0 = selection, 1 = sentence, 2 = paragraph.
  int _scope = 0;
  ReadingAssistBlocks? _blocks;

  /// True while a sentence/paragraph colour is drawn in the book.
  bool _markActive = false;

  Widget? _translationWidget;
  Timer? _debounceTimer;
  bool _translationInitialized = false;

  Future<ReadingAssistContext>? _explainContext;

  /// "Whole book" lets the Who tab use the entire book (spoilers allowed).
  bool _wholeBook = false;
  GlobalKey<WhoRecallState> _whoKey = GlobalKey<WhoRecallState>();

  // Sheet size: changed by dragging the handle.
  double? _height;
  double _minHeight = 260;
  double _maxHeight = 600;
  double _defaultHeight = 380;
  double _overshoot = 0;

  @override
  void initState() {
    super.initState();
    // First use: make Arabic the default target for translation and answers
    // (otherwise the app follows its interface language). Later choices made
    // with the language picker are kept.
    if (Prefs().prefs.getString('translateTo') == null) {
      unawaited(
        Prefs().prefs.setString('translateTo', LangListEnum.arabic.code),
      );
    }

    final guess = guessInitialTab(
      selected: widget.content,
      contextText: _effectiveContext,
      answerIsArabic: Prefs().translateTo == LangListEnum.arabic,
    );
    _tab = guess.tab;
    _opened.add(_tab);
    if (_tab == 0) {
      _startTranslation();
    } else {
      _prepareAiTab(_tab);
    }
    if (guess.needsNameCheck) {
      unawaited(_runNameCheck());
    }
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    if (_markActive) {
      // The colour in the book only lives as long as the card.
      unawaited(_runScript(buildClearMarkScript()));
    }
    super.dispose();
  }

  String? get _effectiveContext =>
      (widget.contextText?.trim().isEmpty ?? true) ? null : widget.contextText;

  bool get _arabic =>
      !kAssistEnglishLabels &&
      (Localizations.localeOf(context).languageCode == 'ar' ||
          Prefs().translateTo == LangListEnum.arabic);

  String _t(String ar, String en) => _arabic ? ar : en;

  TextDirection get _answerDirection =>
      Prefs().translateTo == LangListEnum.arabic
      ? TextDirection.rtl
      : TextDirection.ltr;

  String _targetLanguageCode() {
    final target = Prefs().translateTo;
    if (target == LangListEnum.auto) return _arabic ? 'ar' : 'en';
    return target.code;
  }

  String _targetLanguageName() {
    final target = Prefs().translateTo;
    if (target == LangListEnum.auto) return _arabic ? 'العربية' : 'English';
    return target.nativeName;
  }

  // ---------------------------------------------------------------------------
  // Talking to the reader page
  // ---------------------------------------------------------------------------

  Future<Object?> _runScript(
    String script, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    try {
      final controller = epubPlayerKey.currentState?.webViewController;
      if (controller == null) return null;
      final result = await controller
          .callAsyncJavaScript(functionBody: script)
          .timeout(timeout);
      return result.value;
    } catch (e) {
      return null;
    }
  }

  /// Is the selection a name? Looks at the text read so far in this chapter.
  Future<void> _runNameCheck() async {
    final raw = await _runScript(
      buildContextScript(
        query: widget.content.trim(),
        scan: false,
        nameCheck: true,
        recentChars: 100,
      ),
      timeout: const Duration(seconds: 8),
    );
    final check = parseNameCheckResult(raw);
    if (!mounted || _userInteracted || !check.looksLikeName) return;
    _debounceTimer?.cancel();
    _select(2, manual: false);
  }

  /// Reads the book text from the reader WebView, strictly up to the end of
  /// the page on screen. On any problem it fails instead of guessing.
  Future<ReadingAssistContext> _loadContext({required bool scan}) async {
    final raw = await _runScript(
      buildContextScript(
        query: widget.content.trim(),
        scan: scan,
        recentChars: scan ? 1200 : 2500,
      ),
    );
    if (raw == null) return const ReadingAssistContext.failed('error');
    return parseContextResult(raw);
  }

  /// Reads the sentence/paragraph around the selection and colours it
  /// (mark: 0 = no colour, 1 = sentence, 2 = paragraph).
  Future<ReadingAssistBlocks> _loadBlocks({required int mark}) async {
    final raw = await _runScript(
      buildBlocksScript(mark: mark),
      timeout: const Duration(seconds: 10),
    );
    return parseBlocksResult(raw);
  }

  // ---------------------------------------------------------------------------
  // Translation tab
  // ---------------------------------------------------------------------------

  static bool _isShortLookup(String text) {
    final t = text.trim();
    final words = t.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;
    return words >= 1 && words <= 3 && t.length <= 40;
  }

  /// A word or short phrase is answered like a dictionary entry.
  bool get _dictionaryMode => _scope == 0 && _isShortLookup(widget.content);

  /// The text the translation currently covers.
  String _sourceText() {
    if (_scope == 0) return widget.content;
    final blocks = _blocks;
    if (blocks != null && blocks.ok) {
      final text = _scope == 1 ? blocks.sentence : blocks.paragraph;
      if (text.isNotEmpty) return text;
    }
    return sentenceFromContext(_effectiveContext, widget.content);
  }

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

  /// Creates the translation widget. Only changes fields: call it inside
  /// setState, in initState or from [_select].
  void _createTranslation() {
    _translationInitialized = true;
    _translationVersion++;
    if (_dictionaryMode) {
      _translationWidget = DefaultTextStyle.merge(
        style: const TextStyle(
          fontSize: 26,
          fontWeight: FontWeight.w700,
          height: 1.3,
        ),
        child: AiStream(
          prompt: _payload(
            buildDictionaryPrompt(
              language: _targetLanguageName(),
              word: widget.content,
              sentence: sentenceFromContext(_effectiveContext, widget.content),
            ),
          ),
          regenerate: true,
        ),
      );
    } else {
      _translationWidget = translateText(
        _sourceText(),
        service: TranslateService.ai,
        contextText: _scope == 0 ? _effectiveContext : null,
      );
    }
  }

  void _startTranslation() {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 300), () {
      if (!mounted || _translationInitialized || _tab != 0) return;
      setState(_createTranslation);
    });
  }

  Future<void> _setScope(int scope) async {
    _userInteracted = true;
    if (scope == _scope) return;
    _debounceTimer?.cancel();
    setState(() {
      _scope = scope;
      _translationWidget = null;
      _translationInitialized = true;
    });
    // Colours the sentence/paragraph in the book (or removes the colour) and
    // returns its text.
    final blocks = await _loadBlocks(mark: scope);
    if (!mounted || _scope != scope) return;
    _blocks = blocks;
    _markActive = scope != 0 && blocks.ok;
    setState(_createTranslation);
  }

  void _onLanguageChanged() {
    _debounceTimer?.cancel();
    _userInteracted = true;
    setState(() {
      _version++;
      _whoKey = GlobalKey<WhoRecallState>();
      _tab = 0;
      _opened
        ..clear()
        ..add(0);
      _explainContext = null;
      _createTranslation();
    });
  }

  Widget _langPicker(bool isFrom) {
    final MenuController menuController = MenuController();

    return PointerInterceptor(
      child: MenuAnchor(
        style: MenuStyle(
          backgroundColor: WidgetStateProperty.all(
            Theme.of(context).colorScheme.secondaryContainer,
          ),
          maximumSize: WidgetStateProperty.all(const Size(300, 300)),
        ),
        controller: menuController,
        menuChildren: [
          for (var lang in LangListEnum.values)
            PointerInterceptor(
              child: MenuItemButton(
                onPressed: () {
                  if (isFrom) {
                    Prefs().translateFrom = lang;
                  } else {
                    Prefs().translateTo = lang;
                  }
                  _onLanguageChanged();
                },
                child: Text(lang.getNative(context)),
              ),
            ),
        ],
        builder: (context, controller, child) {
          return GestureDetector(
            onTap: () {
              if (controller.isOpen) {
                controller.close();
              } else {
                controller.open();
              }
            },
            child: Text(
              isFrom
                  ? Prefs().translateFrom.getNative(context)
                  : Prefs().translateTo.getNative(context),
            ),
          );
        },
      ),
    );
  }

  Widget _languageRow(AssistPalette p) {
    return DefaultTextStyle.merge(
      style: TextStyle(fontSize: 13, color: p.muted),
      child: Row(
        children: [
          Icon(Icons.translate, size: 15, color: p.muted),
          const SizedBox(width: 8),
          _langPicker(true),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Icon(
              _answerDirection == TextDirection.rtl
                  ? Icons.arrow_back_ios
                  : Icons.arrow_forward_ios,
              size: 12,
              color: p.muted,
            ),
          ),
          _langPicker(false),
        ],
      ),
    );
  }

  Widget _scopeChip(AssistPalette p, int index, String label) {
    final selected = _scope == index;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _setScope(index),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? p.track : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected ? Colors.transparent : p.track,
            width: 1.5,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            color: selected ? p.text : p.muted,
          ),
        ),
      ),
    );
  }

  Widget _scopeChips(AssistPalette p) {
    return Wrap(
      spacing: 8,
      runSpacing: 6,
      children: [
        _scopeChip(p, 0, _t('المحدد', 'Selection')),
        _scopeChip(p, 1, _t('الجملة', 'Sentence')),
        _scopeChip(p, 2, _t('الفقرة', 'Paragraph')),
      ],
    );
  }

  Widget _translateBody(AssistPalette p) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _scopeChips(p),
        const SizedBox(height: 14),
        DefaultTextStyle.merge(
          style: TextStyle(fontSize: 16, height: 1.65, color: p.text),
          child: KeyedSubtree(
            key: ValueKey('translation-$_translationVersion'),
            child:
                _translationWidget ??
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 6),
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Explain
  // ---------------------------------------------------------------------------

  void _prepareAiTab(int index) {
    // "Who's this?" (tab 2) gathers its own text and keeps its own notebook.
    if (index == 1) {
      _explainContext ??= _loadContext(scan: false);
    }
  }

  Widget _hint(AssistPalette p, String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Text(
        text,
        style: TextStyle(fontSize: 14, height: 1.5, color: p.muted),
      ),
    );
  }

  String _failureMessage(String reason) {
    return _t(
      'تعذّر تحديد موضعك في الكتاب، فلم يُرسَل أي نص إلى الذكاء الاصطناعي '
          'حتى لا تنكشف لك أحداث لم تقرأها. هذه الميزة تعمل مع الكتب النصية '
          '(مثل EPUB)، وليس مع PDF.  [$reason]',
      'Could not determine where you are in the book, so no text was sent to '
          'the AI (to avoid spoilers). This works with text books such as '
          'EPUB, not PDF.  [$reason]',
    );
  }

  Widget _aiBody(AssistPalette p) {
    return FutureBuilder<ReadingAssistContext>(
      future: _explainContext,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return _hint(
            p,
            _t(
              'أقرأ ما وصلتَ إليه من الكتاب…',
              'Reading what you have read so far…',
            ),
          );
        }
        final ctx = snapshot.data;
        if (ctx == null || !ctx.ok) {
          return _hint(p, _failureMessage(ctx?.reason ?? 'unknown'));
        }
        final prompt = buildExplainPrompt(
          language: _targetLanguageName(),
          selected: widget.content,
          contextSentence: _effectiveContext,
          recent: ctx.recent,
        );
        return DefaultTextStyle.merge(
          style: TextStyle(fontSize: 16, height: 1.7, color: p.text),
          child: AiStream(
            key: ValueKey('explain-$_version'),
            prompt: _payload(prompt),
            regenerate: true,
          ),
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Tabs and the sheet itself
  // ---------------------------------------------------------------------------

  void _select(int index, {bool manual = true}) {
    if (manual) _userInteracted = true;
    if (index == _tab) return;
    _tab = index;
    _opened.add(index);
    if (index == 0) {
      if (!_translationInitialized) {
        _debounceTimer?.cancel();
        _createTranslation();
      }
    } else {
      _prepareAiTab(index);
    }
    setState(() {});
  }

  Widget _handle(AssistPalette p) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onVerticalDragUpdate: (d) {
        final next = (_height ?? _defaultHeight) - d.delta.dy;
        if (next < _minHeight && d.delta.dy > 0) {
          _overshoot += d.delta.dy;
        } else {
          _overshoot = 0;
        }
        setState(() => _height = next.clamp(_minHeight, _maxHeight).toDouble());
      },
      onVerticalDragEnd: (_) {
        // Pulled down past the smallest size: close the sheet.
        if (_overshoot > 70) widget.onDismiss();
        _overshoot = 0;
      },
      child: SizedBox(
        height: 26,
        width: double.infinity,
        child: Center(
          child: Container(
            width: 44,
            height: 5,
            decoration: BoxDecoration(
              color: p.muted.withValues(alpha: 0.35),
              borderRadius: BorderRadius.circular(3),
            ),
          ),
        ),
      ),
    );
  }

  Widget _tabPill(AssistPalette p, int index, String label) {
    final selected = _tab == index;
    return Expanded(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _select(index),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          padding: const EdgeInsets.symmetric(vertical: 11),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? p.raised : Colors.transparent,
            borderRadius: BorderRadius.circular(15),
            boxShadow: selected
                ? [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.10),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ]
                : null,
          ),
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 15.5,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              color: selected ? p.text : p.muted,
            ),
          ),
        ),
      ),
    );
  }

  /// Order as in the design: Translation, Who's this?, Explain.
  Widget _tabBar(AssistPalette p) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: p.track,
        borderRadius: BorderRadius.circular(19),
      ),
      child: Row(
        children: [
          _tabPill(p, 0, _t('ترجمة', 'Translation')),
          _tabPill(p, 2, _t('من هذا؟', "Who's this?")),
          _tabPill(p, 1, _t('شرح', 'Explain')),
        ],
      ),
    );
  }

  Widget _modePill(AssistPalette p, bool whole, String label) {
    final selected = _wholeBook == whole;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        if (selected) return;
        setState(() {
          _wholeBook = whole;
          // A new lookup in the other mode.
          _whoKey = GlobalKey<WhoRecallState>();
        });
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? p.raised : Colors.transparent,
          borderRadius: BorderRadius.circular(14),
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.09),
                    blurRadius: 6,
                    offset: const Offset(0, 2),
                  ),
                ]
              : null,
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 14,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            color: selected ? p.text : p.muted,
          ),
        ),
      ),
    );
  }

  /// "No spoilers | Whole book" and the flag (redo from scratch).
  Widget _contextBar(AssistPalette p) {
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            color: p.track,
            borderRadius: BorderRadius.circular(17),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _modePill(p, false, _t('بلا حرق', 'No spoilers')),
              _modePill(p, true, _t('الكتاب كله', 'Whole book')),
            ],
          ),
        ),
        const Spacer(),
        IconButton(
          tooltip: _t('إعادة الإجابة من الصفر', 'Redo from scratch'),
          visualDensity: VisualDensity.compact,
          icon: Icon(Icons.outlined_flag, color: p.muted),
          onPressed: () => _whoKey.currentState?.redo(),
        ),
      ],
    );
  }

  Widget _whoBody(AssistPalette p) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _contextBar(p),
        const SizedBox(height: 10),
        WhoRecall(
          key: _whoKey,
          selected: widget.content,
          languageName: _targetLanguageName(),
          languageCode: _targetLanguageCode(),
          arabic: _arabic,
          wholeBook: _wholeBook,
          annoCfi: widget.annoCfi,
          onJump: widget.onJump,
        ),
      ],
    );
  }

  Widget _bodyFor(AssistPalette p, int index) {
    if (!_opened.contains(index)) return const SizedBox.shrink();
    if (index == 0) return _translateBody(p);
    if (index == 2) return _whoBody(p);
    return _aiBody(p);
  }

  /// True when the sheet at the bottom would hide the selection. The
  /// rectangle is already in screen coordinates.
  bool _coversSelection(double screenHeight, double height, double margin) {
    final rect = widget.selectionRect;
    if (rect == null) return false;
    final sheetTop = screenHeight - margin - height;
    return rect.bottom > sheetTop - 8;
  }

  @override
  Widget build(BuildContext context) {
    final p = AssistPalette.of(context);
    final media = MediaQuery.of(context);
    final screenHeight = media.size.height;
    final bottomMargin = media.padding.bottom + 46;

    _minHeight = 260;
    _maxHeight = (screenHeight * 0.82).clamp(300.0, 900.0).toDouble();
    _defaultHeight = (screenHeight * 0.48)
        .clamp(_minHeight, _maxHeight)
        .toDouble();
    final height = (_height ?? _defaultHeight)
        .clamp(_minHeight, _maxHeight)
        .toDouble();

    // Bottom by default; at the top when the bottom would cover the selection
    // and the top does not.
    var atTop = false;
    if (_coversSelection(screenHeight, height, bottomMargin)) {
      final rect = widget.selectionRect;
      final topEdge = media.padding.top + 8 + height;
      if (rect != null && rect.top > topEdge + 8) atTop = true;
    }

    final sheet = Directionality(
      textDirection: _answerDirection,
      child: Material(
        type: MaterialType.transparency,
        child: Container(
          height: height,
          decoration: BoxDecoration(
            color: p.sheet,
            borderRadius: BorderRadius.circular(30),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.18),
                blurRadius: 28,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: DefaultTextStyle.merge(
            style: TextStyle(color: p.text),
            child: Column(
              children: [
                _handle(p),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  child: _tabBar(p),
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: IndexedStack(
                    index: _tab,
                    sizing: StackFit.expand,
                    children: [
                      for (var i = 0; i < 3; i++)
                        SingleChildScrollView(
                          padding: const EdgeInsets.fromLTRB(20, 2, 20, 20),
                          child: _bodyFor(p, i),
                        ),
                    ],
                  ),
                ),
                if (_tab == 0) ...[
                  Divider(height: 1, color: p.track),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 10, 20, 12),
                    child: Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: _languageRow(p),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );

    return Positioned(
      left: 12,
      right: 12,
      top: atTop ? media.padding.top + 8 : null,
      bottom: atTop ? null : bottomMargin,
      child: PointerInterceptor(child: sheet),
    );
  }
}
