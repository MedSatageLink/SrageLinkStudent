import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:go_router/go_router.dart';
import 'package:gap/gap.dart';
import 'package:stagelink_student/core/utils/app_error_message.dart';
import '../../../core/theme/app_theme.dart';

// Videos list for a subject
final videosBySubjectProvider =
    FutureProvider.family<List<Map<String, dynamic>>, String>((
      ref,
      subjectId,
    ) async {
      final res = await Supabase.instance.client
          .from('videos')
          .select('id, title, youtube_video_id, duration_seconds')
          .eq('subject_id', subjectId)
          .order('created_at');
      return List<Map<String, dynamic>>.from(res);
    });

// Completed videos for current student
final completedVideosProvider = FutureProvider.family<Set<String>, String>((
  ref,
  subjectId,
) async {
  final uid = Supabase.instance.client.auth.currentUser!.id;
  final res = await Supabase.instance.client
      .from('video_attendance')
      .select('video_id')
      .eq('student_id', uid)
      .eq('is_completed', true);
  return Set<String>.from((res as List).map((e) => e['video_id'] as String));
});

class VideosScreen extends ConsumerWidget {
  final String subjectId;
  const VideosScreen({super.key, required this.subjectId});

  void _goBackToPreviousOrHome(BuildContext context) {
    if (context.canPop()) {
      context.pop();
      return;
    }
    context.go('/');
  }

  String _formatDuration(int seconds) {
    final m = (seconds ~/ 60).toString().padLeft(2, '0');
    final s = (seconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final videosAsync = ref.watch(videosBySubjectProvider(subjectId));
    final completedAsync = ref.watch(completedVideosProvider(subjectId));

    return WillPopScope(
      onWillPop: () async {
        _goBackToPreviousOrHome(context);
        return false;
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('الفيديوهات'),
          actions: [
            IconButton(
              icon: const Icon(Icons.arrow_forward_rounded),
              onPressed: () => _goBackToPreviousOrHome(context),
            ),
          ],
        ),
        body: videosAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text(AppErrorMessage.from(e))),
          data: (videos) {
            final completed = completedAsync.value ?? {};
            return ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              itemCount: videos.length,
              itemBuilder: (context, i) {
                final v = videos[i];
                final ytId = v['youtube_video_id'] as String;
                final isDone = completed.contains(v['id'] as String);
                return Card(
                  margin: const EdgeInsets.only(bottom: 10),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () => context.push('/theoretical/player/${v['id']}'),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Row(
                        children: [
                          Stack(
                            children: [
                              ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: CachedNetworkImage(
                                  imageUrl:
                                      'https://img.youtube.com/vi/$ytId/mqdefault.jpg',
                                  width: 90,
                                  height: 54,
                                  fit: BoxFit.cover,
                                  errorWidget: (_, _, _) => Container(
                                    width: 90,
                                    height: 54,
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.surfaceVariant,
                                    child: const Icon(
                                      Icons.play_circle_outline,
                                    ),
                                  ),
                                ),
                              ),
                              if (isDone)
                                Positioned.fill(
                                  child: Container(
                                    decoration: BoxDecoration(
                                      color: AppColors.success.withValues(
                                        alpha: 0.7,
                                      ),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: const Icon(
                                      Icons.check_circle_rounded,
                                      color: Colors.white,
                                      size: 28,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          const Gap(12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  v['title'] as String,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.titleSmall,
                                ),
                                const Gap(4),
                                Row(
                                  children: [
                                    Icon(
                                      Icons.timer_outlined,
                                      size: 14,
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurface
                                          .withValues(alpha: 0.6),
                                    ),
                                    const Gap(4),
                                    Text(
                                      _formatDuration(
                                        v['duration_seconds'] as int,
                                      ),
                                      style: Theme.of(
                                        context,
                                      ).textTheme.bodyMedium,
                                    ),
                                    const Gap(12),
                                    if (isDone)
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 8,
                                          vertical: 2,
                                        ),
                                        decoration: BoxDecoration(
                                          color: AppColors.success.withValues(
                                            alpha: 0.1,
                                          ),
                                          borderRadius: BorderRadius.circular(
                                            8,
                                          ),
                                        ),
                                        child: Text(
                                          'مكتمل',
                                          style: TextStyle(
                                            color: AppColors.success,
                                            fontSize: 11,
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ).animate(delay: (30 * i).ms).fadeIn();
              },
            );
          },
        ),
      ),
    );
  }
}
