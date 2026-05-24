import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:youtube_player_flutter/youtube_player_flutter.dart';
import 'package:local_auth/local_auth.dart';
import 'package:gap/gap.dart';
import '../../../core/theme/app_theme.dart';

class VideoPlayerScreen extends ConsumerStatefulWidget {
  final String videoId;
  const VideoPlayerScreen({super.key, required this.videoId});
  @override
  ConsumerState<VideoPlayerScreen> createState() => _State();
}

class _State extends ConsumerState<VideoPlayerScreen> {
  YoutubePlayerController? _ytController;
  Map<String, dynamic>? _video;
  bool _loading = true;
  bool _biometricOk = false;
  bool _attendanceMarked = false;
  bool _checkingBiometric = false;
  double _watchedPercent = 0.0;

  @override
  void initState() {
    super.initState();
    _loadAndCheckBiometric();
  }

  Future<void> _loadAndCheckBiometric() async {
    // 1. Load video data
    final res = await Supabase.instance.client
        .from('videos')
        .select('id, title, youtube_video_id, duration_seconds')
        .eq('id', widget.videoId)
        .single();
    _video = res;

    // 2. Check if already completed
    final uid = Supabase.instance.client.auth.currentUser!.id;
    final existing = await Supabase.instance.client
        .from('video_attendance')
        .select('is_completed')
        .eq('student_id', uid)
        .eq('video_id', widget.videoId)
        .maybeSingle();
    if (existing != null && existing['is_completed'] == true) {
      setState(() {
        _attendanceMarked = true;
        _biometricOk = true;
      });
    }

    // 3. Biometric
    await _doBiometric();

    // 4. Init player
    if (_biometricOk) {
      _initPlayer();
    }
    if (mounted) {
      setState(() => _loading = false);
    }
  }

  Future<void> _doBiometric() async {
    setState(() => _checkingBiometric = true);
    try {
      final auth = LocalAuthentication();
      final canCheck = await auth.canCheckBiometrics;
      if (!canCheck) {
        setState(() {
          _biometricOk = true;
        });
        return;
      }
      final ok = await auth.authenticate(
        localizedReason: 'تحقق من هويتك لمشاهدة الفيديو',
        options: const AuthenticationOptions(
          biometricOnly: false,
          stickyAuth: true,
        ),
      );
      setState(() => _biometricOk = ok);
    } catch (_) {
      setState(() => _biometricOk = true); // fail-open on error
    } finally {
      setState(() => _checkingBiometric = false);
    }
  }

  void _initPlayer() {
    final ytId = _video!['youtube_video_id'] as String;
    _ytController = YoutubePlayerController(
      initialVideoId: ytId,
      flags: const YoutubePlayerFlags(autoPlay: false, mute: false),
    )..addListener(_onPlayerUpdate);
  }

  void _onPlayerUpdate() {
    if (_ytController == null || !mounted) return;
    final dur = _ytController!.value.metaData.duration.inSeconds;
    final pos = _ytController!.value.position.inSeconds;
    if (dur > 0) {
      final pct = pos / dur;
      setState(() => _watchedPercent = pct.clamp(0.0, 1.0));
      // Mark completed when ≥90%
      if (pct >= 0.9 && !_attendanceMarked) _markAttendance();
    }
  }

  Future<void> _markAttendance() async {
    setState(() => _attendanceMarked = true);
    final uid = Supabase.instance.client.auth.currentUser!.id;
    await Supabase.instance.client.from('video_attendance').upsert({
      'student_id': uid,
      'video_id': widget.videoId,
      'is_completed': true,
    }, onConflict: 'student_id, video_id');
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Row(
            children: [
              Icon(Icons.check_circle_rounded, color: Colors.white),
              Gap(8),
              Text('تم تسجيل حضورك ✓'),
            ],
          ),
          backgroundColor: AppColors.success,
        ),
      );
    }
  }

  @override
  void dispose() {
    _ytController?.removeListener(_onPlayerUpdate);
    _ytController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    if (_checkingBiometric) {
      return Scaffold(
        appBar: AppBar(title: const Text('جاري التحقق من الهوية')),
        body: const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              Gap(16),
              Text('يرجى التحقق البيومتري...'),
            ],
          ),
        ),
      );
    }

    if (!_biometricOk) {
      return Scaffold(
        appBar: AppBar(title: Text(_video?['title'] as String? ?? '')),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.fingerprint, size: 80, color: AppColors.error),
              const Gap(16),
              const Text('فشل التحقق من الهوية'),
              const Gap(16),
              ElevatedButton.icon(
                onPressed: () async {
                  await _doBiometric();
                  if (_biometricOk) {
                    _initPlayer();
                    setState(() {});
                  }
                },
                icon: const Icon(Icons.replay),
                label: const Text('إعادة المحاولة'),
              ),
            ],
          ),
        ),
      );
    }

    return YoutubePlayerBuilder(
      player: YoutubePlayer(
        controller: _ytController!,
        showVideoProgressIndicator: true,
        progressIndicatorColor: AppColors.primary,
      ),
      builder: (context, player) => Scaffold(
        appBar: AppBar(title: Text(_video?['title'] as String? ?? '')),
        body: Column(
          children: [
            player,
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _video?['title'] as String? ?? '',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const Gap(12),
                  Row(
                    children: [
                      const Text('نسبة المشاهدة: '),
                      Expanded(
                        child: LinearProgressIndicator(
                          value: _watchedPercent,
                          backgroundColor: AppColors.divider,
                          valueColor: AlwaysStoppedAnimation(AppColors.primary),
                          minHeight: 8,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                      const Gap(8),
                      Text('${(_watchedPercent * 100).toStringAsFixed(0)}%'),
                    ],
                  ),
                  if (_attendanceMarked) ...[
                    const Gap(12),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppColors.success.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.check_circle_rounded,
                            color: AppColors.success,
                          ),
                          const Gap(8),
                          const Text('تم تسجيل الحضور بنجاح ✓'),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
