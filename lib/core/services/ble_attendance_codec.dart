import 'dart:typed_data';

class BleAttendanceCodec {
  static const int manufacturerId = 0x1234;

  static Uint8List buildManufacturerData({
    required String studentId,
  }) {
    final studentBytes = _uuidToBytes(studentId);
    return Uint8List.fromList(<int>[1, ...studentBytes]);
  }

  static List<String> buildServiceUuids({
    required String studentId,
  }) {
    return <String>[normalizeUuid(studentId)];
  }

  static String normalizeUuid(String uuid) {
    final clean = uuid.replaceAll('-', '').toLowerCase();
    if (clean.length != 32) {
      throw const FormatException('Invalid UUID');
    }
    return '${clean.substring(0, 8)}-${clean.substring(8, 12)}-${clean.substring(12, 16)}-${clean.substring(16, 20)}-${clean.substring(20, 32)}';
  }

  static Uint8List _uuidToBytes(String uuid) {
    final clean = normalizeUuid(uuid).replaceAll('-', '');
    final out = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      out[i] = int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }
}
