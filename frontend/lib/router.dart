import 'package:go_router/go_router.dart';
import 'providers/auth_provider.dart';
import 'screens/app_shell.dart';
import 'screens/profile_screen.dart';
import 'screens/login_screen.dart';
import 'screens/register_screen.dart';
import 'screens/group_workspace_screen.dart';
import 'screens/group_detail_screen.dart';
import 'screens/join_screen.dart';
import 'screens/onboarding_screen.dart';
import 'screens/project_slideshow_screen.dart';
import 'screens/teams_screen.dart';
import 'screens/team_workspace_screen.dart';
import 'screens/team_detail_screen.dart';

GoRouter createRouter(AuthProvider auth) => GoRouter(
      refreshListenable: auth,
      initialLocation: '/teams',
      redirect: (context, state) {
        if (auth.isLoading) return null;
        final loc = state.matchedLocation;
        final isOnAuthPage =
            loc.startsWith('/auth/login') || loc.startsWith('/auth/register');
        // Slideshow handles guest access internally — don't redirect to login
        final isSlideshow =
            loc.contains('/projects/') && loc.startsWith('/groups/');

        if (!auth.isAuthenticated && !isOnAuthPage && !isSlideshow) {
          final dest = Uri.encodeComponent(state.uri.toString());
          return '/auth/login?redirect=$dest';
        }

        if (auth.isAuthenticated && isOnAuthPage) {
          final redirectTo = state.uri.queryParameters['redirect'];
          if (redirectTo != null && redirectTo.startsWith('/')) {
            return redirectTo;
          }
          if (auth.pendingPlan != null) return '/onboarding';
          return '/teams';
        }

        return null;
      },
      routes: [
        GoRoute(path: '/', redirect: (_, __) => '/teams'),
        GoRoute(path: '/groups', redirect: (_, __) => '/teams'),
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

        // Onboarding — full-screen, outside the shell
        GoRoute(
          path: '/onboarding',
          builder: (_, __) => const OnboardingScreen(),
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
              path: '/teams',
              builder: (_, __) => const TeamsScreen(),
            ),
            GoRoute(
              path: '/teams/:teamSlug',
              builder: (_, state) => TeamWorkspaceScreen(
                teamSlug: state.pathParameters['teamSlug']!,
              ),
              routes: [
                GoRoute(
                  path: 'settings',
                  builder: (_, state) => TeamDetailScreen(
                    teamSlug: state.pathParameters['teamSlug']!,
                  ),
                ),
              ],
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
