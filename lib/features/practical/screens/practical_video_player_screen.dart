import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:youtube_player_flutter/youtube_player_flutter.dart';
import 'package:go_router/go_router.dart';
import 'package:gap/gap.dart';

import '../../../core/theme/app_theme.dart';

class PracticalVideoPlayerScreen extends ConsumerStatefulWidget {
  final String videoId;
  final String? subjectId;
  const PracticalVideoPlayerScreen({
    super.key,
    required this.videoId,
    this.subjectId,
  });

  @override
  ConsumerState<PracticalVideoPlayerScreen> createState() => _State();
}

class _State extends ConsumerState<PracticalVideoPlayerScreen> {
  YoutubePlayerController? _ytController;
  Map<String, dynamic>? _video;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadVideo();
  }

  Future<void> _loadVideo() async {
    try {
      final res = await Supabase.instance.client
          .from('practical_videos')
          .select(
            'id, subject_id, title, description, youtube_video_id, resident_name',
          )
          .eq('id', widget.videoId)
          .single();
      _video = Map<String, dynamic>.from(res);

      final ytId = _video!['youtube_video_id'] as String;
      _ytController = YoutubePlayerController(
        initialVideoId: ytId,
        flags: const YoutubePlayerFlags(autoPlay: false, mute: false),
      );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _ytController?.dispose();
    super.dispose();
  }

  void _goBack() {
    final sid = widget.subjectId ?? (_video?['subject_id'] as String?);
    if (sid == null) {
      Navigator.of(context).maybePop();
      return;
    }
    context.go('/practical/videos/$sid');
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    if (_video == null || _ytController == null) {
      return const Scaffold(body: Center(child: Text('تعذر تحميل الفيديو')));
    }

    final title = _video!['title'] as String? ?? '';
    final description = (_video!['description'] as String?)?.trim() ?? '';
    final residentName = _video!['resident_name'] as String? ?? '—';

    return WillPopScope(
      onWillPop: () async {
        _goBack();
        return false;
      },
      child: YoutubePlayerBuilder(
        player: YoutubePlayer(
          controller: _ytController!,
          showVideoProgressIndicator: true,
          progressIndicatorColor: AppColors.primary,
        ),
        builder: (context, player) => Scaffold(
          appBar: AppBar(
            leading: IconButton(
              icon: const Icon(Icons.arrow_back_rounded),
              onPressed: _goBack,
            ),
            title: Text(title),
          ),
          body: ListView(
            children: [
              player,
              Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: Theme.of(context).textTheme.titleMedium),
                    const Gap(8),
                    Row(
                      children: [
                        const Icon(Icons.person_outline, size: 16),
                        const Gap(6),
                        Expanded(
                          child: Text(
                            residentName,
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                        ),
                      ],
                    ),
                    if (description.isNotEmpty) ...[
                      const Gap(12),
                      Text(
                        description,
                        style: Theme.of(context).textTheme.bodyMedium,
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
  }
}
