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
///  * Translate: translation in context (uses the translation engine you chose)
///  * Explain:   explains the hard passage, knowing the book only up to your page
///  * Who is it: reminds you who a character / what a term is, from what you read
///
/// The AI tabs are loaded lazily (only when tapped) so nothing is sent to an AI
/// provider unless you ask for it.
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
  int _tab = 0;
  final Set<int> _opened = <int>{0};
  int _version = 0;

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
    if (widget.axis == Axis.horizontal) {
      _initializeTranslation();
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

  // ---------------------------------------------------------------------------
  // Translation tab (same behaviour as the original translation card)
  // ---------------------------------------------------------------------------

  void _initializeTranslation() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _translationInitialized) return;
      _debounceTimer?.cancel();
      _debounceTimer = Timer(const Duration(milliseconds: 300), () {
        if (!mounted || _translationInitialized) return;
        setState(() {
          _translationWidget = translateText(
            widget.content,
            service: TranslateService.ai,
            contextText: _effectiveContext,
          );
          _translationInitialized = true;
        });
      });
    });
  }

  void _onLanguageChanged() {
    _debounceTimer?.cancel();
    setState(() {
      _version++;
      _tab = 0;
      _opened
        ..clear()
        ..add(0);
      _explainContext = null;
      _whoContext = null;
      _translationWidget = translateText(
        widget.content,
        service: TranslateService.ai,
        contextText: _effectiveContext,
      );
      _translationInitialized = true;
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
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 6),
          child: Icon(Icons.arrow_forward_ios, size: 14),
        ),
        _langPicker(false),
      ],
    );
  }

  Widget _translateBody() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          widget.content,
          maxLines: 4,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 16),
        ),
        const SizedBox(height: 8),
        Directionality(
          textDirection: _answerDirection,
          child: KeyedSubtree(
            key: ValueKey('translation-$_version'),
            child:
                _translationWidget ??
                const SizedBox(height: 20, child: Center(child: Text('...'))),
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // AI tabs (Explain / Who is it)
  // ---------------------------------------------------------------------------

  /// Reads the book text from the reader WebView, strictly up to the end of
  /// the page on screen. On any problem it fails instead of guessing.
  Future<ReadingAssistContext> _loadContext({required bool scan}) async {
    try {
      final controller = epubPlayerKey.currentState?.webViewController;
      if (controller == null) {
        return const ReadingAssistContext.failed('no-reader');
      }
      final script = buildContextScript(
        query: widget.content.trim(),
        scan: scan,
        recentChars: scan ? 1200 : 2500,
      );
      final result = await controller
          .callAsyncJavaScript(functionBody: script)
          .timeout(const Duration(seconds: 30));
      return parseContextResult(result.value);
    } catch (e) {
      return const ReadingAssistContext.failed('error');
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
    return Directionality(
      textDirection: _answerDirection,
      child: FutureBuilder<ReadingAssistContext>(
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
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Tabs
  // ---------------------------------------------------------------------------

  void _select(int index) {
    if (index == _tab) return;
    setState(() {
      _tab = index;
      _opened.add(index);
      if (index == 1) {
        _explainContext ??= _loadContext(scan: false);
      } else if (index == 2) {
        _whoContext ??= _loadContext(scan: true);
      }
    });
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
    );
  }
}
