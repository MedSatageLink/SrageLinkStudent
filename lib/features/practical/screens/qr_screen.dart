import 'dart:convert';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_ble_peripheral/flutter_ble_peripheral.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:go_router/go_router.dart';
import 'package:gap/gap.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../core/services/ble_attendance_codec.dart';

final qrLectureProvider = FutureProvider.family<Map<String, dynamic>?, String>((
  ref,
  lectureId,
) async {
  Future<Map<String, dynamic>> fetchRemote() async {
    final res = await Supabase.instance.client
        .from('lectures')
        .select(
          'id, start_at, end_at, location, attendance_window_start, attendance_window_end, practical_sessions(title)',
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

  bool _isGrantedState(PeripheralBluetoothState state) {
    final value = state.toString().toLowerCase();
    return value.contains('granted') || value.contains('ready');
  }

  bool _isTurnedOffState(PeripheralBluetoothState state) {
    final value = state.toString().toLowerCase();
    return value.contains('turnedoff') || value.endsWith('.off');
  }

  StudentAttendanceEventType get _eventType =>
      widget.eventType == StudentAttendanceEventType.checkOut.name
      ? StudentAttendanceEventType.checkOut
      : StudentAttendanceEventType.checkIn;

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
    final location = lecture['location'] as String? ?? '—';
    if (start == null) return '—';
    final dateStr = DateFormat('yyyy-MM-dd').format(start);
    final timeStr = DateFormat('HH:mm').format(start);
    final dur = end == null
        ? ''
        : _formatDuration(end.difference(start).inMinutes);
    final durStr = dur.isEmpty ? '' : ' · $dur';
    return '$dateStr · $timeStr · $location$durStr';
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
      if (!await _peripheral.isSupported) {
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
      final payload = BleAttendanceCodec.buildManufacturerData(
        studentId: uid,
        eventType: _eventType,
      );

      final advertiseData = AdvertiseDataCore(
        manufacturerId: BleAttendanceCodec.manufacturerId,
        manufacturerData: payload,
      );

      await _peripheral.start(advertiseData: advertiseData);

      final started = await _peripheral.isAdvertising;

      setState(() {
        _isAdvertising = started;
        _status = started
            ? 'تم بدء الإرسال بنجاح، قم بتقريب جهازك من جهاز المقيم'
            : 'تعذر بدء الإرسال، تحقق من البلوتوث والصلاحيات';
      });
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
    try {
      await _peripheral.stop();
    } catch (_) {}
    if (!mounted) return;
    setState(() => _isAdvertising = false);
  }

  @override
  void dispose() {
    unawaited(_stopAdvertising());
    super.dispose();
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

    final eventTitle = _eventType == StudentAttendanceEventType.checkIn
        ? 'إرسال تسجيل الدخول'
        : 'إرسال تسجيل الخروج';

    final eventHelp = _eventType == StudentAttendanceEventType.checkIn
        ? 'اضغط بدء الإرسال ثم اقترب من جهاز المقيم لتسجيل الدخول'
        : 'اضغط بدء الإرسال ثم اقترب من جهاز المقيم لتسجيل الخروج';

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
