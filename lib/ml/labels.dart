/// The model's label space, read from `labels.csv` — never hard-coded.
///
/// Contract (ml-pipeline/arm2_export/README_for_app_agent.md): output index i
/// corresponds to row i of labels.csv. The parser enforces that `model_index`
/// equals the row position, so a reordered or truncated file fails loudly
/// instead of silently shifting every label by one.
library;

/// One class of the classifier output.
class ModelLabel {
  const ModelLabel({
    required this.index,
    required this.classId,
    required this.label,
    required this.rank,
    required this.genus,
    required this.family,
  });

  /// Position in the output vector.
  final int index;

  /// GBIF taxon key for species, `genus_<Name>` for genus classes, or an
  /// aggregate id (e.g. `bryophyta`).
  final String classId;

  /// Human-readable name, e.g. `Carduus defloratus L.` or `Carduus`.
  final String label;

  /// `species`, `genus` or `aggregate` — a genus-level answer is a valid
  /// answer of the label space, not a degraded one.
  final String rank;

  final String genus;
  final String family;
}

class LabelTable {
  LabelTable._(this.labels);

  final List<ModelLabel> labels;

  int get length => labels.length;

  ModelLabel operator [](int index) => labels[index];

  /// Parses labels.csv (UTF-8 text). Throws [FormatException] on any
  /// structural problem.
  static LabelTable parse(String csvText) {
    var text = csvText;
    // Tolerate a UTF-8 byte-order mark (U+FEFF) at the start of the file.
    if (text.isNotEmpty && text.codeUnitAt(0) == 0xFEFF) text = text.substring(1);
    final rows = parseCsv(text);
    if (rows.isEmpty) throw const FormatException('labels.csv is empty');

    final header = rows.first;
    int column(String name) {
      final i = header.indexOf(name);
      if (i < 0) throw FormatException('labels.csv: missing column "$name"');
      return i;
    }

    final cIndex = column('model_index');
    final cClass = column('class_id');
    final cLabel = column('label');
    final cRank = column('rank');
    final cGenus = column('genus');
    final cFamily = column('family');
    final width = header.length;

    final labels = <ModelLabel>[];
    for (var r = 1; r < rows.length; r++) {
      final row = rows[r];
      if (row.length == 1 && row.first.isEmpty) continue; // blank line
      if (row.length != width) {
        throw FormatException(
            'labels.csv: line ${r + 1} has ${row.length} fields, header has $width');
      }
      final index = int.parse(row[cIndex]);
      if (index != labels.length) {
        throw FormatException(
            'labels.csv: line ${r + 1} has model_index $index, expected '
            '${labels.length} (row order must equal output order)');
      }
      labels.add(ModelLabel(
        index: index,
        classId: row[cClass],
        label: row[cLabel],
        rank: row[cRank],
        genus: row[cGenus],
        family: row[cFamily],
      ));
    }
    return LabelTable._(List.unmodifiable(labels));
  }
}

/// Minimal RFC 4180 parser: comma-separated, double-quoted fields with `""`
/// escapes, LF or CRLF line ends. labels.csv needs the quoting — one label
/// reads "Bryophyta (aggregate) - moss, needs an expert".
List<List<String>> parseCsv(String text) {
  final rows = <List<String>>[];
  var row = <String>[];
  final field = StringBuffer();
  var inQuotes = false;
  var i = 0;
  while (i < text.length) {
    final ch = text[i];
    if (inQuotes) {
      if (ch == '"') {
        if (i + 1 < text.length && text[i + 1] == '"') {
          field.write('"');
          i += 2;
          continue;
        }
        inQuotes = false;
        i++;
        continue;
      }
      field.write(ch);
      i++;
      continue;
    }
    if (ch == '"') {
      inQuotes = true;
    } else if (ch == ',') {
      row.add(field.toString());
      field.clear();
    } else if (ch == '\n') {
      row.add(field.toString());
      field.clear();
      rows.add(row);
      row = <String>[];
    } else if (ch != '\r') {
      field.write(ch);
    }
    i++;
  }
  if (inQuotes) throw const FormatException('CSV ends inside a quoted field');
  if (field.isNotEmpty || row.isNotEmpty) {
    row.add(field.toString());
    rows.add(row);
  }
  return rows;
}
