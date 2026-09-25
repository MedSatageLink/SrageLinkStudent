import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:stagelink_student/core/utils/app_error_message.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/router/app_router.dart';
import '../../../core/services/device_service.dart';

DateTime _currentWeekStartSaturdayLocal() {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final daysSinceSaturday = (today.weekday - DateTime.saturday + 7) % 7;
  return today.subtract(Duration(days: daysSinceSaturday));
}

final studentProfileProvider = FutureProvider<Map<String, dynamic>>((
  ref,
) async {
  final uid = Supabase.instance.client.auth.currentUser!.id;

  Future<Map<String, dynamic>> fetchRemote() async {
    final res = await Supabase.instance.client
        .from('profiles')
        .select('*, categories(name, year_id, years(name))')
        .eq('id', uid)
        .single();
    return Map<String, dynamic>.from(res);
  }

  final prefs = await SharedPreferences.getInstance();
  final cacheKey = 'student_profile_$uid';
  final cachedRaw = prefs.getString(cacheKey);
  if (cachedRaw != null) {
    final cached = Map<String, dynamic>.from(jsonDecode(cachedRaw) as Map);
    unawaited(
      fetchRemote()
          .then((fresh) async {
            await prefs.setString(cacheKey, jsonEncode(fresh));
          })
          .catchError((_) {}),
    );
    return cached;
  }

  final fresh = await fetchRemote();
  await prefs.setString(cacheKey, jsonEncode(fresh));
  return fresh;
});

final subjectsByYearProvider =
    FutureProvider.family<List<Map<String, dynamic>>, String>((
      ref,
      yearId,
    ) async {
      List<Map<String, dynamic>> sortSubjects(
        List<Map<String, dynamic>> input,
      ) {
        final list = List<Map<String, dynamic>>.from(input);
        list.sort((a, b) {
          final ao = a['rotation_order'] as int?;
          final bo = b['rotation_order'] as int?;
          if (ao != null && bo != null) return ao.compareTo(bo);
          if (ao != null) return -1;
          if (bo != null) return 1;
          final an = (a['name'] as String? ?? '').toLowerCase();
          final bn = (b['name'] as String? ?? '').toLowerCase();
          return an.compareTo(bn);
        });
        return list;
      }

      Future<List<Map<String, dynamic>>> fetchRemote() async {
        final res = await Supabase.instance.client
            .from('subjects')
            .select(
              'id, name, description, rotation_order, location, needed_hours',
            )
            .eq('year_id', yearId)
            .order('rotation_order')
            .order('name');
        return sortSubjects(List<Map<String, dynamic>>.from(res as List));
      }

      final prefs = await SharedPreferences.getInstance();
      final cacheKey = 'home_subjects_year_$yearId';
      final cachedRaw = prefs.getString(cacheKey);
      if (cachedRaw != null) {
        final cachedList = List<Map<String, dynamic>>.from(
          (jsonDecode(cachedRaw) as List).cast<Map<String, dynamic>>(),
        );

        unawaited(
          fetchRemote()
              .then((fresh) async {
                await prefs.setString(cacheKey, jsonEncode(fresh));
              })
              .catchError((_) {}),
        );

        return sortSubjects(cachedList);
      }

      final fresh = await fetchRemote();
      await prefs.setString(cacheKey, jsonEncode(fresh));
      return fresh;
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

class StudentHomeScreen extends ConsumerStatefulWidget {
  const StudentHomeScreen({super.key});

  @override
  ConsumerState<StudentHomeScreen> createState() => _StudentHomeScreenState();
}

class _StudentHomeScreenState extends ConsumerState<StudentHomeScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  static const String _homeTabPrefKey = 'student_home_selected_tab_v1';
  late final TabController _tabController;
  bool _tabReady = false;
  bool _onlyThisWeek = false;
  Timer? _deviceLockTimer;
  bool _checkingDeviceLock = false;
  bool _forcedLogout = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(_persistSelectedTab);
    _loadSavedTab();
    unawaited(_enforceDeviceLock());
    _deviceLockTimer = Timer.periodic(
      const Duration(seconds: 45),
      (_) => unawaited(_enforceDeviceLock()),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_enforceDeviceLock());
    }
  }

  Future<void> _enforceDeviceLock() async {
    if (_checkingDeviceLock || _forcedLogout) return;
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) return;

    _checkingDeviceLock = true;
    try {
      final myDeviceId = await DeviceService().getDeviceId();
      final row = await Supabase.instance.client
          .from('profiles')
          .select('role, login_enabled, login_device_id')
          .eq('id', user.id)
          .single();
      final profile = Map<String, dynamic>.from(row);
      final role = profile['role'] as String?;
      final enabled = (profile['login_enabled'] as bool?) ?? true;
      final lockedDeviceId = profile['login_device_id'] as String?;

      final shouldLogout =
          role != 'student' ||
          !enabled ||
          lockedDeviceId == null ||
          lockedDeviceId != myDeviceId;

      if (shouldLogout) {
        _forcedLogout = true;
        await Supabase.instance.client.auth.signOut();
        if (mounted) {
          ref.invalidate(routerProvider);
        }
      }
    } catch (_) {
      // Ignore transient connectivity failures.
    } finally {
      _checkingDeviceLock = false;
    }
  }

  Future<void> _loadSavedTab() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getInt(_homeTabPrefKey) ?? 0;
    if (saved >= 0 && saved < 2) {
      _tabController.index = saved;
    }
    if (!mounted) return;
    setState(() => _tabReady = true);
  }

  Future<void> _persistSelectedTab() async {
    if (_tabController.indexIsChanging) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_homeTabPrefKey, _tabController.index);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _deviceLockTimer?.cancel();
    _tabController.removeListener(_persistSelectedTab);
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_tabReady) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final profileAsync = ref.watch(studentProfileProvider);

    return profileAsync.when(
      loading: () =>
          const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (e, _) =>
          Scaffold(body: Center(child: Text(AppErrorMessage.from(e)))),
      data: (profile) {
        final yearId =
            (profile['categories'] as Map<String, dynamic>?)?['year_id']
                as String?;

        return Scaffold(
          appBar: AppBar(
            title: const Text('StageLink'),
            actions: [
              IconButton(
                tooltip: _onlyThisWeek
                    ? 'عرض كل البطاقات'
                    : 'فلترة هذا الأسبوع',
                icon: Icon(
                  _onlyThisWeek ? Icons.filter_alt : Icons.filter_alt_outlined,
                ),
                onPressed: () => setState(() => _onlyThisWeek = !_onlyThisWeek),
              ),
              IconButton(
                icon: const Icon(Icons.person_outline_rounded),
                onPressed: () => context.go('/profile'),
              ),
            ],
            bottom: TabBar(
              controller: _tabController,
              tabs: [
                Tab(text: 'نظري الستاج'),
                Tab(text: 'عملي الستاج'),
              ],
            ),
          ),
          body: yearId == null
              ? const Center(child: Text('لا توجد سنة دراسية مرتبطة'))
              : TabBarView(
                  controller: _tabController,
                  children: [
                    _SubjectsTab(
                      yearId: yearId,
                      emptyText: 'لا توجد ستاجات نظرية',
                      onTap: (id) => context.push('/theoretical/videos/$id'),
                      leading: const Icon(
                        Icons.play_lesson_outlined,
                        color: AppColors.primary,
                      ),
                      leadingBg: AppColors.primaryContainer,
                      showLocation: false,
                      onlyThisWeek: _onlyThisWeek,
                    ),
                    _SubjectsTab(
                      yearId: yearId,
                      emptyText: 'لا توجد ستاجات عملية',
                      onTap: (id) => context.push('/practical/sessions/$id'),
                      leading: const Icon(
                        Icons.science_outlined,
                        color: Color(0xFF059669),
                      ),
                      leadingBg: const Color(0xFF059669),
                      leadingBgOpacity: 0.1,
                      showLocation: true,
                      onlyThisWeek: _onlyThisWeek,
                    ),
                  ],
                ),
        );
      },
    );
  }
}

class _SubjectsTab extends ConsumerStatefulWidget {
  final String yearId;
  final String emptyText;
  final void Function(String id) onTap;
  final Widget leading;
  final Color leadingBg;
  final double leadingBgOpacity;
  final bool showLocation;
  final bool onlyThisWeek;

  const _SubjectsTab({
    required this.yearId,
    required this.emptyText,
    required this.onTap,
    required this.leading,
    required this.leadingBg,
    this.leadingBgOpacity = 0.2,
    required this.showLocation,
    required this.onlyThisWeek,
  });

  @override
  ConsumerState<_SubjectsTab> createState() => _SubjectsTabState();
}

class _SubjectsTabState extends ConsumerState<_SubjectsTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  String _formatMinutes(int mins) {
    final h = mins ~/ 60;
    final m = mins % 60;
    if (h <= 0) return '$m د';
    if (m == 0) return '$h س';
    return '$h س $m د';
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final subjectsAsync = ref.watch(subjectsByYearProvider(widget.yearId));
    final weeklyAttendanceIdsAsync = ref.watch(
      weeklyAttendanceSubjectIdsProvider(widget.yearId),
    );
    final weeklyAttendanceIds =
        weeklyAttendanceIdsAsync.valueOrNull ?? const <String>{};
    final Map<String, _PracticalSubjectAttendanceStats> attendanceStats =
        widget.showLocation
        ? (ref
                  .watch(practicalAttendanceStatsByYearProvider(widget.yearId))
                  .valueOrNull ??
              const <String, _PracticalSubjectAttendanceStats>{})
        : const <String, _PracticalSubjectAttendanceStats>{};
    return Column(
      children: [
        Expanded(
          child: subjectsAsync.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Center(child: Text(AppErrorMessage.from(e))),
            data: (subjects) {
              final visible = widget.onlyThisWeek
                  ? subjects
                        .where(
                          (s) =>
                              weeklyAttendanceIds.contains(s['id'] as String),
                        )
                        .toList()
                  : subjects;

              return visible.isEmpty
                  ? Center(
                      child: Text(
                        widget.onlyThisWeek
                            ? 'لا توجد بطاقات مطابقة لفلترة هذا الأسبوع'
                            : widget.emptyText,
                      ),
                    )
                  : ListView.separated(
                      key: PageStorageKey<String>(
                        'student_home_subjects_${widget.yearId}_${widget.showLocation ? 'practical' : 'theoretical'}',
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      itemCount: visible.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 10),
                      itemBuilder: (context, i) {
                        final s = visible[i];
                        final subjectId = s['id'] as String;
                        final isThisWeek = weeklyAttendanceIds.contains(
                          subjectId,
                        );
                        final description = s['description'] as String?;
                        final location = (s['location'] as String?)?.trim();
                        final stats = attendanceStats[subjectId];
                        final neededMinutesRaw = (s['needed_hours'] as num?)
                            ?.toDouble();
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

                        final cardBg = isThisWeek
                            ? const Color(0xFF059669).withValues(alpha: 0.10)
                            : Theme.of(context).colorScheme.surface;
                        final borderColor = isThisWeek
                            ? const Color(0xFF059669).withValues(alpha: 0.55)
                            : Theme.of(
                                context,
                              ).colorScheme.outline.withValues(alpha: 0.15);

                        return Material(
                          color: cardBg,
                          borderRadius: BorderRadius.circular(14),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(14),
                            onTap: () => widget.onTap(subjectId),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 12,
                              ),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(color: borderColor),
                              ),
                              child: Row(
                                children: [
                                  Container(
                                    width: 42,
                                    height: 42,
                                    decoration: BoxDecoration(
                                      color: widget.leadingBg.withValues(
                                        alpha: widget.leadingBgOpacity,
                                      ),
                                      shape: BoxShape.circle,
                                    ),
                                    alignment: Alignment.center,
                                    child: Text(
                                      '${i + 1}',
                                      style: TextStyle(
                                        fontWeight: FontWeight.w700,
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.onSurface,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            widget.leading,
                                            const SizedBox(width: 6),
                                            Expanded(
                                              child: Text(
                                                s['name'] as String,
                                                style: const TextStyle(
                                                  fontWeight: FontWeight.w700,
                                                ),
                                              ),
                                            ),
                                            if (isThisWeek)
                                              Container(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                      horizontal: 8,
                                                      vertical: 3,
                                                    ),
                                                decoration: BoxDecoration(
                                                  color: const Color(
                                                    0xFF059669,
                                                  ).withValues(alpha: 0.14),
                                                  borderRadius:
                                                      BorderRadius.circular(
                                                        999,
                                                      ),
                                                ),
                                                child: const Text(
                                                  'هذا الأسبوع',
                                                  style: TextStyle(
                                                    color: Color(0xFF065F46),
                                                    fontSize: 11,
                                                    fontWeight: FontWeight.w700,
                                                  ),
                                                ),
                                              ),
                                          ],
                                        ),
                                        if (widget.showLocation &&
                                            location != null &&
                                            location.isNotEmpty) ...[
                                          const SizedBox(height: 4),
                                          Row(
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
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
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
                                        ],
                                        if (description != null &&
                                            description.trim().isNotEmpty) ...[
                                          const SizedBox(height: 4),
                                          Text(
                                            description.trim(),
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              color: Theme.of(
                                                context,
                                              ).colorScheme.onSurfaceVariant,
                                              fontSize: 12,
                                            ),
                                          ),
                                        ],
                                        if (widget.showLocation &&
                                            neededPerSessionMinutes > 0) ...[
                                          const SizedBox(height: 6),
                                          Text(
                                            assignedSessions <= 0
                                                ? 'عدد الساعات لكل جلسة: ${_formatMinutes(neededPerSessionMinutes)} '
                                                : (progressPct == null
                                                      ? 'المطلوب لكل جلسة: ${_formatMinutes(neededPerSessionMinutes)}'
                                                      : 'المطلوب لكل جلسة: ${_formatMinutes(neededPerSessionMinutes)} · الإنجاز: ${progressPct.toStringAsFixed(1)}%'),
                                            style: const TextStyle(
                                              color: Color(0xFF065F46),
                                              fontWeight: FontWeight.w700,
                                              fontSize: 11,
                                            ),
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                                  const Icon(
                                    Icons.arrow_back_ios_new_rounded,
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
        ),
      ],
    );
  }
}
