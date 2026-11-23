// FILE PATH: lib/widgets/context_menu/reader_note_menu.dart  (existing file, modified)
import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/dao/book_note.dart';
import 'package:anx_reader/enums/lang_list.dart';
import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/models/book_note.dart';
import 'package:anx_reader/page/reading_page.dart';
import 'package:anx_reader/service/notes/note_everywhere.dart';
import 'package:anx_reader/utils/toast/common.dart';
import 'package:anx_reader/widgets/common/axis_flex.dart';
import 'package:flutter/material.dart';
import 'package:iconsx_plus/iconsx_plus.dart';

class ReaderNoteMenu extends StatefulWidget {
  const ReaderNoteMenu({
    super.key,
    this.noteId,
    required this.decoration,
    required this.axis,
    required this.onVisibilityChange,
    required this.onSizeChanged,
    this.onSaved,
  });

  final int? noteId;
  final BoxDecoration decoration;
  final Axis axis;
  final ValueChanged<bool> onVisibilityChange;
  final VoidCallback onSizeChanged;

  /// Close the selection menu after a successful save (desktop parity).
  final VoidCallback? onSaved;

  @override
  State<ReaderNoteMenu> createState() => ReaderNoteMenuState();
}

class ReaderNoteMenuState extends State<ReaderNoteMenu> {
  BookNote? note;
  bool _showNoteDialog = false;
  final textFieldController = TextEditingController();
  final FocusNode _noteFocusNode = FocusNode(debugLabel: 'reader_note');
  bool showSaveButton = false;
  bool _applying = false;

  @override
  void initState() {
    super.initState();
    getNoteDetail(widget.noteId);
  }

  @override
  void dispose() {
    textFieldController.dispose();
    _noteFocusNode.dispose();
    super.dispose();
  }

  void _focusNoteField() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // Hand keyboard to Flutter; CEF otherwise keeps GTK/CEF focus.
      readingPageKey.currentState?.releaseReaderFocusForChrome();
      _noteFocusNode.requestFocus();
    });
  }

  void _notifyVisibility(bool visible) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        widget.onVisibilityChange(visible);
      }
    });
  }

  void _notifySizeChange() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        widget.onSizeChanged();
      }
    });
  }

  void _setShowNoteDialog(bool value) {
    if (!mounted) {
      _showNoteDialog = value;
      return;
    }
    if (_showNoteDialog == value) {
      setState(() {});
      _notifySizeChange();
      _notifyVisibility(value);
      if (value) _focusNoteField();
      return;
    }
    setState(() {
      _showNoteDialog = value;
    });
    _notifyVisibility(value);
    _notifySizeChange();
    if (value) _focusNoteField();
  }

  Future<void> getNoteDetail(int? id) async {
    if (id == null) return;
    try {
      final fetchedNote = await bookNoteDao.selectBookNoteById(id);
      note = fetchedNote;

      if (note != null &&
          note!.readerNote != null &&
          note!.readerNote!.isNotEmpty) {
        textFieldController.text = note!.readerNote!;
        _setShowNoteDialog(true);
      }
    } finally {
      if (mounted) {
        setState(() {});
        _notifySizeChange();
      }
    }
  }

  Future<void> showNoteDialog(int noteId) async {
    await getNoteDetail(noteId);
    _setShowNoteDialog(true);
  }

  void saveNote() {
    textFieldController.text = textFieldController.text.trim();
    if (note != null) {
      note!.readerNote = textFieldController.text;
      bookNoteDao.updateBookNoteById(note!);
    }
    _notifySizeChange();
    widget.onSaved?.call();
  }

  /// Saves this note, then adds the same highlight and note to every other
  /// occurrence of the selected word in the whole book (after confirmation).
  /// Occurrences that already have a note or highlight are never touched.
  Future<void> applyEverywhere() async {
    if (_applying) return;
    final arabic =
        Localizations.localeOf(context).languageCode == 'ar' ||
        Prefs().translateTo == LangListEnum.arabic;
    String tr(String ar, String en) => arabic ? ar : en;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final current = note;
    final player = epubPlayerKey.currentState;
    final text = textFieldController.text.trim();

    if (current == null || player == null) {
      AnxToast.show(
        tr(
          'تعذّر العثور على الملاحظة الحالية',
          'Could not find the current note',
        ),
      );
      return;
    }
    if (text.isEmpty) {
      AnxToast.show(tr('اكتب الملاحظة أولاً', 'Write the note first'));
      return;
    }
    final query = current.content.trim();
    if (query.isEmpty || query.length > 120) {
      AnxToast.show(
        tr(
          'التحديد طويل جداً للتطبيق على كل المطابقات',
          'The selection is too long to apply everywhere',
        ),
      );
      return;
    }

    setState(() => _applying = true);
    try {
      // 1) save this note first (same as the check button)
      current.readerNote = text;
      await bookNoteDao.updateBookNoteById(current);

      // 2) find every occurrence in the whole book
      final controller = player.webViewController;
      final raw = await controller
          .callAsyncJavaScript(
            functionBody: buildFindEverywhereScript(query: query),
          )
          .timeout(const Duration(minutes: 3));
      final found = parseFindEverywhere(raw.value);
      if (!found.ok) {
        AnxToast.show(
          tr('تعذّر البحث في الكتاب', 'Could not search the book') +
              ' [${found.reason}]',
        );
        return;
      }

      // 3) never touch an existing note or highlight
      final existing = await bookNoteDao.selectBookNotesByBookId(
        current.bookId,
      );
      final existingCfis = <String>[...existing.map((n) => n.cfi), current.cfi];
      final plan = planNewHits(hits: found.hits, existingCfis: existingCfis);
      if (plan.isEmpty) {
        AnxToast.show(
          tr(
            'لا توجد مواضع أخرى لهذه الكلمة',
            'No other occurrences of this word',
          ),
        );
        return;
      }
      final others = found.hits
          .where((h) => !cfiOverlaps(h.cfi, current.cfi))
          .length;
      final skipped = others > plan.length ? others - plan.length : 0;
      final chapters = plan.map((h) => h.chapter).toSet().length;

      // 4) ask before writing anything
      if (!mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => Directionality(
          textDirection: arabic ? TextDirection.rtl : TextDirection.ltr,
          child: AlertDialog(
            title: Text(
              tr(
                'تطبيق الملاحظة على كل المطابقات؟',
                'Apply the note to every match?',
              ),
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tr(
                      'عُثر على ${plan.length} موضعاً آخر لـ «$query» في $chapters فصلاً. سيُضاف إلى كل موضع تظليل بنفس اللون مع هذه الملاحظة.',
                      'Found ${plan.length} more occurrences of "$query" in $chapters chapters. Each will get the same highlight and this note.',
                    ),
                  ),
                  if (skipped > 0) ...[
                    const SizedBox(height: 8),
                    Text(
                      tr(
                        'تم تخطي $skipped موضعاً عليه ملاحظة أو تظليل سابق (لن يُمس).',
                        '$skipped occurrences that already have a note or highlight were skipped (left untouched).',
                      ),
                    ),
                  ],
                  if (found.truncated) ...[
                    const SizedBox(height: 8),
                    Text(
                      tr(
                        'تنبيه: توقف البحث عند الحد الأقصى، فقد توجد مواضع أخرى.',
                        'Note: the search stopped at its limit, so there may be more.',
                      ),
                    ),
                  ],
                  const SizedBox(height: 10),
                  for (final h in plan.take(3))
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(
                        '…${h.pre}[${h.match}]${h.post}…',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        textDirection: TextDirection.ltr,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: Text(tr('إلغاء', 'Cancel')),
              ),
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: Text(tr('تطبيق', 'Apply')),
              ),
            ],
          ),
        ),
      );
      if (confirmed != true) return;

      // 5) create the notes and draw them in the book
      final now = DateTime.now();
      final created = <BookNote>[];
      for (final hit in plan) {
        final newNote = BookNote(
          bookId: current.bookId,
          content: hit.match.isNotEmpty ? hit.match : query,
          cfi: hit.cfi,
          chapter: hit.chapter.isNotEmpty ? hit.chapter : current.chapter,
          type: current.type,
          color: current.color,
          readerNote: text,
          createTime: now,
          updateTime: now,
        );
        final id = await bookNoteDao.save(newNote);
        newNote.setId(id);
        created.add(newNote);
      }
      final items = created
          .map(
            (n) => <String, Object?>{
              'id': n.id,
              'type': n.type,
              'value': n.cfi,
              'color': '#${n.color}',
              'note': n.content,
            },
          )
          .toList();
      for (var i = 0; i < items.length; i += 100) {
        final end = i + 100 < items.length ? i + 100 : items.length;
        await controller.execute(
          buildAddAnnotationsScript(items.sublist(i, end)),
        );
      }

      // 6) tell the reader, with a way back
      Future<void> undo() async {
        for (final n in created) {
          if (n.id != null) await bookNoteDao.deleteBookNoteById(n.id!);
        }
        try {
          await controller.execute(
            buildRemoveAnnotationsScript(created.map((n) => n.cfi).toList()),
          );
        } catch (_) {}
      }

      final message = tr(
        'تمت إضافة ${created.length} ملاحظة في الكتاب',
        'Added ${created.length} notes across the book',
      );
      if (messenger != null) {
        messenger.showSnackBar(
          SnackBar(
            content: Text(message),
            duration: const Duration(seconds: 12),
            action: SnackBarAction(label: tr('تراجع', 'Undo'), onPressed: undo),
          ),
        );
      } else {
        AnxToast.show(message);
      }
      widget.onSaved?.call();
    } catch (e) {
      AnxToast.show(
        tr(
          'حدث خطأ أثناء التطبيق على كل المطابقات',
          'Something went wrong while applying to all matches',
        ),
      );
    } finally {
      if (mounted) setState(() => _applying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: AnimatedSize(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: widget.axis == Axis.vertical ? double.infinity : 200,
            maxWidth: widget.axis == Axis.vertical ? 100 : double.infinity,
          ),
          child: !_showNoteDialog
              ? null
              : Container(
                  decoration: widget.decoration,
                  padding: const EdgeInsets.all(8),
                  child: AxisFlex(
                    reverse: false,
                    axis: widget.axis,
                    children: [
                      Expanded(
                        child: SingleChildScrollView(
                          // scrollDirection: widget.axis,
                          child: TextField(
                            controller: textFieldController,
                            focusNode: _noteFocusNode,
                            autofocus: true,
                            decoration: InputDecoration(
                              border: InputBorder.none,
                              hintText: L10n.of(context).contextMenuAddNoteTips,
                            ),
                            maxLines: widget.axis == Axis.vertical
                                ? double.maxFinite.toInt()
                                : 5,
                            minLines: 1,
                            onSubmitted: (String value) {
                              saveNote();
                            },
                            onChanged: (String value) {
                              setState(() {
                                showSaveButton = true;
                              });
                              _notifySizeChange();
                            },
                          ),
                        ),
                      ),
                      if (showSaveButton) ...[
                        IconButton(
                          icon: const Icon(EvaIcons.checkmark_circle_2_outline),
                          onPressed: saveNote,
                        ),
                        IconButton(
                          tooltip:
                              Localizations.localeOf(context).languageCode ==
                                      'ar' ||
                                  Prefs().translateTo == LangListEnum.arabic
                              ? 'تطبيق على كل المطابقات في الكتاب'
                              : 'Apply to every match in the book',
                          icon: _applying
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.done_all),
                          onPressed: _applying ? null : applyEverywhere,
                        ),
                      ],
                    ],
                  ),
                ),
        ),
      ),
    );
  }
}
