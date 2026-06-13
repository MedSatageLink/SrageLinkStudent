import 'dart:convert';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:go_router/go_router.dart';
import 'package:gap/gap.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

final qrLectureProvider = FutureProvider.family<Map<String, dynamic>?, String>((
  ref,
  lectureId,
) async {
  Future<Map<String, dynamic>> fetchRemote() async {
    final res = await Supabase.instance.client
        .from('lectures')
        .select(
          'id, start_at, end_at, location, attendance_window_start, attendance_window_end, practical_sessions(title)',
        )
        .eq('id', lectureId)
        .single();
    return Map<String, dynamic>.from(res);
  }

  final prefs = await SharedPreferences.getInstance();
  final cacheKey = 'qr_lecture_$lectureId';
  final cached = prefs.getString(cacheKey);

  if (cached != null) {
    final cachedMap = Map<String, dynamic>.from(
      jsonDecode(cached) as Map<String, dynamic>,
    );

    unawaited(
      fetchRemote()
          .then((fresh) async {
            await prefs.setString(cacheKey, jsonEncode(fresh));
          })
          .catchError((_) {}),
    );

    return cachedMap;
  }

  try {
    final res = await fetchRemote();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(cacheKey, jsonEncode(res));
    return res;
  } catch (_) {
    return null;
  }
});

class QrScreen extends ConsumerWidget {
  final String lectureId;
  final String? subjectId;
  final String? seed;
  const QrScreen({
    super.key,
    required this.lectureId,
    this.subjectId,
    this.seed,
  });

  Map<String, dynamic>? _parseSeed() {
    if (seed == null || seed!.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(seed!);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
      return null;
    } catch (_) {
      return null;
    }
  }

  String _formatDuration(int mins) {
    if (mins <= 0) return '';
    final hours = mins ~/ 60;
    final rem = mins % 60;
    if (hours == 0) return '$mins د';
    if (rem == 0) return '$hours س';
    return '$hours س $rem د';
  }

  String _formatLectureTime(Map<String, dynamic> lecture) {
    final start = DateTime.tryParse(lecture['start_at'] as String? ?? '');
    final end = DateTime.tryParse(lecture['end_at'] as String? ?? '');
    final location = lecture['location'] as String? ?? '—';
    if (start == null) return '—';
    final dateStr = DateFormat('yyyy-MM-dd').format(start);
    final timeStr = DateFormat('HH:mm').format(start);
    final dur = end == null
        ? ''
        : _formatDuration(end.difference(start).inMinutes);
    final durStr = dur.isEmpty ? '' : ' · $dur';
    return '$dateStr · $timeStr · $location$durStr';
  }

  void _goBack(BuildContext context, Map<String, dynamic>? lecture) {
    final sid =
        subjectId ??
        (lecture?['subject_id'] as String?) ??
        (lecture?['practical_sessions'] as Map<String, dynamic>?)?['subject_id']
            as String?;
    if (sid == null) {
      Navigator.of(context).maybePop();
      return;
    }
    context.go('/practical/sessions/$sid');
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lectureAsync = ref.watch(qrLectureProvider(lectureId));
    final uid = Supabase.instance.client.auth.currentUser!.id;
    final seededLecture = _parseSeed();
    final lecture = lectureAsync.valueOrNull ?? seededLecture;

    final lectureData = lecture ?? <String, dynamic>{};

    // QR payload: JSON with student_id and lecture_id
    final qrData = jsonEncode({'student_id': uid, 'lecture_id': lectureId});

    final sessionTitle =
        (lectureData['practical_sessions']
            as Map<String, dynamic>?)?['title'] ??
        'جلسة عملية';

    return WillPopScope(
      onWillPop: () async {
        _goBack(context, lecture);
        return false;
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back_rounded),
            onPressed: () => _goBack(context, lecture),
          ),
          title: const Text('رمز الحضور'),
        ),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  sessionTitle,
                  style: Theme.of(context).textTheme.titleLarge,
                  textAlign: TextAlign.center,
                ),
                const Gap(6),
                Text(
                  _formatLectureTime(lectureData),
                  style: Theme.of(context).textTheme.bodyMedium,
                  textAlign: TextAlign.center,
                ),
                const Gap(24),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.08),
                        blurRadius: 20,
                        spreadRadius: 2,
                      ),
                    ],
                  ),
                  child: QrImageView(
                    data: qrData,
                    size: 240,
                    version: QrVersions.auto,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
