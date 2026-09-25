import 'dart:typed_data';

enum BleAttendanceEventType { checkIn, checkOut }

class BleAttendanceCodec {
  static const int manufacturerId = 0x1234;
  static const String markerServiceUuidShort = 'a100';
  static const String markerServiceUuidFull =
      '0000a100-0000-1000-8000-00805f9b34fb';
  static const int studentLectureBindingVersion = 4;

  static Uint8List buildManufacturerData({
    required String studentId,
    required String lectureId,
    required BleAttendanceEventType eventType,
  }) {
    final studentBytes = _uuidToBytes(studentId);
    final lectureToken = _lectureToken16(lectureId);
    final eventCode = eventType == BleAttendanceEventType.checkIn ? 1 : 2;
    return Uint8List.fromList(<int>[
      studentLectureBindingVersion,
      eventCode,
      ...studentBytes,
      (lectureToken >> 8) & 0xFF,
      lectureToken & 0xFF,
    ]);
  }

  static List<String> buildServiceUuids({required String studentId}) {
    return <String>[markerServiceUuidShort];
  }

  static int lectureToken16(String lectureId) => _lectureToken16(lectureId);

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

  static int _lectureToken16(String lectureId) {
    final clean = normalizeUuid(lectureId).replaceAll('-', '');
    final bytes = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      bytes[i] = int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16);
    }

    int hash = 0x811C9DC5;
    for (final b in bytes) {
      hash ^= b;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return hash & 0xFFFF;
  }
}
