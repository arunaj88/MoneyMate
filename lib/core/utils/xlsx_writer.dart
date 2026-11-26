import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

/// Horizontal alignment of a cell's content.
enum XlsxAlign { left, center, right }

/// How a cell looks. Styles are compared by value, so equal styles share
/// one entry in the workbook's style table.
class XlsxStyle {
  const XlsxStyle({
    this.bold = false,
    this.italic = false,
    this.fontSize = 11,
    this.fontColor,
    this.fill,
    this.numberFormat,
    this.align,
    this.indent = 0,
    this.borderTop,
    this.borderBottom,
  });

  final bool bold;
  final bool italic;
  final double fontSize;

  /// Colours are `RRGGBB` hex strings.
  final String? fontColor;
  final String? fill;

  /// An Excel number format code such as `#,##0.00` or `dd mmm yyyy`.
  final String? numberFormat;
  final XlsxAlign? align;
  final int indent;

  /// Colour of a thin top / bottom border, or null for none.
  final String? borderTop;
  final String? borderBottom;

  XlsxStyle copyWith({
    bool? bold,
    bool? italic,
    double? fontSize,
    String? fontColor,
    String? fill,
    String? numberFormat,
    XlsxAlign? align,
    int? indent,
    String? borderTop,
    String? borderBottom,
  }) {
    return XlsxStyle(
      bold: bold ?? this.bold,
      italic: italic ?? this.italic,
      fontSize: fontSize ?? this.fontSize,
      fontColor: fontColor ?? this.fontColor,
      fill: fill ?? this.fill,
      numberFormat: numberFormat ?? this.numberFormat,
      align: align ?? this.align,
      indent: indent ?? this.indent,
      borderTop: borderTop ?? this.borderTop,
      borderBottom: borderBottom ?? this.borderBottom,
    );
  }

  String get _fontKey => '$bold|$italic|$fontSize|$fontColor';
  String get _borderKey => '$borderTop|$borderBottom';

  @override
  bool operator ==(Object other) =>
      other is XlsxStyle &&
      other._fontKey == _fontKey &&
      other._borderKey == _borderKey &&
      other.fill == fill &&
      other.numberFormat == numberFormat &&
      other.align == align &&
      other.indent == indent;

  @override
  int get hashCode =>
      Object.hash(_fontKey, _borderKey, fill, numberFormat, align, indent);
}

/// One cell. Numbers are kept as decimal literals (e.g. "-12.34") so money
/// is written exactly, without going through a double.
class XlsxCell {
  const XlsxCell._(this._kind, this.value, this.style);

  const XlsxCell.text(String value, [XlsxStyle style = const XlsxStyle()])
    : this._(_CellKind.text, value, style);

  /// [value] must be a plain decimal literal such as `12`, `-3.5`.
  const XlsxCell.number(String value, [XlsxStyle style = const XlsxStyle()])
    : this._(_CellKind.number, value, style);

  XlsxCell.integer(int value, [XlsxStyle style = const XlsxStyle()])
    : this._(_CellKind.number, '$value', style);

  /// A calendar date (the time of day is ignored). Give the style a date
  /// [XlsxStyle.numberFormat] or it shows as a plain number.
  XlsxCell.date(DateTime value, [XlsxStyle style = const XlsxStyle()])
    : this._(_CellKind.number, '${_excelSerial(value)}', style);

  /// An empty cell that still carries a style (fill, border).
  const XlsxCell.blank([XlsxStyle style = const XlsxStyle()])
    : this._(_CellKind.blank, '', style);

  final _CellKind _kind;
  final String value;
  final XlsxStyle style;

  /// Days since 1899-12-30, Excel's (and Sheets') date origin.
  static int _excelSerial(DateTime date) => DateTime.utc(
    date.year,
    date.month,
    date.day,
  ).difference(DateTime.utc(1899, 12, 30)).inDays;
}

enum _CellKind { text, number, blank }

/// One worksheet. Rows and columns are 0-based here and 1-based in Excel.
class XlsxSheet {
  XlsxSheet(this.name) {
    if (name.isEmpty ||
        name.length > 31 ||
        name.contains(RegExp(r'[\[\]:*?/\\]'))) {
      throw ArgumentError.value(name, 'name', 'Not a valid sheet name');
    }
  }

  final String name;
  final List<List<XlsxCell?>> rows = [];
  final Map<int, double> rowHeights = {};
  final Map<int, double> columnWidths = {};
  final List<String> merges = [];

  /// Rows above this index stay visible while scrolling.
  int frozenRows = 0;

  /// Cell range such as `A7:H40` that gets filter buttons.
  String? autoFilter;

  /// 0-based row repeated at the top of every printed page.
  int? printTitleRow;
  bool landscape = false;
  bool showGridLines = true;

  /// Appends a row and returns its 0-based index.
  int addRow(List<XlsxCell?> cells, {double? height}) {
    rows.add(cells);
    if (height != null) rowHeights[rows.length - 1] = height;
    return rows.length - 1;
  }

  /// Merges a block of cells given by 0-based coordinates.
  void merge(int row, int firstColumn, int lastColumn, {int? lastRow}) {
    merges.add(
      '${cellRef(row, firstColumn)}:${cellRef(lastRow ?? row, lastColumn)}',
    );
  }

  /// `A1`-style reference for 0-based [row] and [column].
  static String cellRef(int row, int column) =>
      '${columnLetter(column)}${row + 1}';

  static String columnLetter(int column) {
    var n = column + 1;
    final buffer = StringBuffer();
    while (n > 0) {
      final rem = (n - 1) % 26;
      buffer.write(String.fromCharCode(65 + rem));
      n = (n - 1) ~/ 26;
    }
    return buffer.toString().split('').reversed.join();
  }
}

/// Writes a small, styled Office Open XML workbook (.xlsx) that opens in
/// Excel, Google Sheets, Numbers and LibreOffice.
class XlsxWorkbook {
  XlsxWorkbook({this.title, this.creator});

  static const mimeType =
      'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';

  final String? title;
  final String? creator;
  final List<XlsxSheet> sheets = [];

  XlsxSheet addSheet(String name) {
    final sheet = XlsxSheet(name);
    sheets.add(sheet);
    return sheet;
  }

  Uint8List encode({DateTime? created}) {
    if (sheets.isEmpty) throw StateError('A workbook needs at least one sheet');
    final styles = _StyleTable();
    final sheetXml = [
      for (final s in sheets) _sheetXml(s, styles, s == sheets.first),
    ];
    final archive = Archive();
    void add(String path, String xml) =>
        archive.addFile(ArchiveFile.bytes(path, utf8.encode(xml)));

    add('[Content_Types].xml', _contentTypes());
    add('_rels/.rels', _rootRels);
    add('docProps/core.xml', _core(created ?? DateTime.now()));
    add('docProps/app.xml', _app());
    add('xl/workbook.xml', _workbook());
    add('xl/_rels/workbook.xml.rels', _workbookRels());
    add('xl/styles.xml', styles.toXml());
    for (var i = 0; i < sheets.length; i++) {
      add('xl/worksheets/sheet${i + 1}.xml', sheetXml[i]);
    }
    return ZipEncoder().encodeBytes(archive);
  }

  static const _xmlHeader =
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n';
  static const _mainNs =
      'http://schemas.openxmlformats.org/spreadsheetml/2006/main';
  static const _relNs =
      'http://schemas.openxmlformats.org/officeDocument/2006/relationships';

  String _contentTypes() {
    final buffer = StringBuffer(_xmlHeader)
      ..write(
        '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
        '<Default Extension="xml" ContentType="application/xml"/>'
        '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
        '<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>'
        '<Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>'
        '<Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>',
      );
    for (var i = 1; i <= sheets.length; i++) {
      buffer.write(
        '<Override PartName="/xl/worksheets/sheet$i.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>',
      );
    }
    buffer.write('</Types>');
    return buffer.toString();
  }

  static const _rootRels =
      '$_xmlHeader<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
      '<Relationship Id="rId1" Type="$_relNs/officeDocument" Target="xl/workbook.xml"/>'
      '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>'
      '<Relationship Id="rId3" Type="$_relNs/extended-properties" Target="docProps/app.xml"/>'
      '</Relationships>';

  String _core(DateTime created) {
    final stamp = '${created.toUtc().toIso8601String().split('.').first}Z';
    return '$_xmlHeader<cp:coreProperties '
        'xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" '
        'xmlns:dc="http://purl.org/dc/elements/1.1/" '
        'xmlns:dcterms="http://purl.org/dc/terms/" '
        'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">'
        '${title == null ? '' : '<dc:title>${_escape(title!)}</dc:title>'}'
        '${creator == null ? '' : '<dc:creator>${_escape(creator!)}</dc:creator>'}'
        '<dcterms:created xsi:type="dcterms:W3CDTF">$stamp</dcterms:created>'
        '<dcterms:modified xsi:type="dcterms:W3CDTF">$stamp</dcterms:modified>'
        '</cp:coreProperties>';
  }

  String _app() =>
      '$_xmlHeader<Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties">'
      '<Application>${_escape(creator ?? 'Microsoft Excel')}</Application>'
      '</Properties>';

  String _workbook() {
    final buffer = StringBuffer(_xmlHeader)
      ..write('<workbook xmlns="$_mainNs" xmlns:r="$_relNs">')
      ..write('<bookViews><workbookView activeTab="0"/></bookViews><sheets>');
    for (var i = 0; i < sheets.length; i++) {
      buffer.write(
        '<sheet name="${_escape(sheets[i].name)}" sheetId="${i + 1}" r:id="rId${i + 1}"/>',
      );
    }
    buffer.write('</sheets>');
    final names = StringBuffer();
    for (var i = 0; i < sheets.length; i++) {
      final sheet = sheets[i];
      final quoted = "'${sheet.name.replaceAll("'", "''")}'";
      if (sheet.autoFilter != null) {
        final absolute = sheet.autoFilter!
            .split(':')
            .map(
              (ref) => ref.replaceAllMapped(
                RegExp(r'([A-Z]+)(\d+)'),
                (m) => '\$${m[1]}\$${m[2]}',
              ),
            )
            .join(':');
        names.write(
          '<definedName name="_xlnm._FilterDatabase" localSheetId="$i" hidden="1">'
          '${_escape('$quoted!$absolute')}</definedName>',
        );
      }
      if (sheet.printTitleRow != null) {
        final row = sheet.printTitleRow! + 1;
        names.write(
          '<definedName name="_xlnm.Print_Titles" localSheetId="$i">'
          '${_escape('$quoted!\$$row:\$$row')}</definedName>',
        );
      }
    }
    if (names.isNotEmpty) buffer.write('<definedNames>$names</definedNames>');
    buffer.write('</workbook>');
    return buffer.toString();
  }

  String _workbookRels() {
    final buffer = StringBuffer(_xmlHeader)
      ..write(
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">',
      );
    for (var i = 1; i <= sheets.length; i++) {
      buffer.write(
        '<Relationship Id="rId$i" Type="$_relNs/worksheet" Target="worksheets/sheet$i.xml"/>',
      );
    }
    buffer
      ..write(
        '<Relationship Id="rId${sheets.length + 1}" Type="$_relNs/styles" Target="styles.xml"/>',
      )
      ..write('</Relationships>');
    return buffer.toString();
  }

  String _sheetXml(XlsxSheet sheet, _StyleTable styles, bool selected) {
    var lastColumn = 0;
    for (final row in sheet.rows) {
      if (row.length > lastColumn) lastColumn = row.length;
    }
    for (final c in sheet.columnWidths.keys) {
      if (c + 1 > lastColumn) lastColumn = c + 1;
    }
    final dimension = sheet.rows.isEmpty || lastColumn == 0
        ? 'A1'
        : 'A1:${XlsxSheet.cellRef(sheet.rows.length - 1, lastColumn - 1)}';

    final buffer = StringBuffer(_xmlHeader)
      ..write('<worksheet xmlns="$_mainNs" xmlns:r="$_relNs">');
    if (sheet.landscape) {
      buffer.write('<sheetPr><pageSetUpPr fitToPage="1"/></sheetPr>');
    }
    buffer
      ..write('<dimension ref="$dimension"/>')
      ..write('<sheetViews><sheetView workbookViewId="0"')
      ..write(sheet.showGridLines ? '' : ' showGridLines="0"')
      ..write(selected ? ' tabSelected="1"' : '')
      ..write('>');
    if (sheet.frozenRows > 0) {
      final topLeft = XlsxSheet.cellRef(sheet.frozenRows, 0);
      buffer.write(
        '<pane ySplit="${sheet.frozenRows}" topLeftCell="$topLeft" activePane="bottomLeft" state="frozen"/>'
        '<selection pane="bottomLeft" activeCell="$topLeft" sqref="$topLeft"/>',
      );
    }
    buffer.write(
      '</sheetView></sheetViews><sheetFormatPr defaultRowHeight="15"/>',
    );

    if (sheet.columnWidths.isNotEmpty) {
      buffer.write('<cols>');
      final columns = sheet.columnWidths.keys.toList()..sort();
      for (final c in columns) {
        final width = sheet.columnWidths[c]!.toStringAsFixed(2);
        buffer.write(
          '<col min="${c + 1}" max="${c + 1}" width="$width" customWidth="1"/>',
        );
      }
      buffer.write('</cols>');
    }

    buffer.write('<sheetData>');
    for (var r = 0; r < sheet.rows.length; r++) {
      final height = sheet.rowHeights[r];
      buffer.write('<row r="${r + 1}"');
      if (height != null) buffer.write(' ht="$height" customHeight="1"');
      buffer.write('>');
      final cells = sheet.rows[r];
      for (var c = 0; c < cells.length; c++) {
        final cell = cells[c];
        if (cell == null) continue;
        final ref = XlsxSheet.cellRef(r, c);
        final s = styles.indexOf(cell.style);
        final styleAttr = s == 0 ? '' : ' s="$s"';
        switch (cell._kind) {
          case _CellKind.blank:
            buffer.write('<c r="$ref"$styleAttr/>');
          case _CellKind.number:
            buffer.write('<c r="$ref"$styleAttr><v>${cell.value}</v></c>');
          case _CellKind.text:
            buffer.write(
              '<c r="$ref"$styleAttr t="inlineStr"><is><t xml:space="preserve">'
              '${_escape(cell.value)}</t></is></c>',
            );
        }
      }
      buffer.write('</row>');
    }
    buffer.write('</sheetData>');

    if (sheet.autoFilter != null) {
      buffer.write('<autoFilter ref="${sheet.autoFilter}"/>');
    }
    if (sheet.merges.isNotEmpty) {
      buffer.write('<mergeCells count="${sheet.merges.length}">');
      for (final m in sheet.merges) {
        buffer.write('<mergeCell ref="$m"/>');
      }
      buffer.write('</mergeCells>');
    }
    buffer.write(
      '<pageMargins left="0.5" right="0.5" top="0.6" bottom="0.6" header="0.3" footer="0.3"/>',
    );
    if (sheet.landscape) {
      buffer.write(
        '<pageSetup orientation="landscape" fitToWidth="1" fitToHeight="0"/>',
      );
    }
    buffer.write('</worksheet>');
    return buffer.toString();
  }
}

/// Collects the fonts, fills, borders and number formats the cells use.
class _StyleTable {
  _StyleTable() {
    indexOf(const XlsxStyle()); // xf 0 is the default style.
  }

  final Map<XlsxStyle, int> _xfs = {};
  final List<XlsxStyle> _ordered = [];
  final Map<String, int> _fonts = {};
  final Map<String, int> _fills = {'none': 0, 'gray125': 1};
  final Map<String, int> _borders = {'null|null': 0};
  final Map<String, int> _numFmts = {};

  int indexOf(XlsxStyle style) {
    return _xfs.putIfAbsent(style, () {
      _ordered.add(style);
      _fonts.putIfAbsent(style._fontKey, () => _fonts.length);
      if (style.fill != null) {
        _fills.putIfAbsent(style.fill!, () => _fills.length);
      }
      _borders.putIfAbsent(style._borderKey, () => _borders.length);
      if (style.numberFormat != null) {
        _numFmts.putIfAbsent(style.numberFormat!, () => 164 + _numFmts.length);
      }
      return _ordered.length - 1;
    });
  }

  String toXml() {
    final buffer = StringBuffer(XlsxWorkbook._xmlHeader)
      ..write('<styleSheet xmlns="${XlsxWorkbook._mainNs}">');
    if (_numFmts.isNotEmpty) {
      buffer.write('<numFmts count="${_numFmts.length}">');
      _numFmts.forEach((code, id) {
        buffer.write('<numFmt numFmtId="$id" formatCode="${_escape(code)}"/>');
      });
      buffer.write('</numFmts>');
    }

    final fontStyles = <String, XlsxStyle>{
      for (final s in _ordered) s._fontKey: s,
    };
    buffer.write('<fonts count="${_fonts.length}">');
    for (final key in _fonts.keys) {
      final s = fontStyles[key]!;
      buffer
        ..write('<font>')
        ..write(s.bold ? '<b/>' : '')
        ..write(s.italic ? '<i/>' : '')
        ..write('<sz val="${_number(s.fontSize)}"/>')
        ..write(s.fontColor == null ? '' : '<color rgb="FF${s.fontColor}"/>')
        ..write('<name val="Calibri"/><family val="2"/></font>');
    }
    buffer.write('</fonts>');

    buffer.write('<fills count="${_fills.length}">');
    for (final key in _fills.keys) {
      if (key == 'none' || key == 'gray125') {
        buffer.write('<fill><patternFill patternType="$key"/></fill>');
      } else {
        buffer.write(
          '<fill><patternFill patternType="solid"><fgColor rgb="FF$key"/>'
          '<bgColor indexed="64"/></patternFill></fill>',
        );
      }
    }
    buffer.write('</fills>');

    String edge(String tag, String color) => color == 'null'
        ? '<$tag/>'
        : '<$tag style="thin"><color rgb="FF$color"/></$tag>';
    buffer.write('<borders count="${_borders.length}">');
    for (final key in _borders.keys) {
      final [top, bottom] = key.split('|');
      buffer.write(
        '<border><left/><right/>${edge('top', top)}${edge('bottom', bottom)}<diagonal/></border>',
      );
    }
    buffer.write('</borders>');

    buffer.write(
      '<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>',
    );
    buffer.write('<cellXfs count="${_ordered.length}">');
    for (final s in _ordered) {
      final numFmt = s.numberFormat == null ? 0 : _numFmts[s.numberFormat]!;
      final fill = s.fill == null ? 0 : _fills[s.fill]!;
      buffer.write(
        '<xf numFmtId="$numFmt" fontId="${_fonts[s._fontKey]}" fillId="$fill" '
        'borderId="${_borders[s._borderKey]}" xfId="0" applyNumberFormat="1" '
        'applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1">'
        '<alignment vertical="center"',
      );
      if (s.align != null) buffer.write(' horizontal="${s.align!.name}"');
      if (s.indent > 0) buffer.write(' indent="${s.indent}"');
      buffer.write('/></xf>');
    }
    buffer.write('</cellXfs>');
    buffer.write(
      '<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>'
      '</styleSheet>',
    );
    return buffer.toString();
  }

  static String _number(double v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toString();
}

final _invalidXmlChars = RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F]');

/// Escapes text for XML content and attributes and drops control
/// characters XML 1.0 cannot represent.
String _escape(String text) => text
    .replaceAll(_invalidXmlChars, '')
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');
