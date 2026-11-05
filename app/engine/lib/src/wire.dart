/// JSON境界で使う型・範囲の検査。I/Oは行わない。
void wireKeys(
  Map<String, dynamic> json,
  List<String> required,
  List<String> allowed,
) {
  if (!json.keys.toSet().containsAll(required) ||
      json.keys.any((key) => !allowed.contains(key))) {
    throw FormatException('JSONの必須項目または許可する項目が一致しません');
  }
}

Map<String, dynamic> wireMap(Object? value, String field) {
  if (value is! Map<String, dynamic>)
    throw FormatException('$fieldはオブジェクトが必要です');
  return value;
}

List<T> wireList<T>(
  Object? value,
  String field,
  T Function(Object?) parse, {
  int? min,
  int? max,
}) {
  if (value is! List ||
      (min != null && value.length < min) ||
      (max != null && value.length > max)) {
    throw FormatException('$fieldの配列または件数が不正です');
  }
  return List<T>.unmodifiable(value.map(parse));
}

String wireString(
  Object? value,
  String field, {
  String? pattern,
  int? minLength,
  int? maxLength,
  List<String>? values,
  String? constant,
}) {
  if (value is! String ||
      (pattern != null && !RegExp(pattern).hasMatch(value)) ||
      (minLength != null && value.runes.length < minLength) ||
      (maxLength != null && value.runes.length > maxLength) ||
      (values != null && !values.contains(value)) ||
      (constant != null && value != constant)) {
    throw FormatException('$fieldの文字列が不正です');
  }
  return value;
}

bool wireBool(Object? value, String field) {
  if (value is! bool) throw FormatException('$fieldは真偽値が必要です');
  return value;
}

double wireDouble(
  Object? value,
  String field, {
  num? min,
  num? max,
  num? exclusiveMin,
  num? exclusiveMax,
}) {
  if (value is! num ||
      !value.isFinite ||
      (min != null && value < min) ||
      (max != null && value > max) ||
      (exclusiveMin != null && value <= exclusiveMin) ||
      (exclusiveMax != null && value >= exclusiveMax)) {
    throw FormatException('$fieldの数値が範囲外です');
  }
  return value.toDouble();
}

int wireInt(
  Object? value,
  String field, {
  int? min,
  int? max,
  int? constant,
  int? multipleOf,
}) {
  if (value is! num ||
      !value.isFinite ||
      value != value.toInt() ||
      (min != null && value < min) ||
      (max != null && value > max) ||
      (constant != null && value != constant) ||
      (multipleOf != null && value % multipleOf != 0)) {
    throw FormatException('$fieldの整数が不正です');
  }
  return value.toInt();
}
