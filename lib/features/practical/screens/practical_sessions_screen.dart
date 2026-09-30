import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:go_router/go_router.dart';
import 'package:gap/gap.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:stagelink_student/core/utils/app_error_message.dart';
import '../../../core/theme/app_theme.dart';

Future<void> _cacheQrLecturesLocally(List assignments) async {
  final prefs = await SharedPreferences.getInstance();
  for (final a in assignments) {
    final map = a as Map<String, dynamic>;
    final lecture = map['lectures'] as Map<String, dynamic>?;
    final lectureId = map['lecture_id'] as String?;
    if (lecture == null || lectureId == null) continue;
    await prefs.setString('qr_lecture_$lectureId', jsonEncode(lecture));
  }
}

Future<List<Map<String, dynamic>>> _fetchPracticalSessionsRemote({
  required String uid,
  required String subjectId,
}) async {
  // Get all sessions for this subject
  final sessions = await Supabase.instance.client
      .from('practical_sessions')
      .select('id, title, prerequisite_video_id, order_index, created_at')
      .eq('subject_id', subjectId)
      .order('order_index')
      .order('created_at');

  // Get student's lecture assignments (join through lectures to get session_id)
  final assignmentsRes = await Supabase.instance.client
      .from('lecture_assignments')
      .select(
        'lecture_id, subgroup_letter, lectures(id, practical_session_id, start_at, end_at, attendance_window_start, attendance_window_end, practical_sessions(subject_id, subjects(location)))',
      )
      .eq('student_id', uid);
  final assignments = List<Map<String, dynamic>>.from(assignmentsRes as List);

  // Cache lecture payloads locally so attendance screen can still work offline.
  await _cacheQrLecturesLocally(assignments);

  // Map: session_id -> assignment
  final assignMap = <String, Map<String, dynamic>>{};
  for (final a in assignments) {
    final lecture = a['lectures'] as Map<String, dynamic>?;
    if (lecture == null) continue;
    final sessionId = lecture['practical_session_id'] as String;
    assignMap[sessionId] = a;
  }

  // Get attendance state for each lecture (check-in/check-out)
  final attendance = await Supabase.instance.client
      .from('practical_attendance')
      .select('lecture_id, check_in_at, check_out_at')
      .eq('student_id', uid);
  final attendanceMap = <String, Map<String, dynamic>>{};
  for (final row in (attendance as List)) {
    final map = Map<String, dynamic>.from(row as Map);
    final lectureId = map['lecture_id'] as String?;
    if (lectureId == null) continue;
    attendanceMap[lectureId] = map;
  }

  final result = (sessions as List).map((s) {
    final session = Map<String, dynamic>.from(s as Map);
    final assign = assignMap[session['id'] as String];
    final lectureId = assign?['lecture_id'] as String?;
    final attendanceRow = lectureId == null ? null : attendanceMap[lectureId];
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
      if (checkIn != null && checkOut != null && checkOut.isAfter(checkIn)) {
        spentMinutes = checkOut.difference(checkIn).inMinutes;
      }
    }

    String attendanceState;
    if (assign == null) {
      attendanceState = 'unassigned';
    } else if (attendanceRow == null || attendanceRow['check_in_at'] == null) {
      attendanceState = 'pending_check_in';
    } else if (attendanceRow['check_out_at'] == null) {
      attendanceState = 'pending_check_out';
    } else {
      attendanceState = 'completed';
    }

    return {
      ...session,
      'assignment': assign,
      'attendance_state': attendanceState,
      'has_check_in': hasCheckIn,
      'has_check_out': hasCheckOut,
      'check_in_at': attendanceRow?['check_in_at'],
      'check_out_at': attendanceRow?['check_out_at'],
      'spent_minutes': spentMinutes,
    };
  }).toList();

  result.sort((a, b) {
    final ao = a['order_index'] as int?;
    final bo = b['order_index'] as int?;
    if (ao != null && bo != null) return ao.compareTo(bo);
    if (ao != null) return -1;
    if (bo != null) return 1;
    final an = (a['title'] as String? ?? '').toLowerCase();
    final bn = (b['title'] as String? ?? '').toLowerCase();
    return an.compareTo(bn);
  });

  return result;
}

Future<List<Map<String, dynamic>>?> _readPracticalSessionsCache(
  String subjectId,
) async {
  final prefs = await SharedPreferences.getInstance();
  final cachedRaw = prefs.getString('practical_sessions_subject_$subjectId');
  if (cachedRaw == null) return null;
  return List<Map<String, dynamic>>.from(
    (jsonDecode(cachedRaw) as List).cast<Map<String, dynamic>>(),
  );
}

Future<void> _writePracticalSessionsCache(
  String subjectId,
  List<Map<String, dynamic>> data,
) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(
    'practical_sessions_subject_$subjectId',
    jsonEncode(data),
  );
}

// Sessions for a subject
final practicalSessionsBySubjectProvider =
    FutureProvider.family<List<Map<String, dynamic>>, String>((
      ref,
      subjectId,
    ) async {
      List<Map<String, dynamic>> sortSessions(List<Map<String, dynamic>> list) {
        final out = List<Map<String, dynamic>>.from(list);
        out.sort((a, b) {
          final ao = a['order_index'] as int?;
          final bo = b['order_index'] as int?;
          if (ao != null && bo != null) return ao.compareTo(bo);
          if (ao != null) return -1;
          if (bo != null) return 1;
          final an = (a['title'] as String? ?? '').toLowerCase();
          final bn = (b['title'] as String? ?? '').toLowerCase();
          return an.compareTo(bn);
        });
        return out;
      }

      final uid = Supabase.instance.client.auth.currentUser!.id;
      final cached = await _readPracticalSessionsCache(subjectId);
      if (cached != null) {
        return sortSessions(cached);
      }

      final fresh = await _fetchPracticalSessionsRemote(
        uid: uid,
        subjectId: subjectId,
      );
      await _writePracticalSessionsCache(subjectId, fresh);
      return sortSessions(fresh);
    });

class PracticalSessionsScreen extends ConsumerStatefulWidget {
  final String subjectId;
  final String? ackResult;
  final String? ackEventType;

  const PracticalSessionsScreen({
    super.key,
    required this.subjectId,
    this.ackResult,
    this.ackEventType,
  });

  @override
  ConsumerState<PracticalSessionsScreen> createState() =>
      _PracticalSessionsScreenState();
}

class _PracticalSessionsScreenState
    extends ConsumerState<PracticalSessionsScreen> {
  bool _didShowAckMessage = false;
  StreamSubscription<List<Map<String, dynamic>>>? _attendanceRealtimeSub;
  Set<String> _visibleLectureIds = <String>{};
  Timer? _elapsedTicker;
  DateTime _nowLocal = DateTime.now();

  ButtonStyle _compactBleButtonStyle(BuildContext context) {
    final buttonTextStyle = Theme.of(context).textTheme.labelLarge?.copyWith(
      fontSize: 13,
      fontWeight: FontWeight.w600,
      height: 1.1,
    );

    return ElevatedButton.styleFrom(
      minimumSize: const Size.fromHeight(40),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      textStyle: buttonTextStyle,
    );
  }

  void _goBackToPreviousOrHome() {
    if (context.canPop()) {
      context.pop();
      return;
    }
    context.go('/');
  }

  @override
  void initState() {
    super.initState();
    _startRealtimeAttendanceSync();
    unawaited(_refreshSessionsFromServerOnce());
    _elapsedTicker = Timer.periodic(const Duration(seconds: 30), (_) {
      if (!mounted) return;
      setState(() => _nowLocal = DateTime.now());
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _showAckMessageIfAny();
    });
  }

  @override
  void dispose() {
    _attendanceRealtimeSub?.cancel();
    _elapsedTicker?.cancel();
    super.dispose();
  }

  void _showAckMessageIfAny() {
    if (!mounted || _didShowAckMessage) return;

    final ackResult = widget.ackResult;
    final ackEventType = widget.ackEventType;
    if (ackResult == null || ackEventType == null) return;

    _showAckMessage(ackResult: ackResult, ackEventType: ackEventType);
  }

  void _showAckMessage({
    required String ackResult,
    required String ackEventType,
  }) {
    if (!mounted || _didShowAckMessage) return;

    final isCheckOut = ackEventType == 'check_out';
    final isQueued = ackResult == 'queued';

    final text = isQueued
        ? (isCheckOut
              ? 'تم استلام تسجيل الخروج وسيتم رفعه عند توفر الإنترنت ✓'
              : 'تم استلام تسجيل الدخول وسيتم رفعه عند توفر الإنترنت ✓')
        : (isCheckOut ? 'تم تسجيل الخروج بنجاح ✓' : 'تم تسجيل الدخول بنجاح ✓');

    _didShowAckMessage = true;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(text),
          behavior: SnackBarBehavior.floating,
          backgroundColor: Colors.green,
          duration: const Duration(seconds: 5),
        ),
      );
  }

  void _startRealtimeAttendanceSync() {
    final uid = Supabase.instance.client.auth.currentUser?.id;
    if (uid == null) return;

    _attendanceRealtimeSub = Supabase.instance.client
        .from('practical_attendance')
        .stream(primaryKey: ['id'])
        .eq('student_id', uid)
        .listen(
          (rows) {
            unawaited(_applyRealtimeAttendanceRows(rows));
          },
          onError: (_, __) {
            // Ignore transient realtime errors while offline.
          },
        );
  }

  Future<void> _applyRealtimeAttendanceRows(
    List<Map<String, dynamic>> rows,
  ) async {
    if (!mounted || _visibleLectureIds.isEmpty) return;
    try {
      final rowByLecture = <String, Map<String, dynamic>>{};
      for (final row in rows) {
        final lectureId = row['lecture_id'] as String?;
        if (lectureId == null || !_visibleLectureIds.contains(lectureId)) {
          continue;
        }
        rowByLecture[lectureId] = row;
      }

      if (rowByLecture.isEmpty) return;

      final prefs = await SharedPreferences.getInstance();
      final key = 'practical_sessions_subject_${widget.subjectId}';
      final raw = prefs.getString(key);
      if (raw == null) return;

      final list = List<Map<String, dynamic>>.from(
        (jsonDecode(raw) as List).cast<Map<String, dynamic>>(),
      );

      bool changed = false;
      for (final item in list) {
        final assignment = item['assignment'] as Map<String, dynamic>?;
        final lectureId = assignment?['lecture_id'] as String?;
        if (lectureId == null) continue;
        if (!_visibleLectureIds.contains(lectureId)) continue;

        final attendanceRow = rowByLecture[lectureId];
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

        final oldCheckIn = (item['has_check_in'] as bool?) ?? false;
        final oldCheckOut = (item['has_check_out'] as bool?) ?? false;
        final oldSpent = item['spent_minutes'] as int?;
        final oldState = item['attendance_state'] as String?;

        if (oldCheckIn != hasCheckIn ||
            oldCheckOut != hasCheckOut ||
            oldSpent != spentMinutes ||
            oldState != attendanceState) {
          item['has_check_in'] = hasCheckIn;
          item['has_check_out'] = hasCheckOut;
          item['check_in_at'] = attendanceRow?['check_in_at'];
          item['check_out_at'] = attendanceRow?['check_out_at'];
          item['spent_minutes'] = spentMinutes;
          item['attendance_state'] = attendanceState;
          changed = true;
        }
      }

      if (!changed) return;
      await prefs.setString(key, jsonEncode(list));
      if (!mounted) return;
      ref.invalidate(practicalSessionsBySubjectProvider(widget.subjectId));
    } catch (_) {}
  }

  Future<void> _refreshSessionsFromServerOnce() async {
    try {
      final uid = Supabase.instance.client.auth.currentUser?.id;
      if (uid == null) return;
      final fresh = await _fetchPracticalSessionsRemote(
        uid: uid,
        subjectId: widget.subjectId,
      );
      await _writePracticalSessionsCache(widget.subjectId, fresh);
      if (!mounted) return;
      ref.invalidate(practicalSessionsBySubjectProvider(widget.subjectId));
    } catch (_) {}
  }

  Map<String, dynamic> _buildQrSeed(
    Map<String, dynamic> lecture,
    String sessionTitle,
  ) {
    return {
      ...lecture,
      'practical_sessions': {'title': sessionTitle},
    };
  }

  Future<void> _openQr(
    BuildContext context, {
    required String subjectId,
    required String lectureId,
    required Map<String, dynamic> lecture,
    required String sessionTitle,
    required String eventType,
  }) async {
    _didShowAckMessage = false;
    final seedMap = _buildQrSeed(lecture, sessionTitle);
    final seedJson = jsonEncode(seedMap);

    // Persist locally first to make QR details instantly available offline.
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('qr_lecture_$lectureId', seedJson);

    final seedEncoded = Uri.encodeComponent(seedJson);
    if (!context.mounted) return;
    final qrResult = await context.push<Map<String, String>>(
      '/practical/qr/$lectureId?subjectId=$subjectId&seed=$seedEncoded&eventType=$eventType',
    );
    if (!mounted || qrResult == null) return;

    final ackResult = qrResult['ack'];
    final ackEventType = qrResult['eventType'];
    if (ackResult == null || ackEventType == null) return;

    _showAckMessage(ackResult: ackResult, ackEventType: ackEventType);
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

  String _formatLectureLine(Map<String, dynamic> lecture) {
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

  String _formatSpentMinutes(int? mins) {
    if (mins == null || mins <= 0) return '—';
    final h = mins ~/ 60;
    final m = mins % 60;
    if (h == 0) return '$m د';
    if (m == 0) return '$h س';
    return '$h س $m د';
  }

  String _formatTimeOnly(String? iso) {
    if (iso == null || iso.trim().isEmpty) return '—';
    final dt = DateTime.tryParse(iso);
    if (dt == null) return '—';
    return DateFormat('HH:mm').format(dt.toLocal());
  }

  int? _computeLiveSpentMinutes({
    required String? checkInAt,
    required bool hasCheckOut,
    required int? storedSpentMinutes,
  }) {
    if (hasCheckOut) return storedSpentMinutes;
    if (checkInAt == null || checkInAt.trim().isEmpty)
      return storedSpentMinutes;
    final checkIn = DateTime.tryParse(checkInAt);
    if (checkIn == null) return storedSpentMinutes;
    final diff = _nowLocal.difference(checkIn.toLocal()).inMinutes;
    return diff < 0 ? 0 : diff;
  }

  @override
  Widget build(BuildContext context) {
    final sessionsAsync = ref.watch(
      practicalSessionsBySubjectProvider(widget.subjectId),
    );
    return WillPopScope(
      onWillPop: () async {
        _goBackToPreviousOrHome();
        return false;
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.ondemand_video_rounded),
            tooltip: 'فيديوهات اختيارية',
            onPressed: () =>
                context.push('/practical/videos/${widget.subjectId}'),
          ),
          title: const Text('جلساتي العملية'),
          actions: [
            IconButton(
              icon: const Icon(Icons.arrow_forward_rounded),
              onPressed: _goBackToPreviousOrHome,
            ),
          ],
        ),
        body: sessionsAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text(AppErrorMessage.from(e))),
          data: (sessions) {
            _visibleLectureIds = sessions
                .map(
                  (s) =>
                      (s['assignment'] as Map<String, dynamic>?)?['lecture_id']
                          as String?,
                )
                .whereType<String>()
                .where((id) => id.isNotEmpty)
                .toSet();

            return sessions.isEmpty
                ? const Center(child: Text('لا توجد جلسات'))
                : RefreshIndicator(
                    onRefresh: () async {
                      final uid = Supabase.instance.client.auth.currentUser!.id;
                      final fresh = await _fetchPracticalSessionsRemote(
                        uid: uid,
                        subjectId: widget.subjectId,
                      );
                      await _writePracticalSessionsCache(
                        widget.subjectId,
                        fresh,
                      );
                      ref.invalidate(
                        practicalSessionsBySubjectProvider(widget.subjectId),
                      );
                      await ref.read(
                        practicalSessionsBySubjectProvider(
                          widget.subjectId,
                        ).future,
                      );
                    },
                    child: ListView.builder(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      itemCount: sessions.length,
                      itemBuilder: (context, i) {
                        final s = sessions[i];
                        final assignment =
                            s['assignment'] as Map<String, dynamic>?;
                        final attendanceState =
                            s['attendance_state'] as String? ??
                            'pending_check_in';
                        final isCompleted = attendanceState == 'completed';
                        final hasCheckIn =
                            (s['has_check_in'] as bool?) ?? false;
                        final hasCheckOut =
                            (s['has_check_out'] as bool?) ?? false;
                        final checkInAt = s['check_in_at'] as String?;
                        final checkOutAt = s['check_out_at'] as String?;
                        final spentMinutes = s['spent_minutes'] as int?;
                        final displaySpentMinutes = _computeLiveSpentMinutes(
                          checkInAt: checkInAt,
                          hasCheckOut: hasCheckOut,
                          storedSpentMinutes: spentMinutes,
                        );
                        final muted = Theme.of(
                          context,
                        ).colorScheme.onSurface.withValues(alpha: 0.6);

                        Color statusColor;
                        String statusText;
                        IconData statusIcon;
                        if (isCompleted) {
                          statusColor = AppColors.success;
                          statusText = 'حاضر ✓';
                          statusIcon = Icons.check_circle_rounded;
                        } else if (hasCheckIn) {
                          statusColor = AppColors.primary;
                          statusText = 'تم تسجيل الدخول';
                          statusIcon = Icons.login_rounded;
                        } else if (assignment != null) {
                          statusColor = AppColors.warning;
                          statusText = 'مسجّل';
                          statusIcon = Icons.schedule_rounded;
                        } else {
                          statusColor = muted;
                          statusText = 'غير مسجّل';
                          statusIcon = Icons.help_outline_rounded;
                        }

                        final lecture =
                            assignment?['lectures'] as Map<String, dynamic>?;
                        final subgroupLetter =
                            assignment?['subgroup_letter'] as String?;

                        return Card(
                          margin: const EdgeInsets.only(bottom: 10),
                          child: Padding(
                            padding: const EdgeInsets.all(14),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        s['title'] as String,
                                        style: Theme.of(
                                          context,
                                        ).textTheme.titleMedium,
                                      ),
                                    ),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 10,
                                        vertical: 4,
                                      ),
                                      decoration: BoxDecoration(
                                        color: statusColor.withValues(
                                          alpha: 0.1,
                                        ),
                                        borderRadius: BorderRadius.circular(20),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(
                                            statusIcon,
                                            size: 14,
                                            color: statusColor,
                                          ),
                                          const Gap(4),
                                          Text(
                                            statusText,
                                            style: TextStyle(
                                              color: statusColor,
                                              fontSize: 12,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                                if (lecture != null) ...[
                                  const Gap(8),
                                  if (subgroupLetter != null &&
                                      subgroupLetter.trim().isNotEmpty) ...[
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 10,
                                        vertical: 4,
                                      ),
                                      decoration: BoxDecoration(
                                        color: AppColors.primary.withValues(
                                          alpha: 0.1,
                                        ),
                                        borderRadius: BorderRadius.circular(20),
                                      ),
                                      child: Text(
                                        'المجموعة $subgroupLetter',
                                        style: TextStyle(
                                          color: AppColors.primary,
                                          fontSize: 12,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ),
                                    const Gap(8),
                                  ],
                                  Row(
                                    children: [
                                      Icon(
                                        Icons.event_outlined,
                                        size: 14,
                                        color: muted,
                                      ),
                                      const Gap(4),
                                      Text(
                                        _formatLectureLine(lecture),
                                        style: Theme.of(
                                          context,
                                        ).textTheme.bodyMedium,
                                      ),
                                    ],
                                  ),
                                  const Gap(8),
                                  Row(
                                    children: [
                                      Expanded(
                                        child: _AttendanceInfoChip(
                                          icon: Icons.login_rounded,
                                          label: 'الدخول',
                                          value: _formatTimeOnly(checkInAt),
                                          color: AppColors.primary,
                                        ),
                                      ),
                                      const Gap(8),
                                      Expanded(
                                        child: _AttendanceInfoChip(
                                          icon: Icons.logout_rounded,
                                          label: 'الخروج',
                                          value: _formatTimeOnly(checkOutAt),
                                          color: AppColors.warning,
                                        ),
                                      ),
                                      const Gap(8),
                                      Expanded(
                                        child: _AttendanceInfoChip(
                                          icon: Icons.timer_outlined,
                                          label: 'المدة',
                                          value: _formatSpentMinutes(
                                            displaySpentMinutes,
                                          ),
                                          color: AppColors.success,
                                        ),
                                      ),
                                    ],
                                  ),
                                  if (!isCompleted) ...[
                                    const Gap(10),
                                    Row(
                                      children: [
                                        Expanded(
                                          child: ElevatedButton.icon(
                                            style: _compactBleButtonStyle(
                                              context,
                                            ),
                                            onPressed: () => _openQr(
                                              context,
                                              subjectId: widget.subjectId,
                                              lectureId:
                                                  assignment!['lecture_id']
                                                      as String,
                                              lecture: lecture,
                                              sessionTitle:
                                                  s['title'] as String,
                                              eventType: 'check_in',
                                            ),
                                            icon: const Icon(
                                              Icons.login_rounded,
                                              size: 18,
                                            ),
                                            label: const Text(
                                              'تسجيل دخول',
                                              maxLines: 1,
                                              overflow: TextOverflow.fade,
                                              softWrap: false,
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          child: ElevatedButton.icon(
                                            style: _compactBleButtonStyle(
                                              context,
                                            ),
                                            onPressed: () => _openQr(
                                              context,
                                              subjectId: widget.subjectId,
                                              lectureId:
                                                  assignment!['lecture_id']
                                                      as String,
                                              lecture: lecture,
                                              sessionTitle:
                                                  s['title'] as String,
                                              eventType: 'check_out',
                                            ),
                                            icon: const Icon(
                                              Icons.logout_rounded,
                                              size: 18,
                                            ),
                                            label: const Text(
                                              'تسجيل خروج',
                                              maxLines: 1,
                                              overflow: TextOverflow.fade,
                                              softWrap: false,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ],
                              ],
                            ),
                          ),
                        ).animate(delay: (40 * i).ms).fadeIn();
                      },
                    ),
                  );
          },
        ),
      ),
    );
  }
}

class _AttendanceInfoChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color color;

  const _AttendanceInfoChip({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 14, color: color),
              const Gap(4),
              Expanded(
                child: Text(
                  label,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: color,
                    fontWeight: FontWeight.w700,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const Gap(4),
          Text(
            value,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w700),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}
