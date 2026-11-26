import 'dart:typed_data';

import 'package:intl/intl.dart';

import 'package:money_mate/core/constants/app_constants.dart';
import 'package:money_mate/core/utils/money.dart';
import 'package:money_mate/core/utils/xlsx_writer.dart';
import 'package:money_mate/models/scope_models.dart';
import 'package:money_mate/models/transaction_model.dart';

/// One transaction as it appears in the exported workbook.
class ExportTransaction {
  const ExportTransaction({
    required this.date,
    required this.type,
    required this.category,
    required this.amountMinor,
    required this.paymentMethod,
    required this.note,
    required this.isShared,
    this.addedBy,
  });

  factory ExportTransaction.from(TransactionModel t, {String? categoryName}) {
    return ExportTransaction(
      date: t.date,
      type: t.type,
      category: categoryName ?? 'Unknown',
      amountMinor: t.amountMinor,
      paymentMethod: t.paymentMethod.label,
      note: t.note,
      isShared: t.isShared,
      addedBy: t.isShared ? t.createdByName : null,
    );
  }

  final DateTime date;
  final TransactionType type;
  final String category;

  /// Always positive; [type] gives the direction.
  final int amountMinor;
  final String paymentMethod;
  final String note;
  final bool isShared;
  final String? addedBy;

  bool get isIncome => type == TransactionType.income;

  /// Income positive, expenses negative.
  int get signedMinor => isIncome ? amountMinor : -amountMinor;
}

/// Builds the "Export transactions" spreadsheet for one scope: the
/// user's personal transactions or the household's shared ones (never
/// both in one file). It has a formatted transactions sheet and a summary
/// sheet with monthly totals and spending by category.
class TransactionsWorkbook {
  TransactionsWorkbook._();

  static const mimeType = XlsxWorkbook.mimeType;

  /// e.g. `moneymate_household_transactions_20261126_143000.xlsx`.
  static String fileName(DateTime now, {required ViewScope view}) {
    final stamp = DateFormat('yyyyMMdd_HHmmss').format(now);
    final scope = view == ViewScope.shared ? 'household' : 'personal';
    return 'moneymate_${scope}_transactions_$stamp.xlsx';
  }

  /// The sheet title, e.g. "Household transactions · Our Home".
  static String title(ViewScope view, {String? householdName}) {
    if (view == ViewScope.personal) return 'Personal transactions';
    final name = householdName?.trim() ?? '';
    return name.isEmpty
        ? 'Household transactions'
        : 'Household transactions · $name';
  }

  /// [transactions] must all belong to [view]. The sheet lists them newest
  /// first; rows on the same day keep the order they were given in.
  static Uint8List build({
    required List<ExportTransaction> transactions,
    required ViewScope view,
    String? householdName,
    required String currencyCode,
    required DateTime exportedAt,
  }) {
    return create(
      transactions: transactions,
      view: view,
      householdName: householdName,
      currencyCode: currencyCode,
      exportedAt: exportedAt,
    ).encode(created: exportedAt);
  }

  /// The workbook before encoding (exposed for tests).
  static XlsxWorkbook create({
    required List<ExportTransaction> transactions,
    required ViewScope view,
    String? householdName,
    required String currencyCode,
    required DateTime exportedAt,
  }) {
    final household = view == ViewScope.shared;
    assert(
      transactions.every((t) => t.isShared == household),
      'Personal and household transactions are never exported together',
    );
    // Newest first; same-day rows keep their given order (List.sort is
    // not stable, so the index breaks ties).
    final indexed = transactions.indexed.toList()
      ..sort((a, b) {
        final byDate = b.$2.date.compareTo(a.$2.date);
        return byDate != 0 ? byDate : a.$1.compareTo(b.$1);
      });
    final rows = [for (final (_, t) in indexed) t];
    final styles = _Styles(currencyCode);
    final exported = DateFormat('d MMM yyyy, HH:mm').format(exportedAt);
    final heading = title(view, householdName: householdName);

    final book = XlsxWorkbook(
      title: '${AppConstants.appName} · $heading',
      creator: AppConstants.appName,
    );
    _transactionsSheet(
      book.addSheet(view.label),
      title: heading,
      rows: rows,
      showAddedBy: household,
      styles: styles,
      exported: exported,
    );
    _summarySheet(
      book.addSheet('Summary'),
      title: '${view.label} summary',
      rows: rows,
      styles: styles,
      exported: exported,
    );
    return book;
  }

  static String _subtitle(String exported, List<ExportTransaction> rows) {
    final parts = [AppConstants.appName, 'Exported $exported'];
    if (rows.isNotEmpty) {
      final f = DateFormat('d MMM yyyy');
      parts.add('${f.format(rows.last.date)} – ${f.format(rows.first.date)}');
      parts.add('${rows.length} transaction${rows.length == 1 ? '' : 's'}');
    }
    return parts.join('  ·  ');
  }

  static void _transactionsSheet(
    XlsxSheet sheet, {
    required String title,
    required List<ExportTransaction> rows,
    required bool showAddedBy,
    required _Styles styles,
    required String exported,
  }) {
    final headers = [
      'Date',
      'Type',
      'Category',
      'Description',
      'Payment method',
      if (showAddedBy) 'Added by',
      'Amount (${styles.currency})',
    ];
    final columns = headers.length;
    final last = columns - 1;

    sheet
      ..showGridLines = false
      ..landscape = true;

    // Title block.
    sheet.addRow([XlsxCell.text(title, styles.title)], height: 30);
    sheet.merge(0, 0, last);
    sheet.addRow([
      XlsxCell.text(_subtitle(exported, rows), styles.subtitle),
    ], height: 18);
    sheet.merge(1, 0, last);
    sheet.addRow([], height: 10);

    // Summary cards: income, expenses, net, spread over the columns.
    var income = 0;
    var expenses = 0;
    for (final t in rows) {
      if (t.isIncome) {
        income += t.amountMinor;
      } else {
        expenses += t.amountMinor;
      }
    }
    final net = income - expenses;
    final cards = [
      ('TOTAL INCOME', income, styles.cardIncome),
      ('TOTAL EXPENSES', expenses, styles.cardExpense),
      ('NET BALANCE', net, net < 0 ? styles.cardExpense : styles.cardNet),
    ];
    final spans = _split(columns, cards.length);
    final labelRow = List<XlsxCell?>.filled(columns, null);
    final valueRow = List<XlsxCell?>.filled(columns, null);
    for (var i = 0; i < cards.length; i++) {
      final (start, end) = spans[i];
      for (var c = start; c <= end; c++) {
        labelRow[c] = XlsxCell.blank(styles.cardLabel);
        valueRow[c] = XlsxCell.blank(styles.cardNet);
      }
      labelRow[start] = XlsxCell.text(cards[i].$1, styles.cardLabel);
      valueRow[start] = XlsxCell.number(
        Money.toInputString(cards[i].$2),
        cards[i].$3,
      );
    }
    final labelIndex = sheet.addRow(labelRow, height: 20);
    final valueIndex = sheet.addRow(valueRow, height: 30);
    for (final (start, end) in spans) {
      sheet
        ..merge(labelIndex, start, end)
        ..merge(valueIndex, start, end);
    }
    sheet.addRow([], height: 14);

    // Table.
    final headerIndex = sheet.addRow([
      for (var c = 0; c < columns; c++)
        XlsxCell.text(
          headers[c],
          c == last
              ? styles.header.copyWith(align: XlsxAlign.right)
              : styles.header,
        ),
    ], height: 24);
    sheet
      ..frozenRows = headerIndex + 1
      ..printTitleRow = headerIndex;

    if (rows.isEmpty) {
      final index = sheet.addRow([
        XlsxCell.text('No transactions yet', styles.empty),
      ], height: 28);
      sheet.merge(index, 0, last);
    } else {
      for (var i = 0; i < rows.length; i++) {
        final t = rows[i];
        final band = i.isOdd;
        final base = band ? styles.bandCell : styles.cell;
        sheet.addRow([
          XlsxCell.date(
            t.date,
            base.copyWith(numberFormat: _Styles.dateFormat),
          ),
          XlsxCell.text(
            t.type.label,
            base.copyWith(fontColor: t.isIncome ? _Styles.green : _Styles.red),
          ),
          XlsxCell.text(t.category, base),
          XlsxCell.text(t.note, base),
          XlsxCell.text(t.paymentMethod, base),
          if (showAddedBy) XlsxCell.text(t.addedBy ?? '', base),
          XlsxCell.number(
            Money.toInputString(t.signedMinor),
            base.copyWith(
              numberFormat: _Styles.signedMoney,
              align: XlsxAlign.right,
              fontColor: t.isIncome ? _Styles.green : _Styles.red,
              bold: true,
            ),
          ),
        ], height: 20);
      }
      sheet.autoFilter =
          '${XlsxSheet.cellRef(headerIndex, 0)}:'
          '${XlsxSheet.cellRef(headerIndex + rows.length, last)}';
    }

    // Column widths sized to the content, within sensible bounds.
    double fit(Iterable<String> values, double min, double max) {
      var longest = 0;
      for (final v in values) {
        if (v.length > longest) longest = v.length;
      }
      return (longest + 3).clamp(min, max).toDouble();
    }

    final widths = [
      14.0,
      11.0,
      fit(rows.map((t) => t.category), 16, 30),
      fit(rows.map((t) => t.note), 24, 50),
      16.0,
      if (showAddedBy) fit(rows.map((t) => t.addedBy ?? ''), 14, 26),
      18.0,
    ];
    for (var c = 0; c < widths.length; c++) {
      sheet.columnWidths[c] = widths[c];
    }
  }

  static void _summarySheet(
    XlsxSheet sheet, {
    required String title,
    required List<ExportTransaction> rows,
    required _Styles styles,
    required String exported,
  }) {
    const columns = 5;
    sheet
      ..showGridLines = false
      ..landscape = false;
    sheet.addRow([XlsxCell.text(title, styles.title)], height: 30);
    sheet.merge(0, 0, columns - 1);
    sheet.addRow([
      XlsxCell.text(
        '${AppConstants.appName}  ·  Exported $exported  ·  '
        'Amounts in ${styles.currency}',
        styles.subtitle,
      ),
    ], height: 18);
    sheet.merge(1, 0, columns - 1);

    // Month by month, newest first.
    sheet.addRow([], height: 14);
    final heading = sheet.addRow([
      XlsxCell.text('Month by month', styles.section),
    ], height: 22);
    sheet.merge(heading, 0, columns - 1);
    _headerRow(sheet, styles, [
      'Month',
      'Income',
      'Expenses',
      'Net',
      'Transactions',
    ]);

    final months = <DateTime, _Totals>{};
    for (final t in rows) {
      months
          .putIfAbsent(DateTime(t.date.year, t.date.month), _Totals.new)
          .add(t);
    }
    final keys = months.keys.toList()..sort((a, b) => b.compareTo(a));
    final total = _Totals();
    if (keys.isEmpty) _emptyRow(sheet, styles, columns);
    for (var i = 0; i < keys.length; i++) {
      final m = months[keys[i]]!;
      total.merge(m);
      final base = i.isOdd ? styles.bandCell : styles.cell;
      sheet.addRow([
        XlsxCell.date(
          keys[i],
          base.copyWith(numberFormat: _Styles.monthFormat),
        ),
        _money(m.income, base, _Styles.green),
        _money(m.expenses, base, _Styles.red),
        XlsxCell.number(
          Money.toInputString(m.net),
          base.copyWith(
            numberFormat: _Styles.signedMoney,
            align: XlsxAlign.right,
            bold: true,
            fontColor: m.net < 0 ? _Styles.red : _Styles.ink,
          ),
        ),
        XlsxCell.integer(m.count, base.copyWith(align: XlsxAlign.center)),
      ], height: 20);
    }
    if (keys.isNotEmpty) {
      sheet.addRow([
        XlsxCell.text('Total', styles.total),
        _money(total.income, styles.total, _Styles.green),
        _money(total.expenses, styles.total, _Styles.red),
        XlsxCell.number(
          Money.toInputString(total.net),
          styles.total.copyWith(
            numberFormat: _Styles.signedMoney,
            align: XlsxAlign.right,
            fontColor: total.net < 0 ? _Styles.red : _Styles.ink,
          ),
        ),
        XlsxCell.integer(
          total.count,
          styles.total.copyWith(align: XlsxAlign.center),
        ),
      ], height: 22);
    }

    // Spending by category, largest first.
    sheet.addRow([], height: 14);
    final catHeading = sheet.addRow([
      XlsxCell.text('Spending by category', styles.section),
    ], height: 22);
    sheet.merge(catHeading, 0, columns - 1);
    _headerRow(sheet, styles, ['Category', 'Spent', 'Share', 'Transactions']);

    final spent = <String, (int, int)>{};
    for (final t in rows.where((t) => !t.isIncome)) {
      final (amount, count) = spent[t.category] ?? (0, 0);
      spent[t.category] = (amount + t.amountMinor, count + 1);
    }
    final categories = spent.entries.toList()
      ..sort((a, b) {
        final byAmount = b.value.$1.compareTo(a.value.$1);
        return byAmount != 0 ? byAmount : a.key.compareTo(b.key);
      });
    final totalSpent = categories.fold<int>(0, (s, e) => s + e.value.$1);
    final totalCount = categories.fold<int>(0, (s, e) => s + e.value.$2);
    if (categories.isEmpty) _emptyRow(sheet, styles, 4, 'No expenses yet');
    for (var i = 0; i < categories.length; i++) {
      final (amount, count) = categories[i].value;
      final base = i.isOdd ? styles.bandCell : styles.cell;
      sheet.addRow([
        XlsxCell.text(categories[i].key, base),
        _money(amount, base, _Styles.red),
        XlsxCell.number(
          _ratio(amount, totalSpent),
          base.copyWith(numberFormat: _Styles.percent, align: XlsxAlign.right),
        ),
        XlsxCell.integer(count, base.copyWith(align: XlsxAlign.center)),
      ], height: 20);
    }
    if (categories.isNotEmpty) {
      sheet.addRow([
        XlsxCell.text('Total', styles.total),
        _money(totalSpent, styles.total, _Styles.red),
        XlsxCell.number(
          '1',
          styles.total.copyWith(
            numberFormat: _Styles.percent,
            align: XlsxAlign.right,
          ),
        ),
        XlsxCell.integer(
          totalCount,
          styles.total.copyWith(align: XlsxAlign.center),
        ),
      ], height: 22);
    }

    final categoryNames = rows.map((t) => t.category);
    var longest = 0;
    for (final n in categoryNames) {
      if (n.length > longest) longest = n.length;
    }
    sheet.columnWidths
      ..[0] = (longest + 3).clamp(18, 32).toDouble()
      ..[1] = 18
      ..[2] = 18
      ..[3] = 18
      ..[4] = 14;
  }

  static void _headerRow(XlsxSheet sheet, _Styles styles, List<String> labels) {
    sheet.addRow([
      for (var c = 0; c < labels.length; c++)
        XlsxCell.text(
          labels[c],
          c == 0
              ? styles.header
              : styles.header.copyWith(
                  align: labels[c] == 'Transactions'
                      ? XlsxAlign.center
                      : XlsxAlign.right,
                ),
        ),
    ], height: 22);
  }

  static void _emptyRow(
    XlsxSheet sheet,
    _Styles styles,
    int columns, [
    String text = 'No transactions yet',
  ]) {
    final index = sheet.addRow([XlsxCell.text(text, styles.empty)], height: 24);
    sheet.merge(index, 0, columns - 1);
  }

  static XlsxCell _money(int minor, XlsxStyle base, String color) {
    return XlsxCell.number(
      Money.toInputString(minor),
      base.copyWith(
        numberFormat: _Styles.money,
        align: XlsxAlign.right,
        fontColor: minor == 0 ? _Styles.muted : color,
      ),
    );
  }

  /// [part] / [whole] as a decimal literal with 4 places (0.0% format).
  static String _ratio(int part, int whole) {
    if (whole == 0) return '0';
    return (part / whole).toStringAsFixed(4);
  }

  /// Splits [columns] into [parts] contiguous, near-equal (start, end)
  /// column ranges.
  static List<(int, int)> _split(int columns, int parts) {
    final result = <(int, int)>[];
    var start = 0;
    for (var i = 0; i < parts; i++) {
      final size = (columns - start) ~/ (parts - i);
      result.add((start, start + size - 1));
      start += size;
    }
    return result;
  }
}

class _Totals {
  int income = 0;
  int expenses = 0;
  int count = 0;

  int get net => income - expenses;

  void add(ExportTransaction t) {
    if (t.isIncome) {
      income += t.amountMinor;
    } else {
      expenses += t.amountMinor;
    }
    count++;
  }

  void merge(_Totals other) {
    income += other.income;
    expenses += other.expenses;
    count += other.count;
  }
}

/// The workbook's palette and cell styles, matching the app's teal theme.
class _Styles {
  _Styles(String currencyCode)
    : currency = currencyCode.replaceAll(RegExp('[^A-Za-z]'), '');

  final String currency;

  static const teal = '0F766E';
  static const tealSoft = 'E6F2F1';
  static const ink = '1F2937';
  static const muted = '6B7280';
  static const green = '15803D';
  static const red = 'B91C1C';
  static const line = 'DDE3E2';
  static const band = 'F6F8F8';

  static const dateFormat = 'dd mmm yyyy';
  static const monthFormat = 'mmmm yyyy';
  static const money = '#,##0.00';
  static const signedMoney = '+#,##0.00;-#,##0.00;0.00';
  static const percent = '0.0%';

  String get _cardMoney => '"$currency "#,##0.00;-"$currency "#,##0.00';

  final title = const XlsxStyle(bold: true, fontSize: 18, fontColor: teal);
  final subtitle = const XlsxStyle(
    italic: true,
    fontSize: 10,
    fontColor: muted,
  );
  final section = const XlsxStyle(
    bold: true,
    fontSize: 13,
    fontColor: teal,
    borderBottom: teal,
  );
  final header = const XlsxStyle(
    bold: true,
    fontColor: 'FFFFFF',
    fill: teal,
    indent: 1,
  );
  final cell = const XlsxStyle(fontColor: ink, indent: 1, borderBottom: line);
  final bandCell = const XlsxStyle(
    fontColor: ink,
    fill: band,
    indent: 1,
    borderBottom: line,
  );
  final total = const XlsxStyle(
    bold: true,
    fontColor: ink,
    fill: tealSoft,
    indent: 1,
    borderTop: teal,
    borderBottom: teal,
  );
  final empty = const XlsxStyle(
    italic: true,
    fontColor: muted,
    align: XlsxAlign.center,
  );
  final cardLabel = const XlsxStyle(
    bold: true,
    fontSize: 9,
    fontColor: muted,
    fill: tealSoft,
    indent: 1,
  );

  XlsxStyle _card(String color) => XlsxStyle(
    bold: true,
    fontSize: 15,
    fontColor: color,
    fill: tealSoft,
    numberFormat: _cardMoney,
    indent: 1,
  );

  XlsxStyle get cardIncome => _card(green);
  XlsxStyle get cardExpense => _card(red);
  XlsxStyle get cardNet => _card(teal);
}
