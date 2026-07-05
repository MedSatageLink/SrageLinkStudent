import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:go_router/go_router.dart';
import 'package:stagelink_student/core/utils/app_error_message.dart';
import '../../../core/theme/app_theme.dart';

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

class TheoreticalSubjectsScreen extends ConsumerWidget {
  final String yearId;
  const TheoreticalSubjectsScreen({super.key, required this.yearId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final subjectsAsync = ref.watch(subjectsByYearProvider(yearId));
    return Scaffold(
      appBar: AppBar(title: const Text('الستاجات')),
      body: subjectsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text(AppErrorMessage.from(e))),
        data: (subjects) => subjects.isEmpty
            ? const Center(child: Text('لا توجد ستاجات'))
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
                    tileColor: AppColors.surface,
                    leading: CircleAvatar(
                      backgroundColor: AppColors.primaryContainer,
                      child: Icon(
                        Icons.play_lesson_outlined,
                        color: AppColors.primary,
                      ),
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
                    onTap: () => context.go('/theoretical/videos/${s['id']}'),
                  ).animate(delay: (30 * i).ms).fadeIn();
                },
              ),
      ),
    );
  }
}
