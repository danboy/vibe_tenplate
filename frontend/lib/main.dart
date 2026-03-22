import 'package:flutter/material.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'providers/auth_provider.dart';
import 'router.dart';

void main() {
  usePathUrlStrategy();
  final auth = AuthProvider();
  final router = createRouter(auth);
  auth.loadToken();
  runApp(
    ChangeNotifierProvider.value(
      value: auth,
      child: _App(router: router),
    ),
  );
}

class _App extends StatelessWidget {
  final GoRouter router;

  const _App({required this.router});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: '10Plate',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: const ColorScheme.light(
          primary: Color(0xFF4A90E2),
          onPrimary: Color(0xFFFFFFFF),
          primaryContainer: Color(0xFFDBEAFE),
          onPrimaryContainer: Color(0xFF1A4A7A),
          secondary: Color(0xFF6C8EBD),
          onSecondary: Color(0xFFFFFFFF),
          secondaryContainer: Color(0xFFEFF6FF),
          onSecondaryContainer: Color(0xFF2C6FBD),
          error: Color(0xFFE74C3C),
          onError: Color(0xFFFFFFFF),
          errorContainer: Color(0xFFFFDAD6),
          onErrorContainer: Color(0xFF410002),
          surface: Color(0xFFFFFFFF),
          onSurface: Color(0xFF1A1A2E),
          surfaceContainerHighest: Color(0xFFF0F2F7),
          onSurfaceVariant: Color(0xFF666666),
          outline: Color(0xFFDDE1EA),
          outlineVariant: Color(0xFFEEF0F4),
          scrim: Color(0xFF000000),
          inverseSurface: Color(0xFF1A1A2E),
          onInverseSurface: Color(0xFFFFFFFF),
          inversePrimary: Color(0xFF90CAF9),
          shadow: Color(0xFF000000),
        ),
        scaffoldBackgroundColor: const Color(0xFFEEF0F4),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFFFFFFFF),
          foregroundColor: Color(0xFF1A1A2E),
          elevation: 0,
          scrolledUnderElevation: 0,
          shadowColor: Color(0x14000000),
          surfaceTintColor: Colors.transparent,
          titleTextStyle: TextStyle(
            fontFamily: 'system-ui',
            fontSize: 17,
            fontWeight: FontWeight.w700,
            color: Color(0xFF1A1A2E),
            letterSpacing: -0.3,
          ),
          shape: Border(
            bottom: BorderSide(color: Color(0xFFDDE1EA), width: 1),
          ),
        ),
        navigationBarTheme: NavigationBarThemeData(
          backgroundColor: const Color(0xFFFFFFFF),
          surfaceTintColor: Colors.transparent,
          indicatorColor: const Color(0xFFDBEAFE),
          elevation: 0,
          shadowColor: Colors.transparent,
          labelTextStyle: WidgetStateProperty.resolveWith((states) {
            final active = states.contains(WidgetState.selected);
            return TextStyle(
              fontSize: 11,
              fontWeight: active ? FontWeight.w600 : FontWeight.w400,
              color: active
                  ? const Color(0xFF4A90E2)
                  : const Color(0xFF888888),
            );
          }),
          iconTheme: WidgetStateProperty.resolveWith((states) {
            final active = states.contains(WidgetState.selected);
            return IconThemeData(
              color: active
                  ? const Color(0xFF4A90E2)
                  : const Color(0xFF888888),
              size: 22,
            );
          }),
        ),
        cardTheme: CardThemeData(
          color: const Color(0xFFFFFFFF),
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: const BorderSide(color: Color(0xFFDDE1EA), width: 1.5),
          ),
          margin: EdgeInsets.zero,
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFFF8F9FC),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(7),
            borderSide: const BorderSide(color: Color(0xFFDDE1EA), width: 1.5),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(7),
            borderSide: const BorderSide(color: Color(0xFFDDE1EA), width: 1.5),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(7),
            borderSide: const BorderSide(color: Color(0xFF4A90E2), width: 1.5),
          ),
          labelStyle: const TextStyle(color: Color(0xFF888888), fontSize: 13),
          hintStyle: const TextStyle(color: Color(0xFFBBBBBB), fontSize: 13),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFF4A90E2),
            foregroundColor: const Color(0xFFFFFFFF),
            textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          ),
        ),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(
            foregroundColor: const Color(0xFF4A90E2),
            textStyle: const TextStyle(fontWeight: FontWeight.w500, fontSize: 13),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
          ),
        ),
        chipTheme: ChipThemeData(
          backgroundColor: const Color(0xFFF0F2F7),
          labelStyle: const TextStyle(fontSize: 12, color: Color(0xFF555555)),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: const BorderSide(color: Color(0xFFDDE1EA)),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 6),
        ),
        dividerTheme: const DividerThemeData(
          color: Color(0xFFEEF0F4),
          thickness: 1,
        ),
        dialogTheme: DialogThemeData(
          backgroundColor: const Color(0xFFFFFFFF),
          surfaceTintColor: Colors.transparent,
          elevation: 8,
          shadowColor: const Color(0x1F000000),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          titleTextStyle: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            color: Color(0xFF1A1A2E),
          ),
        ),
        floatingActionButtonTheme: FloatingActionButtonThemeData(
          backgroundColor: const Color(0xFF4A90E2),
          foregroundColor: const Color(0xFFFFFFFF),
          elevation: 3,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
        listTileTheme: const ListTileThemeData(
          tileColor: Color(0xFFFFFFFF),
          titleTextStyle: TextStyle(fontSize: 14, color: Color(0xFF333333)),
          subtitleTextStyle: TextStyle(fontSize: 12, color: Color(0xFF888888)),
        ),
        textTheme: const TextTheme(
          titleLarge: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w700,
              color: Color(0xFF1A1A2E),
              letterSpacing: -0.3),
          titleMedium: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: Color(0xFF1A1A2E)),
          titleSmall: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: Color(0xFF333333)),
          bodyMedium: TextStyle(fontSize: 13, color: Color(0xFF333333)),
          bodySmall: TextStyle(fontSize: 12, color: Color(0xFF888888)),
          labelSmall: TextStyle(fontSize: 11, color: Color(0xFF888888)),
        ),
      ),
      routerConfig: router,
    );
  }
}
