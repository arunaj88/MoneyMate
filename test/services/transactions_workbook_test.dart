import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_mate/core/services/transactions_workbook.dart';
import 'package:money_mate/core/utils/xlsx_writer.dart';
import 'package:money_mate/models/scope_models.dart';
import 'package:money_mate/models/transaction_model.dart';

ExportTransaction _t(
  DateTime date,
  int amountMinor, {
  TransactionType type = TransactionType.expense,
  String category = 'Food',
  String note = '',
  bool shared = false,
  String? addedBy,
}) => ExportTransaction(
  date: date,
  type: type,
  category: category,
  amountMinor: amountMinor,
  paymentMethod: 'Card',
  note: note,
  isShared: shared,
  addedBy: addedBy,
);

/// Text or number values of a sheet's cells, row by row.
List<List<String?>> _values(XlsxSheet sheet) => [
  for (final row in sheet.rows) [for (final c in row) c?.value],
];

void main() {
  final exportedAt = DateTime(2026, 11, 26, 14, 30);

  group('TransactionsWorkbook', () {
    test('personal sheet: title, totals, header and newest-first rows', () {
      final book = TransactionsWorkbook.create(
        transactions: [
          _t(
            DateTime(2026, 10, 1),
            500000,
            type: TransactionType.income,
            category: 'Salary',
          ),
          _t(DateTime(2026, 11, 5), 1234, note: 'Lunch'),
          _t(DateTime(2026, 11, 5), 200, note: 'Coffee'),
        ],
        view: ViewScope.personal,
        currencyCode: 'AED',
        exportedAt: exportedAt,
      );
      expect(book.sheets.map((s) => s.name), ['Personal', 'Summary']);

      final sheet = book.sheets.first;
      final values = _values(sheet);
      expect(values[0].first, 'Personal transactions');
      expect(values[1].first, contains('3 transactions'));
      expect(values[1].first, contains('1 Oct 2026 – 5 Nov 2026'));
      // Cards: income, expenses, net.
      expect(values[4].whereType<String>().where((v) => v.isNotEmpty), [
        '5000.00',
        '14.34',
        '4985.66',
      ]);
      expect(values[6], [
        'Date',
        'Type',
        'Category',
        'Description',
        'Payment method',
        'Amount (AED)',
      ]);
      // Same-day rows keep their order; amounts are signed.
      expect(values[7].sublist(1), [
        'Expense',
        'Food',
        'Lunch',
        'Card',
        '-12.34',
      ]);
      expect(values[8][3], 'Coffee');
      expect(values[9].sublist(1), ['Income', 'Salary', '', 'Card', '5000.00']);
      expect(sheet.frozenRows, 7);
      expect(sheet.autoFilter, 'A7:F10');
      expect(sheet.showGridLines, isFalse);
    });

    test('household export: own title, file name and who added each', () {
      final book = TransactionsWorkbook.create(
        transactions: [
          _t(DateTime(2026, 11, 3), 2500, shared: true, addedBy: 'Priya'),
        ],
        view: ViewScope.shared,
        householdName: 'Our Home',
        currencyCode: 'AED',
        exportedAt: exportedAt,
      );
      expect(book.sheets.map((s) => s.name), ['Household', 'Summary']);
      final household = _values(book.sheets.first);
      expect(household[0].first, 'Household transactions · Our Home');
      expect(household[6], contains('Added by'));
      expect(household[7], contains('Priya'));
      expect(_values(book.sheets.last)[0].first, 'Household summary');
      expect(
        TransactionsWorkbook.fileName(exportedAt, view: ViewScope.shared),
        'moneymate_household_transactions_20261126_143000.xlsx',
      );
      expect(
        TransactionsWorkbook.fileName(exportedAt, view: ViewScope.personal),
        'moneymate_personal_transactions_20261126_143000.xlsx',
      );
    });

    test('summary has monthly totals and category shares per scope', () {
      final book = TransactionsWorkbook.create(
        transactions: [
          _t(DateTime(2026, 11, 2), 3000, category: 'Rent'),
          _t(DateTime(2026, 11, 9), 1000, category: 'Food'),
          _t(
            DateTime(2026, 10, 9),
            10000,
            type: TransactionType.income,
            category: 'Salary',
          ),
        ],
        view: ViewScope.personal,
        currencyCode: 'AED',
        exportedAt: exportedAt,
      );
      final rows = _values(book.sheets.last);
      final flat = rows.map((r) => r.join('|')).toList();
      expect(flat, contains('Month by month'));
      expect(rows[0].first, 'Personal summary');
      // November then October, then the total.
      final nov = flat.indexWhere((r) => r.endsWith('|0.00|40.00|-40.00|2'));
      final oct = flat.indexWhere((r) => r.endsWith('|100.00|0.00|100.00|1'));
      expect(nov, greaterThan(0));
      expect(oct, nov + 1);
      expect(flat[oct + 1], 'Total|100.00|40.00|60.00|3');
      expect(
        flat,
        containsAllInOrder([
          'Rent|30.00|0.7500|1',
          'Food|10.00|0.2500|1',
          'Total|40.00|1|2',
        ]),
      );
    });

    test('an empty export still has a readable sheet', () {
      final book = TransactionsWorkbook.create(
        transactions: const [],
        view: ViewScope.personal,
        currencyCode: 'AED',
        exportedAt: exportedAt,
      );
      final sheet = book.sheets.first;
      expect(_values(sheet).last.first, 'No transactions yet');
      expect(sheet.autoFilter, isNull);
    });

    test('encodes a valid xlsx package', () {
      final bytes = TransactionsWorkbook.build(
        transactions: [
          _t(DateTime(2026, 11, 5), 1234, note: 'Tom & "Jerry" <x>\u0001'),
        ],
        view: ViewScope.personal,
        currencyCode: 'AED',
        exportedAt: exportedAt,
      );
      final archive = ZipDecoder().decodeBytes(bytes);
      String file(String name) => utf8.decode(archive.findFile(name)!.content);

      expect(
        archive.files.map((f) => f.name),
        containsAll([
          '[Content_Types].xml',
          '_rels/.rels',
          'xl/workbook.xml',
          'xl/_rels/workbook.xml.rels',
          'xl/styles.xml',
          'xl/worksheets/sheet1.xml',
          'xl/worksheets/sheet2.xml',
        ]),
      );
      final sheet = file('xl/worksheets/sheet1.xml');
      expect(sheet, contains('Tom &amp; &quot;Jerry&quot; &lt;x&gt;</t>'));
      expect(sheet, isNot(contains('\u0001')));
      // 5 Nov 2026 as an Excel date serial.
      expect(sheet, contains('<v>46331</v>'));
      expect(sheet, contains('<pane ySplit="7"'));
      expect(sheet, contains('<autoFilter ref="A7:F8"/>'));
      expect(
        file('xl/workbook.xml'),
        contains(
          "_xlnm._FilterDatabase\" localSheetId=\"0\" hidden=\"1\">"
          "'Personal'!\$A\$7:\$F\$8",
        ),
      );
      final styles = file('xl/styles.xml');
      expect(styles, contains('formatCode="dd mmm yyyy"'));
      expect(styles, contains('<fgColor rgb="FF0F766E"/>'));
    });
  });

  group('XlsxSheet', () {
    test('column letters', () {
      expect(XlsxSheet.columnLetter(0), 'A');
      expect(XlsxSheet.columnLetter(25), 'Z');
      expect(XlsxSheet.columnLetter(26), 'AA');
      expect(XlsxSheet.columnLetter(701), 'ZZ');
      expect(XlsxSheet.columnLetter(702), 'AAA');
    });

    test('rejects invalid sheet names', () {
      expect(() => XlsxSheet('a/b'), throwsArgumentError);
      expect(() => XlsxSheet(''), throwsArgumentError);
    });
  });
}
