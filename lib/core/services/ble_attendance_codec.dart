import 'dart:typed_data';

enum StudentAttendanceEventType { checkIn, checkOut }

class BleAttendanceCodec {
  static const int manufacturerId = 0x1234;
  static const String _checkInServiceUuid =
      '0000a101-0000-1000-8000-00805f9b34fb';
  static const String _checkOutServiceUuid =
      '0000a102-0000-1000-8000-00805f9b34fb';

  static Uint8List buildManufacturerData({
    required String studentId,
    required StudentAttendanceEventType eventType,
  }) {
    final studentBytes = _uuidToBytes(studentId);
    final eventByte = eventType == StudentAttendanceEventType.checkIn ? 1 : 2;
    return Uint8List.fromList(<int>[1, eventByte, ...studentBytes]);
  }

  static List<String> buildServiceUuids({
    required String studentId,
    required StudentAttendanceEventType eventType,
  }) {
    return <String>[
      // Student UUID first: some scanners/platforms only expose one UUID.
      // Keeping student first maximizes the chance we can identify the user.
      normalizeUuid(studentId),
      eventType == StudentAttendanceEventType.checkIn
          ? _checkInServiceUuid
          : _checkOutServiceUuid,
    ];
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
