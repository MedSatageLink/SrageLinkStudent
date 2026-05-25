import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:go_router/go_router.dart';
import 'package:gap/gap.dart';
import 'package:intl/intl.dart';
import '../../../core/theme/app_theme.dart';

// Sessions for a subject
final practicalSessionsBySubjectProvider =
    FutureProvider.family<List<Map<String, dynamic>>, String>((
      ref,
      subjectId,
    ) async {
      final uid = Supabase.instance.client.auth.currentUser!.id;

      // Get all sessions for this subject
      final sessions = await Supabase.instance.client
          .from('practical_sessions')
          .select('id, title, prerequisite_video_id')
          .eq('subject_id', subjectId)
          .order('created_at');

      // Get student's lecture assignments (join through lectures to get session_id)
      final assignments = await Supabase.instance.client
          .from('lecture_assignments')
          .select(
            'lecture_id, lectures(id, practical_session_id, start_at, end_at, location, attendance_window_start, attendance_window_end, profiles(full_name))',
          )
          .eq('student_id', uid);

      // Map: session_id -> assignment
      final assignMap = <String, Map<String, dynamic>>{};
      for (final a in (assignments as List)) {
        final lecture = a['lectures'] as Map<String, dynamic>?;
        if (lecture == null) continue;
        final sessionId = lecture['practical_session_id'] as String;
        assignMap[sessionId] = a as Map<String, dynamic>;
      }

      // Get attended lectures
      final attendance = await Supabase.instance.client
          .from('practical_attendance')
          .select('lecture_id')
          .eq('student_id', uid);
      final attendedIds = Set<String>.from(
        (attendance as List).map((a) => a['lecture_id'] as String),
      );

      final result = (sessions as List).map((s) {
        final assign = assignMap[s['id'] as String];
        return {
          ...s as Map<String, dynamic>,
          'assignment': assign,
          'is_attended':
              assign != null && attendedIds.contains(assign['lecture_id']),
        };
      }).toList();

      return result;
    });

class PracticalSessionsScreen extends ConsumerWidget {
  final String subjectId;
  const PracticalSessionsScreen({super.key, required this.subjectId});

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

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sessionsAsync = ref.watch(
      practicalSessionsBySubjectProvider(subjectId),
    );
    return Scaffold(
      appBar: AppBar(title: const Text('جلساتي العملية')),
      body: sessionsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text(e.toString())),
        data: (sessions) => sessions.isEmpty
            ? const Center(child: Text('لا توجد جلسات'))
            : ListView.builder(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                itemCount: sessions.length,
                itemBuilder: (context, i) {
                  final s = sessions[i];
                  final assignment = s['assignment'] as Map<String, dynamic>?;
                  final isAttended = s['is_attended'] as bool;

                  Color statusColor;
                  String statusText;
                  IconData statusIcon;
                  if (isAttended) {
                    statusColor = AppColors.success;
                    statusText = 'حاضر ✓';
                    statusIcon = Icons.check_circle_rounded;
                  } else if (assignment != null) {
                    statusColor = AppColors.warning;
                    statusText = 'مسجّل';
                    statusIcon = Icons.schedule_rounded;
                  } else {
                    statusColor = AppColors.textSecondary;
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
                                const Icon(
                                  Icons.event_outlined,
                                  size: 14,
                                  color: AppColors.textSecondary,
                                ),
                                const Gap(4),
                                Text(
                                  _formatLectureLine(lecture),
                                  style: Theme.of(context).textTheme.bodyMedium,
                                ),
                              ],
                            ),
                            const Gap(4),
                            Row(
                              children: [
                                const Icon(
                                  Icons.location_on_outlined,
                                  size: 14,
                                  color: AppColors.textSecondary,
                                ),
                                const Gap(4),
                                Text(
                                  '${lecture['location']}',
                                  style: Theme.of(context).textTheme.bodyMedium,
                                ),
                                const Gap(8),
                                const Icon(
                                  Icons.person_outline,
                                  size: 14,
                                  color: AppColors.textSecondary,
                                ),
                                const Gap(4),
                                Text(
                                  residentName,
                                  style: Theme.of(context).textTheme.bodyMedium,
                                ),
                              ],
                            ),
                            if (!isAttended) ...[
                              const Gap(10),
                              SizedBox(
                                width: double.infinity,
                                child: ElevatedButton.icon(
                                  onPressed: () => context.go(
                                    '/practical/qr/${assignment!['lecture_id']}',
                                  ),
                                  icon: const Icon(Icons.qr_code_rounded),
                                  label: const Text('عرض رمز QR للحضور'),
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
    );
  }
}
