import 'dart:typed_data';

enum StudentAttendanceEventType { checkIn, checkOut }

class BleAttendanceCodec {
  static const int manufacturerId = 0x1234;

  static Uint8List buildManufacturerData({
    required String studentId,
    required StudentAttendanceEventType eventType,
  }) {
    final studentBytes = _uuidToBytes(studentId);
    final eventByte = eventType == StudentAttendanceEventType.checkIn ? 1 : 2;
    return Uint8List.fromList(<int>[1, eventByte, ...studentBytes]);
  }

  static Uint8List _uuidToBytes(String uuid) {
    final clean = uuid.replaceAll('-', '').toLowerCase();
    if (clean.length != 32) {
      throw const FormatException('Invalid UUID');
    }
    final out = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      out[i] = int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }
}
