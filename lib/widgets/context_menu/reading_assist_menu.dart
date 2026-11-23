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
import 'package:flutter/material.dart';
import 'package:langchain_core/prompts.dart'
    show ChatPromptTemplate, HumanChatMessagePromptTemplate;
import 'package:pointer_interceptor/pointer_interceptor.dart';

/// A card shown under the selection toolbar with three tabs:
///  * Translate: AI translation in context (selection / sentence / paragraph)
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
  Future<ReadingAssistBlocks>? _blocksFuture;
  ReadingAssistBlocks? _blocks;

  Widget? _translationWidget;
  Timer? _debounceTimer;
  bool _translationInitialized = false;

  Future<ReadingAssistContext>? _explainContext;
  Future<ReadingAssistContext>? _whoContext;

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

  static bool _looksRtl(String text) =>
      RegExp(r'[\u0590-\u08FF]').hasMatch(text);

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

  Future<ReadingAssistBlocks> _loadBlocks() async {
    final raw = await _runScript(
      buildBlocksScript(),
      timeout: const Duration(seconds: 10),
    );
    return parseBlocksResult(raw);
  }

  // ---------------------------------------------------------------------------
  // Translation tab
  // ---------------------------------------------------------------------------

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

  /// Creates the translation widget. Only changes fields: call it inside
  /// setState, in initState or from [_select].
  void _createTranslation() {
    _translationInitialized = true;
    _translationVersion++;
    _translationWidget = translateText(
      _sourceText(),
      service: TranslateService.ai,
      contextText: _scope == 0 ? _effectiveContext : null,
    );
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
    if (scope != 0) {
      _blocksFuture ??= _loadBlocks();
    }
    setState(() {
      _scope = scope;
      _translationWidget = null;
      _translationInitialized = true;
    });
    if (scope != 0) {
      final blocks = await _blocksFuture!;
      if (!mounted || _scope != scope) return;
      _blocks = blocks;
    }
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
      _whoContext = null;
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

  Widget _languageRow() {
    return Row(
      children: [
        _langPicker(true),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Icon(
            _answerDirection == TextDirection.rtl
                ? Icons.arrow_back_ios
                : Icons.arrow_forward_ios,
            size: 14,
          ),
        ),
        _langPicker(false),
      ],
    );
  }

  Widget _scopeChips() {
    final labels = [
      _t('المحدد', 'Selection'),
      _t('الجملة', 'Sentence'),
      _t('الفقرة', 'Paragraph'),
    ];
    return Wrap(
      spacing: 6,
      children: [
        for (var i = 0; i < 3; i++)
          ChoiceChip(
            label: Text(labels[i], style: const TextStyle(fontSize: 12)),
            selected: _scope == i,
            visualDensity: VisualDensity.compact,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            onSelected: (_) => _setScope(i),
          ),
      ],
    );
  }

  Widget _translateBody() {
    final source = _sourceText();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _scopeChips(),
        const SizedBox(height: 6),
        Text(
          source,
          maxLines: _scope == 2 ? 3 : 4,
          overflow: TextOverflow.ellipsis,
          textDirection: _looksRtl(source)
              ? TextDirection.rtl
              : TextDirection.ltr,
          style: const TextStyle(fontSize: 15),
        ),
        const SizedBox(height: 8),
        KeyedSubtree(
          key: ValueKey('translation-$_translationVersion'),
          child:
              _translationWidget ??
              const SizedBox(height: 20, child: Center(child: Text('...'))),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // AI tabs (Explain / Who is it)
  // ---------------------------------------------------------------------------

  void _prepareAiTab(int index) {
    if (index == 1) {
      _explainContext ??= _loadContext(scan: false);
    } else if (index == 2) {
      _whoContext ??= _loadContext(scan: true);
    }
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

  Widget _hint(String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 13,
          color: Theme.of(context).colorScheme.onSecondaryContainer
              .withValues(alpha: 0.75),
        ),
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

  Widget _caption() {
    final color = Theme.of(context).colorScheme.onSecondaryContainer
        .withValues(alpha: 0.6);
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
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

  Widget _aiBody({required bool who}) {
    final future = who ? _whoContext : _explainContext;
    return FutureBuilder<ReadingAssistContext>(
      future: future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return _hint(
            _t(
              'أقرأ ما وصلتَ إليه من الكتاب…',
              'Reading what you have read so far…',
            ),
          );
        }
        final ctx = snapshot.data;
        if (ctx == null || !ctx.ok) {
          return _hint(_failureMessage(ctx?.reason ?? 'unknown'));
        }
        final target = Prefs().translateTo;
        final language = target == LangListEnum.auto
            ? (_arabic ? 'العربية' : 'English')
            : target.nativeName;
        final prompt = who
            ? buildWhoPrompt(
                language: language,
                selected: widget.content,
                context: ctx,
              )
            : buildExplainPrompt(
                language: language,
                selected: widget.content,
                contextSentence: _effectiveContext,
                recent: ctx.recent,
              );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            _caption(),
            AiStream(
              key: ValueKey('${who ? 'who' : 'explain'}-$_version'),
              prompt: _payload(prompt),
              regenerate: true,
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

  Widget _tabButton(int index, IconData icon, String label) {
    final theme = Theme.of(context);
    final selected = _tab == index;
    final color = selected
        ? theme.colorScheme.primary
        : theme.colorScheme.onSecondaryContainer.withValues(alpha: 0.65);
    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => _select(index),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 6),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: selected
                    ? theme.colorScheme.primary
                    : Colors.transparent,
                width: 2,
              ),
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 16, color: color),
              const SizedBox(width: 4),
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

  Widget _bodyFor(int index) {
    if (!_opened.contains(index)) return const SizedBox.shrink();
    if (index == 0) return _translateBody();
    return _aiBody(who: index == 2);
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

    final screenHeight = MediaQuery.of(context).size.height;
    final cardHeight = (screenHeight * 0.42).clamp(190.0, 320.0).toDouble();

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
              decoration: widget.decoration,
              padding: const EdgeInsets.fromLTRB(10, 4, 10, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      _tabButton(0, Icons.translate, _t('ترجمة', 'Translate')),
                      _tabButton(
                        1,
                        Icons.lightbulb_outline,
                        _t('شرح', 'Explain'),
                      ),
                      _tabButton(
                        2,
                        Icons.person_search_outlined,
                        _t('من هذا؟', 'Who is it?'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Expanded(
                    child: IndexedStack(
                      index: _tab,
                      sizing: StackFit.expand,
                      children: [
                        for (var i = 0; i < 3; i++)
                          SingleChildScrollView(child: _bodyFor(i)),
                      ],
                    ),
                  ),
                  if (_tab == 0) ...[const Divider(height: 8), _languageRow()],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
