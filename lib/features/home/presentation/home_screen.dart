import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/utils/formatters.dart';
import '../../../core/utils/app_snackbar.dart';
import '../../../core/utils/platform_utils.dart';
import '../../../core/widgets/ad_navigation_shortcuts.dart';
import '../../../data/models/app_notification.dart';
import '../../../data/models/app_clock_settings.dart';
import '../../../data/models/app_user.dart';
import '../../../data/models/loan.dart';
import '../../../data/models/loan_defaults_settings.dart';
import '../../../data/models/payment_schedule_item.dart';
import '../../../data/models/payment_settings.dart';
import '../../../data/models/user_role.dart';
import '../../../data/repositories/app_settings_repository.dart';
import '../../../data/repositories/auth_repository.dart';
import '../../../data/repositories/loan_repository.dart';
import '../../../data/repositories/notification_repository.dart';
import '../../../data/services/local_notification_service.dart';
import '../../../data/services/app_clock.dart';
import '../../../data/services/backup_service.dart';
import '../../auth/presentation/login_controller.dart';
import 'widgets/admin_dashboard.dart';
import 'widgets/client_dashboard.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final sessionUser = context.watch<LoginController>().currentUser!;
    final authRepository = context.read<AuthRepository>();
    final loanRepository = context.read<LoanRepository>();
    final appSettingsRepository = context.read<AppSettingsRepository>();
    final notificationRepository = context.read<NotificationRepository>();
    final backupService = context.read<BackupService>();

    return StreamBuilder<AppUser?>(
      stream: authRepository.watchUserById(sessionUser.id),
      initialData: sessionUser,
      builder: (context, snapshot) {
        final currentUser = snapshot.data;
        if (currentUser == null) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        return StreamBuilder<AppClockSettings>(
          stream: appSettingsRepository.watchClockSettings(),
          builder: (context, clockSnapshot) {
            if (!clockSnapshot.hasData) {
              return const Scaffold(
                body: Center(child: CircularProgressIndicator()),
              );
            }

            AppClock.applySettings(clockSnapshot.data!);

            if (currentUser.role == UserRole.admin) {
              return _AdminHome(
                currentUser: currentUser,
                authRepository: authRepository,
                loanRepository: loanRepository,
                appSettingsRepository: appSettingsRepository,
                notificationRepository: notificationRepository,
                backupService: backupService,
                clockSettings: clockSnapshot.data!,
              );
            }

            return _ClientHome(
              currentUser: currentUser,
              loanRepository: loanRepository,
              appSettingsRepository: appSettingsRepository,
              notificationRepository: notificationRepository,
            );
          },
        );
      },
    );
  }
}

class _ClientHome extends StatefulWidget {
  const _ClientHome({
    required this.currentUser,
    required this.loanRepository,
    required this.appSettingsRepository,
    required this.notificationRepository,
  });

  final AppUser currentUser;
  final LoanRepository loanRepository;
  final AppSettingsRepository appSettingsRepository;
  final NotificationRepository notificationRepository;

  @override
  State<_ClientHome> createState() => _ClientHomeState();
}

class _ClientHomeState extends State<_ClientHome> {
  late final Stream<List<Loan>> _loansStream;
  late final Stream<PaymentSettings> _paymentSettingsStream;
  late final Stream<List<AppNotification>> _notificationsStream;
  bool _showTelegramWebBanner = false;
  bool _telegramWebBannerLoaded = false;

  String get _telegramWebBannerKey =>
      'client_web_tg_banner_dismissed_${widget.currentUser.id}';

  @override
  void initState() {
    super.initState();
    _loansStream = widget.loanRepository.watchLoansForUser(widget.currentUser.id);
    _paymentSettingsStream = widget.appSettingsRepository.watchPaymentSettings();
    _notificationsStream = widget.notificationRepository.watchForUser(
      widget.currentUser.id,
    );
    _loadTelegramWebBannerState();
  }

  @override
  void didUpdateWidget(covariant _ClientHome oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentUser.id != widget.currentUser.id ||
        oldWidget.currentUser.telegramChatId != widget.currentUser.telegramChatId ||
        oldWidget.currentUser.telegramNotificationsEnabled !=
            widget.currentUser.telegramNotificationsEnabled) {
      _loadTelegramWebBannerState();
    }
  }

  bool get _hasTelegramNotificationsConfigured =>
      widget.currentUser.hasTelegramLinked &&
      widget.currentUser.telegramNotificationsEnabled;

  Future<void> _loadTelegramWebBannerState() async {
    if (!AppPlatform.isWeb) {
      if (!mounted) {
        return;
      }
      setState(() {
        _telegramWebBannerLoaded = true;
        _showTelegramWebBanner = false;
      });
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    final dismissed = prefs.getBool(_telegramWebBannerKey) ?? false;
    if (!mounted) {
      return;
    }
    setState(() {
      _telegramWebBannerLoaded = true;
      _showTelegramWebBanner =
          !dismissed && !_hasTelegramNotificationsConfigured;
    });
  }

  Future<void> _dismissTelegramWebBanner() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_telegramWebBannerKey, true);
    if (!mounted) {
      return;
    }
    setState(() {
      _showTelegramWebBanner = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Loan>>(
      stream: _loansStream,
      builder: (context, loansSnapshot) {
        if (!loansSnapshot.hasData) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        return StreamBuilder<PaymentSettings>(
          stream: _paymentSettingsStream,
          builder: (context, settingsSnapshot) {
            if (!settingsSnapshot.hasData) {
              return const Scaffold(
                body: Center(child: CircularProgressIndicator()),
              );
            }
            return StreamBuilder<List<AppNotification>>(
              stream: _notificationsStream,
              builder: (context, notificationsSnapshot) {
                if (!notificationsSnapshot.hasData) {
                  return const Scaffold(
                    body: Center(child: CircularProgressIndicator()),
                  );
                }

                final loans = loansSnapshot.data!;
                final notifications = notificationsSnapshot.data!;

                return Scaffold(
                  appBar: AppBar(
                    title: const Text('Мои займы'),
                    actions: [
                      _NotificationsAction(
                        user: widget.currentUser,
                        notifications: notifications,
                        notificationRepository: widget.notificationRepository,
                      ),
                      IconButton(
                        tooltip: 'Настройки',
                        onPressed: () => _showSettingsSheet(
                          context,
                          widget.currentUser,
                          onSaveUserReminderTime: ({
                            required int hour,
                            required int minute,
                          }) async {
                            await context.read<AuthRepository>().updateReminderTime(
                              user: widget.currentUser,
                              hour: hour,
                              minute: minute,
                            );
                          },
                        ),
                        icon: Icon(
                          Icons.settings_outlined,
                          color: Theme.of(context).colorScheme.secondary,
                        ),
                      ),
                      IconButton(
                        tooltip: 'Выйти',
                        onPressed: () => _confirmLogout(context),
                        icon: const Icon(
                          Icons.logout_rounded,
                          color: Color(0xFFFF8A80),
                        ),
                      ),
                    ],
                  ),
                  body: Stack(
                    children: [
                      Column(
                        children: [
                          if (_telegramWebBannerLoaded && _showTelegramWebBanner)
                            MaterialBanner(
                              content: const Text(
                                'В веб-версии настоятельно рекомендуется включить уведомления через Telegram-бота в настройках профиля.',
                              ),
                              leading: const Icon(Icons.telegram_rounded),
                              actions: [
                                TextButton(
                                  onPressed: _dismissTelegramWebBanner,
                                  child: const Text('Понятно'),
                                ),
                              ],
                            ),
                          Expanded(
                            child: ClientDashboard(
                              user: widget.currentUser,
                              loans: loans,
                              paymentSettings: settingsSnapshot.data!,
                            ),
                          ),
                        ],
                      ),
                      _NotificationEffects(
                        user: widget.currentUser,
                        loans: loans,
                        notifications: notifications,
                        reminderTime: TimeOfDay(
                          hour: widget.currentUser.reminderHour,
                          minute: widget.currentUser.reminderMinute,
                        ),
                      ),
                    ],
                  ),
                );
              },
            );
          },
        );
      },
    );
  }
}

class _AdminHome extends StatefulWidget {
  const _AdminHome({
    required this.currentUser,
    required this.authRepository,
    required this.loanRepository,
    required this.appSettingsRepository,
    required this.notificationRepository,
    required this.backupService,
    required this.clockSettings,
  });

  final AppUser currentUser;
  final AuthRepository authRepository;
  final LoanRepository loanRepository;
  final AppSettingsRepository appSettingsRepository;
  final NotificationRepository notificationRepository;
  final BackupService backupService;
  final AppClockSettings clockSettings;

  @override
  State<_AdminHome> createState() => _AdminHomeState();
}

class _AdminHomeState extends State<_AdminHome> {
  bool _hideClosedLoans = false;
  late final Stream<List<AppUser>> _clientsStream;
  late final Stream<List<Loan>> _allLoansStream;
  late final Stream<PaymentSettings> _paymentSettingsStream;
  late final Stream<LoanDefaultsSettings> _loanDefaultsStream;
  late final Stream<List<AppNotification>> _notificationsStream;

  String get _hideClosedLoansKey =>
      'admin_hide_closed_loans_${widget.currentUser.id}';

  @override
  void initState() {
    super.initState();
    _clientsStream = widget.authRepository.watchClients();
    _allLoansStream = widget.loanRepository.watchAllLoans();
    _paymentSettingsStream = widget.appSettingsRepository.watchPaymentSettings();
    _loanDefaultsStream = widget.appSettingsRepository.watchLoanDefaults();
    _notificationsStream = widget.notificationRepository.watchForUser(
      widget.currentUser.id,
    );
    _loadAdminSettings();
  }

  Future<void> _loadAdminSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) {
        return;
      }
      setState(() {
        _hideClosedLoans = prefs.getBool(_hideClosedLoansKey) ?? false;
      });
    } on Object {
      if (!mounted) {
        return;
      }
      setState(() {
        _hideClosedLoans = false;
      });
    }
  }

  Future<void> _updateAdminSettings({required bool hideClosedLoans}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_hideClosedLoansKey, hideClosedLoans);
    } on Object {
      // Web or storage-restricted environments may fail to persist local UI settings.
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _hideClosedLoans = hideClosedLoans;
    });
  }

  Future<void> _openLoanEditor(
    BuildContext context,
    List<AppUser> clients,
    Loan loan,
    LoanDefaultsSettings loanDefaults,
  ) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      builder: (sheetContext) => LoanEditorSheet(
        clients: clients,
        existingLoan: loan,
        defaultSettings: loanDefaults,
        onCreate: ({
          required String userId,
          required String title,
          required double principal,
          required double interestPercent,
          required double totalAmount,
          required double dailyPenaltyAmount,
          required DateTime issuedAt,
          required List<PaymentScheduleItem> schedule,
          required int paymentIntervalCount,
          required String paymentIntervalUnit,
          String? note,
        }) async {
          await widget.loanRepository.createLoan(
            userId: userId,
            title: title,
            principal: principal,
            interestPercent: interestPercent,
            totalAmount: totalAmount,
            dailyPenaltyAmount: dailyPenaltyAmount,
            issuedAt: issuedAt,
            schedule: schedule,
            paymentIntervalCount: paymentIntervalCount,
            paymentIntervalUnit: paymentIntervalUnit,
            note: note,
          );
        },
        onUpdate: widget.loanRepository.updateLoan,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      animationDuration: AppPlatform.isWindows
          ? const Duration(milliseconds: 1)
          : kTabScrollDuration,
      child: StreamBuilder<List<AppUser>>(
        stream: _clientsStream,
        builder: (context, clientsSnapshot) {
          if (!clientsSnapshot.hasData) {
            return const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
          }
          return StreamBuilder<List<Loan>>(
            stream: _allLoansStream,
            builder: (context, loansSnapshot) {
              if (!loansSnapshot.hasData) {
                return const Scaffold(
                  body: Center(child: CircularProgressIndicator()),
                );
              }
              return StreamBuilder<PaymentSettings>(
                stream: _paymentSettingsStream,
                builder: (context, paymentSettingsSnapshot) {
                  if (!paymentSettingsSnapshot.hasData) {
                    return const Scaffold(
                      body: Center(child: CircularProgressIndicator()),
                    );
                  }
                  return StreamBuilder<LoanDefaultsSettings>(
                    stream: _loanDefaultsStream,
                    builder: (context, defaultsSnapshot) {
                      if (!defaultsSnapshot.hasData) {
                        return const Scaffold(
                          body: Center(child: CircularProgressIndicator()),
                        );
                      }
                      return StreamBuilder<List<AppNotification>>(
                        stream: _notificationsStream,
                        builder: (context, notificationsSnapshot) {
                          if (!notificationsSnapshot.hasData) {
                            return const Scaffold(
                              body: Center(
                                child: CircularProgressIndicator(),
                              ),
                            );
                          }

                          final clients = clientsSnapshot.data!;
                          final loans = loansSnapshot.data!;
                          final paymentSettings = paymentSettingsSnapshot.data!;
                          final loanDefaults = defaultsSnapshot.data!;
                          final notifications = notificationsSnapshot.data!;

                          return Scaffold(
                            appBar: AppBar(
                              title: const Text('Админ Панель'),
                              actions: [
                                _NotificationsAction(
                                  user: widget.currentUser,
                                  notifications: notifications,
                                  notificationRepository:
                                      widget.notificationRepository,
                                ),
                                IconButton(
                                  tooltip: 'Настройки',
                                  onPressed: () => _showSettingsSheet(
                                    context,
                                    widget.currentUser,
                                    hideClosedLoans: _hideClosedLoans,
                                    onAdminSettingsChanged: _updateAdminSettings,
                                    loanDefaults: loanDefaults,
                                    paymentSettings: paymentSettings,
                                    onSavePaymentSettings: widget
                                        .appSettingsRepository
                                        .savePaymentSettings,
                                    clockSettings: widget.clockSettings,
                                    onSaveLoanDefaults: widget
                                        .appSettingsRepository
                                        .saveLoanDefaults,
                                    onSaveClockSettings: widget
                                        .appSettingsRepository
                                        .saveClockSettings,
                                    backupService: widget.backupService,
                                    onClearDatabase: () => widget.backupService
                                        .clearAllPreservingAdmin(
                                          widget.currentUser.id,
                                        ),
                                  ),
                                  icon: Icon(
                                    Icons.settings_outlined,
                                    color: Theme.of(context).colorScheme.secondary,
                                  ),
                                ),
                                IconButton(
                                  tooltip: 'Выйти',
                                  onPressed: () => _confirmLogout(context),
                                  icon: const Icon(
                                    Icons.logout_rounded,
                                    color: Color(0xFFFF8A80),
                                  ),
                                ),
                              ],
                              bottom: const TabBar(
                                tabs: [
                                  Tab(
                                    icon: Icon(Icons.people_outline),
                                    text: 'Клиенты',
                                  ),
                                  Tab(
                                    icon: Icon(
                                      Icons.dashboard_customize_outlined,
                                    ),
                                    text: 'Управление',
                                  ),
                                ],
                              ),
                            ),
                            body: Stack(
                              children: [
                                AdNavigationShortcuts(
                                  onPrevious: () {
                                    final controller = DefaultTabController.of(context);
                                    if (controller.index > 0) {
                                      controller.animateTo(controller.index - 1);
                                    }
                                  },
                                  onNext: () {
                                    final controller = DefaultTabController.of(context);
                                    if (controller.index < controller.length - 1) {
                                      controller.animateTo(controller.index + 1);
                                    }
                                  },
                                  child: TabBarView(
                                    physics: AppPlatform.isWindows
                                        ? const NeverScrollableScrollPhysics()
                                        : null,
                                    children: [
                                      AdminClientsTab(
                                      currentViewerId: widget.currentUser.id,
                                      clients: clients,
                                      loans: loans,
                                      hideClosedLoans: _hideClosedLoans,
                                      watchLoansForUser: widget.loanRepository.watchLoansForUser,
                                      onEditLoan: (loan) => _openLoanEditor(
                                        context,
                                        clients,
                                        loan,
                                        loanDefaults,
                                      ),
                                      onCloseLoan: (
                                        Loan loan, {
                                        DateTime? paidAt,
                                      }) => widget.loanRepository.closeLoan(loan, paidAt: paidAt),
                                      onDeleteLoan: (loan) =>
                                          widget.loanRepository.deleteLoan(loan.id),
                                    ),
                                      AdminDashboard(
                                      clients: clients,
                                      loans: loans,
                                      paymentSettings: paymentSettings,
                                      loanDefaults: loanDefaults,
                                      onDeleteClients: (clientsToDelete) async {
                                        for (final client in clientsToDelete) {
                                          await widget.notificationRepository
                                              .deleteForUser(client.id);
                                          await widget.loanRepository
                                              .deleteLoansForUser(client.id);
                                          await widget.authRepository.deleteUser(
                                            client.id,
                                          );
                                        }
                                      },
                                      onCreateClient: ({
                                        required String name,
                                        required String phone,
                                      }) => widget.authRepository.createUser(
                                        name: name,
                                        phone: phone,
                                        role: UserRole.client,
                                      ),
                                      onIssueLoan: ({
                                        required String userId,
                                        required String title,
                                        required double principal,
                                        required double interestPercent,
                                        required double totalAmount,
                                        required double dailyPenaltyAmount,
                                        required DateTime issuedAt,
                                        required List<PaymentScheduleItem>
                                            schedule,
                                        required int paymentIntervalCount,
                                        required String paymentIntervalUnit,
                                        String? note,
                                      }) async {
                                        await widget.loanRepository.createLoan(
                                          userId: userId,
                                          title: title,
                                          principal: principal,
                                          interestPercent: interestPercent,
                                          totalAmount: totalAmount,
                                          dailyPenaltyAmount:
                                              dailyPenaltyAmount,
                                          issuedAt: issuedAt,
                                          schedule: schedule,
                                          paymentIntervalCount:
                                              paymentIntervalCount,
                                          paymentIntervalUnit:
                                              paymentIntervalUnit,
                                          note: note,
                                        );
                                      },
                                      onUpdateLoan:
                                          widget.loanRepository.updateLoan,
                                      onSavePaymentSettings: widget
                                          .appSettingsRepository
                                          .savePaymentSettings,
                                      ),
                                    ],
                                  ),
                                ),
                                      _NotificationEffects(
                                        user: widget.currentUser,
                                        loans: loans,
                                        notifications: notifications,
                                        clientNames: {
                                          for (final client in clients)
                                            client.id: client.name,
                                        },
                                        reminderTime: TimeOfDay(
                                          hour:
                                              paymentSettings.adminDueReminderHour,
                                          minute:
                                              paymentSettings.adminDueReminderMinute,
                                        ),
                                      ),
                              ],
                            ),
                          );
                        },
                      );
                    },
                  );
                },
              );
            },
          );
        },
      ),
    );
  }
}

class _NotificationsAction extends StatelessWidget {
  const _NotificationsAction({
    required this.user,
    required this.notifications,
    required this.notificationRepository,
  });

  final AppUser user;
  final List<AppNotification> notifications;
  final NotificationRepository notificationRepository;

  @override
  Widget build(BuildContext context) {
    final unreadCount = notifications.where((item) => !item.isRead).length;
    return IconButton(
      tooltip: 'Уведомления',
      onPressed: () => _showNotificationsSheet(
        context,
        user: user,
        notifications: notifications,
        notificationRepository: notificationRepository,
      ),
      icon: Stack(
        clipBehavior: Clip.none,
        children: [
          Icon(
            Icons.notifications_none_rounded,
            color: Theme.of(context).colorScheme.secondary,
          ),
          if (unreadCount > 0)
            Positioned(
              right: -4,
              top: -4,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: const Color(0xFFFF8A80),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  unreadCount > 99 ? '99+' : '$unreadCount',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _NotificationEffects extends StatefulWidget {
  const _NotificationEffects({
    required this.user,
    required this.loans,
    required this.notifications,
    this.clientNames = const <String, String>{},
    this.reminderTime,
  });

  final AppUser user;
  final List<Loan> loans;
  final List<AppNotification> notifications;
  final Map<String, String> clientNames;
  final TimeOfDay? reminderTime;

  @override
  State<_NotificationEffects> createState() => _NotificationEffectsState();
}

class _NotificationEffectsState extends State<_NotificationEffects> {
  final Set<String> _knownNotificationIds = <String>{};
  static bool _serviceNotificationPromptShown = false;
  bool _initialized = false;
  bool _backgroundStarted = false;
  String? _backgroundUserId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncEffects());
  }

  @override
  void didUpdateWidget(covariant _NotificationEffects oldWidget) {
    super.didUpdateWidget(oldWidget);
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncEffects());
  }

  Future<void> _syncEffects() async {
    if (!mounted) {
      return;
    }

    if (AppPlatform.isAndroid &&
        (!_backgroundStarted || _backgroundUserId != widget.user.id)) {
      await LocalNotificationService.startBackgroundNotifications(widget.user.id);
      _backgroundStarted = true;
      _backgroundUserId = widget.user.id;
    }
    await _maybeSuggestDisablingServiceNotification();
    if (widget.reminderTime != null) {
      await LocalNotificationService.setReminderTime(
        forAdmin: widget.user.isAdmin,
        time: widget.reminderTime!,
      );
    }

    final currentIds = widget.notifications.map((item) => item.id).toSet();
    if (!_initialized) {
      _knownNotificationIds
        ..clear()
        ..addAll(currentIds);
      _initialized = true;
    } else {
      final newNotifications = widget.notifications
          .where(
            (item) =>
                !_knownNotificationIds.contains(item.id) &&
                item.type != AppNotificationType.paymentReminder,
          )
          .toList()
        ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
      if (!AppPlatform.isAndroid) {
        for (final notification in newNotifications) {
          final shouldDisplay =
              await LocalNotificationService.shouldDisplayNotification(
                userId: widget.user.id,
                notificationId: notification.id,
              );
          if (!shouldDisplay) {
            continue;
          }
          await LocalNotificationService.showUpdate(
            title: notification.title,
            body: notification.body,
            payload: notification.id,
          );
        }
      }
      _knownNotificationIds.addAll(currentIds);
      _knownNotificationIds.removeWhere((id) => !currentIds.contains(id));
    }

    if (AppPlatform.isAndroid) {
      return;
    }

    if (widget.user.role == UserRole.client) {
      await LocalNotificationService.syncLoanRemindersForUser(
        widget.user,
        widget.loans,
      );
      return;
    }

    await LocalNotificationService.syncAdminDueReminders(
      user: widget.user,
      loans: widget.loans,
      clientNames: widget.clientNames,
    );
  }

  Future<void> _maybeSuggestDisablingServiceNotification() async {
    if (_serviceNotificationPromptShown || !mounted) {
      return;
    }
    final enabled =
        await LocalNotificationService.isServiceNotificationEnabled();
    if (!mounted || !enabled) {
      return;
    }
    _serviceNotificationPromptShown = true;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Сервисное уведомление'),
        content: const Text(
          'Чтобы не видеть постоянное уведомление синхронизации, откройте настройки уведомлений приложения и отключите этот канал',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Позже'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.of(dialogContext).pop();
              await LocalNotificationService.openServiceNotificationSettings();
            },
            child: const Text('Открыть настройки'),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return const SizedBox.shrink();
  }
}

Future<void> _showNotificationsSheet(
  BuildContext context, {
  required AppUser user,
  required List<AppNotification> notifications,
  required NotificationRepository notificationRepository,
}) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: Theme.of(context).cardColor,
    builder: (sheetContext) {
      return StreamBuilder<List<AppNotification>>(
        stream: notificationRepository.watchForUser(user.id),
        initialData: notifications,
        builder: (context, snapshot) {
          final liveNotifications = snapshot.data ?? notifications;
          final unreadCount = liveNotifications
              .where((item) => !item.isRead)
              .length;

          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Уведомления',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                      ),
                      if (liveNotifications.isNotEmpty)
                        IconButton(
                          tooltip: 'Очистить уведомления',
                          onPressed: () async {
                            final shouldClear = await showDialog<bool>(
                              context: sheetContext,
                              builder: (dialogContext) => AlertDialog(
                                title: const Text('Очистить уведомления'),
                                content: const Text(
                                  'Все уведомления будут удалены без возможности восстановления',
                                ),
                                actions: [
                                  TextButton(
                                    onPressed: () =>
                                        Navigator.of(dialogContext).pop(false),
                                    child: const Text('Отмена'),
                                  ),
                                  FilledButton(
                                    onPressed: () =>
                                        Navigator.of(dialogContext).pop(true),
                                    child: const Text('Удалить'),
                                  ),
                                ],
                              ),
                            );
                            if (shouldClear != true) {
                              return;
                            }
                            await notificationRepository.deleteForUser(user.id);
                            if (sheetContext.mounted) {
                              Navigator.of(sheetContext).pop();
                            }
                          },
                          icon: const Icon(
                            Icons.delete_outline_rounded,
                            color: Color(0xFFFF8A80),
                          ),
                        ),
                      if (unreadCount > 0)
                        TextButton.icon(
                          onPressed: () async {
                            await notificationRepository.markAllAsRead(user.id);
                          },
                          icon: const Icon(Icons.done_all_rounded),
                          label: const Text('Прочитать все'),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (liveNotifications.isEmpty)
                    const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: Text('Пока уведомлений нет'),
                    )
                  else
                    Flexible(
                      child: ListView.separated(
                        shrinkWrap: true,
                        itemCount: liveNotifications.length,
                        separatorBuilder: (context, index) =>
                            const SizedBox(height: 10),
                        itemBuilder: (context, index) {
                          final item = liveNotifications[index];
                          return Material(
                            color: Theme.of(context)
                                .colorScheme
                                .surfaceContainerHighest
                                .withValues(alpha: item.isRead ? 0.22 : 0.38),
                            borderRadius: BorderRadius.circular(22),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(22),
                              onTap: item.isRead
                                  ? null
                                  : () async {
                                      await notificationRepository.markAsRead(
                                        item.id,
                                      );
                                    },
                              child: Padding(
                                padding: const EdgeInsets.all(16),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Container(
                                      width: 10,
                                      height: 10,
                                      margin: const EdgeInsets.only(top: 6),
                                      decoration: BoxDecoration(
                                        color: item.isRead
                                            ? Colors.transparent
                                            : Theme.of(context)
                                                .colorScheme
                                                .secondary,
                                        shape: BoxShape.circle,
                                        border: Border.all(
                                          color: Theme.of(context)
                                              .colorScheme
                                              .secondary
                                              .withValues(alpha: 0.45),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            item.title,
                                            style: Theme.of(context)
                                                .textTheme
                                                .titleMedium,
                                          ),
                                          const SizedBox(height: 4),
                                          Text(item.body),
                                          const SizedBox(height: 8),
                                          Text(
                                            Formatters.dateTime(item.createdAt),
                                            style: Theme.of(context)
                                                .textTheme
                                                .bodySmall,
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      );
    },
  );
}

Future<void> _showSettingsSheet(
  BuildContext context,
  AppUser user, {
  bool hideClosedLoans = false,
  Future<void> Function({required bool hideClosedLoans})? onAdminSettingsChanged,
  LoanDefaultsSettings loanDefaults = const LoanDefaultsSettings.empty(),
  Future<void> Function(LoanDefaultsSettings settings)? onSaveLoanDefaults,
  PaymentSettings paymentSettings = const PaymentSettings.empty(),
  Future<void> Function(PaymentSettings settings)? onSavePaymentSettings,
  Future<void> Function({required int hour, required int minute})?
  onSaveUserReminderTime,
  AppClockSettings clockSettings = const AppClockSettings.disabled(),
  Future<void> Function(AppClockSettings settings)? onSaveClockSettings,
  BackupService? backupService,
  Future<void> Function()? onClearDatabase,
}) async {
  final settingsSheet = _SettingsSheet(
    user: user,
    hideClosedLoans: hideClosedLoans,
    onAdminSettingsChanged: onAdminSettingsChanged,
    loanDefaults: loanDefaults,
    onSaveLoanDefaults: onSaveLoanDefaults,
    paymentSettings: paymentSettings,
    onSavePaymentSettings: onSavePaymentSettings,
    onSaveUserReminderTime: onSaveUserReminderTime,
    clockSettings: clockSettings,
    onSaveClockSettings: onSaveClockSettings,
    backupService: backupService,
    onClearDatabase: onClearDatabase,
  );

  if (AppPlatform.isIOS) {
    await Navigator.of(context).push(
      CupertinoPageRoute<void>(
        builder: (routeContext) => _SettingsPage(sheet: settingsSheet),
      ),
    );
    return;
  }

  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: Theme.of(context).cardColor,
    builder: (context) => settingsSheet,
  );
}

class _SettingsPage extends StatelessWidget {
  const _SettingsPage({required this.sheet});

  final Widget sheet;

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      navigationBar: const CupertinoNavigationBar(
        middle: Text('Настройки'),
      ),
      child: Material(
        color: Theme.of(context).scaffoldBackgroundColor,
        child: sheet,
      ),
    );
  }
}

Future<void> _confirmLogout(BuildContext context) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Выйти из профиля'),
      content: const Text('Подтвердите выход из текущего профиля на этом устройстве.'),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('Выйти'),
        ),
      ],
    ),
  );

  if (confirmed == true && context.mounted) {
    await context.read<LoginController>().logout();
  }
}

class _SettingsSheet extends StatefulWidget {
  const _SettingsSheet({
    required this.user,
    required this.hideClosedLoans,
    required this.loanDefaults,
    required this.paymentSettings,
    required this.clockSettings,
    this.onAdminSettingsChanged,
    this.onSaveLoanDefaults,
    this.onSavePaymentSettings,
    this.onSaveUserReminderTime,
    this.onSaveClockSettings,
    this.backupService,
    this.onClearDatabase,
  });

  final AppUser user;
  final bool hideClosedLoans;
  final Future<void> Function({required bool hideClosedLoans})?
  onAdminSettingsChanged;
  final LoanDefaultsSettings loanDefaults;
  final PaymentSettings paymentSettings;
  final AppClockSettings clockSettings;
  final Future<void> Function(LoanDefaultsSettings settings)?
  onSaveLoanDefaults;
  final Future<void> Function(PaymentSettings settings)? onSavePaymentSettings;
  final Future<void> Function({required int hour, required int minute})?
  onSaveUserReminderTime;
  final Future<void> Function(AppClockSettings settings)? onSaveClockSettings;
  final BackupService? backupService;
  final Future<void> Function()? onClearDatabase;

  @override
  State<_SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<_SettingsSheet> {
  late final TextEditingController _principalController;
  late final TextEditingController _percentController;
  late final TextEditingController _penaltyController;
  late final TextEditingController _countController;
  late final TextEditingController _intervalCountController;
  late bool _hideClosedLoans;
  late _SettingsIntervalUnit _intervalUnit;
  late bool _debugTimeEnabled;
  late TimeOfDay _adminReminderTime;
  late TimeOfDay _clientReminderTime;
  late String? _telegramChatId;
  late String? _telegramUsername;
  late String? _telegramLinkCode;
  late DateTime? _telegramLinkedAt;
  late bool _telegramNotificationsEnabled;
  StreamSubscription<AppUser?>? _userSubscription;
  DateTime? _debugNow;
  bool _backupInProgress = false;

  bool get _isAdmin => widget.user.isAdmin;
  AppUser get _telegramUserState => widget.user.copyWith(
        telegramChatId: _telegramChatId,
        telegramUsername: _telegramUsername,
        telegramLinkCode: _telegramLinkCode,
        telegramLinkedAt: _telegramLinkedAt,
        telegramNotificationsEnabled: _telegramNotificationsEnabled,
      );

  @override
  void initState() {
    super.initState();
    _principalController = TextEditingController(
      text: Formatters.decimalInput(widget.loanDefaults.principal),
    );
    _percentController = TextEditingController(
      text: Formatters.decimalInputPrecise(widget.loanDefaults.interestPercent),
    );
    _penaltyController = TextEditingController(
      text: Formatters.decimalInput(widget.loanDefaults.dailyPenaltyAmount),
    );
    _countController = TextEditingController(
      text: widget.loanDefaults.paymentCount.toString(),
    );
    _intervalCountController = TextEditingController(
      text: widget.loanDefaults.paymentIntervalCount.toString(),
    );
    _hideClosedLoans = widget.hideClosedLoans;
    _intervalUnit = _SettingsIntervalUnit.fromStorage(
      widget.loanDefaults.paymentIntervalUnit,
    );
    _adminReminderTime = TimeOfDay(
      hour: widget.paymentSettings.adminDueReminderHour,
      minute: widget.paymentSettings.adminDueReminderMinute,
    );
    _clientReminderTime = TimeOfDay(
      hour: widget.user.reminderHour,
      minute: widget.user.reminderMinute,
    );
    _telegramChatId = widget.user.telegramChatId;
    _telegramUsername = widget.user.telegramUsername;
    _telegramLinkCode = widget.user.telegramLinkCode;
    _telegramLinkedAt = widget.user.telegramLinkedAt;
    _telegramNotificationsEnabled = widget.user.telegramNotificationsEnabled;
    _debugTimeEnabled = widget.clockSettings.debugEnabled;
    _debugNow = widget.clockSettings.debugNow == null
        ? null
        : AppClock.toMoscow(widget.clockSettings.debugNow!);
    _userSubscription = context.read<AuthRepository>().watchUserById(widget.user.id).listen((
      user,
    ) {
      if (!mounted || user == null) {
        return;
      }
      setState(() {
        _telegramChatId = user.telegramChatId;
        _telegramUsername = user.telegramUsername;
        _telegramLinkCode = user.telegramLinkCode;
        _telegramLinkedAt = user.telegramLinkedAt;
        _telegramNotificationsEnabled = user.telegramNotificationsEnabled;
        _clientReminderTime = TimeOfDay(
          hour: user.reminderHour,
          minute: user.reminderMinute,
        );
      });
    });
  }

  @override
  void dispose() {
    _userSubscription?.cancel();
    _principalController.dispose();
    _percentController.dispose();
    _penaltyController.dispose();
    _countController.dispose();
    _intervalCountController.dispose();
    super.dispose();
  }

  Future<void> _saveClockSettings({
    required bool enabled,
    DateTime? debugNow,
  }) async {
    await widget.onSaveClockSettings?.call(
      enabled && debugNow != null
          ? AppClockSettings(
              debugEnabled: true,
              debugNow: AppClock.fromMoscowWallClock(debugNow),
              updatedAt: AppClock.nowForStorage(),
            )
          : const AppClockSettings.disabled(),
    );
    await LocalNotificationService.clearReminderCache();
    await LocalNotificationService.startBackgroundNotifications(widget.user.id);
  }

  Future<void> _pickDebugDateTime() async {
    final base = _debugNow ?? AppClock.now();
    final date = await showDatePicker(
      context: context,
      initialDate: base,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
      locale: const Locale('ru', 'RU'),
    );
    if (date == null || !mounted) {
      return;
    }
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(base),
    );
    if (time == null || !mounted) {
      return;
    }
    setState(() {
      _debugNow = DateTime(
        date.year,
        date.month,
        date.day,
        time.hour,
        time.minute,
      );
      _debugTimeEnabled = true;
    });
    await _saveClockSettings(enabled: true, debugNow: _debugNow);
  }

  Future<void> _exportBackup() async {
    if (widget.backupService == null || _backupInProgress) {
      return;
    }

    setState(() {
      _backupInProgress = true;
    });

    try {
      final json = await widget.backupService!.exportBackupJson();
      final now = AppClock.now();
      final suggestedName =
          'microzaimich-backup-${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}_${now.hour.toString().padLeft(2, '0')}-${now.minute.toString().padLeft(2, '0')}.json';
      if (AppPlatform.isWindows || AppPlatform.isLinux || AppPlatform.isMacOS) {
        final targetPath = await FilePicker.platform.saveFile(
          dialogTitle: 'Сохранить резервную копию',
          fileName: suggestedName,
          type: FileType.custom,
          allowedExtensions: const ['json'],
        );
        if (targetPath == null) {
          return;
        }
        final backupFile = File(targetPath);
        await backupFile.writeAsString(json, flush: true);
      } else if (AppPlatform.isWeb) {
        final backupBytes = Uint8List.fromList(utf8.encode(json));
        await Share.shareXFiles(
          [
            XFile.fromData(
              backupBytes,
              mimeType: 'application/json',
              name: suggestedName,
            ),
          ],
          subject: 'Резервная копия Microzaimich',
          text: 'Резервная копия базы данных приложения',
          fileNameOverrides: [suggestedName],
        );
      } else {
        final tempDir = await getTemporaryDirectory();
        final backupFile = File('${tempDir.path}/$suggestedName');
        await backupFile.writeAsString(json, flush: true);
        await Share.shareXFiles(
        [XFile(backupFile.path, mimeType: 'application/json')],
        subject: 'Резервная копия Microzaimich',
        text: 'Резервная копия базы данных приложения',
      fileNameOverrides: [suggestedName],
      );
      }

      if (!mounted) {
        return;
      }
      showAppSnackBar('Файл резервной копии подготовлен для сохранения');
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      showAppSnackBar('Не удалось сохранить резервную копию: $error');
    } finally {
      if (mounted) {
        setState(() {
          _backupInProgress = false;
        });
      }
    }
  }

  Future<void> _importBackup() async {
    if (widget.backupService == null || _backupInProgress) {
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Восстановить базу из файла'),
        content: const Text(
          'Текущая база будет полностью очищена и заменена данными из резервной копии. Пользователи, займы, уведомления и настройки будут перезаписаны без возможности отмены.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Восстановить'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) {
      return;
    }

    setState(() {
      _backupInProgress = true;
    });

    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['json'],
        withData: true,
      );
      if (result == null || result.files.isEmpty) {
        return;
      }

      final pickedFile = result.files.single;
      final bytes = pickedFile.bytes;
      String? json;
      if (bytes != null) {
        json = utf8.decode(bytes);
      } else if (!AppPlatform.isWeb) {
        final path = pickedFile.path;
        if (path != null) {
          json = await XFile(path).readAsString();
        }
      }
      if (json == null) {
        throw const BackupException('Не удалось прочитать выбранный файл');
      }
      await widget.backupService!.importBackupJson(json);

      if (!mounted) {
        return;
      }
      showAppSnackBar('База данных восстановлена из файла');
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      showAppSnackBar('Не удалось восстановить резервную копию: $error');
    } finally {
      if (mounted) {
        setState(() {
          _backupInProgress = false;
        });
      }
    }
  }

  Future<void> _pickReminderTime({required bool forAdmin}) async {
    final currentTime = forAdmin ? _adminReminderTime : _clientReminderTime;
    final picked = await showTimePicker(
      context: context,
      initialTime: currentTime,
    );
    if (picked == null || !mounted) {
      return;
    }

    if (forAdmin) {
      await widget.onSavePaymentSettings?.call(
        widget.paymentSettings.copyWith(
          adminDueReminderHour: picked.hour,
          adminDueReminderMinute: picked.minute,
          updatedAt: AppClock.nowForStorage(),
        ),
      );
    } else {
      await widget.onSaveUserReminderTime?.call(
        hour: picked.hour,
        minute: picked.minute,
      );
    }
    await LocalNotificationService.setReminderTime(forAdmin: forAdmin, time: picked);
    await LocalNotificationService.clearReminderCache();
    await LocalNotificationService.startBackgroundNotifications(widget.user.id);

    if (!mounted) {
      return;
    }
    setState(() {
      if (forAdmin) {
        _adminReminderTime = picked;
      } else {
        _clientReminderTime = picked;
      }
    });
    showAppSnackBar(
      forAdmin
          ? 'Время уведомлений о платежах клиентов: ${picked.format(context)}'
          : 'Время ваших напоминаний о платежах: ${picked.format(context)}',
    );
  }

  Future<void> _changePassword() async {
    final passwordController = TextEditingController();
    final confirmController = TextEditingController();
    String? validationError;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            title: const Text('Сменить пароль'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: passwordController,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Новый пароль',
                    prefixIcon: Icon(Icons.lock_outline_rounded),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: confirmController,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Повторите пароль',
                    prefixIcon: Icon(Icons.verified_user_outlined),
                  ),
                ),
                if (validationError != null) ...[
                  const SizedBox(height: 10),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      validationError!,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: const Color(0xFFFF8A80),
                      ),
                    ),
                  ),
                ],
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('Отмена'),
              ),
              FilledButton(
                onPressed: () {
                  final password = passwordController.text.trim();
                  final confirm = confirmController.text.trim();
                  if (password.length < 4) {
                    setDialogState(() {
                      validationError = 'Пароль должен быть не короче 4 символов';
                    });
                    return;
                  }
                  if (password != confirm) {
                    setDialogState(() {
                      validationError = 'Пароли не совпадают';
                    });
                    return;
                  }
                  Navigator.of(dialogContext).pop(true);
                },
                child: const Text('Сохранить'),
              ),
            ],
          ),
        );
      },
    );

    if (confirmed != true || !mounted) {
      passwordController.dispose();
      confirmController.dispose();
      return;
    }

    try {
      await context.read<LoginController>().changePassword(
        passwordController.text.trim(),
      );
      showAppSnackBar('Пароль обновлён');
    } on Object catch (error) {
      showAppSnackBar('Не удалось сменить пароль: $error');
    } finally {
      passwordController.dispose();
      confirmController.dispose();
    }
  }

  Future<void> _refreshTelegramLinkCode() async {
    try {
      final updated = await context.read<AuthRepository>().refreshTelegramLinkCode(
        user: _telegramUserState,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _telegramLinkCode = updated.telegramLinkCode;
      });
      showAppSnackBar('Код привязки Telegram обновлён');
    } on Object catch (error) {
      showAppSnackBar('Не удалось обновить код Telegram: $error');
    }
  }

  Future<void> _refreshTelegramLinkCodeAndSync() async {
    final previousCode = _telegramLinkCode;
    await _refreshTelegramLinkCode();
    if (!mounted) {
      return;
    }
    if ((_telegramLinkCode ?? '').isEmpty || _telegramLinkCode == previousCode) {
      return;
    }
    await _copyTelegramCommand();
    if (!mounted) {
      return;
    }
  }

  Future<void> _copyTelegramCommand() async {
    final code = _telegramLinkCode;
    if (code == null || code.isEmpty) {
      showAppSnackBar('Сначала создайте код привязки Telegram');
      return;
    }
    await Clipboard.setData(ClipboardData(text: '/start $code'));
    showAppSnackBar('Команда /start скопирована');
  }


  Future<void> _toggleTelegramNotifications(bool enabled) async {
    if ((_telegramChatId ?? '').isEmpty) {
      showAppSnackBar('Сначала привяжите Telegram к профилю');
      return;
    }
    try {
      final updated = await context
          .read<AuthRepository>()
          .updateTelegramNotifications(
            user: _telegramUserState,
            enabled: enabled,
          );
      if (!mounted) {
        return;
      }
      setState(() {
        _telegramNotificationsEnabled = updated.telegramNotificationsEnabled;
      });
      showAppSnackBar(
        enabled
            ? 'Уведомления в Telegram включены'
            : 'Уведомления в Telegram отключены',
      );
    } on Object catch (error) {
      showAppSnackBar('Не удалось обновить Telegram-настройки: $error');
    }
  }

  Future<void> _disconnectTelegram() async {
    if ((_telegramChatId ?? '').isEmpty) {
      return;
    }
    try {
      final updated = await context.read<AuthRepository>().disconnectTelegram(
        user: _telegramUserState,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _telegramChatId = updated.telegramChatId;
        _telegramUsername = updated.telegramUsername;
        _telegramLinkedAt = updated.telegramLinkedAt;
        _telegramNotificationsEnabled = updated.telegramNotificationsEnabled;
      });
      showAppSnackBar('Telegram отвязан от профиля');
    } on Object catch (error) {
      showAppSnackBar('Не удалось отвязать Telegram: $error');
    }
  }

  Future<void> _clearDatabase() async {
    if (widget.onClearDatabase == null || _backupInProgress) {
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Очистить всю базу'),
        content: const Text(
          'Будут удалены все клиенты, займы, уведомления и настройки. '
          'Сохранится только текущий профиль администратора. Действие необратимо.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFE85B5B),
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Очистить'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) {
      return;
    }

    setState(() {
      _backupInProgress = true;
    });

    try {
      await widget.onClearDatabase!.call();
      if (!mounted) {
        return;
      }
      showAppSnackBar(
        'База очищена. Сохранён только текущий профиль администратора.',
      );
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      showAppSnackBar('Не удалось очистить базу: $error');
    } finally {
      if (mounted) {
        setState(() {
          _backupInProgress = false;
        });
      }
    }
  }

  Future<void> _sendTestUpdateNotification() async {
    await LocalNotificationService.showUpdate(
      title: 'Тестовое уведомление',
      body: 'Проверка обычного мгновенного уведомления администратору.',
    );
    if (!mounted) {
      return;
    }
    showAppSnackBar('Тестовое уведомление отправлено');
  }

  Future<void> _sendTestAdminReminderNotification() async {
    await LocalNotificationService.showUpdate(
      title: 'У клиента сегодня день платежа',
      body: 'Тест: у клиента сегодня срок платежа 1 000,00 ₽.',
    );
    if (!mounted) {
      return;
    }
    showAppSnackBar('Тестовое напоминание админу отправлено');
  }

  List<Widget> _buildCommonSettingsSections(BuildContext context) {
    final reminderTitle = _isAdmin
        ? 'Время уведомлений о платежах клиентов'
        : 'Время моих напоминаний о платежах';
    final reminderSubtitle = _isAdmin
        ? 'Когда на этом устройстве напоминать администратору о клиентах, у которых сегодня день платежа'
        : 'Когда на этом устройстве показывать напоминания за день и в день вашего платежа';
    final reminderTime = _isAdmin ? _adminReminderTime : _clientReminderTime;

    return [
      _SettingsSectionCard(
        title: 'Уведомления',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              reminderSubtitle,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () => _pickReminderTime(forAdmin: _isAdmin),
                icon: const Icon(Icons.notifications_active_outlined),
                label: Text('$reminderTitle: ${reminderTime.format(context)}'),
              ),
            ),
            if (_isAdmin) ...[
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _sendTestUpdateNotification,
                  icon: const Icon(Icons.campaign_outlined),
                  label: const Text('Тест обычного уведомления'),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _sendTestAdminReminderNotification,
                  icon: const Icon(Icons.notifications_active_outlined),
                  label: const Text('Тест напоминания админу'),
                ),
              ),
            ],
          ],
        ),
      ),
      const SizedBox(height: 16),
      _SettingsSectionCard(
        title: 'Безопасность',
        child: SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: _changePassword,
            icon: const Icon(Icons.lock_reset_outlined),
            label: const Text('Сменить пароль'),
          ),
        ),
      ),
    ];
  }

  List<Widget> _buildCommonSettingsSectionsWithTelegram(BuildContext context) {
    final sections = List<Widget>.of(_buildCommonSettingsSections(context));
    if (sections.isNotEmpty) {
      sections.insertAll(sections.length - 2, [
        const SizedBox(height: 16),
        _SettingsSectionCard(
          title: 'Telegram',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                (_telegramChatId ?? '').isNotEmpty
                    ? 'Telegram уже привязан к этому профилю.'
                    : 'Создайте код и отправьте боту команду /start с этим кодом.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 12),
              if ((_telegramLinkCode ?? '').isNotEmpty)
                SelectableText(
                  'Код: $_telegramLinkCode',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              if ((_telegramChatId ?? '').isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  _telegramUsername?.isNotEmpty == true
                      ? 'Подключён аккаунт: @$_telegramUsername'
                      : 'Подключён Telegram-чат: $_telegramChatId',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                if (_telegramLinkedAt != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    'Привязано: ${Formatters.dateTime(_telegramLinkedAt!)}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ],
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _refreshTelegramLinkCodeAndSync,
                  icon: const Icon(Icons.password_rounded),
                  label: Text(
                    (_telegramLinkCode ?? '').isEmpty
                        ? 'Создать код привязки'
                        : 'Обновить код привязки',
                  ),
                ),
              ),

              const SizedBox(height: 12),
              Text(
                'После создания или обновления кода команда /start копируется автоматически. Статус Telegram обновляется сам по live-данным профиля.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              if ((_telegramChatId ?? '').isNotEmpty) ...[
                const SizedBox(height: 12),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  secondary: const Icon(Icons.send_rounded),
                  title: const Text('Уведомления в Telegram'),
                  subtitle: const Text(
                    'Отправлять новые уведомления в подключённый Telegram-чат',
                  ),
                  value: _telegramNotificationsEnabled,
                  onChanged: _toggleTelegramNotifications,
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: _disconnectTelegram,
                    icon: const Icon(Icons.link_off_rounded),
                    label: const Text('Отвязать Telegram'),
                  ),
                ),
              ],
            ],
          ),
        ),
      ]);
    }
    return sections;
  }

  List<Widget> _buildAdminSettingsSections(BuildContext context) {
    return [
      _SettingsSectionCard(
        title: 'Отображение',
        child: SwitchListTile(
          contentPadding: EdgeInsets.zero,
          secondary: const Icon(Icons.visibility_off_outlined),
          title: const Text('Скрыть выплаченные займы'),
          subtitle: const Text(
            'В списке клиентов показывать только займы в процессе',
          ),
          value: _hideClosedLoans,
          onChanged: (value) async {
            setState(() {
              _hideClosedLoans = value;
            });
            await widget.onAdminSettingsChanged?.call(
              hideClosedLoans: _hideClosedLoans,
            );
          },
        ),
      ),
      const SizedBox(height: 16),
      _SettingsSectionCard(
        title: 'Новый займ',
        child: Column(
          children: [
            TextField(
              controller: _principalController,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                labelText: 'Сумма займа',
                prefixIcon: Icon(Icons.currency_ruble_outlined),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _percentController,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                labelText: 'Процент',
                prefixIcon: Icon(Icons.percent_outlined),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _penaltyController,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                labelText: 'Пеня за день',
                prefixIcon: Icon(Icons.warning_amber_rounded),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _countController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Количество платежей',
                prefixIcon: Icon(Icons.timeline_outlined),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _intervalCountController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Каждые',
                      prefixIcon: Icon(Icons.swap_horiz_rounded),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: DropdownButtonFormField<_SettingsIntervalUnit>(
                    initialValue: _intervalUnit,
                    items: _SettingsIntervalUnit.values
                        .map(
                          (unit) => DropdownMenuItem(
                            value: unit,
                            child: Text(unit.label),
                          ),
                        )
                        .toList(),
                    onChanged: (value) {
                      if (value == null) {
                        return;
                      }
                      setState(() {
                        _intervalUnit = value;
                      });
                    },
                    decoration: const InputDecoration(
                      labelText: 'Интервал',
                      prefixIcon: Icon(Icons.event_repeat_outlined),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () async {
                  final paymentCount =
                      int.tryParse(_countController.text.trim()) ?? 0;
                  final intervalCount =
                      int.tryParse(_intervalCountController.text.trim()) ?? 0;
                  await widget.onSaveLoanDefaults?.call(
                    LoanDefaultsSettings(
                      principal: Formatters.cents(
                        Formatters.parseDecimal(_principalController.text),
                      ),
                      interestPercent: Formatters.cents(
                        Formatters.parseDecimal(_percentController.text),
                      ),
                      dailyPenaltyAmount: Formatters.cents(
                        Formatters.parseDecimal(_penaltyController.text),
                      ),
                      paymentCount: paymentCount <= 0 ? 1 : paymentCount,
                      paymentIntervalCount:
                          intervalCount <= 0 ? 1 : intervalCount,
                      paymentIntervalUnit: _intervalUnit.storageValue,
                      updatedAt: AppClock.nowForStorage(),
                    ),
                  );
                  if (!mounted) {
                    return;
                  }
                  showAppSnackBar('Значения по умолчанию сохранены');
                },
                icon: const Icon(Icons.save_outlined),
                label: const Text('Сохранить значения по умолчанию'),
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 16),
      _SettingsSectionCard(
        title: 'Время',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Сейчас используется: ${Formatters.dateTime(AppClock.now())}',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 12),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              secondary: const Icon(Icons.schedule_outlined),
              title: const Text('Тестовое время'),
              subtitle: const Text(
                'Нужно только для отладки начисления процентов, пени и просрочки',
              ),
              value: _debugTimeEnabled,
              onChanged: (value) async {
                setState(() {
                  _debugTimeEnabled = value;
                  if (!value) {
                    _debugNow = null;
                  } else {
                    _debugNow ??= AppClock.now();
                  }
                });
                await _saveClockSettings(
                  enabled: value,
                  debugNow: value ? _debugNow : null,
                );
              },
            ),
            if (_debugTimeEnabled) ...[
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _pickDebugDateTime,
                  icon: const Icon(Icons.edit_calendar_outlined),
                  label: Text(
                    _debugNow == null
                        ? 'Выбрать тестовые дату и время'
                        : 'Тестовое время: ${Formatters.dateTime(_debugNow!)}',
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
      const SizedBox(height: 16),
      _SettingsSectionCard(
        title: 'Резервка',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Можно полностью выгрузить базу в файл и затем восстановить её обратно',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _backupInProgress ? null : _exportBackup,
                icon: const Icon(Icons.download_rounded),
                label: const Text('Скачать резервную копию'),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _backupInProgress ? null : _importBackup,
                icon: const Icon(Icons.upload_file_rounded),
                label: Text(
                  _backupInProgress
                      ? 'Идёт операция...'
                      : 'Загрузить и восстановить',
                ),
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 16),
      _SettingsSectionCard(
        title: 'Опасные действия',
        accent: const Color(0xFFFF8A80),
        child: SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: _backupInProgress ? null : _clearDatabase,
            style: OutlinedButton.styleFrom(
              foregroundColor: const Color(0xFFFF8A80),
            ),
            icon: const Icon(Icons.delete_sweep_outlined),
            label: const Text('Очистить всю базу, кроме профиля админа'),
          ),
        ),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: 8,
          bottom: MediaQuery.of(context).viewInsets.bottom + 24,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _isAdmin ? 'Настройки администратора' : 'Настройки клиента',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 10),
              Text(
                _isAdmin
                    ? widget.user.name
                    : 'Пользователь: ${widget.user.name}',
              ),
              const SizedBox(height: 16),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.phone_outlined),
                title: const Text('Телефон'),
                subtitle: Text(Formatters.phone(widget.user.phone)),
              ),
              ..._buildCommonSettingsSectionsWithTelegram(context),
              if (_isAdmin) ...[
                const SizedBox(height: 16),
                ..._buildAdminSettingsSections(context),
              ],
              if (AppClock.now().year < 0) ...[
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  secondary: const Icon(Icons.visibility_off_outlined),
                  title: const Text('Скрыть выплаченные займы'),
                  subtitle: const Text(
                    'В списке клиентов показывать только займы в процессе',
                  ),
                  value: _hideClosedLoans,
                  onChanged: (value) async {
                    setState(() {
                      _hideClosedLoans = value;
                    });
                    await widget.onAdminSettingsChanged?.call(
                      hideClosedLoans: _hideClosedLoans,
                    );
                  },
                ),
                if (widget.user.id.isEmpty)
                  SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  secondary: const Icon(Icons.person_off_outlined),
                  title: const Text('Скрыть клиентов без задолженности'),
                  subtitle: const Text(
                    'Спрятать клиентов, у которых все займы выплачены',
                  ),
                  value: false,
                  onChanged: null,
                ),
                const SizedBox(height: 12),
                Text(
                  'Значения по умолчанию для нового займа',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _principalController,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'Сумма займа',
                    prefixIcon: Icon(Icons.currency_ruble_outlined),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _percentController,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'Процент',
                    prefixIcon: Icon(Icons.percent_outlined),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _penaltyController,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'Пеня за день',
                    prefixIcon: Icon(Icons.warning_amber_rounded),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _countController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Количество платежей',
                    prefixIcon: Icon(Icons.timeline_outlined),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _intervalCountController,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'Каждые',
                          prefixIcon: Icon(Icons.swap_horiz_rounded),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: DropdownButtonFormField<_SettingsIntervalUnit>(
                        initialValue: _intervalUnit,
                        items: _SettingsIntervalUnit.values
                            .map(
                              (unit) => DropdownMenuItem(
                                value: unit,
                                child: Text(unit.label),
                              ),
                            )
                            .toList(),
                        onChanged: (value) {
                          if (value == null) {
                            return;
                          }
                          setState(() {
                            _intervalUnit = value;
                          });
                        },
                        decoration: const InputDecoration(
                          labelText: 'Интервал',
                          prefixIcon: Icon(Icons.event_repeat_outlined),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                ElevatedButton.icon(
                  onPressed: () async {
                    final paymentCount =
                        int.tryParse(_countController.text.trim()) ?? 0;
                    final intervalCount =
                        int.tryParse(_intervalCountController.text.trim()) ?? 0;
                    await widget.onSaveLoanDefaults?.call(
                      LoanDefaultsSettings(
                        principal: Formatters.cents(
                          Formatters.parseDecimal(_principalController.text),
                        ),
                        interestPercent: Formatters.cents(
                          Formatters.parseDecimal(_percentController.text),
                        ),
                        dailyPenaltyAmount: Formatters.cents(
                          Formatters.parseDecimal(_penaltyController.text),
                        ),
                        paymentCount: paymentCount <= 0 ? 1 : paymentCount,
                        paymentIntervalCount:
                            intervalCount <= 0 ? 1 : intervalCount,
                        paymentIntervalUnit: _intervalUnit.storageValue,
                        updatedAt: AppClock.nowForStorage(),
                      ),
                    );
                    if (!mounted) {
                      return;
                    }
                    showAppSnackBar('Значения по умолчанию сохранены');
                  },
                  icon: const Icon(Icons.save_outlined),
                  label: const Text('Сохранить значения по умолчанию'),
                ),
                const SizedBox(height: 24),
                Text(
                  'Время расчётов',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                Text(
                  'Сейчас используется: ${Formatters.dateTime(AppClock.now())}',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 12),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  secondary: const Icon(Icons.schedule_outlined),
                  title: const Text('Тестовое время'),
                  subtitle: const Text(
                    'Нужно только для отладки начисления процентов, пени и просрочки',
                  ),
                  value: _debugTimeEnabled,
                  onChanged: (value) async {
                    setState(() {
                      _debugTimeEnabled = value;
                      if (!value) {
                        _debugNow = null;
                      } else {
                        _debugNow ??= AppClock.now();
                      }
                    });
                    await _saveClockSettings(
                      enabled: value,
                      debugNow: value ? _debugNow : null,
                    );
                  },
                ),
                if (_debugTimeEnabled) ...[
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: _pickDebugDateTime,
                    icon: const Icon(Icons.edit_calendar_outlined),
                    label: Text(
                      _debugNow == null
                          ? 'Выбрать тестовые дату и время'
                          : 'Тестовое время: ${Formatters.dateTime(_debugNow!)}',
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                const SizedBox(height: 12),
                Text(
                  'Резервная копия',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                Text(
                  'Можно полностью выгрузить базу в файл и затем восстановить её обратно',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: _backupInProgress ? null : _exportBackup,
                  icon: const Icon(Icons.download_rounded),
                  label: const Text('Скачать резервную копию'),
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: _backupInProgress ? null : _importBackup,
                  icon: const Icon(Icons.upload_file_rounded),
                  label: Text(
                    _backupInProgress
                        ? 'Идёт операция...'
                        : 'Загрузить и восстановить',
                  ),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: _backupInProgress ? null : _clearDatabase,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFFFF8A80),
                  ),
                  icon: const Icon(Icons.delete_sweep_outlined),
                  label: const Text('Очистить всю базу, кроме профиля админа'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _SettingsSectionCard extends StatelessWidget {
  const _SettingsSectionCard({
    required this.title,
    required this.child,
    this.accent,
  });

  final String title;
  final Widget child;
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    final accentColor = accent ?? Theme.of(context).colorScheme.secondary;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: accentColor,
              ),
            ),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}

enum _SettingsIntervalUnit {
  days('Дней', 'days'),
  weeks('Недель', 'weeks'),
  months('Месяцев', 'months');

  const _SettingsIntervalUnit(this.label, this.storageValue);

  final String label;
  final String storageValue;

  static _SettingsIntervalUnit fromStorage(String value) {
    return switch (value) {
      'days' => _SettingsIntervalUnit.days,
      'weeks' => _SettingsIntervalUnit.weeks,
      _ => _SettingsIntervalUnit.months,
    };
  }
}
