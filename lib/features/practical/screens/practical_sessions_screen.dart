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
  const PracticalSessionsScreen({super.key, required this.subjectId});

  @override
  ConsumerState<PracticalSessionsScreen> createState() =>
      _PracticalSessionsScreenState();
}

class _PracticalSessionsScreenState
    extends ConsumerState<PracticalSessionsScreen> {
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
    unawaited(_refreshInBackgroundOnce());
  }

  Future<void> _refreshInBackgroundOnce() async {
    try {
      final uid = Supabase.instance.client.auth.currentUser!.id;
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
    final seedMap = _buildQrSeed(lecture, sessionTitle);
    final seedJson = jsonEncode(seedMap);

    // Persist locally first to make QR details instantly available offline.
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('qr_lecture_$lectureId', seedJson);

    final seedEncoded = Uri.encodeComponent(seedJson);
    if (!context.mounted) return;
    context.go(
      '/practical/qr/$lectureId?subjectId=$subjectId&seed=$seedEncoded&eventType=$eventType',
    );
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
          data: (sessions) => sessions.isEmpty
              ? const Center(child: Text('لا توجد جلسات'))
              : RefreshIndicator(
                  onRefresh: () async {
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
                      final hasCheckIn = (s['has_check_in'] as bool?) ?? false;
                      final hasCheckOut =
                          (s['has_check_out'] as bool?) ?? false;
                      final spentMinutes = s['spent_minutes'] as int?;
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
                                      color: statusColor.withValues(alpha: 0.1),
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
                                Text(
                                  'الدخول: ${hasCheckIn ? 'نعم' : 'لا'}   •   الخروج: ${hasCheckOut ? 'نعم' : 'لا'}   •   المدة: ${_formatSpentMinutes(spentMinutes)}',
                                  style: Theme.of(context).textTheme.bodySmall,
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
                                            sessionTitle: s['title'] as String,
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
                                            sessionTitle: s['title'] as String,
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
                ),
        ),
      ),
    );
  }
}
