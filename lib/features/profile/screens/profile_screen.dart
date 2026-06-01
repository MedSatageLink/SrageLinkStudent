import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/theme_mode_provider.dart';

class StudentProfileScreen extends ConsumerWidget {
  const StudentProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = Supabase.instance.client.auth.currentUser;
    final themeMode = ref.watch(themeModeProvider);
    final isDark = themeMode == ThemeMode.dark;
    return FutureBuilder(
      future: Supabase.instance.client
          .from('profiles')
          .select('*, categories(name, years(name))')
          .eq('id', user!.id)
          .single(),
      builder: (context, snap) {
        if (!snap.hasData) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        final p = snap.data as Map<String, dynamic>;
        final catName =
            (p['categories'] as Map<String, dynamic>?)?['name'] ?? '—';
        final yearName =
            ((p['categories'] as Map<String, dynamic>?)?['years']
                as Map<String, dynamic>?)?['name'] ??
            '—';
        return WillPopScope(
          onWillPop: () async {
            context.go('/');
            return false;
          },
          child: Scaffold(
            appBar: AppBar(
              title: const Text('ملفي الشخصي'),
              actions: [
                IconButton(
                  icon: const Icon(Icons.arrow_forward_rounded),
                  onPressed: () => context.go('/'),
                ),
              ],
            ),
            body: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Center(
                  child: CircleAvatar(
                    radius: 48,
                    backgroundColor: AppColors.primaryContainer,
                    child: Text(
                      (p['full_name'] as String? ?? '?')[0],
                      style: TextStyle(
                        fontSize: 36,
                        color: AppColors.primary,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ).animate().scale(),
                ),
                const Gap(16),
                Center(
                  child: Text(
                    p['full_name'] as String? ?? '',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                Center(
                  child: Text(
                    user.email ?? '',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
                const Gap(24),
                _InfoTile(
                  icon: Icons.badge_outlined,
                  label: 'رقم الجامعة',
                  value: p['university_id'] as String? ?? '—',
                ),
                _InfoTile(
                  icon: Icons.group_work_outlined,
                  label: 'الفئة',
                  value: catName,
                ),
                _InfoTile(
                  icon: Icons.school_outlined,
                  label: 'السنة',
                  value: yearName,
                ),
                _InfoTile(
                  icon: Icons.format_list_numbered,
                  label: 'رقم الترتيب',
                  value: '${p['order_number'] ?? '—'}',
                ),
                Container(
                  margin: const EdgeInsets.only(bottom: 10),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surface,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: Theme.of(context).colorScheme.outline,
                    ),
                  ),
                  child: SwitchListTile.adaptive(
                    value: isDark,
                    onChanged: (value) => ref
                        .read(themeModeProvider.notifier)
                        .setThemeMode(value ? ThemeMode.dark : ThemeMode.light),
                    title: const Text('الوضع الداكن'),
                    subtitle: Text(isDark ? 'مفعل' : 'غير مفعل'),
                    secondary: Icon(
                      isDark
                          ? Icons.dark_mode_rounded
                          : Icons.light_mode_rounded,
                      color: AppColors.primary,
                    ),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
                const Gap(24),
                OutlinedButton.icon(
                  onPressed: () async {
                    await Supabase.instance.client.auth.signOut();
                  },
                  icon: const Icon(Icons.logout_rounded),
                  label: const Text('تسجيل الخروج'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.error,
                    side: BorderSide(color: AppColors.error),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _InfoTile extends StatelessWidget {
  final IconData icon;
  final String label, value;
  const _InfoTile({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Theme.of(context).colorScheme.outline),
      ),
      child: Row(
        children: [
          Icon(icon, color: AppColors.primary, size: 20),
          const Gap(12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurface.withValues(alpha: 0.6),
                ),
              ),
              Text(value, style: Theme.of(context).textTheme.bodyLarge),
            ],
          ),
        ],
      ),
    );
  }
}
