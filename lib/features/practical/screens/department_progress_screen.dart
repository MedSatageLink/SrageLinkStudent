import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gap/gap.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:stagelink_student/core/utils/app_error_message.dart';

final departmentProgressProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
      final res = await Supabase.instance.client.rpc(
        'get_student_department_progress',
      );
      return List<Map<String, dynamic>>.from(res as List);
    });

class DepartmentProgressScreen extends ConsumerWidget {
  const DepartmentProgressScreen({super.key});

  String _formatMinutes(int mins) {
    final h = mins ~/ 60;
    final m = mins % 60;
    if (h <= 0) return '$m د';
    if (m == 0) return '$h س';
    return '$h س $m د';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(departmentProgressProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('معدل الإنجاز')),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(AppErrorMessage.from(e), textAlign: TextAlign.center),
                const Gap(12),
                FilledButton.icon(
                  onPressed: () => ref.invalidate(departmentProgressProvider),
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('إعادة المحاولة'),
                ),
              ],
            ),
          ),
        ),
        data: (rows) {
          if (rows.isEmpty) {
            return const Center(
              child: Text('لا توجد أقسام مرتبطة بسنتك الدراسية حتى الآن'),
            );
          }

          return ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            itemCount: rows.length,
            itemBuilder: (context, i) {
              final r = rows[i];
              final name = (r['department_name'] as String?) ?? '—';
              final spent = (r['spent_minutes'] as num?)?.round() ?? 0;
              final required = (r['required_minutes'] as num?)?.round() ?? 0;
              final pctRaw = (r['progress_percent'] as num?)?.toDouble() ?? 0;
              final pct = pctRaw < 0 ? 0.0 : pctRaw;
              final progressValue = required > 0
                  ? (pct / 100).clamp(0.0, 1.0)
                  : 0.0;

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
                              name,
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                          ),
                          Text(
                            '${pct.toStringAsFixed(1)}%',
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.w800),
                          ),
                        ],
                      ),
                      const Gap(10),
                      LinearProgressIndicator(value: progressValue),
                      const Gap(10),
                      Text(
                        'المنجز: ${_formatMinutes(spent)}   •   المطلوب: ${_formatMinutes(required)}',
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ],
                  ),
                ),
              ).animate(delay: (40 * i).ms).fadeIn();
            },
          );
        },
      ),
    );
  }
}
