import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../../../core/utils/formatters.dart';
import '../../../../data/models/app_user.dart';
import '../../../../data/models/loan.dart';
import '../../../../data/models/payment_schedule_item.dart';
import '../../../../data/models/payment_settings.dart';
import '../../../../data/services/app_clock.dart';

class ClientDashboard extends StatefulWidget {
  const ClientDashboard({
    super.key,
    required this.user,
    required this.loans,
    required this.paymentSettings,
  });

  final AppUser user;
  final List<Loan> loans;
  final PaymentSettings paymentSettings;

  @override
  State<ClientDashboard> createState() => _ClientDashboardState();
}

class _ClientDashboardState extends State<ClientDashboard> {
  Set<String> _expandedLoanIds = <String>{};
  List<String> _loanOrderIds = <String>[];
  bool _closedLoansExpanded = false;
  bool _loadedPrefs = false;
  bool _loadedOrderPrefs = false;
  bool _dragPrepared = false;
  bool _reorderActive = false;
  String? _dragCandidateLoanId;
  String? _visibleDragHintLoanId;
  Set<String> _expandedBeforeDrag = <String>{};
  Timer? _dragPrepareTimer;

  String get _prefsKey => 'expanded_loans_${widget.user.id}';
  String get _orderPrefsKey => 'loan_order_${widget.user.id}';
  String get _closedLoansPrefsKey => 'closed_loans_${widget.user.id}';

  @override
  void initState() {
    super.initState();
    _loadExpandedState();
    _loadLoanOrder();
    _loadClosedLoansState();
  }

  @override
  void didUpdateWidget(covariant ClientDashboard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.user.id != widget.user.id) {
      _expandedLoanIds = <String>{};
      _loanOrderIds = <String>[];
      _loadedPrefs = false;
      _loadedOrderPrefs = false;
      _dragPrepared = false;
      _reorderActive = false;
      _dragCandidateLoanId = null;
      _visibleDragHintLoanId = null;
      _expandedBeforeDrag = <String>{};
      _closedLoansExpanded = false;
      _loadExpandedState();
      _loadLoanOrder();
      _loadClosedLoansState();
    }
  }

  @override
  void dispose() {
    _dragPrepareTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadExpandedState() async {
    final prefs = await SharedPreferences.getInstance();
    final ids = prefs.getStringList(_prefsKey) ?? <String>[];
    if (!mounted) {
      return;
    }
    setState(() {
      _expandedLoanIds = ids.toSet();
      _loadedPrefs = true;
    });
  }

  Future<void> _saveExpandedState() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_prefsKey, _expandedLoanIds.toList());
  }

  Future<void> _loadLoanOrder() async {
    final prefs = await SharedPreferences.getInstance();
    final ids = prefs.getStringList(_orderPrefsKey) ?? <String>[];
    if (!mounted) {
      return;
    }
    setState(() {
      _loanOrderIds = ids;
      _loadedOrderPrefs = true;
    });
  }

  Future<void> _loadClosedLoansState() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) {
      return;
    }
    setState(() {
      _closedLoansExpanded = prefs.getBool(_closedLoansPrefsKey) ?? false;
    });
  }

  Future<void> _saveClosedLoansState() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_closedLoansPrefsKey, _closedLoansExpanded);
  }

  Future<void> _saveLoanOrder(List<String> ids) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_orderPrefsKey, ids);
  }

  void _toggleLoan(String loanId, bool expanded) {
    setState(() {
      if (expanded) {
        _expandedLoanIds.add(loanId);
      } else {
        _expandedLoanIds.remove(loanId);
      }
    });
    _saveExpandedState();
  }

  void _toggleClosedLoans() {
    setState(() {
      _closedLoansExpanded = !_closedLoansExpanded;
    });
    _saveClosedLoansState();
  }

  List<Loan> _applyLoanOrder(List<Loan> loans) {
    final orderedLoans = [...loans]..sort((a, b) => a.issuedAt.compareTo(b.issuedAt));

    if (!_loadedOrderPrefs || _loanOrderIds.isEmpty) {
      return orderedLoans;
    }

    final orderIndex = <String, int>{
      for (var i = 0; i < _loanOrderIds.length; i++) _loanOrderIds[i]: i,
    };

    orderedLoans.sort((a, b) {
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
      return a.issuedAt.compareTo(b.issuedAt);
    });

    return orderedLoans;
  }

  void _prepareForDrag() {
    if (_dragPrepared) {
      return;
    }
    _expandedBeforeDrag = {..._expandedLoanIds};
    setState(() {
      _dragPrepared = true;
      _visibleDragHintLoanId = _dragCandidateLoanId;
      _expandedLoanIds.clear();
    });
  }

  void _restoreAfterDrag() {
    if (!_dragPrepared && !_reorderActive) {
      return;
    }
    final hintLoanId = _visibleDragHintLoanId;
    setState(() {
      _dragPrepared = false;
      _reorderActive = false;
      _dragCandidateLoanId = null;
    });
    Future<void>.delayed(const Duration(milliseconds: 220), () {
      if (!mounted) {
        return;
      }
      if (_visibleDragHintLoanId == hintLoanId) {
        setState(() {
          _visibleDragHintLoanId = null;
        });
      }
    });
    final idsToRestore = {..._expandedBeforeDrag};
    _expandedBeforeDrag.clear();
    Future<void>.delayed(const Duration(milliseconds: 280), () {
      if (!mounted) {
        return;
      }
      setState(() {
        _expandedLoanIds = idsToRestore;
      });
      _saveExpandedState();
    });
  }

  void _scheduleDragPreparation(String loanId) {
    _dragPrepareTimer?.cancel();
    if (!_reorderActive) {
      setState(() {
        _dragCandidateLoanId = loanId;
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
    if (!_reorderActive && !_dragPrepared && _dragCandidateLoanId != null) {
      final hintLoanId = _visibleDragHintLoanId;
      setState(() {
        _dragCandidateLoanId = null;
      });
      Future<void>.delayed(const Duration(milliseconds: 220), () {
        if (!mounted) {
          return;
        }
        if (_visibleDragHintLoanId == hintLoanId && !_dragPrepared && !_reorderActive) {
          setState(() {
            _visibleDragHintLoanId = null;
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

  Future<void> _openPaymentSheet({required Loan loan, required bool fullClose}) async {
    final messenger = ScaffoldMessenger.of(context);
    final settings = widget.paymentSettings;
    final loanLabel = loan.displayTitle;
    final nextUnpaid = loan.nextUnpaid;
    final amount = fullClose ? loan.fullCloseAmount : loan.nextInstallmentAmount;
    final paymentPeriodLabel = fullClose
        ? 'полное погашение'
        : nextUnpaid == null
        ? 'платёж'
        : _paymentPeriodLabel(loan, nextUnpaid);
    final paymentComment = fullClose
        ? '${widget.user.name} | ${Formatters.phone(widget.user.phone)} | $loanLabel | полное погашение'
        : '${widget.user.name} | ${Formatters.phone(widget.user.phone)} | $loanLabel | $paymentPeriodLabel';
    final paymentNumber = settings.recipientPhone.trim();

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      builder: (context) {
        String? copiedLabel;
        return StatefulBuilder(
          builder: (context, setSheetState) {
            Future<void> showCopied(String label) async {
              setSheetState(() {
                copiedLabel = label;
              });
              Future<void>.delayed(const Duration(milliseconds: 1500), () {
                if (!context.mounted) {
                  return;
                }
                setSheetState(() {
                  if (copiedLabel == label) {
                    copiedLabel = null;
                  }
                });
              });
            }

            final viewportHeight = MediaQuery.sizeOf(context).height;
            final maxSheetHeight = (viewportHeight * 0.84).clamp(420.0, 760.0);

            return SafeArea(
              child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: maxSheetHeight),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        fullClose ? 'Погашение займа' : 'Оплата платежа',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 10),
                      Text('К оплате: ${Formatters.money(amount)}'),
                      if (settings.bankName.trim().isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text('Банк: ${settings.bankName}'),
                      ],
                      if (settings.recipientName.trim().isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text('Получатель: ${settings.recipientName}'),
                      ],
                      if (paymentNumber.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text('Номер: $paymentNumber'),
                      ],
                      const SizedBox(height: 12),
                      Text(
                        'Комментарий к переводу',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 6),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: Theme.of(
                            context,
                          ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(paymentComment),
                      ),
                      if (!settings.hasPaymentLink && !settings.hasRecipient) ...[
                        const SizedBox(height: 10),
                        const Text('Администратор ещё не настроил реквизиты оплаты'),
                      ],
                      const SizedBox(height: 14),
                      ClipRect(
                        child: AnimatedSize(
                          duration: const Duration(milliseconds: 220),
                          curve: Curves.easeInOut,
                          child: AnimatedOpacity(
                            duration: const Duration(milliseconds: 220),
                            curve: Curves.easeInOut,
                            opacity: copiedLabel == null ? 0 : 1,
                            child: copiedLabel == null
                                ? const SizedBox.shrink()
                                : Container(
                                    width: double.infinity,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 14,
                                      vertical: 12,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.secondary.withValues(alpha: 0.14),
                                      borderRadius: BorderRadius.circular(18),
                                      border: Border.all(
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.secondary.withValues(alpha: 0.22),
                                      ),
                                    ),
                                    child: Row(
                                      children: [
                                        Icon(
                                          Icons.check_circle_outline,
                                          size: 18,
                                          color: Theme.of(context).colorScheme.secondary,
                                        ),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          child: Text(
                                            copiedLabel!,
                                            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                              color: Theme.of(context).colorScheme.secondary,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 18),
                      Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        children: [
                          if (paymentNumber.isNotEmpty)
                            OutlinedButton.icon(
                              onPressed: () async {
                                await Clipboard.setData(ClipboardData(text: paymentNumber));
                                await showCopied('Номер скопирован');
                              },
                              icon: const Icon(Icons.copy_all_outlined),
                              label: const Text('Скопировать номер'),
                            ),
                          OutlinedButton.icon(
                            onPressed: () async {
                              await Clipboard.setData(ClipboardData(text: paymentComment));
                              await showCopied('Комментарий скопирован');
                            },
                            icon: const Icon(Icons.short_text_rounded),
                            label: const Text('Скопировать комментарий'),
                          ),
                          if (settings.hasPaymentLink)
                            ElevatedButton.icon(
                              onPressed: () async {
                                final uri = Uri.tryParse(settings.paymentLink.trim());
                                if (uri == null ||
                                    !await launchUrl(uri, mode: LaunchMode.externalApplication)) {
                                  if (!context.mounted) {
                                    return;
                                  }
                                  messenger.showSnackBar(
                                    const SnackBar(
                                      content: Text('Не удалось открыть банк по ссылке'),
                                    ),
                                  );
                                }
                              },
                              icon: const Icon(Icons.open_in_new_rounded),
                              label: const Text('Открыть банк'),
                            ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'После оплаты администратор отметит платёж вручную.',
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final activeLoans = _applyLoanOrder(
      widget.loans.where((loan) => loan.status == 'active').toList(),
    );
    final closedLoans = widget.loans.where((loan) => loan.status == 'closed').toList()
      ..sort((a, b) => a.issuedAt.compareTo(b.issuedAt));
    final totalLoans = widget.loans.length;

    final totalOutstanding = activeLoans.fold<double>(
      0,
      (sum, loan) => sum + loan.outstandingAmount,
    );
    final totalPlannedOutstanding = activeLoans.fold<double>(
      0,
      (sum, loan) => sum + loan.plannedOutstandingAmount,
    );
    final totalPenalty = activeLoans.fold<double>(0, (sum, loan) => sum + loan.penaltyOutstanding);
    final totalPenaltyPaid = widget.loans.fold<double>(0, (sum, loan) => sum + loan.penaltyPaid);

    final unpaidDates = activeLoans
        .expand(
          (loan) => loan.orderedSchedule.where((item) => !item.isPaid).map((item) => item.dueDate),
        )
        .toList()
      ..sort();
    final nearestPaymentDate = unpaidDates.isEmpty ? null : unpaidDates.first;
    final latestPaymentDate = unpaidDates.isEmpty ? null : unpaidDates.last;

    return CustomScrollView(
      slivers: [
        if (AppClock.settings.debugEnabled)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
            sliver: SliverToBoxAdapter(
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Row(
                    children: [
                      Icon(
                        Icons.bug_report_outlined,
                        color: Theme.of(context).colorScheme.secondary,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'Тестовое время: ${Formatters.dateTime(AppClock.now())}',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        SliverPadding(
          padding: EdgeInsets.fromLTRB(20, AppClock.settings.debugEnabled ? 12 : 20, 20, 0),
          sliver: SliverToBoxAdapter(
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(22),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Здравствуйте, ${widget.user.name}',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 8),
                    Text('Телефон: ${Formatters.phone(widget.user.phone)}'),
                    const SizedBox(height: 18),
                    Row(
                      children: [
                        Expanded(
                          child: _MetricCard(
                            icon: Icons.layers_outlined,
                            title: 'Займы',
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _CompactMetricLegend(
                                  items: [
                                    _CompactMetricItem(
                                      label: 'всего',
                                      value: totalLoans.toString(),
                                      color: Theme.of(context).colorScheme.secondary,
                                    ),
                                    _CompactMetricItem(
                                      label: 'акт',
                                      value: activeLoans.length.toString(),
                                      color: const Color(0xFFFFC26B),
                                    ),
                                    _CompactMetricItem(
                                      label: 'закр',
                                      value: closedLoans.length.toString(),
                                      color: Theme.of(context).colorScheme.primary,
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _MetricCard(
                            icon: Icons.account_balance_wallet_outlined,
                            title: 'Остаток',
                            child: activeLoans.isEmpty
                                ? Text(
                                    'Нет активных займов',
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context).textTheme.titleMedium,
                                  )
                                : Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      _MetricDetailLine(
                                        label: 'Сегодня',
                                        value: Formatters.money(totalOutstanding),
                                      ),
                                      const SizedBox(height: 4),
                                      _MetricDetailLine(
                                        label: 'По плану',
                                        value: Formatters.money(totalPlannedOutstanding),
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
                          child: _MetricCard(
                            icon: Icons.warning_amber_rounded,
                            title: 'Пени',
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _MetricDetailLine(
                                  label: 'На сегодня',
                                  value: Formatters.money(totalPenalty),
                                ),
                                const SizedBox(height: 4),
                                _MetricDetailLine(
                                  label: 'Оплачено',
                                  value: Formatters.money(totalPenaltyPaid),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _MetricCard(
                            icon: Icons.event_note_outlined,
                            title: 'Платежи',
                            child: nearestPaymentDate == null
                                ? Text(
                                    'Нет платежей',
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context).textTheme.titleMedium,
                                  )
                                : Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      _MetricDetailLine(
                                        label: 'Ближайший',
                                        value: Formatters.dateCompact(nearestPaymentDate),
                                      ),
                                const SizedBox(height: 4),
                                _MetricDetailLine(
                                  label: 'Последний',
                                  value: latestPaymentDate == null
                                      ? 'Нет платежей'
                                      : Formatters.dateCompact(latestPaymentDate),
                                ),
                                    ],
                                  ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
          sliver: SliverToBoxAdapter(
            child: Text('Активные займы', style: Theme.of(context).textTheme.titleLarge),
          ),
        ),
        if (activeLoans.isNotEmpty)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
            sliver: SliverToBoxAdapter(
              child: Text(
                'Зажмите иконку справа, чтобы изменить порядок займов',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
          ),
        if (activeLoans.isEmpty)
          const SliverPadding(
            padding: EdgeInsets.fromLTRB(20, 12, 20, 0),
            sliver: SliverToBoxAdapter(
              child: Card(
                child: Padding(
                  padding: EdgeInsets.all(20),
                  child: Text('У вас пока нет активных займов'),
                ),
              ),
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
            sliver: SliverReorderableList(
              itemCount: activeLoans.length,
              proxyDecorator: (child, index, animation) {
                return Material(color: Colors.transparent, child: child);
              },
              onReorderStart: (_) => _handleReorderStart(),
              onReorderEnd: (_) => _handleReorderEnd(),
              onReorder: (oldIndex, newIndex) async {
                if (newIndex > oldIndex) {
                  newIndex -= 1;
                }

                final ids = activeLoans.map((loan) => loan.id).toList();
                final moved = ids.removeAt(oldIndex);
                ids.insert(newIndex, moved);

                setState(() {
                  _loanOrderIds = ids;
                });

                await _saveLoanOrder(ids);
              },
              itemBuilder: (context, index) {
                final loan = activeLoans[index];
                final isExpanded = _loadedPrefs && _expandedLoanIds.contains(loan.id);
                final interactionsLocked = _dragPrepared || _reorderActive;

                return Padding(
                  key: ValueKey('loan_${loan.id}'),
                  padding: const EdgeInsets.only(bottom: 16),
                  child: _LoanCard(
                    loan: loan,
                    isExpanded: isExpanded,
                    isDragReady:
                        (_dragPrepared || _reorderActive) && _visibleDragHintLoanId == loan.id,
                    showDragHint: _visibleDragHintLoanId == loan.id,
                    onExpansionChanged: interactionsLocked
                        ? (_) {}
                        : (expanded) => _toggleLoan(loan.id, expanded),
                    onPayNext: () => _openPaymentSheet(loan: loan, fullClose: false),
                    onCloseLoan: () => _openPaymentSheet(loan: loan, fullClose: true),
                    dragIndicator: Listener(
                      onPointerDown: (_) => _scheduleDragPreparation(loan.id),
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
                        index: index,
                        child: Icon(
                          Icons.drag_indicator_rounded,
                          color: Theme.of(context).colorScheme.secondary,
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        if (closedLoans.isNotEmpty) ...[
          SliverPadding(
            padding: EdgeInsets.fromLTRB(
              20,
              20,
              20,
              _closedLoansExpanded ? 0 : 20,
            ),
            sliver: SliverToBoxAdapter(
              child: InkWell(
                onTap: _toggleClosedLoans,
                borderRadius: BorderRadius.circular(24),
                child: Container(
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    color: Theme.of(context).cardColor,
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(
                      color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.14),
                    ),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Закрытые займы', style: Theme.of(context).textTheme.titleMedium),
                            const SizedBox(height: 6),
                            Text('Всего ${closedLoans.length}'),
                          ],
                        ),
                      ),
                      Icon(
                        _closedLoansExpanded
                            ? Icons.expand_less_rounded
                            : Icons.expand_more_rounded,
                        color: Theme.of(context).colorScheme.secondary,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (_closedLoansExpanded)
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate((context, index) {
                  final loan = closedLoans[index];
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: _ClosedLoanCard(loan: loan),
                  );
                }, childCount: closedLoans.length),
              ),
            ),
        ] else
          const SliverToBoxAdapter(child: SizedBox(height: 20)),
      ],
    );
  }
}

class _ClosedLoanCard extends StatelessWidget {
  const _ClosedLoanCard({required this.loan});

  final Loan loan;

  @override
  Widget build(BuildContext context) {
    final firstPlannedDate = loan.schedule.isEmpty ? loan.issuedAt : loan.schedule.first.dueDate;
    final lastPlannedDate = loan.schedule.isEmpty ? loan.issuedAt : loan.schedule.last.dueDate;
    final paidDates =
        loan.schedule.where((item) => item.paidAt != null).map((item) => item.paidAt!).toList()
          ..sort();
    final actualStartDate = paidDates.isEmpty ? loan.issuedAt : paidDates.first;
    final actualEndDate = paidDates.isEmpty ? loan.issuedAt : paidDates.last;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const CircleAvatar(child: Icon(Icons.check_circle_outline)),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    loan.displayTitle,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              'Срок займа: ${Formatters.date(firstPlannedDate)} - ${Formatters.date(lastPlannedDate)}',
            ),
            Text(
              'Факт. выплата: ${Formatters.date(actualStartDate)} - ${Formatters.date(actualEndDate)}',
            ),
            Text('Сумма займа: ${Formatters.money(loan.principal)}'),
                        Text('Плановая сумма к возврату: ${Formatters.money(loan.plannedTotalAmount)}'),
            Text('Выплачено фактически: ${Formatters.money(loan.paidAmount)}'),
          ],
        ),
      ),
    );
  }
}

class _LoanCard extends StatelessWidget {
  const _LoanCard({
    required this.loan,
    required this.isExpanded,
    required this.isDragReady,
    required this.showDragHint,
    required this.onExpansionChanged,
    required this.onPayNext,
    required this.onCloseLoan,
    this.dragIndicator,
  });

  final Loan loan;
  final bool isExpanded;
  final bool isDragReady;
  final bool showDragHint;
  final ValueChanged<bool> onExpansionChanged;
  final Future<void> Function() onPayNext;
  final Future<void> Function() onCloseLoan;
  final Widget? dragIndicator;

  @override
  Widget build(BuildContext context) {
    final nextUnpaid = loan.nextUnpaid;
    final firstDate = loan.schedule.isEmpty ? loan.issuedAt : loan.schedule.first.dueDate;
    final lastDate = loan.schedule.isEmpty ? loan.issuedAt : loan.schedule.last.dueDate;
    final secondaryColor = Theme.of(context).colorScheme.secondary;

    return Stack(
      children: [
        Card(
          clipBehavior: Clip.antiAlias,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(22, 20, 22, 22),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(loan.displayTitle, style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 8),
                Row(
                  children: [
                    _StatusChip(label: 'В процессе', color: const Color(0xFFFFC26B)),
                    const Spacer(),
                    if (dragIndicator != null)
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 180),
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
                    duration: const Duration(milliseconds: 220),
                    curve: Curves.easeInOut,
                    alignment: Alignment.topCenter,
                    child: AnimatedOpacity(
                      duration: const Duration(milliseconds: 180),
                      curve: Curves.easeInOut,
                      opacity: isDragReady ? 1 : 0,
                      child: showDragHint
                          ? Padding(
                              padding: const EdgeInsets.only(top: 8),
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
                const SizedBox(height: 8),
                Text(
                  'Плановый остаток: ${Formatters.money(loan.plannedOutstandingAmount)}',
                ),
                Text('Срок: ${Formatters.date(firstDate)} - ${Formatters.date(lastDate)}'),
                if (nextUnpaid != null)
                  Text('Следующий платёж: ${Formatters.date(nextUnpaid.dueDate)}'),
                const SizedBox(height: 10),
                InkWell(
                  onTap: () => onExpansionChanged(!isExpanded),
                  borderRadius: BorderRadius.circular(16),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      border: Border(top: BorderSide(color: Colors.white.withValues(alpha: 0.08))),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          isExpanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                          size: 18,
                          color: secondaryColor,
                        ),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            isExpanded ? 'Свернуть детали' : 'Нажмите, чтобы развернуть',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                AnimatedSize(
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeInOut,
                  alignment: Alignment.topCenter,
                  child: isExpanded
                      ? Padding(
                          padding: const EdgeInsets.only(top: 18),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Сумма займа: ${Formatters.money(loan.principal)}'),
                              Text('Процент: ${Formatters.decimalInput(loan.interestPercent)}%'),
                              Text(
                          'К возврату по плану: ${Formatters.money(loan.plannedTotalAmount)}',
                              ),
                              Text(
                                'Сейчас к закрытию: ${Formatters.money(loan.fullCloseAmount)}',
                              ),
                              Text(
                                'Процент за день: ${Formatters.money(loan.dailyInterestAmount)}',
                              ),
                              Text('Пеня за день: ${Formatters.money(loan.dailyPenaltyAmount)}'),
                              if ((loan.note ?? '').trim().isNotEmpty) ...[
                                const SizedBox(height: 10),
                                Text(loan.note!),
                              ],
                              const SizedBox(height: 18),
                              Row(
                                children: [
                                  Expanded(
                                    child: ElevatedButton.icon(
                                      onPressed: onPayNext,
                                      icon: const Icon(Icons.payments_outlined),
                                      label: const Text('Оплатить следующий платёж'),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              Row(
                                children: [
                                  Expanded(
                                    child: OutlinedButton.icon(
                                      onPressed: onCloseLoan,
                                      icon: const Icon(Icons.task_alt_outlined),
                                      label: const Text('Погасить полностью'),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 20),
                              Text(
                                'График платежей',
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                              const SizedBox(height: 12),
                              ...loan.schedule.map(
                                (item) => Padding(
                                  padding: const EdgeInsets.only(bottom: 12),
                                  child: _ScheduleCard(
                                    loan: loan,
                                    item: item,
                                    isDueToday: loan.isItemDueToday(item),
                                    isOverdue: loan.isItemOverdue(item),
                                    penalty: loan.penaltyForItem(item),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
              ],
            ),
          ),
        ),
        Positioned.fill(
          child: IgnorePointer(
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 180),
              opacity: isDragReady ? 1 : 0,
              child: Padding(
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

class _ScheduleCard extends StatelessWidget {
  const _ScheduleCard({
    required this.loan,
    required this.item,
    required this.penalty,
    required this.isDueToday,
    required this.isOverdue,
  });

  final Loan loan;
  final PaymentScheduleItem item;
  final double penalty;
  final bool isDueToday;
  final bool isOverdue;

  @override
  Widget build(BuildContext context) {
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
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
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
          style: TextStyle(color: accentColor),
        ),
      ),
    );
  }
}

String _paymentPeriodLabel(Loan loan, PaymentScheduleItem item) {
  final sorted = loan.orderedSchedule;
  final index = sorted.indexWhere((scheduleItem) => scheduleItem.id == item.id);
  if (index <= 0) {
    return 'платёж до ${Formatters.date(item.dueDate)}';
  }
  final previousDate = sorted[index - 1].dueDate;
  return 'платёж ${Formatters.date(previousDate)} - ${Formatters.date(item.dueDate)}';
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({required this.title, required this.icon, required this.child});

  final String title;
  final IconData icon;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 176),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(24),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon),
          const SizedBox(height: 14),
          Text(
            title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }
}

class _MetricDetailLine extends StatelessWidget {
  const _MetricDetailLine({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.w500,
            letterSpacing: 0.2,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

class _CompactMetricItem {
  const _CompactMetricItem({
    required this.label,
    required this.value,
    required this.color,
  });

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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: items
          .map(
            (item) => Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
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
                  Text(
                    item.value,
                    style: textStyle?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    item.label,
                    style: textStyle?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          )
          .toList(),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.24)),
      ),
      child: Text(
        label,
        style: TextStyle(color: color, fontWeight: FontWeight.w600),
      ),
    );
  }
}
