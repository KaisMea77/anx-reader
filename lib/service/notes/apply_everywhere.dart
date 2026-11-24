// FILE PATH: lib/service/notes/apply_everywhere.dart  (NEW file - glue used by the note box and the colour bar)
//
// Two actions on every occurrence of the selected word in the whole book:
//  * [applyToEveryOccurrence]: saves a highlight (with or without a note) on
//    each one, after a confirmation. Occurrences that already carry a note or
//    a highlight are never touched.
//  * [toggleTemporaryMarks]: outlines every occurrence while you read, without
//    saving anything. Press again to remove the outlines.
import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/dao/book_note.dart';
import 'package:anx_reader/enums/lang_list.dart';
import 'package:anx_reader/models/book_note.dart';
import 'package:anx_reader/page/reading_page.dart';
import 'package:anx_reader/service/notes/note_everywhere.dart';
import 'package:anx_reader/utils/toast/common.dart';
import 'package:flutter/material.dart';

/// The reader and the word that currently carry temporary marks.
Object? _markedController;
String? _markedTerm;

bool _isArabicUi(BuildContext context) =>
    Localizations.localeOf(context).languageCode == 'ar' ||
    Prefs().translateTo == LangListEnum.arabic;

/// True when [query] is currently outlined everywhere in the open book.
bool temporaryMarksActive(String query) {
  try {
    final controller = epubPlayerKey.currentState?.webViewController;
    return controller != null &&
        identical(controller, _markedController) &&
        _markedTerm == query.trim().toLowerCase();
  } catch (_) {
    return false;
  }
}

/// Outlines every occurrence of [query] in the book, or removes the outlines
/// when they are already shown for the same word.
Future<void> toggleTemporaryMarks(BuildContext context, String query) async {
  final arabic = _isArabicUi(context);
  String tr(String ar, String en) => arabic ? ar : en;
  final player = epubPlayerKey.currentState;
  final term = query.trim();
  if (player == null || term.isEmpty || term.length > 120) {
    AnxToast.show(tr('تعذّر تمييز هذه الكلمة', 'Cannot mark this word'));
    return;
  }
  try {
    final controller = player.webViewController;
    if (temporaryMarksActive(term)) {
      await controller.callAsyncJavaScript(
        functionBody: buildClearSearchMarksScript(),
      );
      _markedController = null;
      _markedTerm = null;
      AnxToast.show(tr('أُزيل التمييز', 'Marks removed'));
      return;
    }
    AnxToast.show(
      tr('جارٍ تمييز الكلمة في الكتاب…', 'Marking the word in the book…'),
    );
    final raw = await controller
        .callAsyncJavaScript(
          functionBody: buildFindEverywhereScript(query: term, keepMarks: true),
        )
        .timeout(const Duration(minutes: 3));
    final found = parseFindEverywhere(raw.value);
    if (!found.ok) {
      AnxToast.show(
        '${tr('تعذّر البحث في الكتاب', 'Could not search the book')} [${found.reason}]',
      );
      return;
    }
    _markedController = controller;
    _markedTerm = term.toLowerCase();
    AnxToast.show(
      tr(
        'تم تمييز ${found.hits.length} موضعاً. اضغط الزر نفسه لإزالته.',
        'Marked ${found.hits.length} places. Press the same button to remove.',
      ),
    );
  } catch (e) {
    AnxToast.show(
      tr('حدث خطأ أثناء التمييز', 'Something went wrong while marking'),
    );
  }
}

/// Adds the same highlight (and [noteText], when given) to every other
/// occurrence of [source]'s text in the whole book. Returns true when notes
/// were added.
Future<bool> applyToEveryOccurrence(
  BuildContext context, {
  required BookNote source,
  String? noteText,
}) async {
  final arabic = _isArabicUi(context);
  String tr(String ar, String en) => arabic ? ar : en;
  final messenger = ScaffoldMessenger.maybeOf(context);
  final player = epubPlayerKey.currentState;
  final query = source.content.trim();
  final text = (noteText ?? '').trim();

  if (player == null) {
    AnxToast.show(
      tr('تعذّر الوصول إلى الكتاب المفتوح', 'Cannot reach the open book'),
    );
    return false;
  }
  if (query.isEmpty || query.length > 120) {
    AnxToast.show(
      tr(
        'التحديد طويل جداً للتطبيق على كل المطابقات',
        'The selection is too long to apply everywhere',
      ),
    );
    return false;
  }

  try {
    AnxToast.show(tr('جارٍ البحث في الكتاب…', 'Searching the book…'));
    final controller = player.webViewController;
    final raw = await controller
        .callAsyncJavaScript(
          functionBody: buildFindEverywhereScript(query: query),
        )
        .timeout(const Duration(minutes: 3));
    final found = parseFindEverywhere(raw.value);
    if (!found.ok) {
      AnxToast.show(
        '${tr('تعذّر البحث في الكتاب', 'Could not search the book')} [${found.reason}]',
      );
      return false;
    }

    // Never touch an existing note or highlight.
    final existing = await bookNoteDao.selectBookNotesByBookId(source.bookId);
    final existingCfis = <String>[...existing.map((n) => n.cfi), source.cfi];
    final plan = planNewHits(hits: found.hits, existingCfis: existingCfis);
    if (plan.isEmpty) {
      AnxToast.show(
        tr(
          'لا توجد مواضع أخرى لهذه الكلمة',
          'No other occurrences of this word',
        ),
      );
      return false;
    }
    final others = found.hits
        .where((h) => !cfiOverlaps(h.cfi, source.cfi))
        .length;
    final skipped = others > plan.length ? others - plan.length : 0;
    final chapters = plan.map((h) => h.chapter).toSet().length;

    // Ask before writing anything.
    if (!context.mounted) return false;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => Directionality(
        textDirection: arabic ? TextDirection.rtl : TextDirection.ltr,
        child: AlertDialog(
          title: Text(
            text.isNotEmpty
                ? tr(
                    'تطبيق الملاحظة على كل المطابقات؟',
                    'Apply the note to every match?',
                  )
                : tr('تظليل كل المطابقات؟', 'Highlight every match?'),
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  text.isNotEmpty
                      ? tr(
                          'عُثر على ${plan.length} موضعاً آخر لـ «$query» في $chapters فصلاً. سيُضاف إلى كل موضع تظليل بنفس اللون مع هذه الملاحظة.',
                          'Found ${plan.length} more occurrences of "$query" in $chapters chapters. Each will get the same highlight and this note.',
                        )
                      : tr(
                          'عُثر على ${plan.length} موضعاً آخر لـ «$query» في $chapters فصلاً. سيُظلَّل كل موضع بنفس اللون والنوع.',
                          'Found ${plan.length} more occurrences of "$query" in $chapters chapters. Each will be highlighted the same way.',
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
    if (confirmed != true) return false;

    // Create the notes and draw them in the book.
    final now = DateTime.now();
    final created = <BookNote>[];
    for (final hit in plan) {
      final newNote = BookNote(
        bookId: source.bookId,
        content: hit.match.isNotEmpty ? hit.match : query,
        cfi: hit.cfi,
        chapter: hit.chapter.isNotEmpty ? hit.chapter : source.chapter,
        type: source.type,
        color: source.color,
        readerNote: text.isNotEmpty ? text : null,
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

    // Tell the reader, with a way back.
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

    final message = text.isNotEmpty
        ? tr(
            'تمت إضافة ${created.length} ملاحظة في الكتاب',
            'Added ${created.length} notes across the book',
          )
        : tr(
            'تم تظليل ${created.length} موضعاً في الكتاب',
            'Highlighted ${created.length} places in the book',
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
    return true;
  } catch (e) {
    AnxToast.show(
      tr(
        'حدث خطأ أثناء التطبيق على كل المطابقات',
        'Something went wrong while applying to all matches',
      ),
    );
    return false;
  }
}
