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
import 'package:url_launcher/url_launcher.dart';

import '../../../core/utils/formatters.dart';
import '../../../core/utils/app_snackbar.dart';
import '../../../core/utils/platform_utils.dart';
import '../../../core/utils/web_install_prompt.dart';
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

const _telegramBotUsername = 'microzaimich_bot';

Future<void> _showWebInstallHelpDialog(BuildContext context) async {
  final message = WebInstallPrompt.isIos
      ? 'На iPhone и iPad откройте меню браузера и выберите «На экран Домой». В Safari используйте кнопку «Поделиться», в Chrome и Edge — меню браузера.'
      : 'Откройте меню браузера и выберите «Установить приложение» или «Добавить на рабочий стол».';
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Установка на рабочий стол'),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('Понятно'),
        ),
      ],
    ),
  );
}

MaterialBanner _buildWebInstallBanner({
  required BuildContext context,
  required VoidCallback onDismiss,
  required VoidCallback onInstall,
}) {
  return MaterialBanner(
    content: const Text(
      'Для более удобного доступа добавьте Микрозаймич на рабочий стол.',
    ),
    leading: const Icon(Icons.install_desktop_rounded),
    actions: [
      TextButton(
        onPressed: onDismiss,
        child: const Text('Скрыть'),
      ),
      FilledButton(
        onPressed: onInstall,
        child: Text(WebInstallPrompt.isIos ? 'Как установить' : 'Установить'),
      ),
    ],
  );
}

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
  bool _showWebInstallBanner = false;
  bool _webInstallBannerLoaded = false;

  String get _telegramWebBannerKey =>
      'client_web_tg_banner_dismissed_${widget.currentUser.id}';
  String get _webInstallBannerKey =>
      'web_install_banner_dismissed_${widget.currentUser.id}';

  @override
  void initState() {
    super.initState();
    _loansStream = widget.loanRepository.watchLoansForUser(widget.currentUser.id);
    _paymentSettingsStream = widget.appSettingsRepository.watchPaymentSettings();
    _notificationsStream = widget.notificationRepository.watchForUser(
      widget.currentUser.id,
    );
    _loadWebInstallBannerState();
    _loadTelegramWebBannerState();
  }

  @override
  void didUpdateWidget(covariant _ClientHome oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentUser.id != widget.currentUser.id ||
        oldWidget.currentUser.telegramChatId != widget.currentUser.telegramChatId ||
        oldWidget.currentUser.telegramNotificationsEnabled !=
            widget.currentUser.telegramNotificationsEnabled) {
      _loadWebInstallBannerState();
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

  Future<void> _loadWebInstallBannerState() async {
    if (!AppPlatform.isWeb) {
      if (!mounted) {
        return;
      }
      setState(() {
        _webInstallBannerLoaded = true;
        _showWebInstallBanner = false;
      });
      return;
    }

    await WebInstallPrompt.initialize();
    final prefs = await SharedPreferences.getInstance();
    final dismissed = prefs.getBool(_webInstallBannerKey) ?? false;
    if (!mounted) {
      return;
    }
    setState(() {
      _webInstallBannerLoaded = true;
      _showWebInstallBanner = !dismissed && !WebInstallPrompt.isStandalone;
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

  Future<void> _dismissWebInstallBanner() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_webInstallBannerKey, true);
    if (!mounted) {
      return;
    }
    setState(() {
      _showWebInstallBanner = false;
    });
  }

  Future<void> _handleWebInstallBannerAction() async {
    final installed = await WebInstallPrompt.promptInstall();
    if (installed) {
      await _dismissWebInstallBanner();
      return;
    }
    if (!mounted) {
      return;
    }
    await _showWebInstallHelpDialog(context);
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
                    title: const Text('РњРѕРё Р·Р°Р№РјС‹'),
                    actions: [
                      _NotificationsAction(
                        user: widget.currentUser,
                        notifications: notifications,
                        notificationRepository: widget.notificationRepository,
                      ),
                      IconButton(
                        tooltip: 'РќР°СЃС‚СЂРѕР№РєРё',
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
                        tooltip: 'Р’С‹Р№С‚Рё',
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
                          if (_webInstallBannerLoaded && _showWebInstallBanner)
                            _buildWebInstallBanner(
                              context: context,
                              onDismiss: _dismissWebInstallBanner,
                              onInstall: _handleWebInstallBannerAction,
                            ),
                          if (_telegramWebBannerLoaded && _showTelegramWebBanner)
                            MaterialBanner(
                              content: const Text(
                                'Р’ РІРµР±-РІРµСЂСЃРёРё РЅР°СЃС‚РѕСЏС‚РµР»СЊРЅРѕ СЂРµРєРѕРјРµРЅРґСѓРµС‚СЃСЏ РІРєР»СЋС‡РёС‚СЊ СѓРІРµРґРѕРјР»РµРЅРёСЏ С‡РµСЂРµР· Telegram-Р±РѕС‚Р° РІ РЅР°СЃС‚СЂРѕР№РєР°С… РїСЂРѕС„РёР»СЏ.',
                              ),
                              leading: const Icon(Icons.telegram_rounded),
                              actions: [
                                TextButton(
                                  onPressed: _dismissTelegramWebBanner,
                                  child: const Text('РџРѕРЅСЏС‚РЅРѕ'),
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
  bool _showWebInstallBanner = false;
  bool _webInstallBannerLoaded = false;

  String get _hideClosedLoansKey =>
      'admin_hide_closed_loans_${widget.currentUser.id}';
  String get _webInstallBannerKey =>
      'web_install_banner_dismissed_${widget.currentUser.id}';

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
    _loadWebInstallBannerState();
    _loadAdminSettings();
  }

  @override
  void didUpdateWidget(covariant _AdminHome oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentUser.id != widget.currentUser.id) {
      _loadWebInstallBannerState();
    }
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

  Future<void> _loadWebInstallBannerState() async {
    if (!AppPlatform.isWeb) {
      if (!mounted) {
        return;
      }
      setState(() {
        _webInstallBannerLoaded = true;
        _showWebInstallBanner = false;
      });
      return;
    }

    await WebInstallPrompt.initialize();
    final prefs = await SharedPreferences.getInstance();
    final dismissed = prefs.getBool(_webInstallBannerKey) ?? false;
    if (!mounted) {
      return;
    }
    setState(() {
      _webInstallBannerLoaded = true;
      _showWebInstallBanner = !dismissed && !WebInstallPrompt.isStandalone;
    });
  }

  Future<void> _dismissWebInstallBanner() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_webInstallBannerKey, true);
    if (!mounted) {
      return;
    }
    setState(() {
      _showWebInstallBanner = false;
    });
  }

  Future<void> _handleWebInstallBannerAction() async {
    final installed = await WebInstallPrompt.promptInstall();
    if (installed) {
      await _dismissWebInstallBanner();
      return;
    }
    if (!mounted) {
      return;
    }
    await _showWebInstallHelpDialog(context);
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
                              title: const Text('РђРґРјРёРЅ РџР°РЅРµР»СЊ'),
                              actions: [
                                _NotificationsAction(
                                  user: widget.currentUser,
                                  notifications: notifications,
                                  notificationRepository:
                                      widget.notificationRepository,
                                ),
                                IconButton(
                                  tooltip: 'РќР°СЃС‚СЂРѕР№РєРё',
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
                                  tooltip: 'Р’С‹Р№С‚Рё',
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
                                    text: 'РљР»РёРµРЅС‚С‹',
                                  ),
                                  Tab(
                                    icon: Icon(
                                      Icons.dashboard_customize_outlined,
                                    ),
                                    text: 'РЈРїСЂР°РІР»РµРЅРёРµ',
                                  ),
                                ],
                              ),
                            ),
                            body: Stack(
                              children: [
                                Column(
                                  children: [
                                    if (_webInstallBannerLoaded &&
                                        _showWebInstallBanner)
                                      _buildWebInstallBanner(
                                        context: context,
                                        onDismiss: _dismissWebInstallBanner,
                                        onInstall: _handleWebInstallBannerAction,
                                      ),
                                    Expanded(
                                      child: AdNavigationShortcuts(
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
                                    ),
                                  ],
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
      tooltip: 'РЈРІРµРґРѕРјР»РµРЅРёСЏ',
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
        title: const Text('РЎРµСЂРІРёСЃРЅРѕРµ СѓРІРµРґРѕРјР»РµРЅРёРµ'),
        content: const Text(
          'Р§С‚РѕР±С‹ РЅРµ РІРёРґРµС‚СЊ РїРѕСЃС‚РѕСЏРЅРЅРѕРµ СѓРІРµРґРѕРјР»РµРЅРёРµ СЃРёРЅС…СЂРѕРЅРёР·Р°С†РёРё, РѕС‚РєСЂРѕР№С‚Рµ РЅР°СЃС‚СЂРѕР№РєРё СѓРІРµРґРѕРјР»РµРЅРёР№ РїСЂРёР»РѕР¶РµРЅРёСЏ Рё РѕС‚РєР»СЋС‡РёС‚Рµ СЌС‚РѕС‚ РєР°РЅР°Р»',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('РџРѕР·Р¶Рµ'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.of(dialogContext).pop();
              await LocalNotificationService.openServiceNotificationSettings();
            },
            child: const Text('РћС‚РєСЂС‹С‚СЊ РЅР°СЃС‚СЂРѕР№РєРё'),
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
                          'РЈРІРµРґРѕРјР»РµРЅРёСЏ',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                      ),
                      if (liveNotifications.isNotEmpty)
                        IconButton(
                          tooltip: 'РћС‡РёСЃС‚РёС‚СЊ СѓРІРµРґРѕРјР»РµРЅРёСЏ',
                          onPressed: () async {
                            final shouldClear = await showDialog<bool>(
                              context: sheetContext,
                              builder: (dialogContext) => AlertDialog(
                                title: const Text('РћС‡РёСЃС‚РёС‚СЊ СѓРІРµРґРѕРјР»РµРЅРёСЏ'),
                                content: const Text(
                                  'Р’СЃРµ СѓРІРµРґРѕРјР»РµРЅРёСЏ Р±СѓРґСѓС‚ СѓРґР°Р»РµРЅС‹ Р±РµР· РІРѕР·РјРѕР¶РЅРѕСЃС‚Рё РІРѕСЃСЃС‚Р°РЅРѕРІР»РµРЅРёСЏ',
                                ),
                                actions: [
                                  TextButton(
                                    onPressed: () =>
                                        Navigator.of(dialogContext).pop(false),
                                    child: const Text('РћС‚РјРµРЅР°'),
                                  ),
                                  FilledButton(
                                    onPressed: () =>
                                        Navigator.of(dialogContext).pop(true),
                                    child: const Text('РЈРґР°Р»РёС‚СЊ'),
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
                          label: const Text('РџСЂРѕС‡РёС‚Р°С‚СЊ РІСЃРµ'),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (liveNotifications.isEmpty)
                    const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: Text('РџРѕРєР° СѓРІРµРґРѕРјР»РµРЅРёР№ РЅРµС‚'),
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
        middle: Text('РќР°СЃС‚СЂРѕР№РєРё'),
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
      title: const Text('Р’С‹Р№С‚Рё РёР· РїСЂРѕС„РёР»СЏ'),
      content: const Text('РџРѕРґС‚РІРµСЂРґРёС‚Рµ РІС‹С…РѕРґ РёР· С‚РµРєСѓС‰РµРіРѕ РїСЂРѕС„РёР»СЏ РЅР° СЌС‚РѕРј СѓСЃС‚СЂРѕР№СЃС‚РІРµ.'),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('РћС‚РјРµРЅР°'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('Р’С‹Р№С‚Рё'),
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
          dialogTitle: 'РЎРѕС…СЂР°РЅРёС‚СЊ СЂРµР·РµСЂРІРЅСѓСЋ РєРѕРїРёСЋ',
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
          subject: 'Р РµР·РµСЂРІРЅР°СЏ РєРѕРїРёСЏ Microzaimich',
          text: 'Р РµР·РµСЂРІРЅР°СЏ РєРѕРїРёСЏ Р±Р°Р·С‹ РґР°РЅРЅС‹С… РїСЂРёР»РѕР¶РµРЅРёСЏ',
          fileNameOverrides: [suggestedName],
        );
      } else {
        final tempDir = await getTemporaryDirectory();
        final backupFile = File('${tempDir.path}/$suggestedName');
        await backupFile.writeAsString(json, flush: true);
        await Share.shareXFiles(
        [XFile(backupFile.path, mimeType: 'application/json')],
        subject: 'Р РµР·РµСЂРІРЅР°СЏ РєРѕРїРёСЏ Microzaimich',
        text: 'Р РµР·РµСЂРІРЅР°СЏ РєРѕРїРёСЏ Р±Р°Р·С‹ РґР°РЅРЅС‹С… РїСЂРёР»РѕР¶РµРЅРёСЏ',
      fileNameOverrides: [suggestedName],
      );
      }

      if (!mounted) {
        return;
      }
      showAppSnackBar('Р¤Р°Р№Р» СЂРµР·РµСЂРІРЅРѕР№ РєРѕРїРёРё РїРѕРґРіРѕС‚РѕРІР»РµРЅ РґР»СЏ СЃРѕС…СЂР°РЅРµРЅРёСЏ');
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      showAppSnackBar('РќРµ СѓРґР°Р»РѕСЃСЊ СЃРѕС…СЂР°РЅРёС‚СЊ СЂРµР·РµСЂРІРЅСѓСЋ РєРѕРїРёСЋ: $error');
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
        title: const Text('Р’РѕСЃСЃС‚Р°РЅРѕРІРёС‚СЊ Р±Р°Р·Сѓ РёР· С„Р°Р№Р»Р°'),
        content: const Text(
          'РўРµРєСѓС‰Р°СЏ Р±Р°Р·Р° Р±СѓРґРµС‚ РїРѕР»РЅРѕСЃС‚СЊСЋ РѕС‡РёС‰РµРЅР° Рё Р·Р°РјРµРЅРµРЅР° РґР°РЅРЅС‹РјРё РёР· СЂРµР·РµСЂРІРЅРѕР№ РєРѕРїРёРё. РџРѕР»СЊР·РѕРІР°С‚РµР»Рё, Р·Р°Р№РјС‹, СѓРІРµРґРѕРјР»РµРЅРёСЏ Рё РЅР°СЃС‚СЂРѕР№РєРё Р±СѓРґСѓС‚ РїРµСЂРµР·Р°РїРёСЃР°РЅС‹ Р±РµР· РІРѕР·РјРѕР¶РЅРѕСЃС‚Рё РѕС‚РјРµРЅС‹.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('РћС‚РјРµРЅР°'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Р’РѕСЃСЃС‚Р°РЅРѕРІРёС‚СЊ'),
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
        throw const BackupException('РќРµ СѓРґР°Р»РѕСЃСЊ РїСЂРѕС‡РёС‚Р°С‚СЊ РІС‹Р±СЂР°РЅРЅС‹Р№ С„Р°Р№Р»');
      }
      await widget.backupService!.importBackupJson(json);

      if (!mounted) {
        return;
      }
      showAppSnackBar('Р‘Р°Р·Р° РґР°РЅРЅС‹С… РІРѕСЃСЃС‚Р°РЅРѕРІР»РµРЅР° РёР· С„Р°Р№Р»Р°');
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      showAppSnackBar('РќРµ СѓРґР°Р»РѕСЃСЊ РІРѕСЃСЃС‚Р°РЅРѕРІРёС‚СЊ СЂРµР·РµСЂРІРЅСѓСЋ РєРѕРїРёСЋ: $error');
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
          ? 'Р’СЂРµРјСЏ СѓРІРµРґРѕРјР»РµРЅРёР№ Рѕ РїР»Р°С‚РµР¶Р°С… РєР»РёРµРЅС‚РѕРІ: ${picked.format(context)}'
          : 'Р’СЂРµРјСЏ РІР°С€РёС… РЅР°РїРѕРјРёРЅР°РЅРёР№ Рѕ РїР»Р°С‚РµР¶Р°С…: ${picked.format(context)}',
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
            title: const Text('РЎРјРµРЅРёС‚СЊ РїР°СЂРѕР»СЊ'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: passwordController,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'РќРѕРІС‹Р№ РїР°СЂРѕР»СЊ',
                    prefixIcon: Icon(Icons.lock_outline_rounded),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: confirmController,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'РџРѕРІС‚РѕСЂРёС‚Рµ РїР°СЂРѕР»СЊ',
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
                child: const Text('РћС‚РјРµРЅР°'),
              ),
              FilledButton(
                onPressed: () {
                  final password = passwordController.text.trim();
                  final confirm = confirmController.text.trim();
                  if (password.length < 4) {
                    setDialogState(() {
                      validationError = 'РџР°СЂРѕР»СЊ РґРѕР»Р¶РµРЅ Р±С‹С‚СЊ РЅРµ РєРѕСЂРѕС‡Рµ 4 СЃРёРјРІРѕР»РѕРІ';
                    });
                    return;
                  }
                  if (password != confirm) {
                    setDialogState(() {
                      validationError = 'РџР°СЂРѕР»Рё РЅРµ СЃРѕРІРїР°РґР°СЋС‚';
                    });
                    return;
                  }
                  Navigator.of(dialogContext).pop(true);
                },
                child: const Text('РЎРѕС…СЂР°РЅРёС‚СЊ'),
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
      showAppSnackBar('РџР°СЂРѕР»СЊ РѕР±РЅРѕРІР»С‘РЅ');
    } on Object catch (error) {
      showAppSnackBar('РќРµ СѓРґР°Р»РѕСЃСЊ СЃРјРµРЅРёС‚СЊ РїР°СЂРѕР»СЊ: $error');
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
      showAppSnackBar('РљРѕРґ РїСЂРёРІСЏР·РєРё Telegram РѕР±РЅРѕРІР»С‘РЅ');
    } on Object catch (error) {
      showAppSnackBar('РќРµ СѓРґР°Р»РѕСЃСЊ РѕР±РЅРѕРІРёС‚СЊ РєРѕРґ Telegram: $error');
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
    await _openTelegramBotWithCode();
    if (!mounted) {
      return;
    }
  }

  Future<void> _openTelegramBotWithCode() async {
    final code = _telegramLinkCode;
    if (code == null || code.isEmpty) {
      showAppSnackBar('РЎРЅР°С‡Р°Р»Р° СЃРѕР·РґР°Р№С‚Рµ РєРѕРґ РїСЂРёРІСЏР·РєРё Telegram');
      return;
    }

    final botUri = Uri.parse('https://t.me/$_telegramBotUsername?start=$code');
    final opened = await launchUrl(
      botUri,
      mode: AppPlatform.isWeb
          ? LaunchMode.platformDefault
          : LaunchMode.externalApplication,
    );

    if (opened) {
      showAppSnackBar('РћС‚РєСЂС‹С‚ Telegram-Р±РѕС‚ СЃ РєРѕРґРѕРј РїСЂРёРІСЏР·РєРё');
      return;
    }

    await _copyTelegramCommand();
    if (!mounted) {
      return;
    }
    showAppSnackBar('РќРµ СѓРґР°Р»РѕСЃСЊ РѕС‚РєСЂС‹С‚СЊ Telegram-Р±РѕС‚Р°, РєРѕРјР°РЅРґР° /start СЃРєРѕРїРёСЂРѕРІР°РЅР°');
  }

  Future<void> _copyTelegramCommand() async {
    final code = _telegramLinkCode;
    if (code == null || code.isEmpty) {
      showAppSnackBar('РЎРЅР°С‡Р°Р»Р° СЃРѕР·РґР°Р№С‚Рµ РєРѕРґ РїСЂРёРІСЏР·РєРё Telegram');
      return;
    }
    await Clipboard.setData(ClipboardData(text: '/start $code'));
    showAppSnackBar('РљРѕРјР°РЅРґР° /start СЃРєРѕРїРёСЂРѕРІР°РЅР°');
  }


  Future<void> _toggleTelegramNotifications(bool enabled) async {
    if ((_telegramChatId ?? '').isEmpty) {
      showAppSnackBar('РЎРЅР°С‡Р°Р»Р° РїСЂРёРІСЏР¶РёС‚Рµ Telegram Рє РїСЂРѕС„РёР»СЋ');
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
            ? 'РЈРІРµРґРѕРјР»РµРЅРёСЏ РІ Telegram РІРєР»СЋС‡РµРЅС‹'
            : 'РЈРІРµРґРѕРјР»РµРЅРёСЏ РІ Telegram РѕС‚РєР»СЋС‡РµРЅС‹',
      );
    } on Object catch (error) {
      showAppSnackBar('РќРµ СѓРґР°Р»РѕСЃСЊ РѕР±РЅРѕРІРёС‚СЊ Telegram-РЅР°СЃС‚СЂРѕР№РєРё: $error');
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
      showAppSnackBar('Telegram РѕС‚РІСЏР·Р°РЅ РѕС‚ РїСЂРѕС„РёР»СЏ');
    } on Object catch (error) {
      showAppSnackBar('РќРµ СѓРґР°Р»РѕСЃСЊ РѕС‚РІСЏР·Р°С‚СЊ Telegram: $error');
    }
  }

  Future<void> _clearDatabase() async {
    if (widget.onClearDatabase == null || _backupInProgress) {
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('РћС‡РёСЃС‚РёС‚СЊ РІСЃСЋ Р±Р°Р·Сѓ'),
        content: const Text(
          'Р‘СѓРґСѓС‚ СѓРґР°Р»РµРЅС‹ РІСЃРµ РєР»РёРµРЅС‚С‹, Р·Р°Р№РјС‹, СѓРІРµРґРѕРјР»РµРЅРёСЏ Рё РЅР°СЃС‚СЂРѕР№РєРё. '
          'РЎРѕС…СЂР°РЅРёС‚СЃСЏ С‚РѕР»СЊРєРѕ С‚РµРєСѓС‰РёР№ РїСЂРѕС„РёР»СЊ Р°РґРјРёРЅРёСЃС‚СЂР°С‚РѕСЂР°. Р”РµР№СЃС‚РІРёРµ РЅРµРѕР±СЂР°С‚РёРјРѕ.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('РћС‚РјРµРЅР°'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFE85B5B),
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('РћС‡РёСЃС‚РёС‚СЊ'),
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
        'Р‘Р°Р·Р° РѕС‡РёС‰РµРЅР°. РЎРѕС…СЂР°РЅС‘РЅ С‚РѕР»СЊРєРѕ С‚РµРєСѓС‰РёР№ РїСЂРѕС„РёР»СЊ Р°РґРјРёРЅРёСЃС‚СЂР°С‚РѕСЂР°.',
      );
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      showAppSnackBar('РќРµ СѓРґР°Р»РѕСЃСЊ РѕС‡РёСЃС‚РёС‚СЊ Р±Р°Р·Сѓ: $error');
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
      title: 'РўРµСЃС‚РѕРІРѕРµ СѓРІРµРґРѕРјР»РµРЅРёРµ',
      body: 'РџСЂРѕРІРµСЂРєР° РѕР±С‹С‡РЅРѕРіРѕ РјРіРЅРѕРІРµРЅРЅРѕРіРѕ СѓРІРµРґРѕРјР»РµРЅРёСЏ Р°РґРјРёРЅРёСЃС‚СЂР°С‚РѕСЂСѓ.',
    );
    if (!mounted) {
      return;
    }
    showAppSnackBar('РўРµСЃС‚РѕРІРѕРµ СѓРІРµРґРѕРјР»РµРЅРёРµ РѕС‚РїСЂР°РІР»РµРЅРѕ');
  }

  Future<void> _sendTestAdminReminderNotification() async {
    await LocalNotificationService.showUpdate(
      title: 'РЈ РєР»РёРµРЅС‚Р° СЃРµРіРѕРґРЅСЏ РґРµРЅСЊ РїР»Р°С‚РµР¶Р°',
      body: 'РўРµСЃС‚: Сѓ РєР»РёРµРЅС‚Р° СЃРµРіРѕРґРЅСЏ СЃСЂРѕРє РїР»Р°С‚РµР¶Р° 1 000,00 в‚Ѕ.',
    );
    if (!mounted) {
      return;
    }
    showAppSnackBar('РўРµСЃС‚РѕРІРѕРµ РЅР°РїРѕРјРёРЅР°РЅРёРµ Р°РґРјРёРЅСѓ РѕС‚РїСЂР°РІР»РµРЅРѕ');
  }

  List<Widget> _buildCommonSettingsSections(BuildContext context) {
    final reminderTitle = _isAdmin
        ? 'Р’СЂРµРјСЏ СѓРІРµРґРѕРјР»РµРЅРёР№ Рѕ РїР»Р°С‚РµР¶Р°С… РєР»РёРµРЅС‚РѕРІ'
        : 'Р’СЂРµРјСЏ РјРѕРёС… РЅР°РїРѕРјРёРЅР°РЅРёР№ Рѕ РїР»Р°С‚РµР¶Р°С…';
    final reminderSubtitle = _isAdmin
        ? 'РљРѕРіРґР° РЅР° СЌС‚РѕРј СѓСЃС‚СЂРѕР№СЃС‚РІРµ РЅР°РїРѕРјРёРЅР°С‚СЊ Р°РґРјРёРЅРёСЃС‚СЂР°С‚РѕСЂСѓ Рѕ РєР»РёРµРЅС‚Р°С…, Сѓ РєРѕС‚РѕСЂС‹С… СЃРµРіРѕРґРЅСЏ РґРµРЅСЊ РїР»Р°С‚РµР¶Р°'
        : 'РљРѕРіРґР° РЅР° СЌС‚РѕРј СѓСЃС‚СЂРѕР№СЃС‚РІРµ РїРѕРєР°Р·С‹РІР°С‚СЊ РЅР°РїРѕРјРёРЅР°РЅРёСЏ Р·Р° РґРµРЅСЊ Рё РІ РґРµРЅСЊ РІР°С€РµРіРѕ РїР»Р°С‚РµР¶Р°';
    final reminderTime = _isAdmin ? _adminReminderTime : _clientReminderTime;

    return [
      _SettingsSectionCard(
        title: 'РЈРІРµРґРѕРјР»РµРЅРёСЏ',
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
                  label: const Text('РўРµСЃС‚ РѕР±С‹С‡РЅРѕРіРѕ СѓРІРµРґРѕРјР»РµРЅРёСЏ'),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _sendTestAdminReminderNotification,
                  icon: const Icon(Icons.notifications_active_outlined),
                  label: const Text('РўРµСЃС‚ РЅР°РїРѕРјРёРЅР°РЅРёСЏ Р°РґРјРёРЅСѓ'),
                ),
              ),
            ],
          ],
        ),
      ),
      const SizedBox(height: 16),
      _SettingsSectionCard(
        title: 'Р‘РµР·РѕРїР°СЃРЅРѕСЃС‚СЊ',
        child: SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: _changePassword,
            icon: const Icon(Icons.lock_reset_outlined),
            label: const Text('РЎРјРµРЅРёС‚СЊ РїР°СЂРѕР»СЊ'),
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
                    ? 'Telegram СѓР¶Рµ РїСЂРёРІСЏР·Р°РЅ Рє СЌС‚РѕРјСѓ РїСЂРѕС„РёР»СЋ.'
                    : 'РЎРѕР·РґР°Р№С‚Рµ РєРѕРґ Рё РѕС‚РїСЂР°РІСЊС‚Рµ Р±РѕС‚Сѓ @microzaimich_bot РєРѕРјР°РЅРґСѓ /start СЃ СЌС‚РёРј РєРѕРґРѕРј.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 12),
              if ((_telegramLinkCode ?? '').isNotEmpty)
                SelectableText(
                  'РљРѕРґ: $_telegramLinkCode',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              if ((_telegramChatId ?? '').isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  _telegramUsername?.isNotEmpty == true
                      ? 'РџРѕРґРєР»СЋС‡С‘РЅ Р°РєРєР°СѓРЅС‚: @$_telegramUsername'
                      : 'РџРѕРґРєР»СЋС‡С‘РЅ Telegram-С‡Р°С‚: $_telegramChatId',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                if (_telegramLinkedAt != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    'РџСЂРёРІСЏР·Р°РЅРѕ: ${Formatters.dateTime(_telegramLinkedAt!)}',
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
                        ? 'РЎРѕР·РґР°С‚СЊ РєРѕРґ РїСЂРёРІСЏР·РєРё'
                        : 'РћР±РЅРѕРІРёС‚СЊ РєРѕРґ РїСЂРёРІСЏР·РєРё',
                  ),
                ),
              ),

              const SizedBox(height: 12),
              Text(
                'РџРѕСЃР»Рµ СЃРѕР·РґР°РЅРёСЏ РёР»Рё РѕР±РЅРѕРІР»РµРЅРёСЏ РєРѕРґР° РєРѕРјР°РЅРґР° /start РєРѕРїРёСЂСѓРµС‚СЃСЏ Р°РІС‚РѕРјР°С‚РёС‡РµСЃРєРё. РЎС‚Р°С‚СѓСЃ Telegram РѕР±РЅРѕРІР»СЏРµС‚СЃСЏ СЃР°Рј РїРѕ live-РґР°РЅРЅС‹Рј РїСЂРѕС„РёР»СЏ.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              if ((_telegramChatId ?? '').isNotEmpty) ...[
                const SizedBox(height: 12),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  secondary: const Icon(Icons.send_rounded),
                  title: const Text('РЈРІРµРґРѕРјР»РµРЅРёСЏ РІ Telegram'),
                  subtitle: const Text(
                    'РћС‚РїСЂР°РІР»СЏС‚СЊ РЅРѕРІС‹Рµ СѓРІРµРґРѕРјР»РµРЅРёСЏ РІ РїРѕРґРєР»СЋС‡С‘РЅРЅС‹Р№ Telegram-С‡Р°С‚',
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
                    label: const Text('РћС‚РІСЏР·Р°С‚СЊ Telegram'),
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
        title: 'РћС‚РѕР±СЂР°Р¶РµРЅРёРµ',
        child: SwitchListTile(
          contentPadding: EdgeInsets.zero,
          secondary: const Icon(Icons.visibility_off_outlined),
          title: const Text('РЎРєСЂС‹С‚СЊ РІС‹РїР»Р°С‡РµРЅРЅС‹Рµ Р·Р°Р№РјС‹'),
          subtitle: const Text(
            'Р’ СЃРїРёСЃРєРµ РєР»РёРµРЅС‚РѕРІ РїРѕРєР°Р·С‹РІР°С‚СЊ С‚РѕР»СЊРєРѕ Р·Р°Р№РјС‹ РІ РїСЂРѕС†РµСЃСЃРµ',
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
        title: 'РќРѕРІС‹Р№ Р·Р°Р№Рј',
        child: Column(
          children: [
            TextField(
              controller: _principalController,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                labelText: 'РЎСѓРјРјР° Р·Р°Р№РјР°',
                prefixIcon: Icon(Icons.currency_ruble_outlined),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _percentController,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                labelText: 'РџСЂРѕС†РµРЅС‚',
                prefixIcon: Icon(Icons.percent_outlined),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _penaltyController,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                labelText: 'РџРµРЅСЏ Р·Р° РґРµРЅСЊ',
                prefixIcon: Icon(Icons.warning_amber_rounded),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _countController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'РљРѕР»РёС‡РµСЃС‚РІРѕ РїР»Р°С‚РµР¶РµР№',
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
                      labelText: 'РљР°Р¶РґС‹Рµ',
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
                      labelText: 'РРЅС‚РµСЂРІР°Р»',
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
                  showAppSnackBar('Р—РЅР°С‡РµРЅРёСЏ РїРѕ СѓРјРѕР»С‡Р°РЅРёСЋ СЃРѕС…СЂР°РЅРµРЅС‹');
                },
                icon: const Icon(Icons.save_outlined),
                label: const Text('РЎРѕС…СЂР°РЅРёС‚СЊ Р·РЅР°С‡РµРЅРёСЏ РїРѕ СѓРјРѕР»С‡Р°РЅРёСЋ'),
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 16),
      _SettingsSectionCard(
        title: 'Р’СЂРµРјСЏ',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'РЎРµР№С‡Р°СЃ РёСЃРїРѕР»СЊР·СѓРµС‚СЃСЏ: ${Formatters.dateTime(AppClock.now())}',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 12),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              secondary: const Icon(Icons.schedule_outlined),
              title: const Text('РўРµСЃС‚РѕРІРѕРµ РІСЂРµРјСЏ'),
              subtitle: const Text(
                'РќСѓР¶РЅРѕ С‚РѕР»СЊРєРѕ РґР»СЏ РѕС‚Р»Р°РґРєРё РЅР°С‡РёСЃР»РµРЅРёСЏ РїСЂРѕС†РµРЅС‚РѕРІ, РїРµРЅРё Рё РїСЂРѕСЃСЂРѕС‡РєРё',
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
                        ? 'Р’С‹Р±СЂР°С‚СЊ С‚РµСЃС‚РѕРІС‹Рµ РґР°С‚Сѓ Рё РІСЂРµРјСЏ'
                        : 'РўРµСЃС‚РѕРІРѕРµ РІСЂРµРјСЏ: ${Formatters.dateTime(_debugNow!)}',
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
      const SizedBox(height: 16),
      _SettingsSectionCard(
        title: 'Р РµР·РµСЂРІРєР°',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'РњРѕР¶РЅРѕ РїРѕР»РЅРѕСЃС‚СЊСЋ РІС‹РіСЂСѓР·РёС‚СЊ Р±Р°Р·Сѓ РІ С„Р°Р№Р» Рё Р·Р°С‚РµРј РІРѕСЃСЃС‚Р°РЅРѕРІРёС‚СЊ РµС‘ РѕР±СЂР°С‚РЅРѕ',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _backupInProgress ? null : _exportBackup,
                icon: const Icon(Icons.download_rounded),
                label: const Text('РЎРєР°С‡Р°С‚СЊ СЂРµР·РµСЂРІРЅСѓСЋ РєРѕРїРёСЋ'),
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
                      ? 'РРґС‘С‚ РѕРїРµСЂР°С†РёСЏ...'
                      : 'Р—Р°РіСЂСѓР·РёС‚СЊ Рё РІРѕСЃСЃС‚Р°РЅРѕРІРёС‚СЊ',
                ),
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 16),
      _SettingsSectionCard(
        title: 'РћРїР°СЃРЅС‹Рµ РґРµР№СЃС‚РІРёСЏ',
        accent: const Color(0xFFFF8A80),
        child: SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: _backupInProgress ? null : _clearDatabase,
            style: OutlinedButton.styleFrom(
              foregroundColor: const Color(0xFFFF8A80),
            ),
            icon: const Icon(Icons.delete_sweep_outlined),
            label: const Text('РћС‡РёСЃС‚РёС‚СЊ РІСЃСЋ Р±Р°Р·Сѓ, РєСЂРѕРјРµ РїСЂРѕС„РёР»СЏ Р°РґРјРёРЅР°'),
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
                _isAdmin ? 'РќР°СЃС‚СЂРѕР№РєРё Р°РґРјРёРЅРёСЃС‚СЂР°С‚РѕСЂР°' : 'РќР°СЃС‚СЂРѕР№РєРё РєР»РёРµРЅС‚Р°',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 10),
              Text(
                _isAdmin
                    ? widget.user.name
                    : 'РџРѕР»СЊР·РѕРІР°С‚РµР»СЊ: ${widget.user.name}',
              ),
              const SizedBox(height: 16),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.phone_outlined),
                title: const Text('РўРµР»РµС„РѕРЅ'),
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
                  title: const Text('РЎРєСЂС‹С‚СЊ РІС‹РїР»Р°С‡РµРЅРЅС‹Рµ Р·Р°Р№РјС‹'),
                  subtitle: const Text(
                    'Р’ СЃРїРёСЃРєРµ РєР»РёРµРЅС‚РѕРІ РїРѕРєР°Р·С‹РІР°С‚СЊ С‚РѕР»СЊРєРѕ Р·Р°Р№РјС‹ РІ РїСЂРѕС†РµСЃСЃРµ',
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
                  title: const Text('РЎРєСЂС‹С‚СЊ РєР»РёРµРЅС‚РѕРІ Р±РµР· Р·Р°РґРѕР»Р¶РµРЅРЅРѕСЃС‚Рё'),
                  subtitle: const Text(
                    'РЎРїСЂСЏС‚Р°С‚СЊ РєР»РёРµРЅС‚РѕРІ, Сѓ РєРѕС‚РѕСЂС‹С… РІСЃРµ Р·Р°Р№РјС‹ РІС‹РїР»Р°С‡РµРЅС‹',
                  ),
                  value: false,
                  onChanged: null,
                ),
                const SizedBox(height: 12),
                Text(
                  'Р—РЅР°С‡РµРЅРёСЏ РїРѕ СѓРјРѕР»С‡Р°РЅРёСЋ РґР»СЏ РЅРѕРІРѕРіРѕ Р·Р°Р№РјР°',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _principalController,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'РЎСѓРјРјР° Р·Р°Р№РјР°',
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
                    labelText: 'РџСЂРѕС†РµРЅС‚',
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
                    labelText: 'РџРµРЅСЏ Р·Р° РґРµРЅСЊ',
                    prefixIcon: Icon(Icons.warning_amber_rounded),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _countController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'РљРѕР»РёС‡РµСЃС‚РІРѕ РїР»Р°С‚РµР¶РµР№',
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
                          labelText: 'РљР°Р¶РґС‹Рµ',
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
                          labelText: 'РРЅС‚РµСЂРІР°Р»',
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
                    showAppSnackBar('Р—РЅР°С‡РµРЅРёСЏ РїРѕ СѓРјРѕР»С‡Р°РЅРёСЋ СЃРѕС…СЂР°РЅРµРЅС‹');
                  },
                  icon: const Icon(Icons.save_outlined),
                  label: const Text('РЎРѕС…СЂР°РЅРёС‚СЊ Р·РЅР°С‡РµРЅРёСЏ РїРѕ СѓРјРѕР»С‡Р°РЅРёСЋ'),
                ),
                const SizedBox(height: 24),
                Text(
                  'Р’СЂРµРјСЏ СЂР°СЃС‡С‘С‚РѕРІ',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                Text(
                  'РЎРµР№С‡Р°СЃ РёСЃРїРѕР»СЊР·СѓРµС‚СЃСЏ: ${Formatters.dateTime(AppClock.now())}',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 12),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  secondary: const Icon(Icons.schedule_outlined),
                  title: const Text('РўРµСЃС‚РѕРІРѕРµ РІСЂРµРјСЏ'),
                  subtitle: const Text(
                    'РќСѓР¶РЅРѕ С‚РѕР»СЊРєРѕ РґР»СЏ РѕС‚Р»Р°РґРєРё РЅР°С‡РёСЃР»РµРЅРёСЏ РїСЂРѕС†РµРЅС‚РѕРІ, РїРµРЅРё Рё РїСЂРѕСЃСЂРѕС‡РєРё',
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
                          ? 'Р’С‹Р±СЂР°С‚СЊ С‚РµСЃС‚РѕРІС‹Рµ РґР°С‚Сѓ Рё РІСЂРµРјСЏ'
                          : 'РўРµСЃС‚РѕРІРѕРµ РІСЂРµРјСЏ: ${Formatters.dateTime(_debugNow!)}',
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                const SizedBox(height: 12),
                Text(
                  'Р РµР·РµСЂРІРЅР°СЏ РєРѕРїРёСЏ',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                Text(
                  'РњРѕР¶РЅРѕ РїРѕР»РЅРѕСЃС‚СЊСЋ РІС‹РіСЂСѓР·РёС‚СЊ Р±Р°Р·Сѓ РІ С„Р°Р№Р» Рё Р·Р°С‚РµРј РІРѕСЃСЃС‚Р°РЅРѕРІРёС‚СЊ РµС‘ РѕР±СЂР°С‚РЅРѕ',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: _backupInProgress ? null : _exportBackup,
                  icon: const Icon(Icons.download_rounded),
                  label: const Text('РЎРєР°С‡Р°С‚СЊ СЂРµР·РµСЂРІРЅСѓСЋ РєРѕРїРёСЋ'),
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: _backupInProgress ? null : _importBackup,
                  icon: const Icon(Icons.upload_file_rounded),
                  label: Text(
                    _backupInProgress
                        ? 'РРґС‘С‚ РѕРїРµСЂР°С†РёСЏ...'
                        : 'Р—Р°РіСЂСѓР·РёС‚СЊ Рё РІРѕСЃСЃС‚Р°РЅРѕРІРёС‚СЊ',
                  ),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: _backupInProgress ? null : _clearDatabase,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFFFF8A80),
                  ),
                  icon: const Icon(Icons.delete_sweep_outlined),
                  label: const Text('РћС‡РёСЃС‚РёС‚СЊ РІСЃСЋ Р±Р°Р·Сѓ, РєСЂРѕРјРµ РїСЂРѕС„РёР»СЏ Р°РґРјРёРЅР°'),
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
  days('Р”РЅРµР№', 'days'),
  weeks('РќРµРґРµР»СЊ', 'weeks'),
  months('РњРµСЃСЏС†РµРІ', 'months');

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
