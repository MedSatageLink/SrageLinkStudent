import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:gap/gap.dart';
import 'package:intl/intl.dart';
import '../../../core/theme/app_theme.dart';

final qrLectureProvider = FutureProvider.family<Map<String, dynamic>?, String>((
  ref,
  lectureId,
) async {
  final res = await Supabase.instance.client
      .from('lectures')
      .select(
        'id, start_at, end_at, location, attendance_window_start, attendance_window_end, practical_sessions(title)',
      )
      .eq('id', lectureId)
      .single();
  return res;
});

class QrScreen extends ConsumerWidget {
  final String lectureId;
  const QrScreen({super.key, required this.lectureId});

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

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lectureAsync = ref.watch(qrLectureProvider(lectureId));
    final uid = Supabase.instance.client.auth.currentUser!.id;

    return Scaffold(
      appBar: AppBar(title: const Text('رمز الحضور')),
      body: lectureAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text(e.toString())),
        data: (lecture) {
          if (lecture == null) {
            return const Center(child: Text('المحاضرة غير موجودة'));
          }

          final now = DateTime.now();
          final windowStart =
              DateTime.tryParse(
                lecture['attendance_window_start'] as String? ?? '',
              ) ??
              DateTime(2000);
          final windowEnd =
              DateTime.tryParse(
                lecture['attendance_window_end'] as String? ?? '',
              ) ??
              DateTime(2000);
          final isWindowOpen =
              now.isAfter(windowStart) && now.isBefore(windowEnd);

          // QR payload: JSON with student_id and lecture_id
          final qrData = jsonEncode({
            'student_id': uid,
            'lecture_id': lectureId,
          });

          final sessionTitle =
              (lecture['practical_sessions']
                  as Map<String, dynamic>?)?['title'] ??
              '';

          return Center(
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
                    _formatLectureTime(lecture),
                    style: Theme.of(context).textTheme.bodyMedium,
                    textAlign: TextAlign.center,
                  ),
                  const Gap(24),
                  if (isWindowOpen) ...[
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
                    const Gap(16),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.success.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.lock_open_rounded,
                            color: AppColors.success,
                            size: 18,
                          ),
                          const Gap(6),
                          Text(
                            'نافذة الحضور مفتوحة',
                            style: TextStyle(
                              color: AppColors.success,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Gap(8),
                    Text(
                      'أبرز هذا الرمز للمقيم لتسجيل حضورك',
                      style: Theme.of(context).textTheme.bodyMedium,
                      textAlign: TextAlign.center,
                    ),
                  ] else ...[
                    Icon(
                      Icons.lock_rounded,
                      size: 80,
                      color: AppColors.error.withValues(alpha: 0.5),
                    ),
                    const Gap(16),
                    Text(
                      now.isBefore(windowStart)
                          ? 'لم تبدأ نافذة الحضور بعد'
                          : 'انتهت نافذة الحضور',
                      style: Theme.of(
                        context,
                      ).textTheme.titleMedium?.copyWith(color: AppColors.error),
                      textAlign: TextAlign.center,
                    ),
                    const Gap(8),
                    Text(
                      'من ${_fmtTime(windowStart)} إلى ${_fmtTime(windowEnd)}',
                      style: Theme.of(context).textTheme.bodyMedium,
                      textAlign: TextAlign.center,
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  String _fmtTime(DateTime dt) =>
      '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
}
