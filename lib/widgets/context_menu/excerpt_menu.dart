// FILE PATH: lib/widgets/context_menu/excerpt_menu.dart  (existing file, modified)
import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/constants/note_annotations.dart';
import 'package:anx_reader/dao/book_note.dart';
import 'package:anx_reader/enums/lang_list.dart';
import 'package:anx_reader/models/bookmark.dart';
import 'package:anx_reader/providers/bookmark.dart';
import 'package:anx_reader/service/ai/reading_assist.dart'
    show kAssistEnglishLabels;
import 'package:anx_reader/widgets/context_menu/who_recall.dart'
    show AssistPalette;
import 'package:anx_reader/enums/search_display_mode.dart';
import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/main.dart';
import 'package:anx_reader/models/book_note.dart';
import 'package:anx_reader/page/reading_page.dart';
import 'package:anx_reader/service/notes/apply_everywhere.dart';
import 'package:anx_reader/service/tts/tts_handler.dart';
import 'package:anx_reader/utils/env_var.dart';
import 'package:anx_reader/utils/toast/common.dart';
import 'package:anx_reader/widgets/book_share/excerpt_share_service.dart';
import 'package:anx_reader/widgets/common/axis_flex.dart';
import 'package:anx_reader/widgets/icon_and_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:iconsx_plus/iconsx_plus.dart';
import 'package:url_launcher/url_launcher.dart';

class ExcerptMenu extends StatefulWidget {
  final String annoCfi;
  final String annoContent;
  final int? id;
  final Function() onClose;
  final bool footnote;
  final BoxDecoration decoration;
  final Function() toggleTranslationMenu;
  final void Function({bool? show}) toggleReaderNoteMenu;
  final void Function({bool? show, String? query}) toggleSearchMenu;
  final Future<void> Function(int noteId) openReaderNoteMenu;
  final void Function(int noteId) onNoteCreated;
  final Axis axis;
  final bool reverse;

  const ExcerptMenu({
    super.key,
    required this.annoCfi,
    required this.annoContent,
    this.id,
    required this.onClose,
    required this.footnote,
    required this.decoration,
    required this.toggleTranslationMenu,
    required this.toggleReaderNoteMenu,
    required this.toggleSearchMenu,
    required this.openReaderNoteMenu,
    required this.onNoteCreated,
    required this.axis,
    required this.reverse,
  });

  @override
  ExcerptMenuState createState() => ExcerptMenuState();
}

class ExcerptMenuState extends State<ExcerptMenu> {
  /// The colour bar opens when "Highlight" is tapped (or when an existing
  /// highlight is being edited).
  bool _showColors = false;

  bool deleteConfirm = false;
  int? noteId;
  BookNote? _currentNote;
  late String annoType;
  late String annoColor;

  @override
  initState() {
    super.initState();
    annoType = Prefs().annotationType;
    annoColor = Prefs().annotationColor;
    _showColors = widget.id != null;
    _initializeExistingNote();
  }

  Future<void> _initializeExistingNote() async {
    final existingId = widget.id;
    if (existingId == null) {
      return;
    }

    try {
      final note = await bookNoteDao.selectBookNoteById(existingId);
      if (!mounted) {
        return;
      }
      setState(() {
        _currentNote = note;
        noteId = note.id;
        annoType = note.type;
        annoColor = note.color;
      });
      if (!widget.footnote &&
          note.readerNote != null &&
          note.readerNote!.isNotEmpty) {
        await widget.openReaderNoteMenu(note.id!);
      }
    } catch (_) {
      // When the note cannot be loaded we keep the defaults from Prefs.
    }
  }

  Future<BookNote?> _fetchLatestNote() async {
    final existingId = noteId ?? widget.id;
    if (existingId == null) {
      return null;
    }

    try {
      return await bookNoteDao.selectBookNoteById(existingId);
    } catch (_) {
      return null;
    }
  }

  Future<BookNote> _persistNote({
    String? color,
    String? type,
    String? content,
  }) async {
    final existingNote = await _fetchLatestNote() ?? _currentNote;
    final now = DateTime.now();

    final resolvedContent = (content ?? widget.annoContent).trim().isNotEmpty
        ? (content ?? widget.annoContent)
        : (existingNote?.content ?? widget.annoContent);
    final resolvedType = type ?? existingNote?.type ?? annoType;
    final resolvedColor = color ?? existingNote?.color ?? annoColor;

    final BookNote bookNote = BookNote(
      id: existingNote?.id ?? widget.id,
      bookId:
          existingNote?.bookId ?? epubPlayerKey.currentState!.widget.book.id,
      content: resolvedContent,
      cfi: existingNote?.cfi ?? widget.annoCfi,
      chapter:
          existingNote?.chapter ?? epubPlayerKey.currentState!.chapterTitle,
      type: resolvedType,
      color: resolvedColor,
      readerNote: existingNote?.readerNote,
      createTime: existingNote?.createTime ?? now,
      updateTime: now,
    );

    final id = await bookNoteDao.save(bookNote);
    bookNote.setId(id);
    widget.onNoteCreated(id);

    if (mounted) {
      setState(() {
        _currentNote = bookNote;
        noteId = id;
        annoType = resolvedType;
        annoColor = resolvedColor;
      });
    } else {
      _currentNote = bookNote;
      noteId = id;
      annoType = resolvedType;
      annoColor = resolvedColor;
    }

    return bookNote;
  }

  Icon deleteIcon() {
    return deleteConfirm
        ? const Icon(EvaIcons.close_circle, color: Colors.red)
        : const Icon(Icons.delete);
  }

  void deleteHandler() {
    if (deleteConfirm) {
      if (widget.id != null) {
        bookNoteDao.deleteBookNoteById(widget.id!);
        epubPlayerKey.currentState!.removeAnnotation(widget.annoCfi);
      }
      widget.onClose();
    } else {
      setState(() {
        deleteConfirm = true;
      });
    }
  }

  Future<void> onColorSelected(String color, {bool close = true}) async {
    Prefs().annotationColor = color;
    if (mounted) {
      setState(() {
        annoColor = color;
      });
    } else {
      annoColor = color;
    }
    final bookNote = await _persistNote(color: color);
    epubPlayerKey.currentState!.addAnnotation(bookNote);
    if (close) {
      widget.onClose();
    }
  }

  Future<void> onTypeSelected(String type) async {
    Prefs().annotationType = type;
    if (mounted) {
      setState(() {
        annoType = type;
      });
    } else {
      annoType = type;
    }
    final bookNote = await _persistNote(type: type);
    epubPlayerKey.currentState!.addAnnotation(bookNote);
  }

  bool get _arabicLabels =>
      !kAssistEnglishLabels && Prefs().translateTo == LangListEnum.arabic;

  String _label(String ar, String en) => _arabicLabels ? ar : en;

  /// "I'm here": a bookmark at the place of the selection.
  Future<void> imHere() async {
    final player = epubPlayerKey.currentState;
    if (player == null || widget.annoCfi.isEmpty) {
      AnxToast.show(
        _label('تعذّر إضافة علامة مرجعية', 'Cannot add a bookmark'),
      );
      return;
    }
    try {
      final now = DateTime.now();
      final bookmark = await player.ref
          .read(BookmarkProvider(player.widget.book.id).notifier)
          .addBookmark(
            BookmarkModel(
              bookId: player.widget.book.id,
              cfi: widget.annoCfi,
              percentage: player.percentage,
              content: widget.annoContent.trim(),
              chapter: player.chapterTitle,
              updateTime: now,
              createTime: now,
            ),
          );
      player.addBookmark(bookmark);
      AnxToast.show(_label('تمت إضافة علامة مرجعية', 'Bookmark added'));
    } catch (e) {
      AnxToast.show(
        _label('تعذّر إضافة علامة مرجعية', 'Cannot add a bookmark'),
      );
    }
    widget.onClose();
  }

  /// Highlights this selection and every other occurrence of it in the whole
  /// book, in the current style and colour (permanent, after confirmation).
  Future<void> highlightAllOccurrences() async {
    final bookNote = await _persistNote();
    epubPlayerKey.currentState!.addAnnotation(bookNote);
    if (!mounted) return;
    final done = await applyToEveryOccurrence(context, source: bookNote);
    if (done) widget.onClose();
  }

  /// Outlines every occurrence while reading (not saved); press again to remove.
  Future<void> toggleOccurrenceMarks() async {
    await toggleTemporaryMarks(context, widget.annoContent);
    if (mounted) setState(() {});
  }

  Widget iconButton({required Icon icon, required Function() onPressed}) {
    return IconButton(
      padding: const EdgeInsets.all(2),
      constraints: const BoxConstraints(),
      style: const ButtonStyle(tapTargetSize: MaterialTapTargetSize.shrinkWrap),
      icon: icon,
      onPressed: onPressed,
    );
  }

  Widget colorButton(String color) {
    return iconButton(
      icon: Icon(Icons.circle, color: Color(int.parse('0x88$color'))),
      onPressed: () {
        onColorSelected(color);
      },
    );
  }

  Widget typeButton(String type, IconData icon) {
    return iconButton(
      icon: Icon(
        icon,
        color: annoType == type ? Color(int.parse('0xff$annoColor')) : null,
      ),
      onPressed: () {
        onTypeSelected(type);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = AssistPalette.of(context);

    // White floating bars (plain, high contrast in e-ink mode).
    final BoxDecoration barDecoration = Prefs().eInkMode
        ? widget.decoration
        : BoxDecoration(
            color: p.sheet,
            borderRadius: BorderRadius.circular(26),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.16),
                blurRadius: 20,
                offset: const Offset(0, 6),
              ),
            ],
          );

    Widget barButton({
      required IconData icon,
      required String label,
      required VoidCallback onTap,
      bool active = false,
    }) {
      return InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          child: SizedBox(
            width: 64,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 25, color: active ? p.accent : p.text),
                const SizedBox(height: 5),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12.5,
                    color: active ? p.accent : p.text,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    Widget annotationMenu = Material(
      type: MaterialType.transparency,
      child: Container(
        padding: const EdgeInsets.all(6),
        decoration: barDecoration,
        child: AxisFlex(
          axis: widget.axis,
          mainAxisSize: MainAxisSize.min,
          children: [
            iconButton(onPressed: deleteHandler, icon: deleteIcon()),
            for (final type in notesType) typeButton(type.type, type.icon),
            for (String color in notesColors) colorButton(color),
            Tooltip(
              message: _label(
                'تمييز مؤقت لكل المطابقات (اضغط مرة أخرى للإزالة)',
                'Temporarily mark every match (press again to remove)',
              ),
              child: iconButton(
                icon: Icon(
                  temporaryMarksActive(widget.annoContent)
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                ),
                onPressed: toggleOccurrenceMarks,
              ),
            ),
            Tooltip(
              message: _label(
                'تظليل دائم لكل المطابقات في الكتاب',
                'Highlight every match in the book (saved)',
              ),
              child: iconButton(
                icon: const Icon(Icons.format_color_fill),
                onPressed: highlightAllOccurrences,
              ),
            ),
          ],
        ),
      ),
    );

    Widget operatorMenu = Material(
      type: MaterialType.transparency,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: barDecoration,
        child: AxisFlex(
          axis: widget.axis,
          mainAxisSize: MainAxisSize.min,
          children: [
            // highlight: opens the colour bar
            if (!widget.footnote)
              barButton(
                icon: Icons.brush_outlined,
                label: _label('تظليل', 'Highlight'),
                active: _showColors,
                onTap: () => setState(() => _showColors = !_showColors),
              ),
            // note
            if (!widget.footnote)
              barButton(
                icon: EvaIcons.edit_2_outline,
                label: _label('ملاحظة', 'Note'),
                onTap: () async {
                  epubPlayerKey.currentState?.setSelectionClearLocked(true);
                  await onColorSelected(annoColor, close: false);
                  final targetId = noteId ?? widget.id;
                  if (targetId != null) {
                    await widget.openReaderNoteMenu(targetId);
                  } else {
                    widget.toggleReaderNoteMenu(show: true);
                  }
                },
              ),
            // bookmark at this place
            if (!widget.footnote)
              barButton(
                icon: Icons.place_outlined,
                label: _label('أنا هنا', "I'm here"),
                onTap: imHere,
              ),
            // copy
            barButton(
              icon: EvaIcons.copy,
              label: _label('نسخ', 'Copy'),
              onTap: () {
                Clipboard.setData(ClipboardData(text: widget.annoContent));
                AnxToast.show(L10n.of(context).notesPageCopied);
                widget.onClose();
              },
            ),
          ],
        ),
      ),
    );

    return Expanded(
      child: AxisFlex(
        reverse: widget.reverse,
        axis: flipAxis(widget.axis),
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AxisFlex(
            axis: flipAxis(widget.axis),
            reverse: widget.reverse,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SingleChildScrollView(
                scrollDirection: widget.axis,
                child: operatorMenu,
              ),
              if (!widget.footnote && _showColors) ...[
                const SizedBox.square(dimension: 10),
                SingleChildScrollView(
                  scrollDirection: widget.axis,
                  child: annotationMenu,
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}
