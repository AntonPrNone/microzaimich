import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';

import '../data/repositories/auth_repository.dart';
import '../data/repositories/app_settings_repository.dart';
import '../data/repositories/loan_repository.dart';
import '../data/repositories/notification_repository.dart';
import '../data/services/backup_service.dart';
import '../data/services/app_clock.dart';
import '../data/services/bootstrap_service.dart';
import '../data/services/firestore_service.dart';
import '../data/services/session_service.dart';
import '../features/auth/presentation/login_controller.dart';
import '../features/auth/presentation/login_screen.dart';
import '../features/home/presentation/home_screen.dart';
import 'app_theme.dart';

class MicrozaimichApp extends StatelessWidget {
  const MicrozaimichApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider(create: (_) => FirestoreService()),
        ProxyProvider<FirestoreService, BackupService>(
          update: (context, firestore, previous) =>
              BackupService(firestoreService: firestore),
        ),
        Provider(create: (_) => SessionService()),
        ProxyProvider<FirestoreService, AuthRepository>(
          update: (context, firestore, previous) => AuthRepository(
            firestoreService: firestore,
          ),
        ),
        ProxyProvider<FirestoreService, NotificationRepository>(
          update: (context, firestore, previous) => NotificationRepository(
            firestoreService: firestore,
          ),
        ),
        ProxyProvider2<FirestoreService, NotificationRepository, LoanRepository>(
          update: (context, firestore, notifications, previous) =>
              LoanRepository(
            firestoreService: firestore,
            notificationRepository: notifications,
          ),
        ),
        ProxyProvider<FirestoreService, AppSettingsRepository>(
          update: (context, firestore, previous) =>
              AppSettingsRepository(firestoreService: firestore),
        ),
        ProxyProvider3<AuthRepository, LoanRepository, SessionService,
            BootstrapService>(
          update: (
            context,
            authRepository,
            loanRepository,
            sessionService,
            previous,
          ) =>
              BootstrapService(
                authRepository: authRepository,
                loanRepository: loanRepository,
                sessionService: sessionService,
              ),
        ),
        ChangeNotifierProxyProvider4<AuthRepository, LoanRepository,
            SessionService, BootstrapService, LoginController>(
          create: (_) => LoginController.empty(),
          update: (_, authRepository, loanRepository, sessionService,
                  bootstrapService, previous) =>
              previous?.rebind(
                    authRepository: authRepository,
                    sessionService: sessionService,
                    bootstrapService: bootstrapService,
                  ) ??
              LoginController(
                authRepository: authRepository,
                sessionService: sessionService,
                bootstrapService: bootstrapService,
              ),
        ),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'Микрозаймич',
        theme: AppTheme.dark(),
        locale: const Locale('ru', 'RU'),
        supportedLocales: const [
          Locale('ru', 'RU'),
          Locale('en', 'US'),
        ],
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: const AppBootstrap(),
      ),
    );
  }
}

class AppBootstrap extends StatefulWidget {
  const AppBootstrap({super.key});

  @override
  State<AppBootstrap> createState() => _AppBootstrapState();
}

class _AppBootstrapState extends State<AppBootstrap> {
  late final Future<void> _bootstrapFuture;
  late final FirestoreService _firestoreService;
  late final LoginController _loginController;

  @override
  void initState() {
    super.initState();
    _firestoreService = context.read<FirestoreService>();
    _loginController = context.read<LoginController>();
    _bootstrapFuture = _initializeApp();
  }

  Future<void> _initializeApp() async {
    await AppClock.syncServerTime(_firestoreService);
    await _loginController.initialize();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<void>(
      future: _bootstrapFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const _SplashScreen();
        }

        if (snapshot.hasError) {
          return _BootstrapError(error: snapshot.error.toString());
        }

        return Consumer<LoginController>(
          builder: (context, controller, _) {
            if (controller.currentUser == null) {
              return const LoginScreen();
            }
            return const HomeScreen();
          },
        );
      },
    );
  }
}

class _SplashScreen extends StatelessWidget {
  const _SplashScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TweenAnimationBuilder<double>(
              tween: Tween<double>(begin: 0, end: 1),
              duration: const Duration(milliseconds: 650),
              curve: Curves.easeOutCubic,
              builder: (context, value, child) {
                return Opacity(
                  opacity: value.clamp(0, 1),
                  child: Transform.scale(
                    scale: 0.94 + (0.06 * value),
                    child: child,
                  ),
                );
              },
              child: Container(
                width: 84,
                height: 84,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primary.withValues(
                        alpha: 0.16,
                      ),
                  borderRadius: BorderRadius.circular(28),
                  boxShadow: [
                    BoxShadow(
                      color: Theme.of(
                        context,
                      ).colorScheme.primary.withValues(alpha: 0.12),
                      blurRadius: 24,
                      spreadRadius: 2,
                    ),
                  ],
                ),
                padding: const EdgeInsets.all(12),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(18),
                  child: Image.asset(
                    'assets/icons/app_icon.png',
                    fit: BoxFit.cover,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              'Микрозаймы',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                fontSize: 0,
                color: Colors.transparent,
                height: 0,
              ),
            ),
            Text(
              'Микрозаймич',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                fontSize: 0,
                color: Colors.transparent,
                height: 0,
              ),
            ),
            TweenAnimationBuilder<double>(
              tween: Tween<double>(begin: 0, end: 1),
              duration: const Duration(milliseconds: 700),
              curve: Curves.easeOutCubic,
              builder: (context, value, child) {
                return Opacity(
                  opacity: value.clamp(0, 1),
                  child: Transform.translate(
                    offset: Offset(0, 8 * (1 - value)),
                    child: child,
                  ),
                );
              },
              child: Text(
                'Микрозаймич',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
            ),
            const SizedBox(height: 12),
            const CircularProgressIndicator(),
          ],
        ),
      ),
    );
  }
}

class _BootstrapError extends StatelessWidget {
  const _BootstrapError({required this.error});

  final String error;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 56),
              const SizedBox(height: 16),
              Text(
                'Не удалось запустить приложение',
                style: Theme.of(context).textTheme.titleLarge,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(error, textAlign: TextAlign.center),
            ],
          ),
        ),
      ),
    );
  }
}
