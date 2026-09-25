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
          .select(
            'id, name, description, rotation_order, location, needed_hours',
          )
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

class _PracticalSubjectAttendanceStats {
  final int assignedSessions;
  final int achievedMinutes;

  const _PracticalSubjectAttendanceStats({
    required this.assignedSessions,
    required this.achievedMinutes,
  });
}

int _spentMinutesFromAttendance(Map<String, dynamic> row) {
  final checkIn = DateTime.tryParse(row['check_in_at'] as String? ?? '');
  final checkOut = DateTime.tryParse(row['check_out_at'] as String? ?? '');
  if (checkIn == null || checkOut == null || !checkOut.isAfter(checkIn)) {
    return 0;
  }
  return checkOut.difference(checkIn).inMinutes;
}

final practicalAttendanceStatsByYearProvider =
    FutureProvider.family<
      Map<String, _PracticalSubjectAttendanceStats>,
      String
    >((ref, yearId) async {
      final uid = Supabase.instance.client.auth.currentUser!.id;

      final assignments = await Supabase.instance.client
          .from('lecture_assignments')
          .select(
            'lecture_id, lectures!inner(practical_sessions!inner(subject_id, subjects!inner(year_id)))',
          )
          .eq('student_id', uid)
          .eq('lectures.practical_sessions.subjects.year_id', yearId);

      final lectureToSubject = <String, String>{};
      final sessionsBySubject = <String, int>{};

      for (final row in (assignments as List)) {
        final map = Map<String, dynamic>.from(row as Map);
        final lectureId = map['lecture_id'] as String?;
        final lecture = map['lectures'] as Map<String, dynamic>?;
        final session = lecture?['practical_sessions'] as Map<String, dynamic>?;
        final subjectId = session?['subject_id'] as String?;
        if (lectureId == null || subjectId == null) continue;
        lectureToSubject[lectureId] = subjectId;
        sessionsBySubject[subjectId] = (sessionsBySubject[subjectId] ?? 0) + 1;
      }

      final achievedMinutesBySubject = <String, int>{};
      final lectureIds = lectureToSubject.keys.toList();
      if (lectureIds.isNotEmpty) {
        final attendanceRows = await Supabase.instance.client
            .from('practical_attendance')
            .select('lecture_id, check_in_at, check_out_at')
            .eq('student_id', uid)
            .inFilter('lecture_id', lectureIds);

        for (final row in (attendanceRows as List)) {
          final map = Map<String, dynamic>.from(row as Map);
          final lectureId = map['lecture_id'] as String?;
          if (lectureId == null) continue;
          final subjectId = lectureToSubject[lectureId];
          if (subjectId == null) continue;
          final spent = _spentMinutesFromAttendance(map);
          if (spent <= 0) continue;
          achievedMinutesBySubject[subjectId] =
              (achievedMinutesBySubject[subjectId] ?? 0) + spent;
        }
      }

      final out = <String, _PracticalSubjectAttendanceStats>{};
      for (final e in sessionsBySubject.entries) {
        out[e.key] = _PracticalSubjectAttendanceStats(
          assignedSessions: e.value,
          achievedMinutes: achievedMinutesBySubject[e.key] ?? 0,
        );
      }
      return out;
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

class PracticalSubjectsScreen extends ConsumerStatefulWidget {
  final String yearId;
  const PracticalSubjectsScreen({super.key, required this.yearId});

  @override
  ConsumerState<PracticalSubjectsScreen> createState() =>
      _PracticalSubjectsScreenState();
}

class _PracticalSubjectsScreenState
    extends ConsumerState<PracticalSubjectsScreen> {
  bool _onlyThisWeek = false;

  String _formatMinutes(int mins) {
    final h = mins ~/ 60;
    final m = mins % 60;
    if (h <= 0) return '$m د';
    if (m == 0) return '$h س';
    return '$h س $m د';
  }

  @override
  Widget build(BuildContext context) {
    final subjectsAsync = ref.watch(
      practicalSubjectsByYearProvider(widget.yearId),
    );
    final weeklyAttendanceIds =
        ref
            .watch(weeklyAttendanceSubjectIdsProvider(widget.yearId))
            .valueOrNull ??
        const <String>{};
    final Map<String, _PracticalSubjectAttendanceStats> attendanceStats =
        ref
            .watch(practicalAttendanceStatsByYearProvider(widget.yearId))
            .valueOrNull ??
        const <String, _PracticalSubjectAttendanceStats>{};

    return Scaffold(
      appBar: AppBar(
        title: const Text('الستاجات العملية'),
        actions: [
          IconButton(
            tooltip: _onlyThisWeek ? 'عرض كل البطاقات' : 'فلترة هذا الأسبوع',
            onPressed: () => setState(() => _onlyThisWeek = !_onlyThisWeek),
            icon: Icon(
              _onlyThisWeek ? Icons.filter_alt : Icons.filter_alt_outlined,
            ),
          ),
        ],
      ),
      body: subjectsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text(AppErrorMessage.from(e))),
        data: (subjects) {
          final visible = _onlyThisWeek
              ? subjects
                    .where(
                      (s) => weeklyAttendanceIds.contains(s['id'] as String),
                    )
                    .toList()
              : subjects;

          return visible.isEmpty
              ? Center(
                  child: Text(
                    _onlyThisWeek
                        ? 'لا توجد بطاقات مطابقة لفلترة هذا الأسبوع'
                        : 'لا توجد ستاجات',
                  ),
                )
              : ListView.separated(
                  key: PageStorageKey<String>(
                    'practical_subjects_${widget.yearId}',
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  itemCount: visible.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 10),
                  itemBuilder: (context, i) {
                    final s = visible[i];
                    final isThisWeek = weeklyAttendanceIds.contains(
                      s['id'] as String,
                    );
                    final location = (s['location'] as String?)?.trim();
                    final description = (s['description'] as String?)?.trim();
                    final subjectId = s['id'] as String;
                    final neededMinutesRaw = (s['needed_hours'] as num?)
                        ?.toDouble();
                    final stats = attendanceStats[subjectId];

                    final neededPerSessionMinutes = neededMinutesRaw == null
                        ? 0
                        : neededMinutesRaw.round();
                    final assignedSessions = stats?.assignedSessions ?? 0;
                    final achievedMinutes = stats?.achievedMinutes ?? 0;
                    final int requiredMinutes =
                        neededPerSessionMinutes * assignedSessions;
                    final double? progressPct = requiredMinutes > 0
                        ? ((achievedMinutes / requiredMinutes) * 100).clamp(
                            0,
                            100,
                          )
                        : null;

                    return Material(
                      color: isThisWeek
                          ? const Color(0xFF059669).withValues(alpha: 0.10)
                          : AppColors.surface,
                      borderRadius: BorderRadius.circular(14),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(14),
                        onTap: () =>
                            context.push('/practical/sessions/$subjectId'),
                        child: Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: isThisWeek
                                  ? const Color(
                                      0xFF059669,
                                    ).withValues(alpha: 0.5)
                                  : Theme.of(context).colorScheme.outline
                                        .withValues(alpha: 0.15),
                            ),
                          ),
                          child: Row(
                            children: [
                              CircleAvatar(
                                backgroundColor: const Color(
                                  0xFF059669,
                                ).withValues(alpha: 0.12),
                                child: Text(
                                  '${i + 1}',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      s['name'] as String,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                    if (location != null && location.isNotEmpty)
                                      Padding(
                                        padding: const EdgeInsets.only(top: 4),
                                        child: Row(
                                          children: [
                                            Icon(
                                              Icons.location_on_outlined,
                                              size: 14,
                                              color: Theme.of(
                                                context,
                                              ).colorScheme.onSurfaceVariant,
                                            ),
                                            const SizedBox(width: 4),
                                            Expanded(
                                              child: Text(
                                                location,
                                                style: TextStyle(
                                                  color: Theme.of(context)
                                                      .colorScheme
                                                      .onSurfaceVariant,
                                                  fontSize: 12,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    if (description != null &&
                                        description.isNotEmpty)
                                      Padding(
                                        padding: const EdgeInsets.only(top: 4),
                                        child: Text(
                                          description,
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            color: Theme.of(
                                              context,
                                            ).colorScheme.onSurfaceVariant,
                                            fontSize: 12,
                                          ),
                                        ),
                                      ),
                                    if (neededPerSessionMinutes > 0)
                                      Padding(
                                        padding: const EdgeInsets.only(top: 6),
                                        child: Text(
                                          assignedSessions <= 0
                                              ? 'المطلوب لكل جلسة: ${_formatMinutes(neededPerSessionMinutes)} · غير مفروز بعد'
                                              : (progressPct == null
                                                    ? 'المطلوب لكل جلسة: ${_formatMinutes(neededPerSessionMinutes)}'
                                                    : 'المطلوب لكل جلسة: ${_formatMinutes(neededPerSessionMinutes)} · الإنجاز: ${progressPct.toStringAsFixed(1)}%'),
                                          style: const TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.w600,
                                            color: Color(0xFF065F46),
                                          ),
                                        ),
                                      ),
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
                              ),
                              const Icon(
                                Icons.arrow_back_ios_rounded,
                                size: 14,
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                );
        },
      ),
    );
  }
}
