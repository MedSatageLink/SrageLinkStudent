import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:go_router/go_router.dart';
import 'package:stagelink_student/core/utils/app_error_message.dart';

final practicalYearsProvider = FutureProvider<List<Map<String, dynamic>>>((
  ref,
) async {
  final res = await Supabase.instance.client
      .from('years')
      .select('id, name, year_number')
      .order('year_number');
  return List<Map<String, dynamic>>.from(res as List);
});

class PracticalYearsScreen extends ConsumerWidget {
  const PracticalYearsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final yearsAsync = ref.watch(practicalYearsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('الجلسات العملية')),
      body: yearsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text(AppErrorMessage.from(e))),
        data: (years) => GridView.builder(
          padding: const EdgeInsets.all(16),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
            childAspectRatio: 1.3,
          ),
          itemCount: years.length,
          itemBuilder: (context, i) {
            final y = years[i];
            return InkWell(
                  onTap: () => context.push('/practical/subjects/${y['id']}'),
                  borderRadius: BorderRadius.circular(16),
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [Color(0xFF065F46), Color(0xFF059669)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Icon(
                          Icons.science_outlined,
                          color: Colors.white70,
                          size: 28,
                        ),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'السنة ${y['year_number']}',
                              style: const TextStyle(
                                color: Colors.white60,
                                fontSize: 12,
                              ),
                            ),
                            Text(
                              y['name'] as String,
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                                fontSize: 14,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                )
                .animate(delay: (60 * i).ms)
                .fadeIn()
                .scale(begin: const Offset(0.9, 0.9));
          },
        ),
      ),
    );
  }
}
