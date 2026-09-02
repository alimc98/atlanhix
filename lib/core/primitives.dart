import 'dart:convert';

/// Utility for strict JSON object access with helpful errors.
class JsonMap {
  JsonMap(this.raw, {this.context = 'config'});

  final dynamic raw;
  final String context;

  Map<String, dynamic> get obj {
    if (raw is Map<String, dynamic>) return raw as Map<String, dynamic>;
    if (raw is Map) return (raw as Map).cast<String, dynamic>();
    throw FormatException('$context: expected a JSON object');
  }

  static String encode(Object? o) => jsonEncode(o);
}
