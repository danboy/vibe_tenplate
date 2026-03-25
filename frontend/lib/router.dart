import 'package:go_router/go_router.dart';
import 'providers/auth_provider.dart';
import 'screens/app_shell.dart';
import 'screens/home_screen.dart';
import 'screens/profile_screen.dart';
import 'screens/login_screen.dart';
import 'screens/register_screen.dart';
import 'screens/group_workspace_screen.dart';
import 'screens/group_detail_screen.dart';
import 'screens/join_screen.dart';
import 'screens/project_slideshow_screen.dart';

GoRouter createRouter(AuthProvider auth) => GoRouter(
      refreshListenable: auth,
      initialLocation: '/groups',
      redirect: (context, state) {
        if (auth.isLoading) return null;
        final loc = state.matchedLocation;
        final isOnAuthPage =
            loc.startsWith('/auth/login') || loc.startsWith('/auth/register');

        if (!auth.isAuthenticated && !isOnAuthPage) {
          final dest = Uri.encodeComponent(state.uri.toString());
          return '/auth/login?redirect=$dest';
        }

        if (auth.isAuthenticated && isOnAuthPage) {
          final redirectTo = state.uri.queryParameters['redirect'];
          if (redirectTo != null && redirectTo.startsWith('/')) {
            return redirectTo;
          }
          return '/groups';
        }

        return null;
      },
      routes: [
        GoRoute(path: '/', redirect: (_, __) => '/groups'),
        GoRoute(path: '/auth/login', builder: (_, __) => const LoginScreen()),
        GoRoute(
            path: '/auth/register',
            builder: (_, __) => const RegisterScreen()),

        GoRoute(
          path: '/join',
          builder: (_, state) => JoinScreen(
            code: state.uri.queryParameters['code'] ?? '',
          ),
        ),

        // Slideshow is full-screen — outside the shell
        GoRoute(
          path: '/groups/:groupSlug/projects/:projectSlug',
          builder: (_, state) => ProjectSlideshowScreen(
            groupSlug: state.pathParameters['groupSlug']!,
            projectSlug: state.pathParameters['projectSlug']!,
          ),
        ),

        // Shell wraps all other authenticated screens
        ShellRoute(
          builder: (_, __, child) => AppShell(child: child),
          routes: [
            GoRoute(
              path: '/groups',
              builder: (_, __) => const MyGroupsScreen(),
            ),
            GoRoute(
              path: '/discover',
              redirect: (_, __) => '/groups',
            ),
            GoRoute(
              path: '/profile',
              builder: (_, __) => const ProfileScreen(),
            ),
            GoRoute(
              path: '/groups/:groupSlug',
              builder: (_, state) => GroupWorkspaceScreen(
                groupSlug: state.pathParameters['groupSlug']!,
              ),
              routes: [
                GoRoute(
                  path: 'members',
                  builder: (_, state) => GroupDetailScreen(
                    groupSlug: state.pathParameters['groupSlug']!,
                  ),
                ),
              ],
            ),
          ],
        ),
      ],
    );
