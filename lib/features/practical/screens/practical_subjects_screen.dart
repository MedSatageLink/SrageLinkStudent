import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:go_router/go_router.dart';
import 'package:stagelink_student/core/utils/app_error_message.dart';
import '../../../core/theme/app_theme.dart';

final practicalSubjectsByYearProvider =
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

class PracticalSubjectsScreen extends ConsumerWidget {
  final String yearId;
  const PracticalSubjectsScreen({super.key, required this.yearId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final subjectsAsync = ref.watch(practicalSubjectsByYearProvider(yearId));
    return Scaffold(
      appBar: AppBar(title: const Text('الستاجات العملية')),
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
                      backgroundColor: const Color(
                        0xFF059669,
                      ).withValues(alpha: 0.1),
                      child: const Icon(
                        Icons.science_outlined,
                        color: Color(0xFF059669),
                      ),
                    ),
                    title: Text(s['name'] as String),
                    trailing: const Icon(
                      Icons.arrow_back_ios_rounded,
                      size: 14,
                    ),
                    onTap: () => context.go('/practical/sessions/${s['id']}'),
                  ).animate(delay: (30 * i).ms).fadeIn();
                },
              ),
      ),
    );
  }
}
