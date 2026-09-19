import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:go_router/go_router.dart';
import 'package:stagelink_student/core/utils/app_error_message.dart';
import '../../../core/theme/app_theme.dart';

DateTime _currentWeekStartSaturdayLocal() {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final daysSinceSaturday = (today.weekday - DateTime.saturday + 7) % 7;
  return today.subtract(Duration(days: daysSinceSaturday));
}

final practicalSubjectsByYearProvider =
    FutureProvider.family<List<Map<String, dynamic>>, String>((
      ref,
      yearId,
    ) async {
      final res = await Supabase.instance.client
          .from('subjects')
          .select('id, name, description, rotation_order, location')
          .eq('year_id', yearId)
          .order('rotation_order')
          .order('name');
      final list = List<Map<String, dynamic>>.from(res as List);
      list.sort((a, b) {
        final ao = a['rotation_order'] as int?;
        final bo = b['rotation_order'] as int?;
        if (ao != null && bo != null) return ao.compareTo(bo);
        if (ao != null) return -1;
        if (bo != null) return 1;
        return (a['name'] as String).compareTo(b['name'] as String);
      });
      return list;
    });

final weeklyAttendanceSubjectIdsProvider =
    FutureProvider.family<Set<String>, String>((ref, yearId) async {
      final uid = Supabase.instance.client.auth.currentUser!.id;
      final weekStartLocal = _currentWeekStartSaturdayLocal();
      final weekEndLocal = weekStartLocal.add(const Duration(days: 7));
      final weekStartUtcIso = weekStartLocal.toUtc().toIso8601String();
      final weekEndUtcIso = weekEndLocal.toUtc().toIso8601String();

      final rows = await Supabase.instance.client
          .from('lecture_assignments')
          .select(
            'lectures!inner(start_at, practical_sessions!inner(subject_id, subjects!inner(year_id)))',
          )
          .eq('student_id', uid)
          .eq('lectures.practical_sessions.subjects.year_id', yearId)
          .gte('lectures.start_at', weekStartUtcIso)
          .lt('lectures.start_at', weekEndUtcIso);

      final ids = <String>{};
      for (final row in (rows as List)) {
        final map = Map<String, dynamic>.from(row as Map);
        final lecture = map['lectures'] as Map<String, dynamic>?;
        final session = lecture?['practical_sessions'] as Map<String, dynamic>?;
        final subjectId = session?['subject_id'] as String?;
        if (subjectId != null && subjectId.isNotEmpty) {
          ids.add(subjectId);
        }
      }
      return ids;
    });

class PracticalSubjectsScreen extends ConsumerWidget {
  final String yearId;
  const PracticalSubjectsScreen({super.key, required this.yearId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final subjectsAsync = ref.watch(practicalSubjectsByYearProvider(yearId));
    final weeklyAttendanceIds =
        ref.watch(weeklyAttendanceSubjectIdsProvider(yearId)).valueOrNull ??
        const <String>{};
    return Scaffold(
      appBar: AppBar(title: const Text('الستاجات العملية')),
      body: subjectsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text(AppErrorMessage.from(e))),
        data: (subjects) => subjects.isEmpty
            ? const Center(child: Text('لا توجد ستاجات'))
            : ListView.separated(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                itemCount: subjects.length,
                separatorBuilder: (_, _) => const SizedBox(height: 10),
                itemBuilder: (context, i) {
                  final s = subjects[i];
                  final isThisWeek = weeklyAttendanceIds.contains(
                    s['id'] as String,
                  );
                  final location = (s['location'] as String?)?.trim();
                  return Material(
                    color: isThisWeek
                        ? const Color(0xFF059669).withValues(alpha: 0.10)
                        : AppColors.surface,
                    borderRadius: BorderRadius.circular(14),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(14),
                      onTap: () => context.go('/practical/sessions/${s['id']}'),
                      child: ListTile(
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                        tileColor: isThisWeek
                            ? const Color(0xFF059669).withValues(alpha: 0.04)
                            : null,
                        leading: CircleAvatar(
                          backgroundColor: const Color(
                            0xFF059669,
                          ).withValues(alpha: 0.12),
                          child: Text(
                            '${i + 1}',
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ),
                        title: Text(s['name'] as String),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (location != null && location.isNotEmpty)
                              Text('📍 $location'),
                            if (isThisWeek)
                              const Padding(
                                padding: EdgeInsets.only(top: 4),
                                child: Text(
                                  'لديك حضور هذا الأسبوع',
                                  style: TextStyle(
                                    color: Color(0xFF065F46),
                                    fontWeight: FontWeight.w700,
                                    fontSize: 11,
                                  ),
                                ),
                              ),
                          ],
                        ),
                        trailing: const Icon(
                          Icons.arrow_back_ios_rounded,
                          size: 14,
                        ),
                      ),
                    ),
                  );
                },
              ),
      ),
    );
  }
}
