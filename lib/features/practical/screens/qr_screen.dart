import 'dart:convert';
import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_ble_peripheral/flutter_ble_peripheral.dart';
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
  const QrScreen({
    super.key,
    required this.lectureId,
    this.subjectId,
    this.seed,
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

  String _formatLectureTime(Map<String, dynamic> lecture) {
    final start = DateTime.tryParse(lecture['start_at'] as String? ?? '');
    final end = DateTime.tryParse(lecture['end_at'] as String? ?? '');
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
      final probeTarget = await _resolveProbeTarget(uid);
      final payload = BleAttendanceCodec.buildManufacturerData(
        studentId: uid,
        lectureId: widget.lectureId,
      );
      final serviceUuids = BleAttendanceCodec.buildServiceUuids(studentId: uid);

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
        _startAttendancePolling(studentId: uid, probeTarget: probeTarget);
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
    try {
      await _peripheral.stop();
    } catch (_) {}
    if (!mounted) return;
    setState(() => _isAdvertising = false);
  }

  @override
  void dispose() {
    _cancelAttendancePolling();
    unawaited(_stopAdvertising());
    super.dispose();
  }

  Future<_AttendanceProbeTarget> _resolveProbeTarget(String studentId) async {
    try {
      final row = await _fetchAttendanceRow(studentId);
      if (row == null) return _AttendanceProbeTarget.checkIn;

      final hasCheckIn = row['check_in_at'] != null;
      final hasCheckOut = row['check_out_at'] != null;

      if (!hasCheckIn) return _AttendanceProbeTarget.checkIn;
      if (!hasCheckOut) return _AttendanceProbeTarget.checkOut;
      return _AttendanceProbeTarget.none;
    } catch (_) {
      return _AttendanceProbeTarget.checkIn;
    }
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

    const eventTitle = 'إرسال الحضور عبر BLE';
    const eventHelp =
        'اضغط بدء الإرسال ثم اقترب من جهاز المقيم. المقيم هو من يحدد تسجيل الدخول أو الخروج';

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
                                    ? _stopAdvertising
                                    : _startAdvertising),
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
