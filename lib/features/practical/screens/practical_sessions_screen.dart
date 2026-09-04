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
      .select('id, title, prerequisite_video_id')
      .eq('subject_id', subjectId)
      .order('created_at');

  // Get student's lecture assignments (join through lectures to get session_id)
  final assignmentsRes = await Supabase.instance.client
      .from('lecture_assignments')
      .select(
        'lecture_id, lectures(id, practical_session_id, start_at, end_at, location, attendance_window_start, attendance_window_end, profiles(full_name))',
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
      final checkIn = DateTime.tryParse(attendanceRow!['check_in_at'] as String);
      final checkOut = DateTime.tryParse(attendanceRow['check_out_at'] as String);
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
      final uid = Supabase.instance.client.auth.currentUser!.id;
      final cached = await _readPracticalSessionsCache(subjectId);
      if (cached != null) {
        unawaited(
          _fetchPracticalSessionsRemote(uid: uid, subjectId: subjectId)
              .then((fresh) => _writePracticalSessionsCache(subjectId, fresh))
              .catchError((_) {}),
        );
        return cached;
      }

      final fresh = await _fetchPracticalSessionsRemote(
        uid: uid,
        subjectId: subjectId,
      );
      await _writePracticalSessionsCache(subjectId, fresh);
      return fresh;
    });

class PracticalSessionsScreen extends ConsumerWidget {
  final String subjectId;
  const PracticalSessionsScreen({super.key, required this.subjectId});

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
  }) async {
    final seedMap = _buildQrSeed(lecture, sessionTitle);
    final seedJson = jsonEncode(seedMap);

    // Persist locally first to make QR details instantly available offline.
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('qr_lecture_$lectureId', seedJson);

    final seedEncoded = Uri.encodeComponent(seedJson);
    if (!context.mounted) return;
    context.go('/practical/qr/$lectureId?subjectId=$subjectId&seed=$seedEncoded');
  }

  String _formatDuration(int mins) {
    if (mins <= 0) return '';
    final hours = mins ~/ 60;
    final rem = mins % 60;
    if (hours == 0) return '$mins د';
    if (rem == 0) return '$hours س';
    return '$hours س $rem د';
  }

  String _formatLectureLine(Map<String, dynamic> lecture) {
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

  String _formatSpentMinutes(int? mins) {
    if (mins == null || mins <= 0) return '—';
    final h = mins ~/ 60;
    final m = mins % 60;
    if (h == 0) return '$m د';
    if (m == 0) return '$h س';
    return '$h س $m د';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sessionsAsync = ref.watch(
      practicalSessionsBySubjectProvider(subjectId),
    );
    return WillPopScope(
      onWillPop: () async {
        context.go('/');
        return false;
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.ondemand_video_rounded),
            tooltip: 'فيديوهات اختيارية',
            onPressed: () => context.go('/practical/videos/$subjectId'),
          ),
          title: const Text('جلساتي العملية'),
          actions: [
            IconButton(
              icon: const Icon(Icons.arrow_forward_rounded),
              onPressed: () => context.go('/'),
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
                    ref.invalidate(practicalSessionsBySubjectProvider(subjectId));
                    await ref.read(
                      practicalSessionsBySubjectProvider(subjectId).future,
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
                    final assignment = s['assignment'] as Map<String, dynamic>?;
                    final attendanceState =
                        s['attendance_state'] as String? ?? 'pending_check_in';
                    final isCompleted = attendanceState == 'completed';
                    final hasCheckIn = (s['has_check_in'] as bool?) ?? false;
                    final hasCheckOut = (s['has_check_out'] as bool?) ?? false;
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
                    final residentName =
                        (lecture?['profiles']
                            as Map<String, dynamic>?)?['full_name'] ??
                        '';

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
                              const Gap(4),
                              Row(
                                children: [
                                  Icon(
                                    Icons.location_on_outlined,
                                    size: 14,
                                    color: muted,
                                  ),
                                  const Gap(4),
                                  Text(
                                    '${lecture['location']}',
                                    style: Theme.of(
                                      context,
                                    ).textTheme.bodyMedium,
                                  ),
                                  const Gap(8),
                                  Icon(
                                    Icons.person_outline,
                                    size: 14,
                                    color: muted,
                                  ),
                                  const Gap(4),
                                  Text(
                                    residentName,
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
                                SizedBox(
                                  width: double.infinity,
                                  child: ElevatedButton.icon(
                                    onPressed: () => _openQr(
                                      context,
                                      subjectId: subjectId,
                                      lectureId:
                                          assignment!['lecture_id'] as String,
                                      lecture: lecture,
                                      sessionTitle: s['title'] as String,
                                    ),
                                    icon: const Icon(Icons.send_rounded),
                                    label: const Text('بدء الإرسال عبر BLE'),
                                  ),
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
