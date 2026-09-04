import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../features/auth/screens/login_screen.dart';
import '../../features/home/screens/home_screen.dart';
import '../../features/theoretical/screens/years_screen.dart';
import '../../features/theoretical/screens/subjects_screen.dart';
import '../../features/theoretical/screens/videos_screen.dart';
import '../../features/theoretical/screens/video_player_screen.dart';
import '../../features/practical/screens/practical_years_screen.dart';
import '../../features/practical/screens/practical_subjects_screen.dart';
import '../../features/practical/screens/practical_sessions_screen.dart';
import '../../features/practical/screens/qr_screen.dart';
import '../../features/practical/screens/practical_videos_screen.dart';
import '../../features/practical/screens/practical_video_player_screen.dart';
import '../../features/profile/screens/profile_screen.dart';

final routerProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: '/',
    redirect: (context, state) {
      final session = Supabase.instance.client.auth.currentSession;
      final isLoggedIn = session != null;
      if (!isLoggedIn && state.matchedLocation != '/login') return '/login';
      if (isLoggedIn && state.matchedLocation == '/login') return '/';
      return null;
    },
    routes: [
      GoRoute(path: '/login', builder: (_, _) => const StudentLoginScreen()),
      GoRoute(path: '/', builder: (_, _) => const StudentHomeScreen()),
      // Theoretical
      GoRoute(
        path: '/theoretical/years',
        builder: (_, _) => const TheoreticalYearsScreen(),
      ),
      GoRoute(
        path: '/theoretical/subjects/:yearId',
        builder: (_, state) =>
            TheoreticalSubjectsScreen(yearId: state.pathParameters['yearId']!),
      ),
      GoRoute(
        path: '/theoretical/videos/:subjectId',
        builder: (_, state) =>
            VideosScreen(subjectId: state.pathParameters['subjectId']!),
      ),
      GoRoute(
        path: '/theoretical/player/:videoId',
        builder: (_, state) =>
            VideoPlayerScreen(videoId: state.pathParameters['videoId']!),
      ),
      // Practical
      GoRoute(
        path: '/practical/years',
        builder: (_, _) => const PracticalYearsScreen(),
      ),
      GoRoute(
        path: '/practical/subjects/:yearId',
        builder: (_, state) =>
            PracticalSubjectsScreen(yearId: state.pathParameters['yearId']!),
      ),
      GoRoute(
        path: '/practical/sessions/:subjectId',
        builder: (_, state) => PracticalSessionsScreen(
          subjectId: state.pathParameters['subjectId']!,
        ),
      ),
      GoRoute(
        path: '/practical/qr/:lectureId',
        builder: (_, state) => QrScreen(
          lectureId: state.pathParameters['lectureId']!,
          subjectId: state.uri.queryParameters['subjectId'],
          seed: state.uri.queryParameters['seed'],
        ),
      ),
      GoRoute(
        path: '/practical/videos/:subjectId',
        builder: (_, state) => PracticalVideosScreen(
          subjectId: state.pathParameters['subjectId']!,
        ),
      ),
      GoRoute(
        path: '/practical/video-player/:videoId',
        builder: (_, state) => PracticalVideoPlayerScreen(
          videoId: state.pathParameters['videoId']!,
          subjectId: state.uri.queryParameters['subjectId'],
        ),
      ),
      GoRoute(
        path: '/profile',
        builder: (_, _) => const StudentProfileScreen(),
      ),
    ],
  );
});
