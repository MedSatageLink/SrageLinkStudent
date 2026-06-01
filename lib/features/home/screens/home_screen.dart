import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:go_router/go_router.dart';
import '../../../core/theme/app_theme.dart';

final studentProfileProvider = FutureProvider<Map<String, dynamic>>((
  ref,
) async {
  final uid = Supabase.instance.client.auth.currentUser!.id;
  final res = await Supabase.instance.client
      .from('profiles')
      .select('*, categories(name, year_id, years(name))')
      .eq('id', uid)
      .single();
  return res;
});

final subjectsByYearProvider =
    FutureProvider.family<List<Map<String, dynamic>>, String>((
      ref,
      yearId,
    ) async {
      final res = await Supabase.instance.client
          .from('subjects')
          .select('id, name, description')
          .eq('year_id', yearId)
          .order('name');
      return List<Map<String, dynamic>>.from(res as List);
    });

class StudentHomeScreen extends ConsumerWidget {
  const StudentHomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profileAsync = ref.watch(studentProfileProvider);

    return profileAsync.when(
      loading: () =>
          const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (e, _) => Scaffold(body: Center(child: Text(e.toString()))),
      data: (profile) {
        final yearId =
            (profile['categories'] as Map<String, dynamic>?)?['year_id']
                as String?;

        return DefaultTabController(
          length: 2,
          child: Scaffold(
            appBar: AppBar(
              title: const Text('StageLink'),
              actions: [
                IconButton(
                  icon: const Icon(Icons.person_outline_rounded),
                  onPressed: () => context.go('/profile'),
                ),
                IconButton(
                  icon: const Icon(Icons.logout_rounded),
                  onPressed: () async {
                    final ok = await showDialog<bool>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: const Text('تسجيل الخروج'),
                        content: const Text('هل أنت متأكد من تسجيل الخروج؟'),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(ctx, false),
                            child: const Text('إلغاء'),
                          ),
                          ElevatedButton(
                            onPressed: () => Navigator.pop(ctx, true),
                            child: const Text('تأكيد'),
                          ),
                        ],
                      ),
                    );
                    if (ok == true) {
                      await Supabase.instance.client.auth.signOut();
                      if (context.mounted) context.go('/login');
                    }
                  },
                ),
              ],
              bottom: const TabBar(
                tabs: [
                  Tab(text: 'نظري الستاج'),
                  Tab(text: 'عملي الستاج'),
                ],
              ),
            ),
            body: yearId == null
                ? const Center(child: Text('لا توجد سنة دراسية مرتبطة'))
                : TabBarView(
                    children: [
                      _SubjectsTab(
                        yearId: yearId,
                        emptyText: 'لا توجد ستاجات نظرية',
                        onTap: (id) => context.go('/theoretical/videos/$id'),
                        leading: const Icon(
                          Icons.play_lesson_outlined,
                          color: AppColors.primary,
                        ),
                        leadingBg: AppColors.primaryContainer,
                      ),
                      _SubjectsTab(
                        yearId: yearId,
                        emptyText: 'لا توجد ستاجات عملية',
                        onTap: (id) => context.go('/practical/sessions/$id'),
                        leading: const Icon(
                          Icons.science_outlined,
                          color: Color(0xFF059669),
                        ),
                        leadingBg: const Color(0xFF059669),
                        leadingBgOpacity: 0.1,
                      ),
                    ],
                  ),
          ),
        );
      },
    );
  }
}

class _SubjectsTab extends ConsumerWidget {
  final String yearId;
  final String emptyText;
  final void Function(String id) onTap;
  final Widget leading;
  final Color leadingBg;
  final double leadingBgOpacity;

  const _SubjectsTab({
    required this.yearId,
    required this.emptyText,
    required this.onTap,
    required this.leading,
    required this.leadingBg,
    this.leadingBgOpacity = 0.2,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final subjectsAsync = ref.watch(subjectsByYearProvider(yearId));
    return Column(
      children: [
        Expanded(
          child: subjectsAsync.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Center(child: Text(e.toString())),
            data: (subjects) => subjects.isEmpty
                ? Center(child: Text(emptyText))
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    itemCount: subjects.length,
                    itemBuilder: (context, i) {
                      final s = subjects[i];
                      return ListTile(
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        tileColor: Theme.of(context).colorScheme.surface,
                        leading: CircleAvatar(
                          backgroundColor: leadingBg.withValues(
                            alpha: leadingBgOpacity,
                          ),
                          child: leading,
                        ),
                        title: Text(s['name'] as String),
                        subtitle: s['description'] != null
                            ? Text(
                                s['description'] as String,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              )
                            : null,
                        trailing: const Icon(
                          Icons.arrow_back_ios_rounded,
                          size: 14,
                        ),
                        onTap: () => onTap(s['id'] as String),
                      ).animate(delay: (30 * i).ms).fadeIn();
                    },
                  ),
          ),
        ),
      ],
    );
  }
}
