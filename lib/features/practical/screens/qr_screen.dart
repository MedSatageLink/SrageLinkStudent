import 'dart:convert';
import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_ble_peripheral/flutter_ble_peripheral.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:go_router/go_router.dart';
import 'package:gap/gap.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../core/services/ble_attendance_codec.dart';
import 'practical_sessions_screen.dart';

enum _AttendanceProbeTarget { checkIn, checkOut, none }

final qrLectureProvider = FutureProvider.family<Map<String, dynamic>?, String>((
  ref,
  lectureId,
) async {
  Future<Map<String, dynamic>> fetchRemote() async {
    final res = await Supabase.instance.client
        .from('lectures')
        .select(
          'id, start_at, end_at, attendance_window_start, attendance_window_end, practical_sessions(title, subject_id, subjects(location))',
        )
        .eq('id', lectureId)
        .single();
    return Map<String, dynamic>.from(res);
  }

  final prefs = await SharedPreferences.getInstance();
  final cacheKey = 'qr_lecture_$lectureId';
  final cached = prefs.getString(cacheKey);

  if (cached != null) {
    final cachedMap = Map<String, dynamic>.from(
      jsonDecode(cached) as Map<String, dynamic>,
    );

    unawaited(
      fetchRemote()
          .then((fresh) async {
            await prefs.setString(cacheKey, jsonEncode(fresh));
          })
          .catchError((_) {}),
    );

    return cachedMap;
  }

  try {
    final res = await fetchRemote();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(cacheKey, jsonEncode(res));
    return res;
  } catch (_) {
    return null;
  }
});

class QrScreen extends ConsumerStatefulWidget {
  final String lectureId;
  final String? subjectId;
  final String? seed;
  final String? eventType;
  const QrScreen({
    super.key,
    required this.lectureId,
    this.subjectId,
    this.seed,
    this.eventType,
  });

  @override
  ConsumerState<QrScreen> createState() => _QrScreenState();
}

class _QrScreenState extends ConsumerState<QrScreen> {
  final FlutterBlePeripheral _peripheral = FlutterBlePeripheral();
  bool _isAdvertising = false;
  bool _isBusy = false;
  String? _status;
  Timer? _attendancePollTimer;
  bool _attendanceProbeInFlight = false;
  Timer? _autoStartRetryTimer;
  int _autoStartAttempts = 0;
  bool _autoStartEnabled = true;
  StreamSubscription<List<ScanResult>>? _ackScanSub;
  int _requestNonce16 = 0;
  bool _ackHandled = false;

  int _nextRequestNonce16() {
    final raw = DateTime.now().microsecondsSinceEpoch & 0xFFFF;
    return raw == 0 ? 1 : raw;
  }

  BleAttendanceEventType _selectedEventType() {
    return widget.eventType == 'check_out'
        ? BleAttendanceEventType.checkOut
        : BleAttendanceEventType.checkIn;
  }

  _AttendanceProbeTarget _selectedProbeTarget() {
    return _selectedEventType() == BleAttendanceEventType.checkOut
        ? _AttendanceProbeTarget.checkOut
        : _AttendanceProbeTarget.checkIn;
  }

  bool _isGrantedState(PeripheralBluetoothState state) {
    final value = state.toString().toLowerCase();
    return value.contains('granted') || value.contains('ready');
  }

  bool _isTurnedOffState(PeripheralBluetoothState state) {
    final value = state.toString().toLowerCase();
    return value.contains('turnedoff') || value.endsWith('.off');
  }

  @override
  void initState() {
    super.initState();
    unawaited(_startAdvertising());
    _scheduleAutoStartRetry();
  }

  void _scheduleAutoStartRetry() {
    _autoStartRetryTimer?.cancel();
    _autoStartRetryTimer = Timer.periodic(const Duration(seconds: 2), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (!_autoStartEnabled) {
        timer.cancel();
        return;
      }
      if (_isAdvertising) {
        timer.cancel();
        return;
      }
      if (_isBusy) {
        return;
      }
      if (_autoStartAttempts >= 3) {
        timer.cancel();
        return;
      }
      _autoStartAttempts++;
      unawaited(_startAdvertising());
    });
  }

  Map<String, dynamic>? _parseSeed() {
    if (widget.seed == null || widget.seed!.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(widget.seed!);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
      return null;
    } catch (_) {
      return null;
    }
  }

  String _formatDuration(int mins) {
    if (mins <= 0) return '';
    final hours = mins ~/ 60;
    final rem = mins % 60;
    if (hours == 0) return '$mins د';
    if (rem == 0) return '$hours س';
    return '$hours س $rem د';
  }

  DateTime _toSyriaTime(DateTime value) {
    const syriaOffset = Duration(hours: 3);
    return (value.isUtc ? value : value.toUtc()).add(syriaOffset);
  }

  String _formatLectureTime(Map<String, dynamic> lecture) {
    final startRaw = DateTime.tryParse(lecture['start_at'] as String? ?? '');
    final endRaw = DateTime.tryParse(lecture['end_at'] as String? ?? '');
    final start = startRaw == null ? null : _toSyriaTime(startRaw);
    final end = endRaw == null ? null : _toSyriaTime(endRaw);
    if (start == null) return '—';
    final dateStr = DateFormat('yyyy-MM-dd').format(start);
    final timeStr = DateFormat('HH:mm').format(start);
    final dur = end == null
        ? ''
        : _formatDuration(end.difference(start).inMinutes);
    final durStr = dur.isEmpty ? '' : ' · $dur';
    return '$dateStr · $timeStr$durStr';
  }

  void _goBack(BuildContext context, Map<String, dynamic>? lecture) {
    final sid =
        widget.subjectId ??
        (lecture?['subject_id'] as String?) ??
        (lecture?['practical_sessions'] as Map<String, dynamic>?)?['subject_id']
            as String?;
    if (sid == null) {
      Navigator.of(context).maybePop();
      return;
    }
    context.go('/practical/sessions/$sid');
  }

  Future<void> _startAdvertising() async {
    if (_isBusy || _isAdvertising) return;
    setState(() {
      _isBusy = true;
      _status = null;
    });

    try {
      final isSupported = await _peripheral.isSupported;
      if (!isSupported) {
        setState(() {
          _status = 'الجهاز لا يدعم بث BLE';
          _isBusy = false;
        });
        return;
      }

      var permissionState = await _peripheral.hasPermission();

      if (!_isGrantedState(permissionState)) {
        permissionState = await _peripheral.requestPermission();
      }

      if (!_isGrantedState(permissionState) &&
          !_isTurnedOffState(permissionState)) {
        setState(() {
          _status =
              'صلاحية البلوتوث غير كافية (${permissionState.toString()})، يرجى السماح بالتطبيق من الإعدادات';
        });
        return;
      }

      if (_isTurnedOffState(permissionState)) {
        final enabled = await _peripheral.enableBluetooth();
        if (!enabled) {
          setState(() {
            _status = 'يرجى تفعيل البلوتوث';
            _isBusy = false;
          });
          return;
        }

        permissionState = await _peripheral.hasPermission();
        if (!_isGrantedState(permissionState)) {
          setState(() {
            _status =
                'تم تشغيل البلوتوث لكن الصلاحية ليست جاهزة (${permissionState.toString()})';
          });
          return;
        }
      }

      final uid = Supabase.instance.client.auth.currentUser!.id;
      _requestNonce16 = _nextRequestNonce16();
      _ackHandled = false;
      final probeTarget = _selectedProbeTarget();
      final payload = BleAttendanceCodec.buildManufacturerData(
        studentId: uid,
        lectureId: widget.lectureId,
        eventType: _selectedEventType(),
        requestNonce16: _requestNonce16,
      );
      final serviceUuids = BleAttendanceCodec.buildServiceUuidsForBroadcast(
        studentId: uid,
        lectureId: widget.lectureId,
        eventType: _selectedEventType(),
        requestNonce16: _requestNonce16,
      );

      final advertiseData = AdvertiseDataCore(
        serviceUuids: serviceUuids,
        manufacturerId: BleAttendanceCodec.manufacturerId,
        manufacturerData: payload,
      );
      final androidServiceData = AndroidAdvertiseData(
        serviceDataUuid: BleAttendanceCodec.markerServiceUuidShort,
        serviceData: payload,
      );

      final attempts = <({String name, AdvertiseDataCore data})>[
        (name: 'full payload', data: advertiseData),
        if (Platform.isAndroid)
          (name: 'android serviceData payload', data: androidServiceData),
        (
          name: 'serviceUuids only',
          data: AdvertiseDataCore(serviceUuids: serviceUuids),
        ),
      ];

      Object? lastError;
      for (var i = 0; i < attempts.length; i++) {
        final attempt = attempts[i];
        try {
          await _peripheral.start(advertiseData: attempt.data);
          lastError = null;
          break;
        } catch (e) {
          lastError = e;
          final text = e.toString();
          final isTooLarge = text.contains('ADVERTISE_FAILED_DATA_TOO_LARGE');
          final isLastAttempt = i == attempts.length - 1;
          if (!isTooLarge || isLastAttempt) {
            rethrow;
          }
        }
      }

      if (lastError != null) {
        throw lastError;
      }

      final started = await _peripheral.isAdvertising;

      setState(() {
        _isAdvertising = started;
        _status = started
            ? 'تم بدء الإرسال بنجاح، قم بتقريب جهازك من جهاز المقيم'
            : 'تعذر بدء الإرسال، تحقق من البلوتوث والصلاحيات';
      });

      if (started) {
        _autoStartRetryTimer?.cancel();
        _startAttendancePolling(studentId: uid, probeTarget: probeTarget);
        unawaited(_startAckListening(uid));
      }
    } catch (_) {
      setState(() {
        _status = 'تعذر بدء الإرسال، حاول مجدداً';
      });
    } finally {
      if (mounted) {
        setState(() => _isBusy = false);
      }
    }
  }

  Future<void> _stopAdvertising() async {
    _cancelAttendancePolling();
    await _stopAckListening();
    try {
      await _peripheral.stop();
    } catch (_) {}
    if (!mounted) return;
    setState(() => _isAdvertising = false);
  }

  Future<void> _startAckListening(String studentId) async {
    try {
      if (!await FlutterBluePlus.isSupported) return;

      final adapterState = await FlutterBluePlus.adapterState.first;
      if (adapterState != BluetoothAdapterState.on) {
        try {
          await FlutterBluePlus.turnOn();
        } catch (_) {
          return;
        }
      }

      await FlutterBluePlus.stopScan();
      await _ackScanSub?.cancel();
      _ackScanSub = FlutterBluePlus.onScanResults.listen(
        (results) => _onAckScanResults(results, studentId),
        onError: (_) {},
      );
      await FlutterBluePlus.startScan(
        timeout: const Duration(days: 1),
        androidUsesFineLocation: false,
      );
    } catch (_) {}
  }

  Future<void> _stopAckListening() async {
    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {}
    await _ackScanSub?.cancel();
    _ackScanSub = null;
  }

  Future<void> _onAckScanResults(
    List<ScanResult> results,
    String studentId,
  ) async {
    if (_ackHandled || !_isAdvertising) return;
    final expectedToken = BleAttendanceCodec.lectureToken16(widget.lectureId);
    final expectedEvent = _selectedEventType();

    for (final result in results) {
      final serviceUuids = result.advertisementData.serviceUuids
          .map((g) => g.toString())
          .toList();
      if (serviceUuids.isEmpty) continue;

      final ack = BleAttendanceCodec.parseAckFromServiceUuids(
        serviceUuids: serviceUuids,
        studentId: studentId,
      );
      if (ack == null) continue;
      if (ack.lectureToken16 != expectedToken) continue;
      if (ack.eventType != expectedEvent) continue;
      if (ack.requestNonce16 != _requestNonce16) continue;

      _ackHandled = true;
      if (!mounted) return;
      setState(() {
        _status = ack.statusCode == 1
            ? (expectedEvent == BleAttendanceEventType.checkIn
                  ? 'لقد تم تسجيل الدخول بنجاح ✓'
                  : 'لقد تم تسجيل الخروج بنجاح ✓')
            : (expectedEvent == BleAttendanceEventType.checkIn
                  ? 'تم استلام تسجيل الدخول وسيتم رفعه عند توفر الإنترنت ✓'
                  : 'تم استلام تسجيل الخروج وسيتم رفعه عند توفر الإنترنت ✓');
      });

      await Future<void>.delayed(const Duration(milliseconds: 500));
      await _stopAdvertising();
      if (!mounted || !context.mounted) return;
      _goBack(context, null);
      return;
    }
  }

  @override
  void dispose() {
    _cancelAttendancePolling();
    _autoStartRetryTimer?.cancel();
    unawaited(_stopAdvertising());
    super.dispose();
  }

  Future<Map<String, dynamic>?> _fetchAttendanceRow(String studentId) async {
    final res = await Supabase.instance.client
        .from('practical_attendance')
        .select('id, check_in_at, check_out_at')
        .eq('lecture_id', widget.lectureId)
        .eq('student_id', studentId)
        .maybeSingle();
    if (res == null) return null;
    return Map<String, dynamic>.from(res);
  }

  Future<void> _updateLocalSessionAttendanceCache({
    required String subjectId,
    required Map<String, dynamic>? attendanceRow,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = 'practical_sessions_subject_$subjectId';
      final raw = prefs.getString(key);
      if (raw == null) return;

      final list = List<Map<String, dynamic>>.from(
        (jsonDecode(raw) as List).cast<Map<String, dynamic>>(),
      );

      bool changed = false;
      for (final item in list) {
        final assignment = item['assignment'] as Map<String, dynamic>?;
        final lectureId = assignment?['lecture_id'] as String?;
        if (lectureId != widget.lectureId) continue;

        final hasCheckIn = attendanceRow?['check_in_at'] != null;
        final hasCheckOut = attendanceRow?['check_out_at'] != null;

        int? spentMinutes;
        if (hasCheckIn && hasCheckOut) {
          final checkIn = DateTime.tryParse(
            attendanceRow!['check_in_at'] as String,
          );
          final checkOut = DateTime.tryParse(
            attendanceRow['check_out_at'] as String,
          );
          if (checkIn != null &&
              checkOut != null &&
              checkOut.isAfter(checkIn)) {
            spentMinutes = checkOut.difference(checkIn).inMinutes;
          }
        }

        String attendanceState;
        if (assignment == null) {
          attendanceState = 'unassigned';
        } else if (!hasCheckIn) {
          attendanceState = 'pending_check_in';
        } else if (!hasCheckOut) {
          attendanceState = 'pending_check_out';
        } else {
          attendanceState = 'completed';
        }

        item['has_check_in'] = hasCheckIn;
        item['has_check_out'] = hasCheckOut;
        item['spent_minutes'] = spentMinutes;
        item['attendance_state'] = attendanceState;
        changed = true;
        break;
      }

      if (!changed) return;
      await prefs.setString(key, jsonEncode(list));
    } catch (_) {}
  }

  void _startAttendancePolling({
    required String studentId,
    required _AttendanceProbeTarget probeTarget,
  }) {
    _cancelAttendancePolling();
    if (probeTarget == _AttendanceProbeTarget.none) {
      return;
    }

    _attendancePollTimer = Timer(const Duration(seconds: 2), () async {
      final done = await _checkAttendanceProbe(
        studentId: studentId,
        target: probeTarget,
      );
      if (done || !mounted || !_isAdvertising) return;

      _attendancePollTimer = Timer.periodic(const Duration(seconds: 5), (
        timer,
      ) async {
        final confirmed = await _checkAttendanceProbe(
          studentId: studentId,
          target: probeTarget,
        );
        if (confirmed || !mounted || !_isAdvertising) {
          timer.cancel();
          if (identical(_attendancePollTimer, timer)) {
            _attendancePollTimer = null;
          }
        }
      });
    });
  }

  Future<bool> _checkAttendanceProbe({
    required String studentId,
    required _AttendanceProbeTarget target,
  }) async {
    if (_attendanceProbeInFlight) return false;
    _attendanceProbeInFlight = true;
    try {
      final row = await _fetchAttendanceRow(studentId);
      final hasCheckIn = row?['check_in_at'] != null;
      final hasCheckOut = row?['check_out_at'] != null;

      final matched =
          (target == _AttendanceProbeTarget.checkIn && hasCheckIn) ||
          (target == _AttendanceProbeTarget.checkOut && hasCheckOut);

      if (!matched) {
        return false;
      }

      final sid = widget.subjectId;
      if (sid != null && sid.isNotEmpty) {
        await _updateLocalSessionAttendanceCache(
          subjectId: sid,
          attendanceRow: row,
        );
      }

      if (!mounted) return true;
      setState(() {
        _status = target == _AttendanceProbeTarget.checkIn
            ? 'تم تأكيد تسجيل الدخول ✓'
            : 'تم تأكيد تسجيل الخروج ✓';
      });

      if (sid != null && sid.isNotEmpty) {
        ref.invalidate(practicalSessionsBySubjectProvider(sid));
      }
      _cancelAttendancePolling();

      await _stopAdvertising();
      if (!mounted || !context.mounted) return true;
      _goBack(context, null);
      return true;
    } catch (_) {
      return false;
    } finally {
      _attendanceProbeInFlight = false;
    }
  }

  void _cancelAttendancePolling() {
    _attendancePollTimer?.cancel();
    _attendancePollTimer = null;
  }

  @override
  Widget build(BuildContext context) {
    final lectureAsync = ref.watch(qrLectureProvider(widget.lectureId));
    final seededLecture = _parseSeed();
    final lecture = lectureAsync.valueOrNull ?? seededLecture;

    final lectureData = lecture ?? <String, dynamic>{};

    final sessionTitle =
        (lectureData['practical_sessions']
            as Map<String, dynamic>?)?['title'] ??
        'جلسة عملية';

    final isCheckOut = _selectedEventType() == BleAttendanceEventType.checkOut;
    final eventTitle = isCheckOut
        ? 'إرسال تسجيل الخروج عبر BLE'
        : 'إرسال تسجيل الدخول عبر BLE';
    final eventHelp = isCheckOut
        ? 'اضغط بدء الإرسال ثم اقترب من جهاز المقيم الذي فعّل وضع تسجيل الخروج.'
        : 'اضغط بدء الإرسال ثم اقترب من جهاز المقيم الذي فعّل وضع تسجيل الدخول.';

    return WillPopScope(
      onWillPop: () async {
        await _stopAdvertising();
        _goBack(context, lecture);
        return false;
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back_rounded),
            onPressed: () async {
              await _stopAdvertising();
              if (!mounted || !context.mounted) return;
              _goBack(context, lecture);
            },
          ),
          title: Text(eventTitle),
        ),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  sessionTitle,
                  style: Theme.of(context).textTheme.titleLarge,
                  textAlign: TextAlign.center,
                ),
                const Gap(6),
                Text(
                  _formatLectureTime(lectureData),
                  style: Theme.of(context).textTheme.bodyMedium,
                  textAlign: TextAlign.center,
                ),
                const Gap(24),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: Theme.of(
                      context,
                    ).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: Theme.of(
                        context,
                      ).dividerColor.withValues(alpha: 0.25),
                    ),
                  ),
                  child: Column(
                    children: [
                      Icon(
                        _isAdvertising
                            ? Icons.bluetooth_connected_rounded
                            : Icons.bluetooth_rounded,
                        size: 72,
                        color: _isAdvertising
                            ? Colors.green
                            : Theme.of(context).colorScheme.primary,
                      ),
                      const Gap(12),
                      Text(
                        _isAdvertising ? 'يتم الإرسال الآن' : eventHelp,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                      if (_status != null) ...[
                        const Gap(10),
                        Text(
                          _status!,
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      ],
                      const Gap(16),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          onPressed: _isBusy
                              ? null
                              : (_isAdvertising
                                    ? () {
                                        _autoStartEnabled = false;
                                        unawaited(_stopAdvertising());
                                      }
                                    : () {
                                        _autoStartEnabled = true;
                                        _autoStartAttempts = 0;
                                        unawaited(_startAdvertising());
                                        _scheduleAutoStartRetry();
                                      }),
                          icon: Icon(
                            _isAdvertising
                                ? Icons.stop_circle_outlined
                                : Icons.play_arrow_rounded,
                          ),
                          label: Text(
                            _isAdvertising ? 'إيقاف الإرسال' : 'بدء الإرسال',
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
