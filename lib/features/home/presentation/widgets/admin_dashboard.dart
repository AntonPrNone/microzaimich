import 'dart:async';

import 'dart:math' as math;
import 'dart:io' show Platform;

import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mask_text_input_formatter/mask_text_input_formatter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../core/utils/formatters.dart';
import '../../../../core/utils/input_formatters.dart';
import '../../../../core/utils/validators.dart';
import '../../../../core/widgets/ad_navigation_shortcuts.dart';
import '../../../../data/models/app_user.dart';
import '../../../../data/models/loan.dart';
import '../../../../data/models/loan_defaults_settings.dart';
import '../../../../data/models/payment_schedule_item.dart';
import '../../../../data/models/payment_settings.dart';
import '../../../../data/services/app_clock.dart';

final Duration _desktopAwareUiDuration =
    Platform.isWindows ? const Duration(milliseconds: 1) : const Duration(milliseconds: 220);
final Duration _desktopAwareFastDuration =
    Platform.isWindows ? const Duration(milliseconds: 1) : const Duration(milliseconds: 180);

enum _ClientQuickFilter {
  overdue('С просрочкой', Icons.warning_amber_rounded, Color(0xFFFFC26B)),
  active('Активные', Icons.bolt_rounded, Color(0xFF71E6C1)),
  closed('Закрытые', Icons.check_circle_rounded, Color(0xFF8BC4FF));

  const _ClientQuickFilter(this.label, this.icon, this.color);

  final String label;
  final IconData icon;
  final Color color;
}

class AdminClientsTab extends StatefulWidget {
  const AdminClientsTab({
    super.key,
    required this.currentViewerId,
    required this.clients,
    required this.loans,
    required this.hideClosedLoans,
    required this.watchLoansForUser,
    required this.onEditLoan,
    required this.onCloseLoan,
    required this.onDeleteLoan,
  });

  final String currentViewerId;
  final List<AppUser> clients;
  final List<Loan> loans;
  final bool hideClosedLoans;
  final Stream<List<Loan>> Function(String userId) watchLoansForUser;
  final Future<void> Function(Loan loan) onEditLoan;
  final Future<void> Function(Loan loan, {DateTime? paidAt}) onCloseLoan;
  final Future<void> Function(Loan loan) onDeleteLoan;

  @override
  State<AdminClientsTab> createState() => _AdminClientsTabState();
}

class _AdminClientsTabState extends State<AdminClientsTab> {
  List<String> _clientOrderIds = <String>[];
  bool _loadedOrderPrefs = false;
  bool _archivedClientsExpanded = false;
  bool _dragPrepared = false;
  bool _reorderActive = false;
  String? _dragCandidateClientId;
  String? _visibleDragHintClientId;
  Timer? _dragPrepareTimer;
  final Set<_ClientQuickFilter> _filters = <_ClientQuickFilter>{};

  String get _orderPrefsKey => 'admin_client_order_${widget.currentViewerId}';
  String get _archivedPrefsKey => 'admin_archived_clients_${widget.currentViewerId}';

  @override
  void initState() {
    super.initState();
    _loadClientOrder();
  }

  @override
  void didUpdateWidget(covariant AdminClientsTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentViewerId != widget.currentViewerId) {
      _clientOrderIds = <String>[];
      _loadedOrderPrefs = false;
      _archivedClientsExpanded = false;
      _dragPrepared = false;
      _reorderActive = false;
      _dragCandidateClientId = null;
      _visibleDragHintClientId = null;
      _loadClientOrder();
    }
  }

  @override
  void dispose() {
    _dragPrepareTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadClientOrder() async {
    final prefs = await SharedPreferences.getInstance();
    final ids = prefs.getStringList(_orderPrefsKey) ?? <String>[];
    if (!mounted) {
      return;
    }
    setState(() {
      _clientOrderIds = ids;
      _loadedOrderPrefs = true;
      _archivedClientsExpanded = prefs.getBool(_archivedPrefsKey) ?? false;
    });
  }

  Future<void> _saveClientOrder(List<String> ids) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_orderPrefsKey, ids);
  }

  Future<void> _setArchivedExpanded(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_archivedPrefsKey, value);
    if (!mounted) {
      return;
    }
    setState(() {
      _archivedClientsExpanded = value;
    });
  }

  List<AppUser> _applyClientOrder(List<AppUser> clients) {
    final orderedClients = [...clients]
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

    if (!_loadedOrderPrefs || _clientOrderIds.isEmpty) {
      return orderedClients;
    }

    final orderIndex = <String, int>{
      for (var i = 0; i < _clientOrderIds.length; i++) _clientOrderIds[i]: i,
    };

    orderedClients.sort((a, b) {
      final aIndex = orderIndex[a.id];
      final bIndex = orderIndex[b.id];

      if (aIndex != null && bIndex != null) {
        return aIndex.compareTo(bIndex);
      }
      if (aIndex != null) {
        return -1;
      }
      if (bIndex != null) {
        return 1;
      }
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });

    return orderedClients;
  }

  void _prepareForDrag() {
    if (_dragPrepared) {
      return;
    }
    setState(() {
      _dragPrepared = true;
      _visibleDragHintClientId = _dragCandidateClientId;
    });
  }

  void _restoreAfterDrag() {
    if (!_dragPrepared && !_reorderActive) {
      return;
    }
    final hintClientId = _visibleDragHintClientId;
    setState(() {
      _dragPrepared = false;
      _reorderActive = false;
      _dragCandidateClientId = null;
    });
    Future<void>.delayed(const Duration(milliseconds: 220), () {
      if (!mounted) {
        return;
      }
      if (_visibleDragHintClientId == hintClientId) {
        setState(() {
          _visibleDragHintClientId = null;
        });
      }
    });
  }

  void _scheduleDragPreparation(String clientId) {
    _dragPrepareTimer?.cancel();
    if (!_reorderActive) {
      setState(() {
        _dragCandidateClientId = clientId;
      });
    }
    _dragPrepareTimer = Timer(const Duration(milliseconds: 180), () {
      if (!mounted || _reorderActive) {
        return;
      }
      _prepareForDrag();
    });
  }

  void _cancelPendingDragPreparation() {
    _dragPrepareTimer?.cancel();
    if (!_reorderActive && !_dragPrepared && _dragCandidateClientId != null) {
      final hintClientId = _visibleDragHintClientId;
      setState(() {
        _dragCandidateClientId = null;
      });
      Future<void>.delayed(const Duration(milliseconds: 220), () {
        if (!mounted) {
          return;
        }
        if (_visibleDragHintClientId == hintClientId && !_dragPrepared && !_reorderActive) {
          setState(() {
            _visibleDragHintClientId = null;
          });
        }
      });
    }
  }

  void _handleReorderStart() {
    _cancelPendingDragPreparation();
    if (!_dragPrepared) {
      _prepareForDrag();
    }
    _reorderActive = true;
  }

  void _handleReorderEnd() {
    _cancelPendingDragPreparation();
    Future<void>.delayed(const Duration(milliseconds: 60), () {
      if (!mounted) {
        return;
      }
      _restoreAfterDrag();
    });
  }

  Future<void> _openClientLoansSheet({
    required AppUser client,
    required List<Loan> clientLoans,
  }) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      builder: (context) {
        final mediaQuery = MediaQuery.of(context);
        final availableHeight = mediaQuery.size.height - mediaQuery.padding.top - 12;
        return SizedBox(
          height: availableHeight,
                                child: _ClientLoansSheet(
                                  client: client,
                                  initialLoans: clientLoans,
                                  loanStream: widget.watchLoansForUser(client.id),
                                  onEditLoan: widget.onEditLoan,
                                  onCloseLoan: widget.onCloseLoan,
                                  onDeleteLoan: widget.onDeleteLoan,
                                ),
                              );
                            },
    );
  }

  @override
  Widget build(BuildContext context) {
    List<Loan> allClientLoans(AppUser client) =>
        widget.loans.where((loan) => loan.userId == client.id).toList()..sort((a, b) {
          final aActive = a.status == 'active';
          final bActive = b.status == 'active';
          if (aActive != bActive) {
            return aActive ? -1 : 1;
          }
          return a.issuedAt.compareTo(b.issuedAt);
        });

    Widget buildClientCard(
      AppUser client, {
      required int? reorderIndex,
      required String keyPrefix,
    }) {
      final loans = allClientLoans(client);
      final clientLoans = loans
          .where((loan) => !widget.hideClosedLoans || loan.status == 'active')
          .toList();
      final previewLoans = clientLoans.isEmpty && loans.isNotEmpty ? loans : clientLoans;
      final totalDebt = loans.fold<double>(
        0,
        (debtSum, loan) => debtSum + loan.plannedOutstandingAmount,
      );
      final totalPenalty = loans.fold<double>(
        0,
        (penaltySum, loan) => penaltySum + loan.penaltyOutstanding + loan.penaltyPaid,
      );
      final totalPaid = loans.fold<double>(0, (paidSum, loan) => paidSum + loan.paidAmount);
      final hasOverdueLoans = loans.any(
        (loan) => loan.status == 'active' && loan.penaltyOutstanding > 0,
      );
      final activeLoans = loans.where((loan) => loan.status == 'active').length;
      final closedLoans = loans.length - activeLoans;
      final nextDates = loans.map((loan) => loan.nextUnpaid?.dueDate).whereType<DateTime>().toList()
        ..sort();
      final nearestPaymentDate = nextDates.isEmpty ? null : nextDates.first;
      final earliestLoanDate = loans.isEmpty ? null : loans.first.issuedAt;
      final latestLoanDate = loans.isEmpty ? null : loans.last.issuedAt;

      return Padding(
        key: ValueKey('${keyPrefix}_${client.id}'),
        padding: const EdgeInsets.only(bottom: 16),
        child: _AdminClientCard(
          client: client,
          clientLoans: previewLoans,
          totalLoans: loans.length,
          totalDebt: totalDebt,
          totalPenalty: totalPenalty,
          totalPaid: totalPaid,
          hasOverdueLoans: hasOverdueLoans,
          activeLoans: activeLoans,
          closedLoans: closedLoans,
          nearestPaymentDate: nearestPaymentDate,
          earliestLoanDate: earliestLoanDate,
          latestLoanDate: latestLoanDate,
          isDragReady:
              reorderIndex != null &&
              (_dragPrepared || _reorderActive) &&
              _visibleDragHintClientId == client.id,
          showDragHint: reorderIndex != null && _visibleDragHintClientId == client.id,
          onOpenLoans: () => _openClientLoansSheet(client: client, clientLoans: previewLoans),
          dragIndicator: reorderIndex == null
              ? null
              : Listener(
                  onPointerDown: (_) => _scheduleDragPreparation(client.id),
                  onPointerUp: (_) {
                    if (!_reorderActive) {
                      _cancelPendingDragPreparation();
                      if (_dragPrepared) {
                        _restoreAfterDrag();
                      }
                    }
                  },
                  onPointerCancel: (_) {
                    if (!_reorderActive) {
                      _cancelPendingDragPreparation();
                      if (_dragPrepared) {
                        _restoreAfterDrag();
                      }
                    }
                  },
                  child: ReorderableDelayedDragStartListener(
                    index: reorderIndex,
                    child: Icon(
                      Icons.drag_indicator_rounded,
                      color: Theme.of(context).colorScheme.secondary,
                    ),
                  ),
                ),
          onEditLoan: widget.onEditLoan,
        ),
      );
    }

    final uniqueClients = <String, AppUser>{for (final client in widget.clients) client.id: client}
        .values
        .toList();
    final orderedClients = _applyClientOrder(uniqueClients);
    bool matchesFilters(AppUser client) {
      final loans = allClientLoans(client);
      final hasActive = loans.any((loan) => loan.status == 'active');
      final hasClosed = loans.any((loan) => loan.status == 'closed');
      final hasOverdue = loans.any(
        (loan) => loan.status == 'active' && loan.penaltyOutstanding > 0,
      );
      if (_filters.contains(_ClientQuickFilter.overdue) && !hasOverdue) {
        return false;
      }
      if (_filters.contains(_ClientQuickFilter.active) && !hasActive) {
        return false;
      }
      if (_filters.contains(_ClientQuickFilter.closed) && (hasActive || !hasClosed)) {
        return false;
      }

      return true;
    }

    final filteredClients = orderedClients.where(matchesFilters).toList();
    final activeClients = filteredClients.where((client) {
      final loans = allClientLoans(client);
      return loans.any((loan) => loan.status == 'active');
    }).toList();
    final archivedClients = filteredClients.where((client) {
      final loans = allClientLoans(client);
      return loans.isEmpty || loans.every((loan) => loan.status != 'active');
    }).toList();

    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
          sliver: SliverToBoxAdapter(
            child: Text('Клиенты и займы', style: Theme.of(context).textTheme.titleLarge),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
          sliver: SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Зажмите иконку справа, чтобы изменить порядок клиентов',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 12),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: _ClientQuickFilter.values.map((filter) {
                      final selected = _filters.contains(filter);
                      return Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: _CompactFilterPill(
                          label: filter.label,
                          icon: filter.icon,
                          color: filter.color,
                          selected: selected,
                          onTap: () {
                            setState(() {
                              if (selected) {
                                _filters.remove(filter);
                              } else {
                                _filters.add(filter);
                              }
                            });
                          },
                        ),
                      );
                    }).toList(),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (filteredClients.isEmpty)
          const SliverPadding(
            padding: EdgeInsets.fromLTRB(20, 12, 20, 20),
            sliver: SliverToBoxAdapter(
              child: Card(
                child: Padding(padding: EdgeInsets.all(20), child: Text('Пока нет клиентов')),
              ),
            ),
          )
        else ...[
          if (activeClients.isNotEmpty)
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
              sliver: SliverReorderableList(
                itemCount: activeClients.length,
                proxyDecorator: (child, index, animation) {
                  return Material(color: Colors.transparent, child: child);
                },
                onReorderStart: (_) => _handleReorderStart(),
                onReorderEnd: (_) => _handleReorderEnd(),
                onReorder: (oldIndex, newIndex) async {
                  if (newIndex > oldIndex) {
                    newIndex -= 1;
                  }

                  final ids = activeClients.map((client) => client.id).toList();
                  final moved = ids.removeAt(oldIndex);
                  ids.insert(newIndex, moved);

                  setState(() {
                    final archivedIds = _clientOrderIds.where((id) => !ids.contains(id)).toList();
                    _clientOrderIds = [...ids, ...archivedIds];
                  });

                  await _saveClientOrder(_clientOrderIds);
                },
                itemBuilder: (context, index) {
                  return buildClientCard(
                    activeClients[index],
                    reorderIndex: index,
                    keyPrefix: 'admin_client_active',
                  );
                },
              ),
            ),
          if (archivedClients.isNotEmpty)
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
              sliver: SliverToBoxAdapter(
                child: Card(
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: () => _setArchivedExpanded(!_archivedClientsExpanded),
                    child: Padding(
                      padding: const EdgeInsets.all(18),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  'Клиенты без активных займов',
                                  style: Theme.of(context).textTheme.titleMedium,
                                ),
                              ),
                              _TagChip(label: '${archivedClients.length}'),
                              const SizedBox(width: 10),
                              Icon(
                                _archivedClientsExpanded
                                    ? Icons.expand_less_rounded
                                    : Icons.expand_more_rounded,
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Клиенты без займов и с полностью выплаченными займами',
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                          AnimatedCrossFade(
                            firstChild: const SizedBox.shrink(),
                            secondChild: Padding(
                              padding: const EdgeInsets.only(top: 16),
                              child: Column(
                                children: archivedClients
                                    .map(
                                      (client) => buildClientCard(
                                        client,
                                        reorderIndex: null,
                                        keyPrefix: 'admin_client_archived',
                                      ),
                                    )
                                    .toList(),
                              ),
                            ),
                            crossFadeState: _archivedClientsExpanded
                                ? CrossFadeState.showSecond
                                : CrossFadeState.showFirst,
                            duration: _desktopAwareUiDuration,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ],
    );
  }
}

class _AdminClientCard extends StatelessWidget {
  const _AdminClientCard({
    required this.client,
    required this.clientLoans,
    required this.totalLoans,
    required this.totalDebt,
    required this.totalPenalty,
    required this.totalPaid,
    required this.hasOverdueLoans,
    required this.activeLoans,
    required this.closedLoans,
    required this.nearestPaymentDate,
    required this.earliestLoanDate,
    required this.latestLoanDate,
    required this.isDragReady,
    required this.showDragHint,
    required this.onOpenLoans,
    required this.onEditLoan,
    this.dragIndicator,
  });

  final AppUser client;
  final List<Loan> clientLoans;
  final int totalLoans;
  final double totalDebt;
  final double totalPenalty;
  final double totalPaid;
  final bool hasOverdueLoans;
  final int activeLoans;
  final int closedLoans;
  final DateTime? nearestPaymentDate;
  final DateTime? earliestLoanDate;
  final DateTime? latestLoanDate;
  final bool isDragReady;
  final bool showDragHint;
  final VoidCallback onOpenLoans;
  final Future<void> Function(Loan loan) onEditLoan;
  final Widget? dragIndicator;

  @override
  Widget build(BuildContext context) {
    final secondaryColor = Theme.of(context).colorScheme.secondary;
    Future<void> showMetricHelp({required String title, required String message}) async {
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Понятно')),
          ],
        ),
      );
    }

    return Stack(
      children: [
        Card(
          clipBehavior: Clip.antiAlias,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const CircleAvatar(child: Icon(Icons.person_outline)),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(client.name, style: Theme.of(context).textTheme.titleMedium),
                          const SizedBox(height: 4),
                          Text(Formatters.phone(client.phone)),
                          if (hasOverdueLoans) ...[
                            const SizedBox(height: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                              decoration: BoxDecoration(
                                color: const Color(0xFFFFC26B).withValues(alpha: 0.14),
                                borderRadius: BorderRadius.circular(999),
                                border: Border.all(
                                  color: const Color(0xFFFFC26B).withValues(alpha: 0.28),
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(
                                    Icons.warning_amber_rounded,
                                    size: 14,
                                    color: Color(0xFFFFC26B),
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    'Есть просрочка',
                                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                      color: const Color(0xFFFFC26B),
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    if (dragIndicator != null)
                      AnimatedContainer(
                        duration: _desktopAwareFastDuration,
                        curve: Curves.easeOut,
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                        decoration: BoxDecoration(
                          color: isDragReady
                              ? secondaryColor.withValues(alpha: 0.18)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: isDragReady
                                ? secondaryColor.withValues(alpha: 0.28)
                                : Colors.transparent,
                          ),
                        ),
                        child: dragIndicator!,
                      ),
                  ],
                ),
                ClipRect(
                  child: AnimatedSize(
                    duration: _desktopAwareUiDuration,
                    curve: Curves.easeInOut,
                    alignment: Alignment.topCenter,
                    child: AnimatedOpacity(
                      duration: _desktopAwareFastDuration,
                      curve: Curves.easeInOut,
                      opacity: isDragReady ? 1 : 0,
                      child: showDragHint
                          ? Padding(
                              padding: const EdgeInsets.only(top: 10),
                              child: Row(
                                children: [
                                  Icon(Icons.open_with_rounded, size: 16, color: secondaryColor),
                                  const SizedBox(width: 6),
                                  Text(
                                    'Теперь можно переносить',
                                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                      color: secondaryColor,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ),
                            )
                          : const SizedBox.shrink(),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                _CompactMetricLegend(
                  items: [
                    _CompactMetricItem(
                      label: 'всего',
                      value: totalLoans.toString(),
                      color: secondaryColor,
                    ),
                    _CompactMetricItem(
                      label: 'акт',
                      value: activeLoans.toString(),
                      color: const Color(0xFFFFC26B),
                    ),
                    if (closedLoans > 0)
                      _CompactMetricItem(
                        label: 'закр',
                        value: closedLoans.toString(),
                        color: Theme.of(context).colorScheme.primary,
                      ),
                  ],
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _TagChip(
                      label: 'Остаток ${Formatters.money(totalDebt)}',
                      onTap: () => showMetricHelp(
                        title: 'Плановый остаток',
                        message:
                            'Сколько клиенту осталось выплатить по всем займам, если дальше он будет платить по обычному плану. Сюда входит остаток по договору и уже начисленные, но ещё не оплаченные пени.',
                      ),
                    ),
                    _TagChip(
                      label: 'Пени ${Formatters.money(totalPenalty)}',
                      color: const Color(0xFFFFC26B),
                      onTap: () => showMetricHelp(
                        title: 'Пени всего',
                        message:
                            'Общая сумма пени по всем займам клиента: и уже оплаченные пени, и начисленные на текущий момент, но ещё не оплаченные.',
                      ),
                    ),
                    _TagChip(
                      label: 'Уплачено ${Formatters.money(totalPaid)}',
                      color: const Color(0xFF8BC4FF),
                      onTap: () => showMetricHelp(
                        title: 'Уплачено всего',
                        message:
                            'Общая сумма, которую клиент уже фактически выплатил по всем займам: тело займа, проценты и пени вместе.',
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                if (earliestLoanDate != null && latestLoanDate != null)
                  Text(
                    earliestLoanDate == latestLoanDate
                        ? 'Займы от ${Formatters.date(earliestLoanDate!)}'
                        : 'Займы с ${Formatters.date(earliestLoanDate!)} по ${Formatters.date(latestLoanDate!)}',
                  ),
                if (nearestPaymentDate != null) ...[
                  const SizedBox(height: 4),
                  Text('Ближайший платёж ${Formatters.date(nearestPaymentDate!)}'),
                ],
                const SizedBox(height: 14),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: onOpenLoans,
                    icon: const Icon(Icons.view_carousel_outlined),
                    label: Text(
                      clientLoans.isEmpty ? 'У клиента пока нет займов' : 'Открыть займы клиента',
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        Positioned.fill(
          child: IgnorePointer(
              child: AnimatedOpacity(
                duration: _desktopAwareFastDuration,
                opacity: isDragReady ? 1 : 0,
                child: Platform.isWindows
                    ? Container(
                        margin: const EdgeInsets.all(2),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(26),
                          border: Border.all(
                            color: secondaryColor.withValues(alpha: 0.65),
                            width: 1.5,
                          ),
                        ),
                      )
                    : Padding(
                        padding: const EdgeInsets.all(2),
                        child: CustomPaint(
                          painter: _DashedCardBorderPainter(
                            color: secondaryColor.withValues(alpha: 0.65),
                            radius: 26,
                          ),
                        ),
                      ),
              ),
            ),
          ),
      ],
    );
  }
}

class _ClientLoansSheet extends StatefulWidget {
  const _ClientLoansSheet({
    required this.client,
    required this.initialLoans,
    required this.loanStream,
    required this.onEditLoan,
    required this.onCloseLoan,
    required this.onDeleteLoan,
  });

  final AppUser client;
  final List<Loan> initialLoans;
  final Stream<List<Loan>> loanStream;
  final Future<void> Function(Loan loan) onEditLoan;
  final Future<void> Function(Loan loan, {DateTime? paidAt}) onCloseLoan;
  final Future<void> Function(Loan loan) onDeleteLoan;

  @override
  State<_ClientLoansSheet> createState() => _ClientLoansSheetState();
}

class _ProfitBreakdownEntry {
  const _ProfitBreakdownEntry({
    required this.clientId,
    required this.clientName,
    required this.amount,
    this.clientPhone,
  });

  final String clientId;
  final String clientName;
  final String? clientPhone;
  final double amount;
}

class _ProfitBreakdownSheet extends StatefulWidget {
  const _ProfitBreakdownSheet({
    required this.plannedEntries,
    required this.receivedEntries,
    required this.remainingEntries,
  });

  final List<_ProfitBreakdownEntry> plannedEntries;
  final List<_ProfitBreakdownEntry> receivedEntries;
  final List<_ProfitBreakdownEntry> remainingEntries;

  @override
  State<_ProfitBreakdownSheet> createState() => _ProfitBreakdownSheetState();
}

class _ProfitBreakdownSheetState extends State<_ProfitBreakdownSheet> {
  late final PageController _pageController;
  int _currentPage = 0;

  static const _titles = ['По плану', 'Получено', 'Осталось'];

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _goToPage(int page) async {
    if (!_pageController.hasClients) {
      return;
    }
    await _pageController.animateToPage(
      page,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeInOut,
    );
  }

  Widget _buildPage(
    BuildContext context,
    String title,
    String subtitle,
    List<_ProfitBreakdownEntry> entries,
  ) {
    if (entries.isEmpty) {
      return Center(child: Text('Пока нет данных', style: Theme.of(context).textTheme.bodyMedium));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 4),
        Text(subtitle, style: Theme.of(context).textTheme.bodyMedium),
        const SizedBox(height: 12),
        Expanded(
          child: ListView.separated(
            itemCount: entries.length,
            separatorBuilder: (context, index) => const SizedBox(height: 10),
            itemBuilder: (context, index) {
              final entry = entries[index];
              return Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Theme.of(
                    context,
                  ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(
                    color: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.3),
                  ),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(entry.clientName, style: Theme.of(context).textTheme.titleSmall),
                          if (entry.clientPhone != null) ...[
                            const SizedBox(height: 4),
                            Text(
                              Formatters.phone(entry.clientPhone!),
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      Formatters.money(entry.amount),
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      (
        title: 'По плану',
        subtitle: 'С кого сколько ожидается по плану',
        entries: widget.plannedEntries,
      ),
      (title: 'Получено', subtitle: 'С кого сколько уже получено', entries: widget.receivedEntries),
      (
        title: 'Осталось получить',
        subtitle: 'С кого сколько ещё осталось получить',
        entries: widget.remainingEntries,
      ),
    ];

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Заработок по клиентам', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            Expanded(
              child: AdNavigationShortcuts(
                onPrevious: () => _goToPage(_currentPage - 1),
                onNext: () => _goToPage(_currentPage + 1),
                canNavigatePrevious: _currentPage > 0,
                canNavigateNext: _currentPage < pages.length - 1,
                child: PageView.builder(
                  controller: _pageController,
                  itemCount: pages.length,
                  onPageChanged: (page) => setState(() => _currentPage = page),
                  itemBuilder: (context, index) {
                    final page = pages[index];
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: _buildPage(context, page.title, page.subtitle, page.entries),
                    );
                  },
                ),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                IconButton(
                  onPressed: _currentPage > 0 ? () => _goToPage(_currentPage - 1) : null,
                  icon: const Icon(Icons.chevron_left_rounded),
                ),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '${_currentPage + 1} / ${pages.length}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(height: 6),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: List<Widget>.generate(pages.length, (index) {
                          final selected = index == _currentPage;
                          return Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 180),
                              width: selected ? 20 : 8,
                              height: 8,
                              decoration: BoxDecoration(
                                color: selected
                                    ? Theme.of(context).colorScheme.secondary
                                    : Theme.of(
                                        context,
                                      ).colorScheme.secondary.withValues(alpha: 0.28),
                                borderRadius: BorderRadius.circular(999),
                              ),
                            ),
                          );
                        }),
                      ),
                      const SizedBox(height: 6),
                      Text(_titles[_currentPage], style: Theme.of(context).textTheme.bodySmall),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: _currentPage < pages.length - 1
                      ? () => _goToPage(_currentPage + 1)
                      : null,
                  icon: const Icon(Icons.chevron_right_rounded),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ClientLoansSheetState extends State<_ClientLoansSheet> {
  late final PageController _pageController;
  StreamSubscription<List<Loan>>? _loanSubscription;
  int _currentPage = 0;
  int? _loanPagesSignature;
  List<Widget> _cachedLoanPages = const [];
  late List<Loan> _loans;

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
    _loans = _sortLoans(widget.initialLoans);
    _loanSubscription = widget.loanStream.listen((loans) {
      if (!mounted) {
        return;
      }
      final sortedLoans = _sortLoans(loans);
      if (_sameSheetLoans(_loans, sortedLoans)) {
        return;
      }
      setState(() {
        _loans = sortedLoans;
      });
    });
  }

  @override
  void dispose() {
    _loanSubscription?.cancel();
    _pageController.dispose();
    super.dispose();
  }

  List<Loan> _sortLoans(List<Loan> loans) {
    final sorted = List<Loan>.from(loans)
      ..sort((a, b) {
        final aActive = a.status == 'active';
        final bActive = b.status == 'active';
        if (aActive != bActive) {
          return aActive ? -1 : 1;
        }
        return a.issuedAt.compareTo(b.issuedAt);
      });
    return sorted;
  }

  bool _sameSheetLoans(List<Loan> previous, List<Loan> next) {
    if (identical(previous, next)) {
      return true;
    }
    if (previous.length != next.length) {
      return false;
    }
    for (var index = 0; index < previous.length; index++) {
      final left = previous[index];
      final right = next[index];
      if (left.id != right.id ||
          left.status != right.status ||
          left.plannedOutstandingAmount != right.plannedOutstandingAmount ||
          left.fullCloseAmount != right.fullCloseAmount ||
          left.paidAmount != right.paidAmount ||
          left.penaltyOutstanding != right.penaltyOutstanding ||
          left.penaltyPaid != right.penaltyPaid ||
          left.schedule.length != right.schedule.length) {
        return false;
      }
    }
    return true;
  }

  Future<void> _goToPage(int page) async {
    if (!_pageController.hasClients) {
      return;
    }
    await _pageController.animateToPage(
      page,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeInOut,
    );
  }

  int _computeLoansSignature(List<Loan> loans) {
    return Object.hashAll(
      loans.map(
        (loan) => Object.hash(
          loan.id,
          loan.displayTitle,
          loan.status,
          loan.plannedOutstandingAmount,
          loan.fullCloseAmount,
          loan.paidAmount,
          loan.interestPaid,
          loan.penaltyOutstanding,
          loan.penaltyPaid,
          loan.schedule.length,
        ),
      ),
    );
  }

  List<Widget> _loanPagesFor(List<Loan> loans) {
    final signature = _computeLoansSignature(loans);
    if (_loanPagesSignature == signature && _cachedLoanPages.length == loans.length) {
      return _cachedLoanPages;
    }

    _loanPagesSignature = signature;
    _cachedLoanPages = loans
        .map(
          (loan) => RepaintBoundary(
            key: ValueKey('client-loan-page-${loan.id}'),
            child: LayoutBuilder(
              builder: (context, constraints) {
                return SingleChildScrollView(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(minHeight: constraints.maxHeight - 8),
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 720),
                        child: _LoanPreviewCard(
                          loan: loan,
                          onEdit: () => widget.onEditLoan(loan),
                          onClose: () => _confirmCloseLoan(loan),
                          onDelete: () => _confirmDeleteLoan(loan),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        )
        .toList(growable: false);
    return _cachedLoanPages;
  }

  Future<void> _confirmDeleteLoan(Loan loan) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Удалить займ'),
        content: Text(
          'Удалить "${loan.displayTitle}" у клиента ${widget.client.name}? Это действие нельзя отменить.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFFF8A80),
              foregroundColor: Colors.black,
            ),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) {
      return;
    }

    await widget.onDeleteLoan(loan);
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Займ "${loan.displayTitle}" удалён')));
  }

  Future<void> _confirmCloseLoan(Loan loan) async {
    if (loan.status == 'closed') {
      return;
    }

    final pickedDate = await showDatePicker(
      context: context,
      initialDate: AppClock.now(),
      firstDate: DateTime(loan.issuedAt.year, loan.issuedAt.month, loan.issuedAt.day),
      lastDate: DateTime(2100),
      locale: const Locale('ru', 'RU'),
    );

    if (pickedDate == null || !mounted) {
      return;
    }

    await widget.onCloseLoan(loan, paidAt: pickedDate);
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(
      SnackBar(
        content: Text(
          'Займ "${loan.displayTitle}" погашен полностью от ${Formatters.date(pickedDate)}',
        ),
      ),
    );
  }

  List<int> _visibleIndicatorIndexes(int maxVisible, int totalLoans) {
    if (totalLoans == 0) {
      return const [];
    }

    final targetCount = maxVisible.isEven ? maxVisible - 1 : maxVisible;
    final normalizedTargetCount = targetCount < 1 ? 1 : targetCount;
    final int count = totalLoans < 3 ? totalLoans : normalizedTargetCount.clamp(3, totalLoans);
    var start = _currentPage - (count ~/ 2);
    var end = start + count - 1;

    if (start < 0) {
      end += -start;
      start = 0;
    }
    if (end >= totalLoans) {
      final shift = end - totalLoans + 1;
      start = (start - shift).clamp(0, totalLoans - 1);
      end = totalLoans - 1;
    }

    return List<int>.generate(end - start + 1, (index) => start + index);
  }

  @override
  Widget build(BuildContext context) {
    final loans = _loans;
    if (loans.isEmpty) {
      _currentPage = 0;
    } else if (_currentPage >= loans.length) {
      _currentPage = loans.length - 1;
    }
    final currentLoan = loans.isEmpty ? null : loans[_currentPage.clamp(0, loans.length - 1)];
    final loanPages = _loanPagesFor(loans);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(widget.client.name, style: Theme.of(context).textTheme.titleLarge),
                      const SizedBox(height: 4),
                      Text(
                        Formatters.phone(widget.client.phone),
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ],
                  ),
                ),
                if (currentLoan != null) ...[
                  const SizedBox(width: 12),
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: Text(
                        currentLoan.displayTitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.end,
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 12),
            if (loans.isEmpty)
              Expanded(
                child: Center(
                  child: Text(
                    'У клиента пока нет займов',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
              )
            else ...[
              Expanded(
                child: AdNavigationShortcuts(
                  onPrevious: () => _goToPage(_currentPage - 1),
                  onNext: () => _goToPage(_currentPage + 1),
                  canNavigatePrevious: _currentPage > 0,
                  canNavigateNext: _currentPage < loans.length - 1,
                  child: PageView(
                    controller: _pageController,
                    allowImplicitScrolling: true,
                    onPageChanged: (page) {
                      setState(() {
                        _currentPage = page;
                      });
                    },
                    children: loanPages,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: Theme.of(context).cardColor,
                  borderRadius: BorderRadius.circular(18),
                ),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final indicatorCapacity = ((constraints.maxWidth - 120) / 16).floor().clamp(
                      3,
                      9,
                    );
                    final visibleIndexes = _visibleIndicatorIndexes(indicatorCapacity, loans.length);

                    return Row(
                      children: [
                        OutlinedButton(
                          onPressed: _currentPage == 0 ? null : () => _goToPage(_currentPage - 1),
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size(40, 40),
                            padding: EdgeInsets.zero,
                          ),
                          child: const Icon(Icons.arrow_back_rounded),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                '${_currentPage + 1} / ${loans.length}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.titleSmall,
                              ),
                              const SizedBox(height: 8),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: visibleIndexes.map((pageIndex) {
                                  final isActive = pageIndex == _currentPage;
                                  return SizedBox(
                                    width: 20,
                                    child: Center(
                                      child: AnimatedContainer(
                                        duration: _desktopAwareFastDuration,
                                        width: isActive ? 20 : 8,
                                        height: 8,
                                        decoration: BoxDecoration(
                                          color: isActive
                                              ? Theme.of(context).colorScheme.secondary
                                              : Theme.of(
                                                  context,
                                                ).colorScheme.secondary.withValues(alpha: 0.28),
                                          borderRadius: BorderRadius.circular(999),
                                        ),
                                      ),
                                    ),
                                  );
                                }).toList(),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        OutlinedButton(
                          onPressed: _currentPage >= loans.length - 1
                              ? null
                              : () => _goToPage(_currentPage + 1),
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size(40, 40),
                            padding: EdgeInsets.zero,
                          ),
                          child: const Icon(Icons.arrow_forward_rounded),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _DashedCardBorderPainter extends CustomPainter {
  const _DashedCardBorderPainter({required this.color, required this.radius});

  final Color color;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(rect, Radius.circular(radius));
    final path = Path()..addRRect(rrect);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;

    const dashWidth = 8.0;
    const dashGap = 6.0;
    for (final metric in path.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        final next = (distance + dashWidth).clamp(0.0, metric.length).toDouble();
        canvas.drawPath(metric.extractPath(distance, next), paint);
        distance += dashWidth + dashGap;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DashedCardBorderPainter oldDelegate) {
    return oldDelegate.color != color || oldDelegate.radius != radius;
  }
}

class AdminDashboard extends StatefulWidget {
  const AdminDashboard({
    super.key,
    required this.clients,
    required this.loans,
    required this.paymentSettings,
    required this.loanDefaults,
    required this.onDeleteClients,
    required this.onCreateClient,
    required this.onIssueLoan,
    required this.onUpdateLoan,
    required this.onSavePaymentSettings,
  });

  final List<AppUser> clients;
  final List<Loan> loans;
  final PaymentSettings paymentSettings;
  final LoanDefaultsSettings loanDefaults;
  final Future<void> Function(List<AppUser> clients) onDeleteClients;
  final Future<void> Function({required String name, required String phone}) onCreateClient;
  final Future<void> Function({
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
  })
  onIssueLoan;
  final Future<void> Function(Loan loan) onUpdateLoan;
  final Future<void> Function(PaymentSettings settings) onSavePaymentSettings;

  @override
  State<AdminDashboard> createState() => _AdminDashboardState();
}

class _AdminDashboardState extends State<AdminDashboard> {
  final _clientNameController = TextEditingController();
  final _clientPhoneController = TextEditingController();
  final _bankNameController = TextEditingController();
  final _recipientNameController = TextEditingController();
  final _recipientPhoneController = TextEditingController();
  final _paymentLinkController = TextEditingController();
  late final MaskTextInputFormatter _phoneMaskFormatter;
  bool _showPortfolioWithoutPenalty = false;

  Future<void> _openProfitBreakdownSheet({
    required List<_ProfitBreakdownEntry> plannedEntries,
    required List<_ProfitBreakdownEntry> receivedEntries,
    required List<_ProfitBreakdownEntry> remainingEntries,
  }) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      builder: (context) {
        final mediaQuery = MediaQuery.of(context);
        final availableHeight = mediaQuery.size.height - mediaQuery.padding.top - 12;
        return SizedBox(
          height: availableHeight,
          child: _ProfitBreakdownSheet(
            plannedEntries: plannedEntries,
            receivedEntries: receivedEntries,
            remainingEntries: remainingEntries,
          ),
        );
      },
    );
  }

  Future<void> _openDeleteClientsSheet() async {
    if (widget.clients.isEmpty) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Нет клиентов для удаления')));
      return;
    }

    final selectedIds = <String>{};
    final confirmedClients = await showModalBottomSheet<List<AppUser>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Удаление клиентов', style: Theme.of(context).textTheme.titleLarge),
                    const SizedBox(height: 8),
                    const Text('Выберите клиентов, которых нужно удалить'),
                    const SizedBox(height: 16),
                    Flexible(
                      child: ListView.separated(
                        shrinkWrap: true,
                        itemCount: widget.clients.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 8),
                        itemBuilder: (context, index) {
                          final client = widget.clients[index];
                          final loansCount = widget.loans
                              .where((loan) => loan.userId == client.id)
                              .length;
                          final isSelected = selectedIds.contains(client.id);

                          return CheckboxListTile(
                            value: isSelected,
                            contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                            title: Text(client.name),
                            subtitle: Text(
                              '${Formatters.phone(client.phone)} • Займов: $loansCount\n'
                              'Профиль создан: ${Formatters.dateTime(client.createdAt)}',
                            ),
                            isThreeLine: true,
                            onChanged: (value) {
                              setSheetState(() {
                                if (value ?? false) {
                                  selectedIds.add(client.id);
                                } else {
                                  selectedIds.remove(client.id);
                                }
                              });
                            },
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: selectedIds.isEmpty
                            ? null
                            : () async {
                                final clientsToDelete = widget.clients
                                    .where((client) => selectedIds.contains(client.id))
                                    .toList();

                                final confirmed = await showDialog<bool>(
                                  context: context,
                                  builder: (context) => AlertDialog(
                                    title: const Text('Подтвердите удаление'),
                                    content: Text(
                                      'Будут безвозвратно удалены клиент, все его данные и все займы.\n\nК удалению: ${clientsToDelete.map((client) => client.name).join(', ')}',
                                    ),
                                    actions: [
                                      TextButton(
                                        onPressed: () => Navigator.of(context).pop(false),
                                        child: const Text('Отмена'),
                                      ),
                                      FilledButton(
                                        style: FilledButton.styleFrom(
                                          backgroundColor: const Color(0xFFE85B5B),
                                        ),
                                        onPressed: () => Navigator.of(context).pop(true),
                                        child: const Text('Удалить навсегда'),
                                      ),
                                    ],
                                  ),
                                );

                                if (confirmed != true || !context.mounted) {
                                  return;
                                }

                                Navigator.of(sheetContext).pop(clientsToDelete);
                              },
                        icon: const Icon(Icons.delete_forever_outlined),
                        label: const Text('Удалить выбранных клиентов'),
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

    if (confirmedClients == null || confirmedClients.isEmpty || !mounted) {
      return;
    }

    await widget.onDeleteClients(confirmedClients);
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Удалено клиентов: ${confirmedClients.length}')));
  }

  @override
  void initState() {
    super.initState();
    _phoneMaskFormatter = InputMasks.phone();
    _syncPaymentSettings();
  }

  @override
  void dispose() {
    _clientNameController.dispose();
    _clientPhoneController.dispose();
    _bankNameController.dispose();
    _recipientNameController.dispose();
    _recipientPhoneController.dispose();
    _paymentLinkController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant AdminDashboard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.paymentSettings != widget.paymentSettings) {
      _syncPaymentSettings();
    }
  }

  void _syncPaymentSettings() {
    _bankNameController.text = widget.paymentSettings.bankName;
    _recipientNameController.text = widget.paymentSettings.recipientName;
    _recipientPhoneController.text = widget.paymentSettings.recipientPhone;
    _paymentLinkController.text = widget.paymentSettings.paymentLink;
  }

  Future<void> _savePaymentSettings() async {
    await widget.onSavePaymentSettings(
      widget.paymentSettings.copyWith(
        bankName: _bankNameController.text.trim(),
        recipientName: _recipientNameController.text.trim(),
        recipientPhone: _recipientPhoneController.text.trim(),
        paymentLink: _paymentLinkController.text.trim(),
        updatedAt: AppClock.nowForStorage(),
      ),
    );
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Реквизиты оплаты сохранены')));
  }

  Future<void> _pickClientFromContacts() async {
    if (!Platform.isAndroid && !Platform.isIOS) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Импорт контактов доступен только на телефоне'),
        ),
      );
      return;
    }

    try {
      final hasPermission = await FlutterContacts.requestPermission(
        readonly: true,
      );
      if (!hasPermission) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Нужен доступ к контактам, чтобы импортировать клиента'),
          ),
        );
        return;
      }

      final pickedContact = await FlutterContacts.openExternalPick();

      if (pickedContact == null || !mounted) {
        return;
      }

      final contact =
          pickedContact.phones.isNotEmpty
              ? pickedContact
              : await FlutterContacts.getContact(
                    pickedContact.id,
                    withProperties: true,
                    withPhoto: false,
                    withThumbnail: false,
                  ) ??
                  pickedContact;

      final normalizedPhone = contact.phones
          .map((entry) => entry.number)
          .map(_normalizeImportedPhone)
          .firstWhere(
            (value) => value.isNotEmpty && Validators.phone(value) == null,
            orElse: () => '',
          );

      final name = _extractImportedContactName(contact);

      final nameError = Validators.name(name);
      final phoneError = normalizedPhone.isEmpty ? 'У контакта нет корректного номера' : null;

      if (nameError != null || phoneError != null) {
        if (!mounted) return;

        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(nameError ?? phoneError!)));
        return;
      }

      if (!mounted) return;

      setState(() {
        _clientNameController.text = name;
        _clientPhoneController.text = _formatImportedPhone(normalizedPhone);
      });
    } on PlatformException catch (e, st) {
      debugPrint('Ошибка платформы при выборе контакта: ${e.code}');
      debugPrint('Message: ${e.message}');
      debugPrintStack(stackTrace: st);

      if (!mounted) return;

      final message = (e.message ?? '').toLowerCase();
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(
        SnackBar(
          content: Text(
            e.code.toLowerCase().contains('permission') ||
                    message.contains('permission')
                ? 'Нужен доступ к контактам, чтобы импортировать клиента'
                : 'Не удалось открыть контакты',
          ),
        ),
      );
    } catch (e, st) {
      debugPrint('Ошибка выбора контакта: $e');
      debugPrintStack(stackTrace: st);

      if (!mounted) return;

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Не удалось выбрать контакт')));
    }
  }

  String _normalizeImportedPhone(String value) {
    var digits = value.replaceAll(RegExp(r'\D'), '');

    if (digits.length == 11 && digits.startsWith('8')) {
      digits = '7${digits.substring(1)}';
    }

    if (digits.length == 10) {
      digits = '7$digits';
    }

    return digits;
  }

  String _extractImportedContactName(Contact contact) {
    final displayName = contact.displayName.trim();
    if (displayName.isNotEmpty) {
      return displayName;
    }

    final parts = [
      contact.name.first.trim(),
      contact.name.middle.trim(),
      contact.name.last.trim(),
    ].where((part) => part.isNotEmpty).toList();

    if (parts.isNotEmpty) {
      return parts.join(' ');
    }

    return '';
  }

  String _formatImportedPhone(String value) {
    final digits = value.replaceAll(RegExp(r'\D'), '');

    if (digits.length != 11 || !digits.startsWith('7')) {
      return value;
    }

    return '+7 (${digits.substring(1, 4)}) '
        '${digits.substring(4, 7)}-'
        '${digits.substring(7, 9)}-'
        '${digits.substring(9, 11)}';
  }

  @override
  Widget build(BuildContext context) {
    final activeLoans = widget.loans.where((loan) => loan.status == 'active').toList();
    final activeClientIds = activeLoans.map((loan) => loan.userId).toSet();

    final totalPortfolio = widget.loans.fold<double>(
      0,
      (portfolioSum, loan) => portfolioSum + loan.plannedTotalAmount,
    );
    final activePortfolio = activeLoans.fold<double>(
      0,
      (portfolioSum, loan) => portfolioSum + loan.plannedOutstandingAmount,
    );
    final totalPenalty = widget.loans.fold<double>(
      0,
      (penaltySum, loan) => penaltySum + loan.penaltyOutstanding,
    );
    final totalPenaltyPaid = widget.loans.fold<double>(
      0,
      (penaltySum, loan) => penaltySum + loan.penaltyPaid,
    );
    final totalPortfolioWithPenalty = Formatters.centsUp(
      totalPortfolio + totalPenalty + totalPenaltyPaid,
    );
    final receivedPortfolio = Formatters.centsUp(
      (totalPortfolioWithPenalty - activePortfolio).clamp(0, double.infinity),
    );
    final activePortfolioWithoutPenalty = activeLoans.fold<double>(
      0,
      (portfolioSum, loan) => portfolioSum + (loan.plannedTotalAmount - loan.plannedPaidAmount),
    );
    final receivedPortfolioWithoutPenalty = Formatters.centsUp(
      (totalPortfolio - activePortfolioWithoutPenalty).clamp(0, double.infinity),
    );
    final activePenalty = activeLoans.fold<double>(
      0,
      (penaltySum, loan) => penaltySum + loan.penaltyOutstanding,
    );
    final totalPotentialProfit = widget.loans.fold<double>(
      0,
      (profitSum, loan) =>
          profitSum +
          (loan.status == 'closed'
              ? (loan.interestPaid + loan.penaltyPaid)
              : (loan.plannedInterestAmount + loan.penaltyOutstanding + loan.penaltyPaid)),
    );
    final actualEarnedProfit = widget.loans.fold<double>(
      0,
      (profitSum, loan) => profitSum + loan.interestPaid + loan.penaltyPaid,
    );
    final remainingProfit = (totalPotentialProfit - actualEarnedProfit).clamp(0, double.infinity);
    final clientById = {for (final client in widget.clients) client.id: client};
    final plannedProfitByClient = <String, double>{};
    final receivedProfitByClient = <String, double>{};
    final remainingProfitByClient = <String, double>{};
    for (final loan in widget.loans) {
      final plannedProfit = loan.status == 'closed'
          ? (loan.interestPaid + loan.penaltyPaid)
          : (loan.plannedInterestAmount + loan.penaltyOutstanding + loan.penaltyPaid);
      final receivedProfit = loan.interestPaid + loan.penaltyPaid;
      final remainingClientProfit = math.max(plannedProfit - receivedProfit, 0).toDouble();

      plannedProfitByClient.update(
        loan.userId,
        (value) => value + plannedProfit,
        ifAbsent: () => plannedProfit,
      );
      receivedProfitByClient.update(
        loan.userId,
        (value) => value + receivedProfit,
        ifAbsent: () => receivedProfit,
      );
      remainingProfitByClient.update(
        loan.userId,
        (value) => value + remainingClientProfit,
        ifAbsent: () => remainingClientProfit,
      );
    }
    List<_ProfitBreakdownEntry> toEntries(Map<String, double> source) {
      final entries =
          source.entries
              .map(
                (entry) => _ProfitBreakdownEntry(
                  clientId: entry.key,
                  clientName: clientById[entry.key]?.name ?? 'Клиент',
                  clientPhone: clientById[entry.key]?.phone,
                  amount: Formatters.centsUp(entry.value).toDouble(),
                ),
              )
              .where((entry) => entry.amount > 0)
              .toList()
            ..sort((a, b) => b.amount.compareTo(a.amount));
      return entries;
    }

    final plannedProfitEntries = toEntries(plannedProfitByClient);
    final receivedProfitEntries = toEntries(receivedProfitByClient);
    final remainingProfitEntries = toEntries(remainingProfitByClient);

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Row(
          children: [
            Expanded(
              child: _AdminMetric(
                title: 'Клиентов',
                value: '',
                detail: '',
                icon: Icons.people_outline,
                onTap: _openDeleteClientsSheet,
                actionHint: 'Управление',
                detailWidget: _StackedMetricLegend(
                  items: [
                    _CompactMetricItem(
                      label: 'всего',
                      value: widget.clients.length.toString(),
                      color: Theme.of(context).colorScheme.secondary,
                    ),
                    _CompactMetricItem(
                      label: 'акт',
                      value: activeClientIds.length.toString(),
                      color: const Color(0xFFFFC26B),
                    ),
                    _CompactMetricItem(
                      label: 'арх',
                      value: (widget.clients.length - activeClientIds.length).toString(),
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _AdminMetric(
                title: 'Займы',
                value: '',
                detail: '',
                icon: Icons.receipt_long_outlined,
                detailWidget: _StackedMetricLegend(
                  items: [
                    _CompactMetricItem(
                      label: 'всего',
                      value: widget.loans.length.toString(),
                      color: Theme.of(context).colorScheme.secondary,
                    ),
                    _CompactMetricItem(
                      label: 'акт',
                      value: activeLoans.length.toString(),
                      color: const Color(0xFFFFC26B),
                    ),
                    _CompactMetricItem(
                      label: 'закр',
                      value: (widget.loans.length - activeLoans.length).toString(),
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _AdminMetric(
                title: 'Пени',
                value: '',
                detail: '',
                icon: Icons.warning_amber_rounded,
                detailWidget: _StackedMetricLegend(
                  items: [
                    _CompactMetricItem(
                      label: 'всего',
                      value: Formatters.money(totalPenalty),
                      color: Theme.of(context).colorScheme.secondary,
                    ),
                    _CompactMetricItem(
                      label: 'акт',
                      value: Formatters.money(activePenalty),
                      color: const Color(0xFFFFC26B),
                    ),
                    _CompactMetricItem(
                      label: 'опл',
                      value: Formatters.money(
                        widget.loans.fold<double>(0, (sum, loan) => sum + loan.penaltyPaid),
                      ),
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _FlippableAdminMetric(
                title: 'Портфель',
                icon: Icons.savings_outlined,
                isFlipped: _showPortfolioWithoutPenalty,
                onTap: () {
                  setState(() {
                    _showPortfolioWithoutPenalty = !_showPortfolioWithoutPenalty;
                  });
                },
                frontHint: 'С пенями',
                backHint: 'Без пени',
                frontItems: [
                  _CompactMetricItem(
                    label: 'всего',
                    value: Formatters.money(totalPortfolioWithPenalty),
                    color: Theme.of(context).colorScheme.secondary,
                  ),
                  _CompactMetricItem(
                    label: 'акт',
                    value: Formatters.money(activePortfolio),
                    color: const Color(0xFFFFC26B),
                  ),
                  _CompactMetricItem(
                    label: 'пол',
                    value: Formatters.money(receivedPortfolio),
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ],
                backItems: [
                  _CompactMetricItem(
                    label: 'всего',
                    value: Formatters.money(totalPortfolio),
                    color: Theme.of(context).colorScheme.secondary,
                  ),
                  _CompactMetricItem(
                    label: 'акт',
                    value: Formatters.money(activePortfolioWithoutPenalty),
                    color: const Color(0xFFFFC26B),
                  ),
                  _CompactMetricItem(
                    label: 'пол',
                    value: Formatters.money(receivedPortfolioWithoutPenalty),
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        _AdminMetric(
          title: 'Заработок',
          value: 'По плану ${Formatters.money(totalPotentialProfit)}',
          detail:
              'Получено ${Formatters.money(actualEarnedProfit)}\nОсталось получить ${Formatters.money(remainingProfit)}',
          icon: Icons.trending_up_rounded,
          onTap: () => _openProfitBreakdownSheet(
            plannedEntries: plannedProfitEntries,
            receivedEntries: receivedProfitEntries,
            remainingEntries: remainingProfitEntries,
          ),
          actionHint: 'Открыть по клиентам',
        ),
        const SizedBox(height: 20),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Создать клиента', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 16),
                OutlinedButton.icon(
                  onPressed: _pickClientFromContacts,
                  icon: const Icon(Icons.contact_phone_outlined),
                  label: const Text('Добавить из контактов'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _clientNameController,
                  decoration: const InputDecoration(
                    labelText: 'Имя клиента',
                    prefixIcon: Icon(Icons.person_add_alt_1_outlined),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _clientPhoneController,
                  keyboardType: TextInputType.phone,
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[\d\s()+-]')),
                    _phoneMaskFormatter,
                  ],
                  decoration: const InputDecoration(
                    labelText: 'Телефон',
                    prefixIcon: Icon(Icons.phone_outlined),
                  ),
                ),
                const SizedBox(height: 16),
                ElevatedButton.icon(
                  onPressed: () async {
                    final messenger = ScaffoldMessenger.of(context);
                    final nameError = Validators.name(_clientNameController.text);
                    final phoneError = Validators.phone(_clientPhoneController.text);
                    if (nameError != null || phoneError != null) {
                      messenger.showSnackBar(SnackBar(content: Text(nameError ?? phoneError!)));
                      return;
                    }
                    await widget.onCreateClient(
                      name: _clientNameController.text.trim(),
                      phone: _clientPhoneController.text.trim(),
                    );
                    if (!mounted) {
                      return;
                    }
                    _clientNameController.clear();
                    _clientPhoneController.clear();
                    messenger.showSnackBar(
                      const SnackBar(
                        content: Text('Клиент создан, пароль он задаст при первом входе'),
                      ),
                    );
                  },
                  icon: const Icon(Icons.person_add_outlined),
                  label: const Text('Добавить клиента'),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 20),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Реквизиты оплаты', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 16),
                TextField(
                  controller: _bankNameController,
                  decoration: const InputDecoration(
                    labelText: 'Название банка',
                    prefixIcon: Icon(Icons.account_balance_outlined),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _recipientNameController,
                  decoration: const InputDecoration(
                    labelText: 'Получатель',
                    prefixIcon: Icon(Icons.person_outline),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _recipientPhoneController,
                  decoration: const InputDecoration(
                    labelText: 'Телефон или реквизиты',
                    prefixIcon: Icon(Icons.credit_card_outlined),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _paymentLinkController,
                  decoration: const InputDecoration(
                    labelText: 'Ссылка для открытия банка или оплаты',
                    prefixIcon: Icon(Icons.open_in_new_rounded),
                  ),
                ),
                const SizedBox(height: 16),
                ElevatedButton.icon(
                  onPressed: _savePaymentSettings,
                  icon: const Icon(Icons.save_outlined),
                  label: const Text('Сохранить реквизиты'),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 20),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Управление займами', style: Theme.of(context).textTheme.titleLarge),
                          const SizedBox(height: 8),
                          const Text(
                            'Создавайте займы, редактируйте график, сумму возврата, процент и пеню',
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 16),
                    ElevatedButton.icon(
                      onPressed: () => _openLoanEditor(),
                      icon: const Icon(Icons.add_card_outlined),
                      label: const Text('Новый займ'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _openLoanEditor({Loan? existingLoan}) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      builder: (context) => LoanEditorSheet(
        clients: widget.clients,
        existingLoan: existingLoan,
        defaultSettings: widget.loanDefaults,
        onCreate: widget.onIssueLoan,
        onUpdate: widget.onUpdateLoan,
      ),
    );
  }
}

class _LoanPreviewCard extends StatelessWidget {
  const _LoanPreviewCard({
    required this.loan,
    required this.onEdit,
    required this.onClose,
    required this.onDelete,
  });

  final Loan loan;
  final VoidCallback onEdit;
  final VoidCallback onClose;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final isClosed = loan.status == 'closed';
    final statusColor = isClosed ? Theme.of(context).colorScheme.primary : const Color(0xFFFFC26B);
    final nextUnpaid = loan.nextUnpaid;
    final card = Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: isClosed
              ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.10)
              : const Color(0xFFFFC26B).withValues(alpha: 0.18),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _TagChip(label: isClosed ? 'Выплачен' : 'В процессе', color: statusColor),
              const Spacer(),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text('Плановый остаток', style: Theme.of(context).textTheme.bodySmall),
                  const SizedBox(height: 2),
                  Text(
                    Formatters.money(loan.plannedOutstandingAmount),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 12),
          _PreviewSection(
            title: 'Основные условия',
            children: [
              _PreviewRow(label: 'Сумма займа', value: Formatters.money(loan.principal)),
              _PreviewRow(label: 'Процент', value: '${loan.interestPercent.toStringAsFixed(2)}%'),
              _PreviewRow(
                label: 'К возврату по плану',
                value: Formatters.money(loan.plannedTotalAmount),
                emphasize: true,
              ),
              _PreviewRow(
                label: 'Пеня за день',
                value: Formatters.money(loan.dailyPenaltyAmount),
                valueColor: const Color(0xFFFFC26B),
              ),
              if (!isClosed)
                _PreviewRow(
                  label: 'Следующий платёж',
                  value: nextUnpaid == null
                      ? 'Все платежи закрыты'
                      : Formatters.date(nextUnpaid.dueDate),
                  allowMultilineValue: true,
                  stackWhenNarrow: true,
                ),
            ],
          ),
          const SizedBox(height: 12),
          _PreviewSection(
            title: 'Возврат и начисления',
            accentColor: isClosed ? null : const Color(0xFFFFC26B),
            children: [
              _PreviewRow(
                label: 'Сейчас к закрытию',
                value: Formatters.money(loan.fullCloseAmount),
                emphasize: true,
              ),
              _PreviewRow(label: 'Уплачено всего', value: Formatters.money(loan.paidAmount)),
              _PreviewRow(label: 'Уплачено процентов', value: Formatters.money(loan.interestPaid)),
              _PreviewRow(
                label: 'Пени сейчас',
                value: Formatters.money(loan.penaltyOutstanding),
                valueColor: const Color(0xFFFFC26B),
              ),
              _PreviewRow(
                label: 'Пени всего',
                value: Formatters.money(loan.penaltyOutstanding + loan.penaltyPaid),
                valueColor: const Color(0xFFFFC26B),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: _LoanActionButton(
                      icon: Icons.calendar_view_month_rounded,
                      label: 'График',
                      onPressed: () => _showAdminScheduleSheet(context, loan),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _LoanActionButton(
                      icon: Icons.edit_outlined,
                      label: 'Ред. займ',
                      onPressed: onEdit,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: _LoanActionButton(
                      icon: isClosed
                          ? Icons.delete_outline_rounded
                          : Icons.task_alt_outlined,
                      label: isClosed ? 'Удалить' : 'Погасить',
                      onPressed: isClosed ? onDelete : onClose,
                      danger: isClosed ? true : false,
                    ),
                  ),
                  if (!isClosed) ...[
                    const SizedBox(width: 12),
                    Expanded(
                      child: _LoanActionButton(
                        icon: Icons.delete_outline_rounded,
                        label: 'Удалить',
                        onPressed: onDelete,
                        danger: true,
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ],
      ),
    );

    if (!Platform.isWindows) {
      return card;
    }

    return RepaintBoundary(child: card);
  }
}

class _LoanActionButton extends StatelessWidget {
  const _LoanActionButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.danger = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final foreground = danger ? const Color(0xFFFF8A80) : null;
    final side = danger ? const BorderSide(color: Color(0x33FF8A80)) : null;
    return OutlinedButton.icon(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        foregroundColor: foreground,
        side: side,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
      ),
      icon: Icon(icon, size: 18),
      label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
    );
  }
}

Future<void> _showAdminScheduleSheet(BuildContext context, Loan loan) async {
  final orderedSchedule = loan.orderedSchedule;
  final firstDate = orderedSchedule.isEmpty ? loan.issuedAt : orderedSchedule.first.dueDate;
  final lastDate = orderedSchedule.isEmpty ? loan.issuedAt : orderedSchedule.last.dueDate;
  final paidDates =
      orderedSchedule.where((item) => item.paidAt != null).map((item) => item.paidAt!).toList()
        ..sort();
  final actualStartDate = paidDates.isEmpty ? loan.issuedAt : paidDates.first;
  final actualEndDate = paidDates.isEmpty ? loan.issuedAt : paidDates.last;

  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: Theme.of(context).scaffoldBackgroundColor,
    builder: (sheetContext) => FractionallySizedBox(
      heightFactor: 0.88,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('График платежей', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 6),
              Text(
                'Выдан ${Formatters.dateTime(loan.issuedAt)}\n'
                'Срок займа: с ${Formatters.date(firstDate)} по ${Formatters.date(lastDate)}\n'
                'Факт. выплата: с ${Formatters.date(actualStartDate)} по ${Formatters.date(actualEndDate)}',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 16),
              Expanded(
                child: orderedSchedule.isEmpty
                    ? Center(
                        child: Text(
                          'График пока пуст',
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      )
                    : ListView.separated(
                        itemCount: orderedSchedule.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 12),
                        itemBuilder: (context, index) {
                          final item = orderedSchedule[index];
                          return _AdminScheduleCard(loan: loan, item: item, index: index);
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _AdminScheduleCard extends StatelessWidget {
  const _AdminScheduleCard({required this.loan, required this.item, required this.index});

  final Loan loan;
  final PaymentScheduleItem item;
  final int index;

  @override
  Widget build(BuildContext context) {
    final isDueToday = loan.isItemDueToday(item);
    final isOverdue = loan.isItemOverdue(item);
    final penalty = item.isPaid ? item.penaltyAccrued : loan.penaltyForItem(item);
    final interest = loan.interestForItem(item);
    final totalAmount = loan.amountForItem(item);
    final accentColor = item.isPaid
        ? Theme.of(context).colorScheme.primary
        : isOverdue
        ? const Color(0xFFFFC26B)
        : isDueToday
        ? const Color(0xFF8BC4FF)
        : Theme.of(context).colorScheme.secondary;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          Positioned(
            top: 0,
            left: 0,
            child: Container(
              width: 34,
              height: 24,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: accentColor.withValues(alpha: 0.14),
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(12),
                  bottomRight: Radius.circular(16),
                ),
              ),
              child: Text(
                '${index + 1}',
                style: Theme.of(
                  context,
                ).textTheme.labelMedium?.copyWith(color: accentColor, fontWeight: FontWeight.w800),
              ),
            ),
          ),
          ListTile(
            contentPadding: const EdgeInsets.fromLTRB(18, 10, 18, 8),
            leading: CircleAvatar(
              backgroundColor: accentColor.withValues(alpha: 0.18),
              child: Icon(
                item.isPaid ? Icons.check_rounded : Icons.calendar_month_outlined,
                color: accentColor,
              ),
            ),
            title: Text(Formatters.money(totalAmount)),
            subtitle: Text(
              item.isPaid
                  ? 'Срок: ${Formatters.date(item.dueDate)}\n'
                        'Оплачен ${item.paidAt == null ? '' : Formatters.date(item.paidAt!)}\n'
                        'Процент: ${Formatters.money(interest)}\n'
                        'Пеня: ${Formatters.money(item.penaltyAccrued)}'
                  : 'Срок: ${Formatters.date(item.dueDate)}\n'
                        'Процент: ${Formatters.money(interest)}\n'
                        'Пеня: ${Formatters.money(penalty)}',
            ),
            isThreeLine: false,
            trailing: Text(
              item.isPaid
                  ? 'Оплачен'
                  : isOverdue
                  ? 'Просрочен'
                  : isDueToday
                  ? 'Сегодня'
                  : 'Ожидается',
              style: TextStyle(color: accentColor, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

class LoanEditorSheet extends StatefulWidget {
  const LoanEditorSheet({
    super.key,
    required this.clients,
    required this.defaultSettings,
    required this.onCreate,
    required this.onUpdate,
    this.existingLoan,
  });

  final List<AppUser> clients;
  final LoanDefaultsSettings defaultSettings;
  final Loan? existingLoan;
  final Future<void> Function({
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
  })
  onCreate;
  final Future<void> Function(Loan loan) onUpdate;

  @override
  State<LoanEditorSheet> createState() => _LoanEditorSheetState();
}

class _LoanEditorSheetState extends State<LoanEditorSheet> {
  final _principalController = TextEditingController();
  final _percentController = TextEditingController();
  final _totalController = TextEditingController();
  final _dailyPenaltyController = TextEditingController();
  final _monthsController = TextEditingController();
  final _intervalCountController = TextEditingController();
  final _titleController = TextEditingController();
  final _noteController = TextEditingController();

  String? _selectedClientId;
  late DateTime _issuedAt;
  bool _isSyncing = false;
  late final PageController _pageController;
  late List<_EditableScheduleRow> _scheduleRows;
  _PaymentIntervalUnit _intervalUnit = _PaymentIntervalUnit.months;
  int _currentPage = 0;
  bool _showDetailedSchedule = false;

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
    _scheduleRows = [];
    _setupInitialState();
  }

  @override
  void dispose() {
    _pageController.dispose();
    _principalController.dispose();
    _percentController.dispose();
    _totalController.dispose();
    _dailyPenaltyController.dispose();
    _monthsController.dispose();
    _intervalCountController.dispose();
    _titleController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  void _setupInitialState() {
    final loan = widget.existingLoan;
    if (loan != null) {
      _issuedAt = loan.issuedAt;
      _selectedClientId = loan.userId;
      _principalController.text = Formatters.decimalInput(loan.principal);
      _percentController.text = Formatters.decimalInputPrecise(loan.interestPercent);
      _totalController.text = Formatters.decimalInput(loan.plannedTotalAmount);
      _dailyPenaltyController.text = Formatters.decimalInput(loan.dailyPenaltyAmount);
      _titleController.text = loan.displayTitle;
      _monthsController.text = loan.schedule.length.toString();
      if (loan.paymentIntervalCount > 0 && loan.paymentIntervalUnit.isNotEmpty) {
        _intervalCountController.text = loan.paymentIntervalCount.toString();
        _intervalUnit = _PaymentIntervalUnitX.fromStorage(loan.paymentIntervalUnit);
      } else {
        final inferredInterval = _inferInterval(loan);
        _intervalCountController.text = inferredInterval.count.toString();
        _intervalUnit = inferredInterval.unit;
      }
      _noteController.text = loan.note ?? '';
      _scheduleRows = loan.schedule
          .map(
            (item) => _EditableScheduleRow.fromItem(
              item,
              initialAmount: loan.principalAmountForItem(item),
            ),
          )
          .toList();
      _rebuildSchedule();
      return;
    }

    _issuedAt = AppClock.now();
    _selectedClientId = widget.clients.isNotEmpty ? widget.clients.first.id : null;
    _principalController.text = Formatters.decimalInput(widget.defaultSettings.principal);
    _percentController.text = Formatters.decimalInputPrecise(
      widget.defaultSettings.interestPercent,
    );
    _totalController.text = Formatters.decimalInput(0);
    _dailyPenaltyController.text = Formatters.decimalInput(
      widget.defaultSettings.dailyPenaltyAmount,
    );
    _titleController.text = _defaultLoanTitle();
    _monthsController.text = widget.defaultSettings.paymentCount.toString();
    _intervalCountController.text = widget.defaultSettings.paymentIntervalCount.toString();
    _intervalUnit = _PaymentIntervalUnitX.fromStorage(widget.defaultSettings.paymentIntervalUnit);
    _generateSchedule();
  }

  _PaymentIntervalValue _inferInterval(Loan loan) {
    if (loan.schedule.isEmpty) {
      return const _PaymentIntervalValue(1, _PaymentIntervalUnit.months);
    }

    final sorted = [...loan.schedule]..sort((a, b) => a.dueDate.compareTo(b.dueDate));
    int days;
    if (sorted.length == 1) {
      final issuedAt = loan.issuedAt;
      final dueDate = sorted.first.dueDate;
      days = dueDate.difference(issuedAt).inDays;
    } else {
      days = sorted[1].dueDate.difference(sorted[0].dueDate).inDays;
    }

    if (days <= 0) {
      return const _PaymentIntervalValue(1, _PaymentIntervalUnit.months);
    }
    if (days % 30 == 0) {
      return _PaymentIntervalValue(days ~/ 30, _PaymentIntervalUnit.months);
    }
    if (days % 7 == 0) {
      return _PaymentIntervalValue(days ~/ 7, _PaymentIntervalUnit.weeks);
    }
    return _PaymentIntervalValue(days, _PaymentIntervalUnit.days);
  }

  int get _intervalCount {
    final parsed = int.tryParse(_intervalCountController.text) ?? 1;
    return parsed <= 0 ? 1 : parsed;
  }

  DateTime _advanceByInterval(DateTime base, int multiplier) {
    final step = _intervalCount * multiplier;
    switch (_intervalUnit) {
      case _PaymentIntervalUnit.days:
        return base.add(Duration(days: step));
      case _PaymentIntervalUnit.weeks:
        return base.add(Duration(days: step * 7));
      case _PaymentIntervalUnit.months:
        final monthIndex = base.month - 1 + step;
        final year = base.year + (monthIndex ~/ 12);
        final month = (monthIndex % 12) + 1;
        final day = base.day.clamp(1, _daysInMonth(year, month));
        return DateTime(
          year,
          month,
          day,
          base.hour,
          base.minute,
          base.second,
          base.millisecond,
          base.microsecond,
        );
    }
  }

  int _daysInMonth(int year, int month) {
    final nextMonth = month == 12 ? DateTime(year + 1, 1, 1) : DateTime(year, month + 1, 1);
    return nextMonth.subtract(const Duration(days: 1)).day;
  }

  void _refreshTotalText() {
    if (_isSyncing) {
      return;
    }
    _isSyncing = true;
    _totalController.text = Formatters.decimalInput(_editorTotal);
    _isSyncing = false;
  }

  String _defaultLoanTitle() {
    final date = _issuedAt;
    final day = date.day.toString().padLeft(2, '0');
    final month = date.month.toString().padLeft(2, '0');
    final year = date.year.toString();
    return 'Займ $day.$month.$year';
  }

  double get _editorPrincipal => Formatters.parseDecimal(_principalController.text);

  double get _editorPercent => Formatters.parseDecimal(_percentController.text);

  double get _editorTotal {
    final preview = _editorPlannedPreviewLoan;
    return preview.plannedTotalAmount;
  }

  double get _editorPlannedInterest => _buildEditorPreviewLoan().plannedInterestAmount;

  int get _editorTermDays {
    if (_scheduleRows.isEmpty) {
      return 1;
    }
    final issuedAt = _issuedAt;
    final lastDueDate = [..._scheduleRows]..sort((a, b) => a.dueDate.compareTo(b.dueDate));
    final days = lastDueDate.last.dueDate.difference(issuedAt).inDays;
    return days <= 0 ? 1 : days;
  }

  Loan _buildEditorPreviewLoan({List<_EditableScheduleRow>? rows, bool plannedOnly = false}) {
    final effectiveRows = rows ?? _scheduleRows;
    final draftSchedule = effectiveRows
        .map(
          (row) => PaymentScheduleItem(
            id: row.id,
            dueDate: AppClock.fromMoscowWallClock(row.dueDate),
            amount: 0,
            principalAmount: Formatters.cents(row.amount),
            isPaid: plannedOnly ? false : row.isPaid,
            penaltyAccrued: plannedOnly ? 0 : row.penaltyAccrued,
            interestAccruedPaid: plannedOnly ? 0 : row.interestAccruedPaid,
            paidAt: plannedOnly
                ? null
                : (row.paidAt == null ? null : AppClock.fromMoscowWallClock(row.paidAt!)),
          ),
        )
        .toList();
    final preview = Loan(
      id: widget.existingLoan?.id ?? 'editor-preview',
      userId: _selectedClientId ?? '',
      title: _titleController.text.trim(),
      principal: _editorPrincipal,
      interestPercent: _editorPercent,
      totalAmount: 0,
      dailyPenaltyAmount: Formatters.parseDecimal(_dailyPenaltyController.text),
      issuedAt: AppClock.fromMoscowWallClock(_issuedAt),
      schedule: draftSchedule,
      status: effectiveRows.every((item) => item.isPaid) ? 'closed' : 'active',
      paymentIntervalCount: _intervalCount,
      paymentIntervalUnit: _intervalUnit.storageValue,
      note: _noteController.text.trim().isEmpty ? null : _noteController.text.trim(),
    );
    final hydratedSchedule = preview.orderedSchedule
        .map((item) => item.copyWith(amount: preview.amountForItem(item)))
        .toList();
    final hydratedPreview = preview.copyWith(schedule: hydratedSchedule);
    return hydratedPreview.copyWith(totalAmount: hydratedPreview.plannedTotalAmount);
  }

  Loan get _editorPlannedPreviewLoan => _buildEditorPreviewLoan(plannedOnly: true);

  Future<void> _goToPage(int page) async {
    if (!_pageController.hasClients) {
      return;
    }
    await _pageController.animateToPage(
      page,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
  }

  void _generateSchedule() {
    _rebuildSchedule();
  }

  void _handlePercentChanged() {
    if (_isSyncing) {
      return;
    }
    setState(() {
      _rebuildSchedule();
    });
  }

  void _rebuildSchedule() {
    final months = int.tryParse(_monthsController.text) ?? 1;
    final safeMonths = months <= 0 ? 1 : months;
    final previousRows = List<_EditableScheduleRow>.from(_scheduleRows);
    final nextRows = <_EditableScheduleRow>[];

    final baseDate = _issuedAt;

    for (var index = 0; index < safeMonths; index++) {
      final previous = index < previousRows.length ? previousRows[index] : null;
      nextRows.add(
        _EditableScheduleRow(
          id: previous?.id ?? 'row-$index-$baseDate.microsecondsSinceEpoch',
          dueDate: _advanceByInterval(baseDate, index + 1),
          amount: previous?.amount ?? 0,
          isPaid: previous?.isPaid ?? false,
          penaltyAccrued: previous?.penaltyAccrued ?? 0,
          interestAccruedPaid: previous?.interestAccruedPaid ?? 0,
          paidAt: previous?.paidAt,
        ),
      );
    }

    _scheduleRows = nextRows;
    final preview = _buildEditorPreviewLoan(plannedOnly: true);
    _scheduleRows = _scheduleRows.map((row) {
      final item = preview.orderedSchedule.firstWhere((scheduleItem) => scheduleItem.id == row.id);
      row.amount = preview.principalAmountForItem(item);
      return row;
    }).toList();
    _refreshTotalText();
  }

  void _setPaidFromIndex(int index, bool isPaid) {
    _setPaidFromIndexWithDate(index, isPaid, paidAt: AppClock.now());
  }

  void _setPaidFromIndexWithDate(int index, bool isPaid, {required DateTime paidAt}) {
    final previewLoan = _editorPlannedPreviewLoan;
    for (var itemIndex = 0; itemIndex < _scheduleRows.length; itemIndex++) {
      final row = _scheduleRows[itemIndex];
      if (isPaid) {
        if (itemIndex <= index) {
          if (!row.isPaid) {
            final item = previewLoan.orderedSchedule.firstWhere(
              (scheduleItem) => scheduleItem.id == row.id,
            );
            row.interestAccruedPaid = previewLoan.plannedInterestForItem(item);
            row.penaltyAccrued = previewLoan.penaltyForItem(item, at: paidAt);
          }
          row.isPaid = true;
          row.paidAt = paidAt;
        }
        continue;
      }

      if (itemIndex >= index) {
        row.isPaid = false;
        row.paidAt = null;
        row.interestAccruedPaid = 0;
        row.penaltyAccrued = 0;
      }
    }
  }

  void _applyDueDatesToPaidRows() {
    final previewLoan = _editorPlannedPreviewLoan;
    final previewItemsById = {
      for (final item in previewLoan.orderedSchedule) item.id: item,
    };

    setState(() {
      for (final row in _scheduleRows) {
        if (!row.isPaid) {
          continue;
        }
        final previewItem = previewItemsById[row.id];
        row.paidAt = row.dueDate;
        row.penaltyAccrued = 0;
        row.interestAccruedPaid = previewItem == null
            ? 0
            : previewLoan.plannedInterestForItem(previewItem);
      }
    });
  }

  void _applyPlannedFullClose() {
    final previewLoan = _editorPlannedPreviewLoan;
    final previewItemsById = {
      for (final item in previewLoan.orderedSchedule) item.id: item,
    };

    setState(() {
      for (final row in _scheduleRows) {
        final previewItem = previewItemsById[row.id];
        row.isPaid = true;
        row.paidAt = row.dueDate;
        row.penaltyAccrued = 0;
        row.interestAccruedPaid = previewItem == null
            ? 0
            : previewLoan.plannedInterestForItem(previewItem);
      }
    });
  }

  Future<void> _openScheduleApplyDialog() async {
    final action = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Проставить'),
        content: const Text(
          'Выберите, что именно нужно проставить по плановому графику.',
        ),
        actions: [
          OutlinedButton(
            onPressed: () => Navigator.of(dialogContext).pop('closed_dates'),
            child: const Text('Плановые даты в закрытые'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop('full_close'),
            child: const Text('Полное плановое погашение'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Отмена'),
          ),
        ],
      ),
    );

    if (action == 'closed_dates') {
      _applyDueDatesToPaidRows();
    } else if (action == 'full_close') {
      _applyPlannedFullClose();
    }
  }

  Future<void> _pickIssuedAt() async {
    final pickedDate = await showDatePicker(
      context: context,
      initialDate: _issuedAt,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
      locale: const Locale('ru', 'RU'),
    );
    if (pickedDate == null || !mounted) {
      return;
    }

    final previousDefaultTitle = _defaultLoanTitle();
    setState(() {
      _issuedAt = DateTime(
        pickedDate.year,
        pickedDate.month,
        pickedDate.day,
        _issuedAt.hour,
        _issuedAt.minute,
        _issuedAt.second,
        _issuedAt.millisecond,
        _issuedAt.microsecond,
      );
      final currentTitle = _titleController.text.trim();
      if (currentTitle.isEmpty || currentTitle == previousDefaultTitle) {
        _titleController.text = _defaultLoanTitle();
      }
      _rebuildSchedule();
    });
  }

  Future<void> _pickPaymentDate(int index, {required bool markPaid}) async {
    final row = _scheduleRows[index];
    final initialDate = markPaid ? AppClock.now() : (row.paidAt ?? row.dueDate);
    final firstDate = _issuedAt;
    final pickedDate = await showDatePicker(
      context: context,
      initialDate: initialDate,
      firstDate: DateTime(firstDate.year, firstDate.month, firstDate.day),
      lastDate: DateTime(2100),
      locale: const Locale('ru', 'RU'),
    );
    if (pickedDate == null || !mounted) {
      return;
    }
    setState(() {
      if (markPaid) {
        _setPaidFromIndexWithDate(index, true, paidAt: pickedDate);
      } else {
        _scheduleRows[index].paidAt = pickedDate;
      }
    });
  }

  Future<void> _save() async {
    final messenger = ScaffoldMessenger.of(context);
    if (_selectedClientId == null) {
      messenger.showSnackBar(const SnackBar(content: Text('Выберите клиента')));
      return;
    }

    final principal = Formatters.parseDecimal(_principalController.text);
    final dailyPenalty = Formatters.parseDecimal(_dailyPenaltyController.text);
    if (principal <= 0) {
      messenger.showSnackBar(const SnackBar(content: Text('Сумма займа должна быть больше нуля')));
      return;
    }
    if (_scheduleRows.isEmpty) {
      messenger.showSnackBar(const SnackBar(content: Text('Добавьте хотя бы один платёж')));
      return;
    }
    final previewLoan = _buildEditorPreviewLoan();
    final schedule = <PaymentScheduleItem>[];
    for (final row in _scheduleRows) {
      final previewItem = previewLoan.orderedSchedule.firstWhere((item) => item.id == row.id);
      final amount = previewLoan.principalAmountForItem(previewItem);
      if (amount <= 0) {
        messenger.showSnackBar(
          const SnackBar(content: Text('Сумма каждого платежа должна быть больше нуля')),
        );
        return;
      }
      schedule.add(
        PaymentScheduleItem(
          id: row.id,
          dueDate: AppClock.fromMoscowWallClock(row.dueDate),
          amount: row.isPaid
              ? Formatters.centsUp(amount + row.interestAccruedPaid + row.penaltyAccrued)
              : previewLoan.amountForItem(previewItem),
          principalAmount: Formatters.cents(amount),
          isPaid: row.isPaid,
          penaltyAccrued: row.penaltyAccrued,
          interestAccruedPaid: row.interestAccruedPaid,
          paidAt: row.isPaid
              ? AppClock.fromMoscowWallClock(row.paidAt ?? AppClock.now())
              : null,
        ),
      );
    }

    final total = _editorTotal;
    final percent = _editorPercent;

    if (widget.existingLoan == null) {
      await widget.onCreate(
        userId: _selectedClientId!,
        title: _titleController.text.trim().isEmpty
            ? _defaultLoanTitle()
            : _titleController.text.trim(),
        principal: principal,
        interestPercent: percent,
        totalAmount: total,
        dailyPenaltyAmount: dailyPenalty,
        issuedAt: AppClock.fromMoscowWallClock(_issuedAt),
        schedule: schedule,
        paymentIntervalCount: _intervalCount,
        paymentIntervalUnit: _intervalUnit.storageValue,
        note: _noteController.text.trim(),
      );
    } else {
      await widget.onUpdate(
        widget.existingLoan!.copyWith(
          userId: _selectedClientId,
          title: _titleController.text.trim().isEmpty
              ? _defaultLoanTitle()
              : _titleController.text.trim(),
          principal: principal,
          interestPercent: percent,
          totalAmount: total,
          dailyPenaltyAmount: dailyPenalty,
          issuedAt: AppClock.fromMoscowWallClock(_issuedAt),
          schedule: schedule,
          paymentIntervalCount: _intervalCount,
          paymentIntervalUnit: _intervalUnit.storageValue,
          note: _noteController.text.trim(),
          status: schedule.every((item) => item.isPaid) ? 'closed' : 'active',
        ),
      );
    }

    if (!mounted) {
      return;
    }
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: 12,
          bottom: mediaQuery.viewInsets.bottom + 20,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.existingLoan == null ? 'Новый займ' : 'Редактирование займа',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 16),
            Expanded(
              child: AdNavigationShortcuts(
                onPrevious: () => _goToPage(_currentPage - 1),
                onNext: () => _goToPage(_currentPage + 1),
                canNavigatePrevious: _currentPage > 0,
                canNavigateNext: _currentPage < 1,
                child: PageView(
                  controller: _pageController,
                  onPageChanged: (page) => setState(() => _currentPage = page),
                  children: [
                  SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Card(
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Основные условия',
                                  style: Theme.of(context).textTheme.titleMedium,
                                ),
                                const SizedBox(height: 12),
                                TextField(
                                  controller: _titleController,
                                  decoration: const InputDecoration(
                                    labelText: 'Наименование займа',
                                    prefixIcon: Icon(Icons.title_rounded),
                                  ),
                                ),
                                const SizedBox(height: 12),
                                InkWell(
                                  onTap: _pickIssuedAt,
                                  borderRadius: BorderRadius.circular(16),
                                  child: InputDecorator(
                                    decoration: const InputDecoration(
                                      labelText: 'Дата выдачи',
                                      prefixIcon: Icon(Icons.event_available_outlined),
                                    ),
                                    child: Text(
                                      Formatters.date(_issuedAt),
                                      style: Theme.of(context).textTheme.bodyLarge,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 12),
                                DropdownButtonFormField<String>(
                                  initialValue: _selectedClientId,
                                  decoration: const InputDecoration(
                                    labelText: 'Клиент',
                                    prefixIcon: Icon(Icons.badge_outlined),
                                  ),
                                  items: widget.clients
                                      .map(
                                        (client) => DropdownMenuItem(
                                          value: client.id,
                                          child: Text(
                                            '${client.name} • ${Formatters.phone(client.phone)}',
                                          ),
                                        ),
                                      )
                                      .toList(),
                                  onChanged: (value) => setState(() => _selectedClientId = value),
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
                                  onChanged: (_) => setState(() {
                                    _rebuildSchedule();
                                  }),
                                ),
                                const SizedBox(height: 12),
                                Row(
                                  children: [
                                    Expanded(
                                      child: TextField(
                                        controller: _percentController,
                                        keyboardType: const TextInputType.numberWithOptions(
                                          decimal: true,
                                        ),
                                        decoration: const InputDecoration(
                                          labelText: 'Процент',
                                          prefixIcon: Icon(Icons.percent_outlined),
                                        ),
                                        onChanged: (_) => _handlePercentChanged(),
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: TextField(
                                        controller: _totalController,
                                        readOnly: true,
                                        decoration: const InputDecoration(
                                          labelText: 'К возврату',
                                          prefixIcon: Icon(Icons.price_change_outlined),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 12),
                                Row(
                                  children: [
                                    Expanded(
                                      child: TextField(
                                        controller: _dailyPenaltyController,
                                        keyboardType: const TextInputType.numberWithOptions(
                                          decimal: true,
                                        ),
                                        decoration: const InputDecoration(
                                          labelText: 'Пеня за день',
                                          prefixIcon: Icon(Icons.warning_amber_rounded),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: TextField(
                                        controller: _monthsController,
                                        keyboardType: TextInputType.number,
                                        decoration: const InputDecoration(
                                          labelText: 'Платежей',
                                          prefixIcon: Icon(Icons.timeline_outlined),
                                        ),
                                        onChanged: (_) => setState(_rebuildSchedule),
                                      ),
                                    ),
                                  ],
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
                                        onChanged: (_) => setState(_rebuildSchedule),
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: DropdownButtonFormField<_PaymentIntervalUnit>(
                                        initialValue: _intervalUnit,
                                        items: _PaymentIntervalUnit.values
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
                                            _rebuildSchedule();
                                          });
                                        },
                                        decoration: const InputDecoration(
                                          labelText: 'Интервал',
                                          prefixIcon: Icon(Icons.date_range_outlined),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 12),
                                TextField(
                                  controller: _noteController,
                                  minLines: 1,
                                  maxLines: 3,
                                  decoration: const InputDecoration(
                                    labelText: 'Комментарий',
                                    prefixIcon: Icon(Icons.sticky_note_2_outlined),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                        Card(
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Сводка расчёта',
                                  style: Theme.of(context).textTheme.titleMedium,
                                ),
                                const SizedBox(height: 12),
                                _PreviewRow(
                                  label: 'Плановая переплата',
                                  value: Formatters.money(_editorPlannedInterest),
                                ),
                                _PreviewRow(label: 'Срок в днях', value: '$_editorTermDays'),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'График платежей',
                                  style: Theme.of(context).textTheme.titleLarge,
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  'Сформирован автоматически по основным условиям',
                                  style: Theme.of(context).textTheme.bodyMedium,
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 12),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text('Подробно', style: Theme.of(context).textTheme.bodySmall),
                              Switch.adaptive(
                                value: _showDetailedSchedule,
                                onChanged: (value) => setState(() => _showDetailedSchedule = value),
                              ),
                            ],
                          ),
                        ],
                      ),
                      if (_showDetailedSchedule) ...[
                        const SizedBox(height: 8),
                        Align(
                          alignment: Alignment.centerRight,
                          child: OutlinedButton.icon(
                            onPressed: _scheduleRows.isNotEmpty
                                ? _openScheduleApplyDialog
                                : null,
                            icon: const Icon(Icons.event_available_outlined),
                            label: const Text('Проставить'),
                          ),
                        ),
                      ],
                      const SizedBox(height: 16),
                      Expanded(
                        child: _scheduleRows.isEmpty
                            ? Center(
                                child: Text(
                                  'График пока пуст',
                                  style: Theme.of(context).textTheme.bodyMedium,
                                ),
                              )
                            : ListView.separated(
                                itemCount: _scheduleRows.length,
                                separatorBuilder: (_, _) => const SizedBox(height: 12),
                                itemBuilder: (context, index) {
                                  final row = _scheduleRows[index];
                                  return _EditorScheduleCard(
                                    loan: _editorPlannedPreviewLoan,
                                    row: row,
                                    index: index,
                                    showDetails: _showDetailedSchedule,
                                    onChanged: (value) async {
                                      if (value) {
                                        if (_showDetailedSchedule) {
                                          setState(() {
                                            _setPaidFromIndex(index, true);
                                          });
                                        } else {
                                          await _pickPaymentDate(index, markPaid: true);
                                        }
                                        return;
                                      }
                                      setState(() {
                                        _setPaidFromIndex(index, false);
                                      });
                                    },
                                    onEditPaidDate: row.isPaid
                                        ? () => _pickPaymentDate(index, markPaid: false)
                                        : null,
                                  );
                                },
                              ),
                      ),
                    ],
                  ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                IconButton(
                  onPressed: _currentPage == 0 ? null : () => _goToPage(0),
                  icon: const Icon(Icons.chevron_left_rounded),
                ),
                Expanded(
                  child: Column(
                    children: [
                      Text('${_currentPage + 1} / 2', style: Theme.of(context).textTheme.bodySmall),
                      const SizedBox(height: 6),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: List.generate(2, (index) {
                          final isActive = index == _currentPage;
                          return Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 180),
                              width: isActive ? 22 : 8,
                              height: 8,
                              decoration: BoxDecoration(
                                color: isActive
                                    ? Theme.of(context).colorScheme.secondary
                                    : Theme.of(
                                        context,
                                      ).colorScheme.secondary.withValues(alpha: 0.28),
                                borderRadius: BorderRadius.circular(999),
                              ),
                            ),
                          );
                        }),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: _currentPage == 1 ? null : () => _goToPage(1),
                  icon: const Icon(Icons.chevron_right_rounded),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _save,
                icon: const Icon(Icons.save_outlined),
                label: Text(widget.existingLoan == null ? 'Сохранить займ' : 'Сохранить изменения'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EditableScheduleRow {
  _EditableScheduleRow({
    required this.id,
    required this.dueDate,
    required this.amount,
    this.isPaid = false,
    this.penaltyAccrued = 0,
    this.interestAccruedPaid = 0,
    this.paidAt,
  });

  factory _EditableScheduleRow.fromItem(PaymentScheduleItem item, {required double initialAmount}) {
    return _EditableScheduleRow(
      id: item.id,
      dueDate: item.dueDate,
      amount: initialAmount,
      isPaid: item.isPaid,
      penaltyAccrued: item.penaltyAccrued,
      interestAccruedPaid: item.interestAccruedPaid,
      paidAt: item.paidAt,
    );
  }

  final String id;
  DateTime dueDate;
  double amount;
  bool isPaid;
  double penaltyAccrued;
  double interestAccruedPaid;
  DateTime? paidAt;
}

class _EditorScheduleCard extends StatelessWidget {
  const _EditorScheduleCard({
    required this.loan,
    required this.row,
    required this.index,
    required this.showDetails,
    required this.onChanged,
    required this.onEditPaidDate,
  });

  final Loan loan;
  final _EditableScheduleRow row;
  final int index;
  final bool showDetails;
  final Future<void> Function(bool value) onChanged;
  final Future<void> Function()? onEditPaidDate;

  @override
  Widget build(BuildContext context) {
    final item = loan.orderedSchedule.firstWhere((scheduleItem) => scheduleItem.id == row.id);
    final accentColor = row.isPaid
        ? Theme.of(context).colorScheme.primary
        : Theme.of(context).colorScheme.secondary;
    final principal = loan.principalAmountForItem(item);
    final interest = loan.plannedInterestForItem(item);
    final amountWithInterest = loan.plannedAmountForItem(item);
    final statusLabel = row.isPaid ? 'Оплачен' : 'Ожидается';

    return Card(
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: Stack(
        children: [
          Positioned(
            top: 0,
            left: 0,
            child: Container(
              width: 34,
              height: 24,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: accentColor.withValues(alpha: 0.14),
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(24),
                  bottomRight: Radius.circular(16),
                ),
              ),
              child: Text(
                '${index + 1}',
                style: Theme.of(
                  context,
                ).textTheme.labelMedium?.copyWith(color: accentColor, fontWeight: FontWeight.w800),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    CircleAvatar(
                      radius: 20,
                      backgroundColor: accentColor.withValues(alpha: 0.18),
                      child: Icon(
                        row.isPaid ? Icons.check_rounded : Icons.calendar_month_outlined,
                        color: accentColor,
                        size: 20,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      Formatters.money(amountWithInterest),
                                      style: Theme.of(context).textTheme.titleMedium,
                                    ),
                                    if (showDetails) ...[
                                      const SizedBox(height: 2),
                                      Text(
                                        'Тело: ${Formatters.money(principal)}',
                                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                          fontWeight: FontWeight.w700,
                                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                              if (showDetails)
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                                  decoration: BoxDecoration(
                                    color: accentColor.withValues(alpha: 0.14),
                                    borderRadius: BorderRadius.circular(999),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(Icons.percent_rounded, size: 14, color: accentColor),
                                      const SizedBox(width: 4),
                                      Text(
                                        '+ ${Formatters.money(interest)}',
                                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                          color: accentColor,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'Срок: ${Formatters.date(row.dueDate)}',
                            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: Theme.of(context).colorScheme.onSurface,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          if (showDetails && row.isPaid && row.paidAt != null) ...[
                            const SizedBox(height: 2),
                            InkWell(
                              onTap: onEditPaidDate,
                              borderRadius: BorderRadius.circular(10),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    'Оплачен ${Formatters.date(row.paidAt!)}',
                                    style: Theme.of(context).textTheme.bodySmall,
                                  ),
                                  const SizedBox(width: 6),
                                  Icon(Icons.edit_calendar_outlined, size: 14, color: accentColor),
                                ],
                              ),
                            ),
                          ],
                          const SizedBox(height: 4),
                          Text(
                            statusLabel,
                            style: TextStyle(color: accentColor, fontWeight: FontWeight.w600),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Платёж уже оплачен',
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ),
                    Switch(
                      value: row.isPaid,
                      onChanged: (value) {
                        onChanged(value);
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

enum _PaymentIntervalUnit {
  days('Дней'),
  weeks('Недель'),
  months('Месяцев');

  const _PaymentIntervalUnit(this.label);

  final String label;
}

extension _PaymentIntervalUnitX on _PaymentIntervalUnit {
  static _PaymentIntervalUnit fromStorage(String value) {
    return switch (value) {
      'days' => _PaymentIntervalUnit.days,
      'weeks' => _PaymentIntervalUnit.weeks,
      _ => _PaymentIntervalUnit.months,
    };
  }

  String get storageValue => switch (this) {
    _PaymentIntervalUnit.days => 'days',
    _PaymentIntervalUnit.weeks => 'weeks',
    _PaymentIntervalUnit.months => 'months',
  };
}

class _PaymentIntervalValue {
  const _PaymentIntervalValue(this.count, this.unit);

  final int count;
  final _PaymentIntervalUnit unit;
}

class _FlippableAdminMetric extends StatelessWidget {
  const _FlippableAdminMetric({
    required this.title,
    required this.icon,
    required this.isFlipped,
    required this.onTap,
    required this.frontItems,
    required this.backItems,
    required this.frontHint,
    required this.backHint,
  });

  final String title;
  final IconData icon;
  final bool isFlipped;
  final VoidCallback onTap;
  final List<_CompactMetricItem> frontItems;
  final List<_CompactMetricItem> backItems;
  final String frontHint;
  final String backHint;

  @override
  Widget build(BuildContext context) {
    final rotation = isFlipped ? math.pi : 0.0;
    final front = _AdminMetric(
      title: title,
      value: '',
      detail: '',
      icon: icon,
      onTap: onTap,
      actionHint: frontHint,
      detailWidget: _StackedMetricLegend(items: frontItems),
    );
    final back = _AdminMetric(
      title: title,
      value: '',
      detail: '',
      icon: icon,
      onTap: onTap,
      actionHint: backHint,
      detailWidget: _StackedMetricLegend(items: backItems),
    );

    return TweenAnimationBuilder<double>(
      tween: Tween<double>(end: rotation),
      duration: Platform.isWindows ? const Duration(milliseconds: 1) : const Duration(milliseconds: 420),
      curve: Curves.easeInOutCubic,
      builder: (context, angle, child) {
        final showBack = angle >= math.pi / 2;
        final visibleAngle = showBack ? angle - math.pi : angle;
        return Transform(
          alignment: Alignment.center,
          transform: Matrix4.identity()
            ..setEntry(3, 2, 0.0012)
            ..rotateY(visibleAngle),
          child: showBack ? back : front,
        );
      },
    );
  }
}

class _AdminMetric extends StatelessWidget {
  const _AdminMetric({
    required this.title,
    required this.value,
    required this.detail,
    required this.icon,
    this.onTap,
    this.actionHint,
    this.detailWidget,
  });

  final String title;
  final String value;
  final String detail;
  final IconData icon;
  final VoidCallback? onTap;
  final String? actionHint;
  final Widget? detailWidget;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(24),
        child: Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: theme.cardColor,
            borderRadius: BorderRadius.circular(24),
            border: onTap == null
                ? null
                : Border.all(color: theme.colorScheme.secondary.withValues(alpha: 0.18)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: theme.colorScheme.secondary),
              const SizedBox(height: 10),
              Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
              if (value.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  value,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: theme.colorScheme.onSurface,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
              if (detailWidget != null) ...[
                const SizedBox(height: 8),
                detailWidget!,
              ] else ...[
                const SizedBox(height: 6),
                Text(
                  detail,
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall,
                ),
              ],
              if (actionHint != null) ...[
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.secondary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.touch_app_outlined, size: 16, color: theme.colorScheme.secondary),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          actionHint!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.secondary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _CompactMetricItem {
  const _CompactMetricItem({required this.label, required this.value, required this.color});

  final String label;
  final String value;
  final Color color;
}

class _CompactMetricLegend extends StatelessWidget {
  const _CompactMetricLegend({required this.items});

  final List<_CompactMetricItem> items;

  @override
  Widget build(BuildContext context) {
    final textStyle = Theme.of(context).textTheme.bodySmall;
    return Wrap(
      spacing: 10,
      runSpacing: 6,
      children: items
          .map(
            (item) => Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: item.color,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
                const SizedBox(width: 6),
                Text(item.value, style: textStyle?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(width: 4),
                Text(
                  item.label,
                  style: textStyle?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          )
          .toList(),
    );
  }
}

class _StackedMetricLegend extends StatelessWidget {
  const _StackedMetricLegend({required this.items});

  final List<_CompactMetricItem> items;

  @override
  Widget build(BuildContext context) {
    final textStyle = Theme.of(context).textTheme.bodySmall;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: items.asMap().entries.map((entry) {
        final index = entry.key;
        final item = entry.value;
        final isPrimary = index == 0;

        return Padding(
          padding: EdgeInsets.only(bottom: index == items.length - 1 ? 0 : 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 4,
                runSpacing: 2,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: item.color,
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    item.value,
                    style: (isPrimary ? Theme.of(context).textTheme.titleSmall : textStyle)
                        ?.copyWith(
                          fontWeight: FontWeight.w800,
                          color: isPrimary
                              ? Theme.of(context).colorScheme.onSurface
                              : Theme.of(context).colorScheme.onSurface,
                        ),
                  ),
                  if (!isPrimary)
                    Text(
                      item.label,
                      style: textStyle?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                ],
              ),
              if (isPrimary && items.length > 1) ...[
                const SizedBox(height: 6),
                Container(
                  height: 1,
                  width: double.infinity,
                  color: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.45),
                ),
              ],
            ],
          ),
        );
      }).toList(),
    );
  }
}

class _TagChip extends StatelessWidget {
  const _TagChip({required this.label, this.color, this.onTap});

  final String label;
  final Color? color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final chipColor = color ?? Theme.of(context).colorScheme.primary;
    const radius = 999.0;
    final body = Container(
      decoration: BoxDecoration(
        color: chipColor.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: chipColor.withValues(alpha: 0.24)),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: Stack(
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(10, 6, onTap == null ? 10 : 18, 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    label,
                    style: TextStyle(color: chipColor, fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
            if (onTap != null)
              Positioned(
                top: 0,
                right: 0,
                child: CustomPaint(
                  size: const Size(16, 16),
                  painter: _CornerFoldPainter(color: chipColor),
                ),
              ),
          ],
        ),
      ),
    );

    if (onTap == null) {
      return body;
    }

    return Material(
      color: Colors.transparent,
      child: InkWell(onTap: onTap, borderRadius: BorderRadius.circular(999), child: body),
    );
  }
}

class _CompactFilterPill extends StatelessWidget {
  const _CompactFilterPill({
    required this.label,
    required this.icon,
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final secondary = color;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: selected
              ? secondary.withValues(alpha: 0.16)
              : Colors.white.withValues(alpha: 0.025),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: selected
                ? secondary.withValues(alpha: 0.32)
                : Colors.white.withValues(alpha: 0.07),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                color: selected
                    ? secondary.withValues(alpha: 0.18)
                    : Colors.white.withValues(alpha: 0.04),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Icon(
                icon,
                size: 14,
                color: selected ? secondary : Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              label,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: selected ? secondary : null,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                letterSpacing: 0.1,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CornerFoldPainter extends CustomPainter {
  const _CornerFoldPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color.withValues(alpha: 0.28);
    final path = Path()
      ..moveTo(size.width, 0)
      ..lineTo(size.width, size.height)
      ..lineTo(0, 0)
      ..close();
    canvas.drawPath(path, paint);

    final accentPaint = Paint()
      ..color = color.withValues(alpha: 0.9)
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke;
    canvas.drawLine(Offset(size.width - 5, 3), Offset(size.width - 3, 5), accentPaint);
  }

  @override
  bool shouldRepaint(covariant _CornerFoldPainter oldDelegate) => oldDelegate.color != color;
}

class _PreviewSection extends StatelessWidget {
  const _PreviewSection({required this.title, required this.children, this.accentColor});

  final String title;
  final List<Widget> children;
  final Color? accentColor;

  @override
  Widget build(BuildContext context) {
    final color = accentColor ?? Theme.of(context).colorScheme.primary;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.28),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: color.withValues(alpha: 0.14)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 10),
          ...children,
        ],
      ),
    );
  }
}

class _PreviewRow extends StatelessWidget {
  const _PreviewRow({
    required this.label,
    required this.value,
    this.emphasize = false,
    this.valueColor,
    this.allowMultilineValue = false,
    this.stackWhenNarrow = false,
  });

  final String label;
  final String value;
  final bool emphasize;
  final Color? valueColor;
  final bool allowMultilineValue;
  final bool stackWhenNarrow;

  @override
  Widget build(BuildContext context) {
    final resolvedColor = valueColor ?? Theme.of(context).colorScheme.onSurface;
    final valueStyle = emphasize
        ? Theme.of(
            context,
          ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700, color: resolvedColor)
        : Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600, color: resolvedColor);

    final labelWidget = Text(
      label,
      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
        color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.92),
      ),
    );

    final valueWidget = Text(
      value,
      textAlign: TextAlign.right,
      maxLines: allowMultilineValue ? 2 : 1,
      overflow: allowMultilineValue ? TextOverflow.visible : TextOverflow.ellipsis,
      softWrap: allowMultilineValue,
      style: valueStyle,
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Platform.isWindows
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: labelWidget),
                const SizedBox(width: 12),
                Flexible(
                  child: Align(alignment: Alignment.centerRight, child: valueWidget),
                ),
              ],
            )
          : LayoutBuilder(
              builder: (context, constraints) {
                if (stackWhenNarrow && constraints.maxWidth < 310) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      labelWidget,
                      const SizedBox(height: 4),
                      Align(alignment: Alignment.centerRight, child: valueWidget),
                    ],
                  );
                }

                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: labelWidget),
                    const SizedBox(width: 12),
                    Flexible(
                      child: Align(alignment: Alignment.centerRight, child: valueWidget),
                    ),
                  ],
                );
              },
            ),
    );
  }
}
