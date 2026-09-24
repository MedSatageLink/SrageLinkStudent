import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:go_router/go_router.dart';
import 'package:gap/gap.dart';
import 'package:stagelink_student/core/utils/app_error_message.dart';

final practicalVideosBySubjectProvider =
    FutureProvider.family<List<Map<String, dynamic>>, String>((
      ref,
      subjectId,
    ) async {
      final res = await Supabase.instance.client
          .from('practical_videos')
          .select(
            'id, title, description, youtube_video_id, created_at, resident_name',
          )
          .eq('subject_id', subjectId)
          .order('created_at', ascending: false);
      return List<Map<String, dynamic>>.from(res as List);
    });

class PracticalVideosScreen extends ConsumerWidget {
  final String subjectId;
  const PracticalVideosScreen({super.key, required this.subjectId});

  void _goBackToSessionsOrPop(BuildContext context) {
    if (context.canPop()) {
      context.pop();
      return;
    }
    context.go('/practical/sessions/$subjectId');
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final videosAsync = ref.watch(practicalVideosBySubjectProvider(subjectId));

    return WillPopScope(
      onWillPop: () async {
        _goBackToSessionsOrPop(context);
        return false;
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back_rounded),
            onPressed: () => _goBackToSessionsOrPop(context),
          ),
          title: const Text('حالات سريرية'),
        ),
        body: videosAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text(AppErrorMessage.from(e))),
          data: (videos) {
            if (videos.isEmpty) {
              return const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('لا توجد فيديوهات لهذه المادة حالياً.'),
                ),
              );
            }

            return ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              itemCount: videos.length,
              itemBuilder: (context, i) {
                final v = videos[i];
                final ytId = v['youtube_video_id'] as String? ?? '';
                final residentName = v['resident_name'] as String? ?? '—';
                final desc = (v['description'] as String?)?.trim() ?? '';

                return Card(
                  margin: const EdgeInsets.only(bottom: 10),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () => context.push(
                      '/practical/video-player/${v['id']}?subjectId=$subjectId',
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: CachedNetworkImage(
                              imageUrl:
                                  'https://img.youtube.com/vi/$ytId/mqdefault.jpg',
                              width: 98,
                              height: 62,
                              fit: BoxFit.cover,
                              errorWidget: (_, _, _) => Container(
                                width: 98,
                                height: 62,
                                color: Theme.of(
                                  context,
                                ).colorScheme.surfaceVariant,
                                child: const Icon(Icons.play_circle_outline),
                              ),
                            ),
                          ),
                          const Gap(12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  v['title'] as String? ?? '—',
                                  style: Theme.of(context).textTheme.titleSmall,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                const Gap(6),
                                Row(
                                  children: [
                                    const Icon(Icons.person_outline, size: 14),
                                    const Gap(4),
                                    Expanded(
                                      child: Text(
                                        residentName,
                                        style: Theme.of(
                                          context,
                                        ).textTheme.bodyMedium,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ],
                                ),
                                if (desc.isNotEmpty) ...[
                                  const Gap(6),
                                  Text(
                                    desc,
                                    style: Theme.of(
                                      context,
                                    ).textTheme.bodyMedium,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ],
                            ),
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
    );
  }
}
