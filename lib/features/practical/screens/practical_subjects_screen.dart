import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
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
            : ListView.separated(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                itemCount: subjects.length,
                separatorBuilder: (_, _) => const SizedBox(height: 10),
                itemBuilder: (context, i) {
                  final s = subjects[i];
                  final location = (s['location'] as String?)?.trim();
                  return Material(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(14),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(14),
                      onTap: () => context.go('/practical/sessions/${s['id']}'),
                      child: ListTile(
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
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
                        subtitle: (location == null || location.isEmpty)
                            ? null
                            : Text('📍 $location'),
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
