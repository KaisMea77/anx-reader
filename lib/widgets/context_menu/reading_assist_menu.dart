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

/// A card shown under the selection toolbar with three tabs:
///  * Translate: a word or short phrase gets a dictionary-style answer (just
///    the equivalent, chosen for its meaning in the sentence); a sentence or a
///    paragraph is translated in full, and the part being translated is
///    coloured in the book while the card is open.
///  * Explain:   explains the hard passage, knowing the book only up to your page
///  * Who is it: reminds you who a character is / what a place or term is
///
/// The card opens on the most useful tab by itself: a name (character, place,
/// people) opens "Who is it?", anything else opens "Translate".
/// The AI tabs are loaded lazily so nothing is sent to an AI provider unless
/// the tab is shown.
class ReadingAssistMenu extends StatefulWidget {
  const ReadingAssistMenu({
    super.key,
    required this.content,
    required this.decoration,
    required this.axis,
    this.contextText,
  });

  final String content;
  final BoxDecoration decoration;
  final Axis axis;
  final String? contextText;

  @override
  State<ReadingAssistMenu> createState() => _ReadingAssistMenuState();
}

class _ReadingAssistMenuState extends State<ReadingAssistMenu> {
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

    _tab = 0;
    if (widget.axis == Axis.horizontal) {
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
    } else {
      _opened.add(0);
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
      Localizations.localeOf(context).languageCode == 'ar' ||
      Prefs().translateTo == LangListEnum.arabic;

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

  Widget _languageRow(ColorScheme scheme) {
    return DefaultTextStyle.merge(
      style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
      child: Row(
        children: [
          Icon(Icons.translate, size: 14, color: scheme.onSurfaceVariant),
          const SizedBox(width: 8),
          _langPicker(true),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Icon(
              _answerDirection == TextDirection.rtl
                  ? Icons.arrow_back_ios
                  : Icons.arrow_forward_ios,
              size: 12,
              color: scheme.onSurfaceVariant,
            ),
          ),
          _langPicker(false),
        ],
      ),
    );
  }

  Widget _scopeChip(ColorScheme scheme, int index, String label) {
    final selected = _scope == index;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _setScope(index),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        decoration: BoxDecoration(
          color: selected ? scheme.secondaryContainer : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected ? Colors.transparent : scheme.outlineVariant,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            color: selected
                ? scheme.onSecondaryContainer
                : scheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }

  Widget _scopeChips(ColorScheme scheme) {
    return Wrap(
      spacing: 8,
      runSpacing: 6,
      children: [
        _scopeChip(scheme, 0, _t('المحدد', 'Selection')),
        _scopeChip(scheme, 1, _t('الجملة', 'Sentence')),
        _scopeChip(scheme, 2, _t('الفقرة', 'Paragraph')),
      ],
    );
  }

  Widget _translateBody(ColorScheme scheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _scopeChips(scheme),
        const SizedBox(height: 12),
        KeyedSubtree(
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
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // AI tabs (Explain / Who is it)
  // ---------------------------------------------------------------------------

  void _prepareAiTab(int index) {
    // "Who is it?" (tab 2) gathers its own text and keeps its own notebook.
    if (index == 1) {
      _explainContext ??= _loadContext(scan: false);
    }
  }

  Widget _hint(ColorScheme scheme, String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Text(
        text,
        style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
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

  Widget _caption(ColorScheme scheme) {
    final color = scheme.onSurfaceVariant.withValues(alpha: 0.8);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Icon(Icons.lock_outline, size: 12, color: color),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              _t(
                'يعتمد على ما قرأتَه فقط، بلا حرق للأحداث',
                'Uses only what you have read — no spoilers',
              ),
              style: TextStyle(fontSize: 11, color: color),
            ),
          ),
        ],
      ),
    );
  }

  Widget _aiBody(ColorScheme scheme) {
    return FutureBuilder<ReadingAssistContext>(
      future: _explainContext,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return _hint(
            scheme,
            _t(
              'أقرأ ما وصلتَ إليه من الكتاب…',
              'Reading what you have read so far…',
            ),
          );
        }
        final ctx = snapshot.data;
        if (ctx == null || !ctx.ok) {
          return _hint(scheme, _failureMessage(ctx?.reason ?? 'unknown'));
        }
        final language = _targetLanguageName();
        final prompt = buildExplainPrompt(
          language: language,
          selected: widget.content,
          contextSentence: _effectiveContext,
          recent: ctx.recent,
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            _caption(scheme),
            DefaultTextStyle.merge(
              style: const TextStyle(fontSize: 15, height: 1.55),
              child: AiStream(
                key: ValueKey('explain-$_version'),
                prompt: _payload(prompt),
                regenerate: true,
              ),
            ),
          ],
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Tabs
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

  Widget _tabPill(ColorScheme scheme, int index, IconData icon, String label) {
    final selected = _tab == index;
    final color = selected
        ? scheme.onPrimaryContainer
        : scheme.onSurfaceVariant;
    return Expanded(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _select(index),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: selected ? scheme.primaryContainer : Colors.transparent,
            borderRadius: BorderRadius.circular(11),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 16, color: color),
              const SizedBox(width: 5),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    color: color,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _tabBar(ColorScheme scheme) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          _tabPill(scheme, 0, Icons.translate, _t('ترجمة', 'Translate')),
          _tabPill(scheme, 1, Icons.lightbulb_outline, _t('شرح', 'Explain')),
          _tabPill(
            scheme,
            2,
            Icons.person_search_outlined,
            _t('من هذا؟', 'Who is it?'),
          ),
        ],
      ),
    );
  }

  Widget _bodyFor(ColorScheme scheme, int index) {
    if (!_opened.contains(index)) return const SizedBox.shrink();
    if (index == 0) return _translateBody(scheme);
    if (index == 2) {
      return DefaultTextStyle.merge(
        style: const TextStyle(fontSize: 15, height: 1.55),
        child: WhoRecall(
          key: ValueKey('who-$_version'),
          selected: widget.content,
          languageName: _targetLanguageName(),
          languageCode: _targetLanguageCode(),
          arabic: _arabic,
        ),
      );
    }
    return _aiBody(scheme);
  }

  BoxDecoration _cardDecoration(ColorScheme scheme) {
    // Keep the original look in e-ink mode (plain, high contrast).
    if (Prefs().eInkMode) return widget.decoration;
    return BoxDecoration(
      color: scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(22),
      border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.6)),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.18),
          blurRadius: 20,
          offset: const Offset(0, 6),
        ),
      ],
    );
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

    final scheme = Theme.of(context).colorScheme;
    final screenHeight = MediaQuery.of(context).size.height;
    final cardHeight = (screenHeight * 0.44).clamp(220.0, 360.0).toDouble();

    return Expanded(
      child: AnimatedSize(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
        child: Material(
          type: MaterialType.transparency,
          // Everything in the card follows the answer language: with Arabic the
          // tabs, chips and text run from right to left.
          child: Directionality(
            textDirection: _answerDirection,
            child: Container(
              height: cardHeight,
              width: double.infinity,
              decoration: _cardDecoration(scheme),
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
              child: DefaultTextStyle.merge(
                style: TextStyle(color: scheme.onSurface),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _tabBar(scheme),
                    const SizedBox(height: 10),
                    Expanded(
                      child: IndexedStack(
                        index: _tab,
                        sizing: StackFit.expand,
                        children: [
                          for (var i = 0; i < 3; i++)
                            SingleChildScrollView(child: _bodyFor(scheme, i)),
                        ],
                      ),
                    ),
                    if (_tab == 0) ...[
                      Divider(
                        height: 1,
                        color: scheme.outlineVariant.withValues(alpha: 0.7),
                      ),
                      const SizedBox(height: 8),
                      _languageRow(scheme),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
