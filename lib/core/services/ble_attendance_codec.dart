import 'dart:typed_data';

enum BleAttendanceEventType { checkIn, checkOut }

class BleAttendanceAck {
  final int lectureToken16;
  final BleAttendanceEventType eventType;
  final int statusCode;
  final int requestNonce16;

  const BleAttendanceAck({
    required this.lectureToken16,
    required this.eventType,
    required this.statusCode,
    required this.requestNonce16,
  });
}

class BleAttendanceCodec {
  static const int manufacturerId = 0x1234;
  static const String markerServiceUuidShort = 'a100';
  static const String markerServiceUuidFull =
      '0000a100-0000-1000-8000-00805f9b34fb';
  static const int studentLectureBindingVersion = 5;

  static Uint8List buildManufacturerData({
    required String studentId,
    required String lectureId,
    required BleAttendanceEventType eventType,
    required int requestNonce16,
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
      (requestNonce16 >> 8) & 0xFF,
      requestNonce16 & 0xFF,
    ]);
  }

  static List<String> buildServiceUuids({required String studentId}) {
    // Include marker and the student's UUID so receivers can identify sender reliably
    // Also include a placeholder slot for lecture-token+event encoded as 8-hex string
    // (constructed by caller via overloaded method when needed).
    return <String>[markerServiceUuidShort, studentId];
  }

  static List<String> buildServiceUuidsForBroadcast({
    required String studentId,
    required String lectureId,
    required BleAttendanceEventType eventType,
    required int requestNonce16,
  }) {
    final token = _lectureToken16(lectureId);
    final tokenHex = token.toRadixString(16).padLeft(4, '0');
    final eventCode = eventType == BleAttendanceEventType.checkIn ? 1 : 2;
    final eventHex = eventCode.toRadixString(16).padLeft(2, '0');
    final combined = (tokenHex + eventHex + '00').toLowerCase(); // 8 chars
    final nonceHex = requestNonce16.toRadixString(16).padLeft(4, '0');
    final nonceCombined = (nonceHex + 'a500').toLowerCase(); // nonce marker
    return <String>[
      markerServiceUuidShort,
      normalizeUuid(studentId),
      combined,
      nonceCombined,
    ];
  }

  static BleAttendanceAck? parseAckFromServiceUuids({
    required Iterable<String> serviceUuids,
    required String studentId,
  }) {
    final normalizedStudent = normalizeUuid(studentId);
    bool hasMarker = false;
    bool hasStudent = false;
    int? token;
    int? eventCode;
    int? statusCode;
    int? nonce;

    for (final raw in serviceUuids) {
      final n = _tryNormalizeUuid(raw);
      if (n == markerServiceUuidFull) {
        hasMarker = true;
      }
      if (n == normalizedStudent) {
        hasStudent = true;
      }
    }

    if (!hasMarker || !hasStudent) return null;

    Iterable<String> payloadCandidates() sync* {
      const baseSuffix = '00001000800000805f9b34fb';
      for (final raw in serviceUuids) {
        final clean = raw.replaceAll('-', '').toLowerCase();
        if (clean.length == 8) {
          yield clean;
          continue;
        }
        if (clean.length == 32 && clean.endsWith(baseSuffix)) {
          yield clean.substring(0, 8);
        }
      }
    }

    for (final clean in payloadCandidates()) {

      // ACK meta: [token_hi2][token_lo2][event][status]
      try {
        final t = int.parse(clean.substring(0, 4), radix: 16);
        final e = int.parse(clean.substring(4, 6), radix: 16);
        final s = int.parse(clean.substring(6, 8), radix: 16);
        if ((e == 1 || e == 2) && (s == 1 || s == 2)) {
          token = t;
          eventCode = e;
          statusCode = s;
        }
      } catch (_) {}

      // Nonce marker uuid: [nonce_hi2][nonce_lo2][a5][00]
      if (clean.endsWith('a500')) {
        try {
          nonce = int.parse(clean.substring(0, 4), radix: 16);
        } catch (_) {}
      }
    }

    if (token == null || eventCode == null || statusCode == null || nonce == null) {
      return null;
    }

    return BleAttendanceAck(
      lectureToken16: token,
      eventType: eventCode == 1
          ? BleAttendanceEventType.checkIn
          : BleAttendanceEventType.checkOut,
      statusCode: statusCode,
      requestNonce16: nonce,
    );
  }

  static int lectureToken16(String lectureId) => _lectureToken16(lectureId);

  static String? _tryNormalizeUuid(String value) {
    final clean = value.replaceAll('-', '').toLowerCase();
    if (clean.length == 4) {
      return '0000$clean-0000-1000-8000-00805f9b34fb';
    }
    if (clean.length == 8) {
      return '$clean-0000-1000-8000-00805f9b34fb';
    }
    if (clean.length != 32) return null;
    final isHex = RegExp(r'^[0-9a-f]{32}$').hasMatch(clean);
    if (!isHex) return null;
    return '${clean.substring(0, 8)}-${clean.substring(8, 12)}-${clean.substring(12, 16)}-${clean.substring(16, 20)}-${clean.substring(20, 32)}';
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
