import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'package:money_mate/core/services/loan_statement.dart';
import 'package:money_mate/models/loan_model.dart';

/// Lays out a [LoanStatement] as an A4 PDF.
///
/// Everything is drawn locally with the PDF standard fonts, so it works
/// offline and looks the same on Android and iOS. Long schedules flow over
/// as many pages as needed, with the table headings repeated on each page.
class LoanStatementPdf {
  LoanStatementPdf._();

  /// Page limit (a 50-year schedule plus its history fits comfortably).
  static const int maxPages = 200;

  static const PdfColor _brand = PdfColor.fromInt(0xFF0F766E);
  static const PdfColor _navy = PdfColor.fromInt(0xFF13294B);
  static const PdfColor _ink = PdfColor.fromInt(0xFF1E293B);
  static const PdfColor _muted = PdfColor.fromInt(0xFF64748B);
  static const PdfColor _line = PdfColor.fromInt(0xFFE2E8F0);
  static const PdfColor _panel = PdfColor.fromInt(0xFFF1F5F9);
  static const PdfColor _brandTint = PdfColor.fromInt(0xFFE6F4F2);

  /// Status colours: text and row tint.
  static (PdfColor, PdfColor?) _statusColors(InstallmentStatus status) =>
      switch (status) {
        InstallmentStatus.paid => (
          const PdfColor.fromInt(0xFF15803D),
          const PdfColor.fromInt(0xFFEAF7EF),
        ),
        InstallmentStatus.overdue => (
          const PdfColor.fromInt(0xFFB91C1C),
          const PdfColor.fromInt(0xFFFDEDED),
        ),
        InstallmentStatus.partiallyPaid => (
          const PdfColor.fromInt(0xFFA16207),
          const PdfColor.fromInt(0xFFFEF7E0),
        ),
        InstallmentStatus.due => (
          const PdfColor.fromInt(0xFFC2410C),
          const PdfColor.fromInt(0xFFFFF3E8),
        ),
        InstallmentStatus.upcoming => (_muted, null),
      };

  static (PdfColor, PdfColor) _loanStatusColors(LoanStatus status) =>
      switch (status) {
        LoanStatus.completed => (
          const PdfColor.fromInt(0xFF15803D),
          const PdfColor.fromInt(0xFFEAF7EF),
        ),
        LoanStatus.overdue => (
          const PdfColor.fromInt(0xFFB91C1C),
          const PdfColor.fromInt(0xFFFDEDED),
        ),
        LoanStatus.active => (_brand, _brandTint),
      };

  /// The PDF file of [statement]. [logoSvg] is the app icon (the brand
  /// mark is drawn without it).
  static Future<Uint8List> build(
    LoanStatement statement, {
    String? logoSvg,
    bool compress = true,
  }) {
    final doc = pw.Document(
      compress: compress,
      title: 'Loan statement ${statement.reference}',
      author: statement.lenderName.isEmpty ? 'MoneyMate' : statement.lenderName,
      creator: 'MoneyMate',
      subject: 'Loan statement for ${statement.borrowerName}',
    );
    final s = _Builder(statement, logoSvg);
    doc.addPage(
      pw.MultiPage(
        maxPages: maxPages,
        pageTheme: pw.PageTheme(
          pageFormat: PdfPageFormat.a4,
          margin: const pw.EdgeInsets.fromLTRB(32, 28, 32, 28),
          theme:
              pw.ThemeData.withFont(
                base: pw.Font.helvetica(),
                bold: pw.Font.helveticaBold(),
                italic: pw.Font.helveticaOblique(),
              ).copyWith(
                defaultTextStyle: const pw.TextStyle(fontSize: 9, color: _ink),
              ),
        ),
        header: s.header,
        footer: s.footer,
        build: (_) => s.body(),
      ),
    );
    return doc.save();
  }

  /// Text the standard fonts can draw: common typographic characters are
  /// replaced with plain ones; anything else outside Latin-1 becomes "?".
  static String safe(String text) {
    const map = {
      0x2018: "'", 0x2019: "'", 0x201A: "'", 0x201B: "'", //
      0x201C: '"', 0x201D: '"', 0x201E: '"', //
      0x2013: '-', 0x2014: '-', 0x2212: '-', //
      0x2026: '...', 0x2022: '*', 0x00A0: ' ', 0x202F: ' ', //
    };
    final out = StringBuffer();
    for (final rune in text.runes) {
      final mapped = map[rune];
      if (mapped != null) {
        out.write(mapped);
      } else if (rune == 0x0A || (rune >= 0x20 && rune <= 0xFF)) {
        out.writeCharCode(rune);
      } else if (rune == 0x09) {
        out.write(' ');
      } else {
        out.write('?');
      }
    }
    return out.toString();
  }
}

class _Builder {
  _Builder(this.s, this.logoSvg);

  final LoanStatement s;
  final String? logoSvg;

  static const _brand = LoanStatementPdf._brand;
  static const _navy = LoanStatementPdf._navy;
  static const _muted = LoanStatementPdf._muted;
  static const _line = LoanStatementPdf._line;
  static const _panel = LoanStatementPdf._panel;
  static const _brandTint = LoanStatementPdf._brandTint;

  String _t(String text) => LoanStatementPdf.safe(text);
  String _date(DateTime? d) =>
      d == null ? '-' : LoanStatement.shortDate.format(d);
  String _long(DateTime? d) =>
      d == null ? '-' : LoanStatement.longDate.format(d);
  String _amt(int? minor) => minor == null ? '-' : LoanStatement.amount(minor);

  pw.Text _text(
    String text, {
    double size = 9,
    bool bold = false,
    PdfColor? color,
    pw.TextAlign? align,
  }) => pw.Text(
    _t(text),
    textAlign: align,
    style: pw.TextStyle(
      fontSize: size,
      fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal,
      color: color,
    ),
  );

  // ------------------------------------------------------------ header

  pw.Widget _logo(double size) {
    final svg = logoSvg;
    if (svg != null && svg.isNotEmpty) {
      return pw.ClipRRect(
        horizontalRadius: size * 0.22,
        verticalRadius: size * 0.22,
        child: pw.SvgImage(svg: svg, width: size, height: size),
      );
    }
    return pw.Container(
      width: size,
      height: size,
      alignment: pw.Alignment.center,
      decoration: pw.BoxDecoration(
        color: _navy,
        borderRadius: pw.BorderRadius.circular(size * 0.22),
      ),
      child: pw.Text(
        'M',
        style: pw.TextStyle(
          color: PdfColors.white,
          fontSize: size * 0.55,
          fontWeight: pw.FontWeight.bold,
        ),
      ),
    );
  }

  pw.Widget header(pw.Context context) {
    if (context.pageNumber > 1) {
      return pw.Container(
        margin: const pw.EdgeInsets.only(bottom: 10),
        padding: const pw.EdgeInsets.only(bottom: 6),
        decoration: const pw.BoxDecoration(
          border: pw.Border(bottom: pw.BorderSide(color: _line)),
        ),
        child: pw.Row(
          children: [
            _logo(14),
            pw.SizedBox(width: 6),
            _text('MoneyMate', bold: true, color: _navy),
            _text('  |  Loan statement ${s.reference}', color: _muted),
            pw.Spacer(),
            _text(s.borrowerName, color: _muted),
          ],
        ),
      );
    }
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.stretch,
      children: [
        pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.center,
          children: [
            _logo(38),
            pw.SizedBox(width: 10),
            pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                _text('MoneyMate', size: 18, bold: true, color: _navy),
                _text('Loan Statement & Repayment Schedule', color: _muted),
              ],
            ),
            pw.Spacer(),
            pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.end,
              children: [
                _text('Reference', size: 8, color: _muted),
                _text(s.reference, size: 11, bold: true),
                pw.SizedBox(height: 2),
                _text('Generated ${s.generatedLabel}', size: 8, color: _muted),
              ],
            ),
          ],
        ),
        pw.SizedBox(height: 10),
        pw.Container(
          padding: const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: pw.BoxDecoration(
            color: _brandTint,
            borderRadius: pw.BorderRadius.circular(4),
          ),
          child: pw.Row(
            children: [
              _text('LATEST SCHEDULE', size: 8, bold: true, color: _brand),
              pw.SizedBox(width: 8),
              pw.Expanded(
                child: _text(
                  'This statement reflects all repayments recorded up to '
                  '${s.generatedLabel} and replaces any statement shared '
                  'earlier.',
                  size: 8,
                  color: _brand,
                ),
              ),
            ],
          ),
        ),
        pw.SizedBox(height: 14),
      ],
    );
  }

  pw.Widget footer(pw.Context context) => pw.Container(
    margin: const pw.EdgeInsets.only(top: 10),
    padding: const pw.EdgeInsets.only(top: 6),
    decoration: const pw.BoxDecoration(
      border: pw.Border(top: pw.BorderSide(color: _line)),
    ),
    child: pw.Row(
      children: [
        pw.Expanded(
          child: _text(
            'Generated by MoneyMate from the lender\'s records on '
            '${s.generatedLabel}. Amounts in ${s.currencyCode}.',
            size: 7,
            color: _muted,
          ),
        ),
        _text(
          'Page ${context.pageNumber} of ${context.pagesCount}',
          size: 7,
          color: _muted,
        ),
      ],
    ),
  );

  // ------------------------------------------------------------ body

  List<pw.Widget> body() => [
    _parties(),
    pw.SizedBox(height: 14),
    _section('A. Loan agreement', 'The terms agreed when the money was lent.'),
    _keyValues([
      ('Lending date', _long(s.lentDate)),
      ('Loan amount', s.money(s.principalMinor)),
      ('Repayment type', s.repaymentType.label),
      ('Interest rate', s.interestLabel),
      if (s.hasInterest && s.interestMethodLabel != null)
        ('Interest calculation', s.interestMethodLabel!),
      ('Original repayment period', s.originalPeriodLabel),
      if (s.isMonthly && s.originalEmiMinor != null)
        ('Original agreed EMI', s.money(s.originalEmiMinor!)),
      if (s.hasInterest)
        ('Agreed total interest', s.money(s.originalInterestMinor)),
      (
        s.isMonthly ? 'Expected final repayment' : 'Expected repayment date',
        _long(s.originalFinalDueDate),
      ),
    ]),
    if (s.notes != null) ...[
      pw.SizedBox(height: 8),
      pw.Container(
        width: double.infinity,
        padding: const pw.EdgeInsets.all(8),
        decoration: pw.BoxDecoration(
          color: _panel,
          borderRadius: pw.BorderRadius.circular(4),
        ),
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            _text('Notes and terms', size: 8, bold: true, color: _muted),
            pw.SizedBox(height: 3),
            _text(s.notes!),
          ],
        ),
      ),
    ],
    pw.SizedBox(height: 16),
    _section(
      'B. Current repayment summary',
      'Where the loan stands today, after every recorded repayment.',
    ),
    _highlights(),
    pw.SizedBox(height: 8),
    _keyValues([
      ('Original loan capital', s.money(s.principalMinor)),
      ('Total principal repaid', s.money(s.principalRepaidMinor)),
      if (s.isMonthly)
        ('Extra principal repayments', s.money(s.extraPrincipalMinor)),
      ('Total interest received', s.money(s.interestReceivedMinor)),
      ('Outstanding principal', s.money(s.outstandingPrincipalMinor)),
      if (s.outstandingMinor != s.outstandingPrincipalMinor)
        ('Total outstanding (incl. interest)', s.money(s.outstandingMinor)),
      if (s.isMonthly)
        (
          s.emiRevised ? 'Current revised EMI' : 'Current EMI',
          s.currentEmiMinor == null ? '-' : s.money(s.currentEmiMinor!),
        ),
      if (s.isMonthly)
        (
          'Instalments completed',
          '${s.completedInstallments} of ${s.totalInstallments}',
        ),
      if (s.isMonthly) ('Instalments remaining', '${s.remainingInstallments}'),
      (
        s.isMonthly ? 'Next EMI amount' : 'Amount due',
        s.nextAmountMinor == null ? '-' : s.money(s.nextAmountMinor!),
      ),
      ('Next due date', _long(s.nextDueDate)),
      if (s.overdueMinor > 0) ('Overdue amount', s.money(s.overdueMinor)),
      (
        'Loan status',
        s.isCompleted ? 'Completed (repaid in full)' : s.status.label,
      ),
    ]),
    if (s.isMonthly) ...[pw.SizedBox(height: 10), _comparison()],
    pw.SizedBox(height: 16),
    _section(
      s.isMonthly ? 'C. Repayment schedule' : 'C. Expected repayment',
      s.isMonthly
          ? 'Every instalment with its current amounts. Amounts in '
                '${s.currencyCode}.'
          : 'Amounts in ${s.currencyCode}.',
    ),
    _legend(),
    pw.SizedBox(height: 4),
    _scheduleTable(),
    if (s.revisions.isNotEmpty) ...[
      pw.SizedBox(height: 6),
      _text(
        '* Revised EMI effective from this instalment after an extra '
        'capital repayment (see section D).',
        size: 7.5,
        color: _muted,
      ),
    ],
    if (s.isMonthly) ...[
      pw.SizedBox(height: 16),
      _section(
        'D. EMI revision history',
        'Payments above the EMI go straight to capital; the remaining '
            'instalments are then recalculated over the same months.',
      ),
      if (s.revisions.isEmpty)
        _text('The EMI has not been revised.', color: _muted)
      else
        _revisionTable(),
    ],
    pw.SizedBox(height: 16),
    _section(
      s.isMonthly ? 'E. Repayment history' : 'D. Repayment history',
      'Every repayment recorded, oldest first. Amounts in '
      '${s.currencyCode}.',
    ),
    if (s.repayments.isEmpty)
      _text('No repayments have been recorded yet.', color: _muted)
    else
      _historyTable(),
    if (s.repayments.any((r) => r.voided)) ...[
      pw.SizedBox(height: 6),
      _text(
        'Voided repayments were recorded by mistake and are not counted.',
        size: 7.5,
        color: _muted,
      ),
    ],
    pw.SizedBox(height: 18),
    _text(
      'This statement is generated from the lender\'s MoneyMate records and '
      'is provided for information. A statement shared earlier is not '
      'updated automatically; this one shows the latest schedule as of its '
      'generation date. Please contact the lender about any difference.',
      size: 7.5,
      color: _muted,
    ),
  ];

  pw.Widget _section(String title, String subtitle) => pw.Padding(
    padding: const pw.EdgeInsets.only(bottom: 6),
    child: pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        _text(title, size: 12, bold: true, color: _navy),
        pw.SizedBox(height: 1),
        _text(subtitle, size: 8, color: _muted),
      ],
    ),
  );

  pw.Widget _parties() {
    pw.Widget party(String role, String name, List<String> extra) =>
        pw.Expanded(
          child: pw.Container(
            padding: const pw.EdgeInsets.all(10),
            decoration: pw.BoxDecoration(
              border: pw.Border.all(color: _line),
              borderRadius: pw.BorderRadius.circular(4),
            ),
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                _text(role.toUpperCase(), size: 7.5, bold: true, color: _muted),
                pw.SizedBox(height: 3),
                _text(name, size: 11, bold: true),
                for (final line in extra) ...[
                  pw.SizedBox(height: 2),
                  _text(line, size: 8.5, color: _muted),
                ],
              ],
            ),
          ),
        );
    return pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        party('Lender', s.lenderName.isEmpty ? '-' : s.lenderName, const []),
        pw.SizedBox(width: 10),
        party('Borrower', s.borrowerName, [
          if (s.borrowerPhone != null) 'Phone: ${s.borrowerPhone}',
          if (s.borrowerEmail != null) 'Email: ${s.borrowerEmail}',
        ]),
      ],
    );
  }

  /// Label / value pairs in two columns.
  pw.Widget _keyValues(List<(String, String)> items) {
    final half = (items.length + 1) ~/ 2;
    pw.Widget column(Iterable<(String, String)> rows) => pw.Expanded(
      child: pw.Column(
        children: [
          for (final (label, value) in rows)
            pw.Container(
              padding: const pw.EdgeInsets.symmetric(vertical: 4),
              decoration: const pw.BoxDecoration(
                border: pw.Border(
                  bottom: pw.BorderSide(color: _line, width: 0.6),
                ),
              ),
              child: pw.Row(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Expanded(flex: 5, child: _text(label, color: _muted)),
                  pw.Expanded(
                    flex: 6,
                    child: _text(value, bold: true, align: pw.TextAlign.right),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
    return pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        column(items.take(half)),
        pw.SizedBox(width: 18),
        column(items.skip(half)),
      ],
    );
  }

  pw.Widget _highlights() {
    final (statusColor, statusTint) = LoanStatementPdf._loanStatusColors(
      s.status,
    );
    pw.Widget tile(
      String label,
      String value, {
      PdfColor? color,
      PdfColor? tint,
    }) => pw.Expanded(
      child: pw.Container(
        padding: const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: pw.BoxDecoration(
          color: tint ?? _panel,
          borderRadius: pw.BorderRadius.circular(4),
        ),
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            _text(label, size: 7.5, color: _muted),
            pw.SizedBox(height: 3),
            _text(value, size: 11, bold: true, color: color),
          ],
        ),
      ),
    );
    return pw.Row(
      children: [
        tile('Outstanding principal', s.money(s.outstandingPrincipalMinor)),
        pw.SizedBox(width: 8),
        tile(
          s.isCompleted
              ? 'Total repaid'
              : (s.isMonthly ? 'Next EMI' : 'Amount due'),
          s.isCompleted
              ? s.money(s.receivedMinor)
              : (s.nextAmountMinor == null ? '-' : s.money(s.nextAmountMinor!)),
        ),
        pw.SizedBox(width: 8),
        tile(
          s.isCompleted ? 'Completed' : 'Next due date',
          s.isCompleted
              ? '${s.completedInstallments} of ${s.totalInstallments} paid'
              : _date(s.nextDueDate),
        ),
        pw.SizedBox(width: 8),
        tile('Status', s.status.label, color: statusColor, tint: statusTint),
      ],
    );
  }

  /// Original agreement against the schedule as it is now.
  pw.Widget _comparison() {
    final rows = <(String, String, String)>[
      (
        'Monthly EMI',
        s.originalEmiMinor == null ? '-' : s.money(s.originalEmiMinor!),
        s.currentEmiMinor == null
            ? (s.isCompleted ? 'Repaid' : '-')
            : s.money(s.currentEmiMinor!),
      ),
      (
        'Number of instalments',
        s.originalTermMonths?.toString() ?? '-',
        '${s.totalInstallments}',
      ),
      (
        'Final repayment date',
        _long(s.originalFinalDueDate),
        _long(s.currentFinalDueDate),
      ),
      if (s.hasInterest)
        (
          'Total interest',
          s.money(s.originalInterestMinor),
          s.money(s.currentInterestMinor),
        ),
    ];
    return _table(
      widths: const [3, 3, 3],
      headings: ['', 'Original agreement', 'Current schedule'],
      align: const [false, true, true],
      rows: [
        for (final (label, original, current) in rows)
          _Row([
            _cell(label, color: _muted),
            _cell(original, align: true),
            _cell(
              current,
              align: true,
              bold: current != original,
              color: current != original ? _brand : null,
            ),
          ]),
      ],
    );
  }

  pw.Widget _legend() {
    pw.Widget item(InstallmentStatus status) {
      final (color, tint) = LoanStatementPdf._statusColors(status);
      return pw.Row(
        mainAxisSize: pw.MainAxisSize.min,
        children: [
          pw.Container(
            width: 8,
            height: 8,
            decoration: pw.BoxDecoration(
              color: tint ?? PdfColors.white,
              border: pw.Border.all(color: color, width: 0.8),
              borderRadius: pw.BorderRadius.circular(2),
            ),
          ),
          pw.SizedBox(width: 3),
          _text(status.label, size: 7.5, color: _muted),
          pw.SizedBox(width: 10),
        ],
      );
    }

    return pw.Row(
      children: [for (final st in InstallmentStatus.values) item(st)],
    );
  }

  pw.Widget _scheduleTable() => _table(
    widths: const [0.7, 1.6, 1.5, 1.5, 1.3, 1.6, 1.4, 1.6],
    headings: const [
      '#',
      'Due date',
      'Scheduled EMI',
      'Principal',
      'Interest',
      'Received',
      'Unpaid',
      'Status',
    ],
    align: const [false, false, true, true, true, true, true, false],
    rows: [
      for (final i in s.installments)
        () {
          final (color, tint) = LoanStatementPdf._statusColors(i.status);
          return _Row(tint: tint, [
            _cell(
              '${i.number}${i.revisedFromHere ? '*' : ''}',
              bold: i.revisedFromHere,
            ),
            _cell(_date(i.dueDate)),
            _cell(_amt(i.scheduledMinor), align: true, bold: i.revisedFromHere),
            _cell(_amt(i.principalMinor), align: true),
            _cell(_amt(i.interestMinor), align: true),
            _cell(
              _amt(i.receivedMinor),
              align: true,
              note: i.extraPrincipalMinor > 0
                  ? 'incl. ${_amt(i.extraPrincipalMinor)} extra'
                  : null,
            ),
            _cell(_amt(i.unpaidMinor), align: true),
            _cell(i.statusLabel, bold: true, color: color),
          ]);
        }(),
    ],
  );

  pw.Widget _revisionTable() => _table(
    widths: const [1.5, 1.5, 1.4, 1.5, 1.4, 1.4, 1.0, 1.5],
    headings: const [
      'Revision date',
      'Capital before',
      'Extra paid',
      'Capital after',
      'Previous EMI',
      'New EMI',
      'EMIs left',
      'Effective from',
    ],
    align: const [false, true, true, true, true, true, true, false],
    rows: [
      for (final r in s.revisions)
        _Row([
          _cell(_date(r.date)),
          _cell(_amt(r.capitalBeforeMinor), align: true),
          _cell(_amt(r.extraPrincipalMinor), align: true, bold: true),
          _cell(_amt(r.capitalAfterMinor), align: true),
          _cell(_amt(r.previousEmiMinor), align: true),
          _cell(
            r.newEmiMinor == null ? 'Settled' : _amt(r.newEmiMinor),
            align: true,
            bold: true,
            color: _brand,
          ),
          _cell('${r.remainingInstallments}', align: true),
          _cell(_date(r.effectiveFrom)),
        ]),
    ],
  );

  pw.Widget _historyTable() => _table(
    widths: s.isMonthly
        ? const [1.5, 1.5, 1.5, 1.5, 1.3, 1.4, 1.6]
        : const [1.5, 1.5, 1.5, 1.5, 1.3, 1.6],
    headings: [
      'Payment date',
      'Amount received',
      if (s.isMonthly) 'EMI at the time' else 'Amount due',
      'Principal',
      'Interest',
      if (s.isMonthly) 'Extra principal',
      'Capital after',
    ],
    align: [false, true, true, true, true, if (s.isMonthly) true, true],
    rows: [
      for (final r in s.repayments)
        if (r.voided)
          _Row(tint: _panel, [
            _cell(_date(r.date), color: _muted),
            _cell(
              _amt(r.amountMinor),
              align: true,
              color: _muted,
              strike: true,
            ),
            _cell('Voided', bold: true, color: _muted),
            for (var k = 0; k < (s.isMonthly ? 4 : 3); k++)
              _cell('-', align: true, color: _muted),
          ])
        else
          _Row([
            _cell(_date(r.date)),
            _cell(_amt(r.amountMinor), align: true, bold: true),
            _cell(_amt(r.scheduledEmiMinor), align: true),
            _cell(_amt(r.principalMinor), align: true),
            _cell(_amt(r.interestMinor), align: true),
            if (s.isMonthly)
              _cell(
                r.extraPrincipalMinor > 0 ? _amt(r.extraPrincipalMinor) : '-',
                align: true,
                bold: r.extraPrincipalMinor > 0,
                color: r.extraPrincipalMinor > 0 ? _brand : null,
              ),
            _cell(_amt(r.capitalAfterMinor), align: true),
          ]),
    ],
  );

  // ------------------------------------------------------------ tables

  _Cell _cell(
    String text, {
    bool align = false,
    bool bold = false,
    PdfColor? color,
    String? note,
    bool strike = false,
  }) => _Cell(
    text: text,
    right: align,
    bold: bold,
    color: color,
    note: note,
    strike: strike,
  );

  /// A table whose heading row repeats on every page it continues on.
  pw.Widget _table({
    required List<double> widths,
    required List<String> headings,
    required List<bool> align,
    required List<_Row> rows,
  }) {
    pw.Widget pad(pw.Widget child, bool right) => pw.Container(
      padding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      alignment: right ? pw.Alignment.centerRight : pw.Alignment.centerLeft,
      child: child,
    );
    return pw.Table(
      columnWidths: {
        for (var k = 0; k < widths.length; k++)
          k: pw.FlexColumnWidth(widths[k]),
      },
      border: const pw.TableBorder(
        horizontalInside: pw.BorderSide(color: _line, width: 0.6),
        bottom: pw.BorderSide(color: _line, width: 0.6),
      ),
      children: [
        pw.TableRow(
          repeat: true,
          decoration: const pw.BoxDecoration(color: _navy),
          children: [
            for (var k = 0; k < headings.length; k++)
              pad(
                _text(
                  headings[k],
                  size: 7.5,
                  bold: true,
                  color: PdfColors.white,
                  align: align[k] ? pw.TextAlign.right : pw.TextAlign.left,
                ),
                align[k],
              ),
          ],
        ),
        for (final row in rows)
          pw.TableRow(
            decoration: row.tint == null
                ? null
                : pw.BoxDecoration(color: row.tint),
            verticalAlignment: pw.TableCellVerticalAlignment.middle,
            children: [
              for (final c in row.cells)
                pad(
                  pw.Column(
                    crossAxisAlignment: c.right
                        ? pw.CrossAxisAlignment.end
                        : pw.CrossAxisAlignment.start,
                    mainAxisSize: pw.MainAxisSize.min,
                    children: [
                      pw.Text(
                        _t(c.text),
                        textAlign: c.right
                            ? pw.TextAlign.right
                            : pw.TextAlign.left,
                        style: pw.TextStyle(
                          fontSize: 8,
                          fontWeight: c.bold
                              ? pw.FontWeight.bold
                              : pw.FontWeight.normal,
                          color: c.color,
                          decoration: c.strike
                              ? pw.TextDecoration.lineThrough
                              : null,
                        ),
                      ),
                      if (c.note != null)
                        _text(c.note!, size: 6.5, color: _brand),
                    ],
                  ),
                  c.right,
                ),
            ],
          ),
      ],
    );
  }
}

class _Cell {
  const _Cell({
    required this.text,
    this.right = false,
    this.bold = false,
    this.color,
    this.note,
    this.strike = false,
  });

  final String text;
  final bool right;
  final bool bold;
  final PdfColor? color;
  final String? note;
  final bool strike;
}

class _Row {
  const _Row(this.cells, {this.tint});

  final List<_Cell> cells;
  final PdfColor? tint;
}
