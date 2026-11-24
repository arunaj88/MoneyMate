/// A currency the user can select for display purposes.
///
/// All amounts are stored as integer minor units with two decimal places
/// (e.g. fils for AED, cents for USD), so only two-decimal currencies are
/// offered to keep stored values consistent when switching currency.
class CurrencyInfo {
  const CurrencyInfo({
    required this.code,
    required this.name,
    required this.symbol,
  });

  final String code;
  final String name;
  final String symbol;
}

class Currencies {
  Currencies._();

  static const String defaultCode = 'AED';

  static const List<CurrencyInfo> all = [
    CurrencyInfo(code: 'AED', name: 'UAE Dirham', symbol: 'AED '),
    CurrencyInfo(code: 'USD', name: 'US Dollar', symbol: r'$'),
    CurrencyInfo(code: 'EUR', name: 'Euro', symbol: '€'),
    CurrencyInfo(code: 'GBP', name: 'British Pound', symbol: '£'),
    CurrencyInfo(code: 'INR', name: 'Indian Rupee', symbol: '₹'),
    CurrencyInfo(code: 'SAR', name: 'Saudi Riyal', symbol: 'SAR '),
    CurrencyInfo(code: 'QAR', name: 'Qatari Riyal', symbol: 'QAR '),
    CurrencyInfo(code: 'PKR', name: 'Pakistani Rupee', symbol: 'Rs '),
    CurrencyInfo(code: 'PHP', name: 'Philippine Peso', symbol: '₱'),
    CurrencyInfo(code: 'EGP', name: 'Egyptian Pound', symbol: 'E£'),
    CurrencyInfo(code: 'CAD', name: 'Canadian Dollar', symbol: r'CA$'),
    CurrencyInfo(code: 'AUD', name: 'Australian Dollar', symbol: r'A$'),
    CurrencyInfo(code: 'SGD', name: 'Singapore Dollar', symbol: r'S$'),
    CurrencyInfo(code: 'CHF', name: 'Swiss Franc', symbol: 'CHF '),
  ];

  static CurrencyInfo byCode(String code) =>
      all.firstWhere((c) => c.code == code, orElse: () => all.first);
}
