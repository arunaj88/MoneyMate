import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart';
import 'package:printing/printing.dart';
import 'package:provider/provider.dart';

import 'package:money_mate/core/services/file_service.dart';
import 'package:money_mate/core/services/loan_statement.dart';
import 'package:money_mate/core/services/loan_statement_pdf.dart';
import 'package:money_mate/core/theme/app_theme.dart';
import 'package:money_mate/providers/auth_provider.dart';
import 'package:money_mate/providers/loan_provider.dart';
import 'package:money_mate/providers/settings_provider.dart';
import 'package:money_mate/shared/widgets/dialogs.dart';
import 'package:money_mate/shared/widgets/state_views.dart';

/// Lets the lender review a loan statement and share it with the borrower
/// as a PDF or a short text, through the system share sheet.
///
/// Nothing is sent automatically and nothing is uploaded: the PDF is made
/// on the device from the saved loan and its repayments, and rebuilt
/// whenever they change while the screen is open.
class LoanStatementScreen extends StatefulWidget {
  const LoanStatementScreen({
    super.key,
    required this.loanId,
    this.clock = DateTime.now,
  });

  final String loanId;
  final DateTime Function() clock;

  /// Shows the rendered PDF pages. Widget tests turn it off: the native
  /// rasteriser is not available there.
  @visibleForTesting
  static bool showPdfPreview = true;

  @override
  State<LoanStatementScreen> createState() => _LoanStatementScreenState();
}

class _LoanStatementScreenState extends State<LoanStatementScreen> {
  static String? _logo;

  late final TextEditingController _lender;
  late LoanStatementOptions _options;
  Timer? _nameDebounce;
  bool _sharing = false;

  /// The statement and its PDF, rebuilt when the data or options change.
  LoanStatement? _statement;
  Future<Uint8List>? _pdf;
  Object? _builtFor;

  final _pdfButtonKey = GlobalKey();
  final _textButtonKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    final user = context.read<AuthProvider>().user;
    final name = user != null && user.hasName ? user.displayName!.trim() : '';
    _lender = TextEditingController(text: name);
    _options = LoanStatementOptions(lenderName: name);
  }

  @override
  void dispose() {
    _nameDebounce?.cancel();
    _lender.dispose();
    super.dispose();
  }

  static Future<String?> _loadLogo() async {
    if (_logo != null) return _logo;
    try {
      return _logo = await rootBundle.loadString(
        'assets/branding/app_icon.svg',
      );
    } on Object {
      return null;
    }
  }

  void _onLenderChanged(String value) {
    _nameDebounce?.cancel();
    _nameDebounce = Timer(const Duration(milliseconds: 600), () {
      if (mounted) {
        setState(() => _options = _options.copyWith(lenderName: value));
      }
    });
  }

  /// The statement for the current data, rebuilt only when it changes.
  LoanStatement? _current(LoanProvider loans, String currency) {
    final loan = loans.storedLoanById(widget.loanId);
    if (loan == null) return null;
    final key = (loans.version, _options, currency);
    if (_builtFor != key || _statement == null) {
      _builtFor = key;
      final statement = LoanStatement.build(
        loan: loan,
        repayments: loans.repaymentsOf(loan.id),
        now: widget.clock(),
        currencyCode: currency,
        options: _options,
      );
      _statement = statement;
      _pdf = _loadLogo().then(
        (logo) => LoanStatementPdf.build(statement, logoSvg: logo),
      );
    }
    return _statement;
  }

  Rect? _originOf(GlobalKey key) {
    final box = key.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  Future<void> _share({required bool pdf}) async {
    final statement = _statement;
    final bytes = _pdf;
    if (statement == null || bytes == null || _sharing) return;
    setState(() => _sharing = true);
    final files = context.read<FileService>();
    final subject = 'Loan statement - ${statement.borrowerName}';
    try {
      if (pdf) {
        await files.shareBytes(
          fileName: statement.fileName,
          bytes: await bytes,
          mimeType: 'application/pdf',
          subject: subject,
          origin: _originOf(_pdfButtonKey),
        );
      } else {
        await files.shareText(
          text: statement.toText(),
          subject: subject,
          origin: _originOf(_textButtonKey),
        );
      }
    } on Object {
      if (mounted) {
        showAppSnackBar(
          context,
          pdf
              ? 'The statement could not be shared. Please try again.'
              : 'The summary could not be shared. Please try again.',
          isError: true,
        );
      }
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final loans = context.watch<LoanProvider>();
    final currency = context.select<SettingsProvider, String>(
      (s) => s.formatter.currency.code,
    );
    final statement = _current(loans, currency);
    if (statement == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Share loan details')),
        body: const EmptyState(
          icon: Icons.search_off_rounded,
          title: 'This lending record no longer exists',
          message: 'It may have been deleted on another device.',
        ),
      );
    }
    final loan = loans.storedLoanById(widget.loanId)!;
    final hasContact =
        loan.borrowerPhone.trim().isNotEmpty ||
        loan.borrowerEmail.trim().isNotEmpty;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Share loan details')),
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.fromLTRB(
          Spacing.lg,
          Spacing.sm,
          Spacing.lg,
          Spacing.md,
        ),
        child: Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                key: _textButtonKey,
                onPressed: _sharing ? null : () => _share(pdf: false),
                icon: const Icon(Icons.short_text_rounded),
                label: const Text('Share as text'),
              ),
            ),
            const SizedBox(width: Spacing.md),
            Expanded(
              child: FilledButton.icon(
                key: _pdfButtonKey,
                onPressed: _sharing ? null : () => _share(pdf: true),
                icon: const Icon(Icons.picture_as_pdf_outlined),
                label: const Text('Share PDF'),
              ),
            ),
          ],
        ),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            key: const Key('statementNotice'),
            margin: const EdgeInsets.fromLTRB(
              Spacing.lg,
              Spacing.sm,
              Spacing.lg,
              0,
            ),
            padding: const EdgeInsets.all(Spacing.md),
            decoration: BoxDecoration(
              color: theme.colorScheme.primary.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.info_outline_rounded,
                  size: 20,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: Spacing.sm),
                Expanded(
                  child: Text(
                    'Latest schedule as of ${statement.generatedLabel}. '
                    'Review it before sharing. Statements you shared earlier '
                    'stay on the borrower\'s device as they were and cannot '
                    'be updated or recalled, so share a new one after any '
                    'change.',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ),
          ExpansionTile(
            key: const Key('statementOptions'),
            tilePadding: const EdgeInsets.symmetric(horizontal: Spacing.lg),
            // Room above the field for its floating label, which the
            // expanding panel would otherwise clip.
            childrenPadding: const EdgeInsets.fromLTRB(
              Spacing.lg,
              Spacing.md,
              Spacing.lg,
              Spacing.sm,
            ),
            title: const Text('Statement options'),
            subtitle: Text(
              'Ref. ${statement.reference} · '
              '${statement.totalInstallments} instalment'
              '${statement.totalInstallments == 1 ? '' : 's'} · '
              '${statement.repayments.length} repayment'
              '${statement.repayments.length == 1 ? '' : 's'}',
              style: theme.textTheme.bodySmall,
            ),
            children: [
              TextField(
                key: const Key('statementLenderField'),
                controller: _lender,
                maxLength: 80,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                  labelText: 'Lender name',
                  helperText: 'Shown on the statement and the text summary',
                  counterText: '',
                ),
                onChanged: _onLenderChanged,
                onSubmitted: (v) {
                  _nameDebounce?.cancel();
                  setState(() => _options = _options.copyWith(lenderName: v));
                },
              ),
              SwitchListTile(
                key: const Key('statementContactSwitch'),
                contentPadding: EdgeInsets.zero,
                title: const Text('Include borrower\'s contact details'),
                subtitle: Text(
                  hasContact
                      ? 'Phone and email you saved for ${loan.borrowerName}'
                      : 'No phone or email saved',
                ),
                value: hasContact && _options.includeContactDetails,
                onChanged: hasContact
                    ? (v) => setState(
                        () => _options = _options.copyWith(
                          includeContactDetails: v,
                        ),
                      )
                    : null,
              ),
              if (loan.notes.trim().isNotEmpty)
                SwitchListTile(
                  key: const Key('statementNotesSwitch'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Include notes and terms'),
                  subtitle: Text(
                    loan.notes.trim(),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  value: _options.includeNotes,
                  onChanged: (v) => setState(
                    () => _options = _options.copyWith(includeNotes: v),
                  ),
                ),
            ],
          ),
          const Divider(height: 1),
          Expanded(
            child: LoanStatementScreen.showPdfPreview
                ? PdfPreview(
                    key: ValueKey(_builtFor),
                    build: (_) => _pdf!,
                    initialPageFormat: PdfPageFormat.a4,
                    useActions: false,
                    allowPrinting: false,
                    allowSharing: false,
                    canChangePageFormat: false,
                    canChangeOrientation: false,
                    canDebug: false,
                    dynamicLayout: false,
                    pdfFileName: statement.fileName,
                    loadingWidget: const LoadingView(),
                    onError: (context, _) => const EmptyState(
                      icon: Icons.picture_as_pdf_outlined,
                      title: 'Preview unavailable',
                      message:
                          'The statement can still be shared as a PDF or '
                          'as text.',
                    ),
                  )
                : const SizedBox.shrink(key: Key('statementPreviewOff')),
          ),
        ],
      ),
    );
  }
}
