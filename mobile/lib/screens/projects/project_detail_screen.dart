import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../config/api_config.dart';
import '../../core/theme/theme.dart';
import '../../data/models/attachment.dart';
import '../../data/models/comment.dart';
import '../../data/models/project.dart';
import '../../data/models/task.dart';
import '../../data/models/time_entry.dart';
import '../../providers/auth_provider.dart';
import '../../providers/invoices_provider.dart';
import '../../providers/lookup_provider.dart';
import '../../providers/org_modules_provider.dart';
import '../../providers/projects_provider.dart';
import '../../providers/tasks_provider.dart';
import '../../routes/app_routes.dart';
import '../../services/attachment_upload.dart';
import '../../widgets/cards/task_row.dart';
import '../../widgets/common/common.dart';
import '../../widgets/time/bill_time_sheet.dart';
import '../../widgets/time/time_entry_parts.dart';
import 'invoice_amount_sheet.dart';
import 'project_parts.dart';

/// One project: Overview (burn, budget, dates, people, rates), Tasks, Time,
/// Invoices, Files and Comments, the sections the web page has. A section whose
/// module is off is left out, as the web leaves it out.
///
/// Edit and log time follow `can_edit`, delete `can_delete`, and the billing
/// actions `can_bill` (org admins). The API enforces every one of them.
class ProjectDetailScreen extends ConsumerStatefulWidget {
  const ProjectDetailScreen({super.key, required this.projectId});

  final String projectId;

  @override
  ConsumerState<ProjectDetailScreen> createState() =>
      _ProjectDetailScreenState();
}

class _ProjectDetailScreenState extends ConsumerState<ProjectDetailScreen> {
  Project? _project;
  bool _loading = true;
  bool _notFound = false;

  List<Task>? _tasks;
  List<TimeEntry>? _entries;
  bool _timeBusy = false;
  Timer? _tick;

  final _note = TextEditingController();
  bool _addingNote = false;
  bool _uploading = false;

  ProjectsNotifier get _api => ref.read(projectsProvider.notifier);

  @override
  void initState() {
    super.initState();
    _load();
    // Redraws a running timer's clock without refetching anything.
    _tick = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted && (_entries ?? const []).any((e) => e.isRunning)) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    _note.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    var notFound = false;
    final p = await _api.getProject(
      widget.projectId,
      onNotFound: () => notFound = true,
    );
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (p != null) {
        _project = p;
      } else if (_project == null) {
        _notFound = notFound;
      }
    });
    if (p == null) return;
    await Future.wait([
      if (ref.read(moduleOnProvider('tasks'))) _loadTasks(),
      if (ref.read(moduleOnProvider('timesheet'))) _loadTime(),
    ]);
  }

  Future<void> _loadTasks() async {
    final tasks = await _api.fetchTasks(widget.projectId);
    if (mounted && tasks != null) setState(() => _tasks = tasks);
  }

  Future<void> _loadTime() async {
    final entries = await _api.fetchTimeEntries(widget.projectId);
    if (mounted && entries != null) setState(() => _entries = entries);
  }

  void _snack(String message, {bool danger = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        backgroundColor: danger ? AppColors.danger600 : null,
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final p = _project;
    if (p == null) {
      return Scaffold(
        appBar: AppBar(),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : EmptyState(
                icon: LucideIcons.folderKanban,
                title: _notFound
                    ? 'Project not found'
                    : 'Could not load this project',
                description: _notFound
                    ? 'It may have been deleted, or you may not have access '
                          'to it.'
                    : 'Check your connection and try again.',
                actionLabel: 'Try again',
                onAction: () {
                  setState(() => _loading = true);
                  _load();
                },
              ),
      );
    }

    final tasksOn = ref.watch(moduleOnProvider('tasks'));
    final timeOn = ref.watch(moduleOnProvider('timesheet'));
    final invoicesOn = ref.watch(moduleOnProvider('invoices'));
    final tabs = <(String, Widget Function())>[
      ('Overview', () => _overview(p)),
      if (tasksOn) ('Tasks', () => _tasksTab(p)),
      if (timeOn) ('Time', () => _timeTab(p)),
      if (invoicesOn) ('Invoices', () => _invoicesTab(p)),
      (
        p.attachments.isEmpty ? 'Files' : 'Files (${p.attachments.length})',
        () => _filesTab(p),
      ),
      (
        p.comments.isEmpty ? 'Comments' : 'Comments (${p.comments.length})',
        () => _notesTab(p),
      ),
    ];

    return DefaultTabController(
      // A module switched while the page is open changes the tab count.
      key: ValueKey('$tasksOn$timeOn$invoicesOn'),
      length: tabs.length,
      child: Scaffold(
        backgroundColor: AppColors.surfaceDim,
        appBar: AppBar(
          backgroundColor: AppColors.surface,
          elevation: 0,
          scrolledUnderElevation: 1,
          leading: IconButton(
            icon: const Icon(LucideIcons.chevronLeft),
            tooltip: 'Back',
            onPressed: () => context.pop(),
          ),
          title: Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          actions: [
            if (p.canEdit)
              IconButton(
                icon: const Icon(LucideIcons.pencil, size: 20),
                tooltip: 'Edit project',
                onPressed: _edit,
              ),
            if (p.canDelete)
              IconButton(
                icon: const Icon(LucideIcons.trash2, size: 20),
                tooltip: 'Delete project',
                onPressed: _confirmDelete,
              ),
          ],
          bottom: TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            labelColor: AppColors.primary600,
            unselectedLabelColor: AppColors.textSecondary,
            indicatorColor: AppColors.primary600,
            labelStyle: AppTypography.label,
            tabs: [for (final t in tabs) Tab(text: t.$1)],
          ),
        ),
        body: TabBarView(children: [for (final t in tabs) t.$2()]),
      ),
    );
  }

  Widget _scroll(List<Widget> children) => RefreshIndicator(
    onRefresh: _load,
    child: ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
      children: children,
    ),
  );

  // ---------------------------------------------------------------------------
  // Overview
  // ---------------------------------------------------------------------------

  bool get _billingOn =>
      (_project?.canBill ?? false) && ref.watch(moduleOnProvider('invoices'));

  /// Bill time also needs Timesheet, and a project whose time can be billed:
  /// a non-billable project's entries never are, as the web has it.
  bool get _billTimeOn =>
      _billingOn &&
      ref.watch(moduleOnProvider('timesheet')) &&
      _project!.billingType != ProjectBillingType.nonBillable;

  Widget _overview(Project p) {
    final dealsOn = ref.watch(moduleOnProvider('deals'));
    final defs =
        ref.watch(customFieldDefinitionsProvider('Project')).value ?? const [];
    return _scroll([
      Text(p.name, style: AppTypography.h2),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          ProjectStatusPill(project: p),
          StatusBadge(label: p.billingType.label, color: AppColors.gray600),
        ],
      ),
      const SizedBox(height: 8),
      if (p.account != null)
        ProjectFact(
          icon: LucideIcons.building2,
          label: 'ACCOUNT',
          value: p.account!.name.isEmpty ? 'Account' : p.account!.name,
          onTap: () => context.push(
            AppRoutes.accountDetail.replaceFirst(':id', p.account!.id),
          ),
        ),
      if (p.deal != null)
        ProjectFact(
          icon: LucideIcons.briefcase,
          label: 'FROM THE DEAL',
          value: p.deal!.name.isEmpty ? 'Deal' : p.deal!.name,
          onTap: dealsOn ? () => context.push('/deals/${p.deal!.id}') : null,
        ),
      const SizedBox(height: 12),
      ..._billingActions(p),
      ProjectCard(title: 'Budget', child: _budget(p)),
      ProjectCard(
        title: 'Dates',
        child: Column(
          children: [
            ProjectFact(
              icon: LucideIcons.calendar,
              label: 'START',
              value: p.startDate == null ? 'Not set' : shortDate(p.startDate!),
            ),
            ProjectFact(
              icon: LucideIcons.calendarClock,
              label: 'DUE',
              value: p.dueDate == null ? 'Not set' : shortDate(p.dueDate!),
            ),
          ],
        ),
      ),
      ProjectCard(
        title: 'People',
        child: p.assignedTo.isEmpty
            ? Text(
                'Nobody assigned',
                style: AppTypography.body.copyWith(
                  color: AppColors.textSecondary,
                ),
              )
            : Column(
                children: [
                  for (final person in p.assignedTo)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: AssigneeRow(profile: person),
                    ),
                ],
              ),
      ),
      ProjectCard(title: 'Rates', child: _ratesList(p)),
      if (p.description.trim().isNotEmpty)
        ProjectCard(
          title: 'Description',
          child: Text(
            p.description,
            style: AppTypography.body.copyWith(height: 1.5),
          ),
        ),
      if (p.tagNames.isNotEmpty)
        ProjectCard(
          title: 'Tags',
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [for (final t in p.tagNames) LabelPill(label: t)],
          ),
        ),
      if (CustomFieldsDisplay.shows(defs))
        ProjectCard(
          title: 'Custom fields',
          child: CustomFieldsDisplay(definitions: defs, values: p.customFields),
        ),
    ]);
  }

  /// Bill time and, on a fixed fee, Invoice an amount. Only for `can_bill`
  /// with Invoices on; Bill time also needs Timesheet.
  List<Widget> _billingActions(Project p) {
    final billTime = _billTimeOn;
    if (!_billingOn || (!billTime && !p.isFixedFee)) return const [];
    return [
      if (billTime)
        SizedBox(
          width: double.infinity,
          height: 48,
          child: FilledButton.icon(
            onPressed: _billTime,
            icon: const Icon(LucideIcons.receipt, size: 18),
            label: const Text('Bill time'),
          ),
        ),
      if (billTime && p.isFixedFee) const SizedBox(height: 8),
      if (p.isFixedFee)
        SizedBox(
          width: double.infinity,
          height: 48,
          child: OutlinedButton.icon(
            onPressed: _invoiceAmount,
            icon: const Icon(LucideIcons.handCoins, size: 18),
            label: const Text('Invoice an amount'),
          ),
        ),
      const SizedBox(height: 16),
    ];
  }

  Widget _budget(Project p) {
    final bars = burnBars(p);
    final fee = p.budgetAmountValue;
    // Null for a member and while Invoices is off: then there is no line.
    final invoiced = p.burn.invoicedAmount;
    final lines = <String>[
      '${hoursLabel(p.burn.loggedHours)}h logged, '
          '${hoursLabel(p.burn.billableHours)}h billable',
      'Not yet billed: ${projectMoney(p, p.burn.unbilledValue)}',
      if (invoiced != null)
        if (p.isFixedFee && fee != null)
          'Invoiced ${projectMoney(p, invoiced)} of the '
              '${projectMoney(p, fee)} fee'
        else
          'Invoiced: ${projectMoney(p, invoiced)}',
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (bars.isEmpty)
          Text(
            'No budget set.',
            style: AppTypography.body.copyWith(color: AppColors.textSecondary),
          )
        else
          ...bars,
        const SizedBox(height: 12),
        for (final line in lines)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(line, style: AppTypography.body),
          ),
      ],
    );
  }

  Widget _ratesList(Project p) {
    final rate = p.hourlyRateValue;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          rate == null
              ? 'No default rate'
              : 'Default: ${projectMoney(p, rate)} an hour',
          style: AppTypography.body,
        ),
        for (final r in p.rates)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              '${r.name.isEmpty ? 'Someone' : r.name}: '
              '${r.value == null ? 'no rate' : '${projectMoney(p, r.value!)} an hour'}',
              style: AppTypography.body,
            ),
          ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Tasks
  // ---------------------------------------------------------------------------

  Widget _tasksTab(Project p) {
    final tasks = _tasks;
    return _scroll([
      Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton.icon(
          style: OutlinedButton.styleFrom(minimumSize: const Size(0, 44)),
          onPressed: () async {
            await context.push('${AppRoutes.taskCreate}?project=${p.id}');
            if (mounted) _loadTasks();
          },
          icon: const Icon(LucideIcons.plus, size: 16),
          label: const Text('New task'),
        ),
      ),
      const SizedBox(height: 12),
      if (tasks == null)
        const Padding(
          padding: EdgeInsets.all(24),
          child: Center(child: CircularProgressIndicator()),
        )
      else if (tasks.isEmpty)
        Text(
          'No tasks on this project yet.',
          style: AppTypography.body.copyWith(color: AppColors.textSecondary),
        )
      else
        // Grouped by status: the phone's take on the web's kanban columns.
        for (final status in TaskStatus.values)
          if (tasks.any((t) => t.status == status)) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(0, 8, 0, 6),
              child: Text(
                '${status.label.toUpperCase()} '
                '(${tasks.where((t) => t.status == status).length})',
                style: AppTypography.overline.copyWith(
                  color: AppColors.textSecondary,
                ),
              ),
            ),
            for (final t in tasks.where((t) => t.status == status))
              TaskRow(
                task: t,
                onTap: () async {
                  await context.push('/tasks/${t.id}');
                  if (mounted) _loadTasks();
                },
                onToggle: () async {
                  final res = await ref
                      .read(tasksProvider.notifier)
                      .toggleTaskStatus(t);
                  if (!mounted) return;
                  if (!res.success) {
                    _snack(
                      res.message ?? 'Could not update that task',
                      danger: true,
                    );
                  }
                  _loadTasks();
                },
              ),
          ],
    ]);
  }

  // ---------------------------------------------------------------------------
  // Time
  // ---------------------------------------------------------------------------

  /// The caller's own running timer here, if any. An admin's list holds
  /// everyone's entries, and only your own timer is yours to stop.
  TimeEntry? get _myRunning {
    final me = ref.read(myEmailProvider)?.toLowerCase();
    for (final e in _entries ?? const <TimeEntry>[]) {
      if (e.isRunning && (me == null || e.profileName?.toLowerCase() == me)) {
        return e;
      }
    }
    return null;
  }

  List<TaskChoice> get _taskChoices => [
    for (final t in _tasks ?? const <Task>[])
      if (!t.completed) (id: t.id, title: t.title),
  ];

  String? _taskTitle(String? id) {
    if (id == null) return null;
    for (final t in _tasks ?? const <Task>[]) {
      if (t.id == id) return t.title;
    }
    return null;
  }

  Widget _timeTab(Project p) {
    final entries = _entries;
    final running = _myRunning;
    final done = [
      for (final e in entries ?? const <TimeEntry>[])
        if (!e.isRunning) e,
    ];
    return _scroll([
      Row(
        children: [
          _stat('Logged', '${hoursLabel(p.burn.loggedHours)}h'),
          const SizedBox(width: 12),
          _stat('Billable', '${hoursLabel(p.burn.billableHours)}h'),
        ],
      ),
      const SizedBox(height: 12),
      if (running != null)
        RunningTimerCard(
          entry: running,
          isBusy: _timeBusy,
          caption: _taskTitle(running.taskId),
          onStop: () => _stopTimer(running),
        )
      else if (p.canEdit)
        SizedBox(
          width: double.infinity,
          height: 44,
          child: OutlinedButton.icon(
            onPressed: _timeBusy ? null : _startTimer,
            icon: const Icon(LucideIcons.play, size: 16),
            label: const Text('Start timer'),
          ),
        ),
      if (p.canEdit) ...[
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          height: 44,
          child: OutlinedButton.icon(
            onPressed: _timeBusy ? null : _logTime,
            icon: const Icon(LucideIcons.plus, size: 16),
            label: const Text('Log time'),
          ),
        ),
      ],
      if (_billTimeOn) ...[
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          height: 44,
          child: OutlinedButton.icon(
            onPressed: _billTime,
            icon: const Icon(LucideIcons.receipt, size: 16),
            label: const Text('Bill time'),
          ),
        ),
      ],
      const Divider(height: 32),
      if (entries == null)
        const Center(child: CircularProgressIndicator())
      else if (done.isEmpty)
        Text(
          'No time logged here yet.',
          style: AppTypography.body.copyWith(color: AppColors.textSecondary),
        )
      else
        for (final e in done)
          TimeEntryRow(entry: e, detail: _taskTitle(e.taskId)),
    ]);
  }

  Widget _stat(String label, String value) => Expanded(
    child: Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: AppTypography.caption.copyWith(
              color: AppColors.textSecondary,
            ),
          ),
          Text(value, style: AppTypography.h3),
        ],
      ),
    ),
  );

  Future<void> _startTimer() async {
    String? taskId;
    final choices = _taskChoices;
    if (choices.isNotEmpty) {
      final picked = await showModalBottomSheet<({String? id})>(
        context: context,
        backgroundColor: AppColors.surface,
        isScrollControlled: true,
        builder: (ctx) => SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(ctx).height * 0.7,
            ),
            child: ListView(
              shrinkWrap: true,
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text('Start the timer on', style: AppTypography.h3),
                ),
                ListTile(
                  minTileHeight: 48,
                  leading: const Icon(LucideIcons.folderKanban),
                  title: const Text('The project'),
                  onTap: () => Navigator.pop(ctx, (id: null)),
                ),
                for (final t in choices)
                  ListTile(
                    minTileHeight: 48,
                    leading: const Icon(LucideIcons.circleCheck),
                    title: Text(t.title, overflow: TextOverflow.ellipsis),
                    onTap: () => Navigator.pop(ctx, (id: t.id)),
                  ),
              ],
            ),
          ),
        ),
      );
      if (picked == null || !mounted) return;
      taskId = picked.id;
    }
    setState(() => _timeBusy = true);
    final res = await _api.startTimer(
      widget.projectId,
      taskId: taskId,
      billable: _project!.billingType != ProjectBillingType.nonBillable,
    );
    if (!mounted) return;
    setState(() => _timeBusy = false);
    if (res.success) {
      await _loadTime();
      return;
    }
    final running = res.statusCode == 409 ? runningTimerPath(res.data) : null;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          res.statusCode == 409
              ? 'You already have a timer running.'
              : (res.message ?? 'Could not start the timer.'),
        ),
        backgroundColor: AppColors.danger600,
        behavior: SnackBarBehavior.floating,
        action: running == null
            ? null
            : SnackBarAction(
                label: 'View',
                textColor: Colors.white,
                onPressed: () => context.push(running),
              ),
      ),
    );
  }

  Future<void> _stopTimer(TimeEntry entry) async {
    setState(() => _timeBusy = true);
    final res = await _api.stopTimer(entry.id);
    if (!mounted) return;
    setState(() => _timeBusy = false);
    if (!res.success) {
      _snack(res.message ?? 'Could not stop the timer.', danger: true);
      return;
    }
    await _load();
  }

  Future<void> _logTime() async {
    final p = _project!;
    final billable = p.billingType != ProjectBillingType.nonBillable;
    final result = await ManualEntrySheet.show(
      context,
      tasks: _taskChoices,
      billableByDefault: billable,
      // A non-billable project keeps every entry non-billable.
      offerBillable: billable,
    );
    if (result == null || !mounted) return;
    setState(() => _timeBusy = true);
    final res = await _api.logTime(
      widget.projectId,
      startedAt: result.startedAt,
      endedAt: result.endedAt,
      billable: result.billable,
      description: result.description,
      taskId: result.taskId,
    );
    if (!mounted) return;
    setState(() => _timeBusy = false);
    if (!res.success) {
      _snack(res.message ?? 'Could not log that time.', danger: true);
      return;
    }
    await _load();
  }

  // ---------------------------------------------------------------------------
  // Billing
  // ---------------------------------------------------------------------------

  Future<void> _billTime() async {
    final invoiceId = await BillTimeSheet.show(
      context,
      loadPreview: (upTo) => _api.unbilled(widget.projectId, upTo),
      onBill: (grouping, upTo) => ref
          .read(invoicesProvider.notifier)
          .createFromTimeEntries(
            projectId: widget.projectId,
            upTo: upTo,
            groupBy: grouping.value,
          ),
    );
    await _afterInvoice(invoiceId);
  }

  Future<void> _invoiceAmount() async {
    final p = _project!;
    final invoiceId = await InvoiceAmountSheet.show(
      context,
      project: p,
      onInvoice: ({amount, percent, description}) => _api.invoiceAmount(
        widget.projectId,
        amount: amount,
        percent: percent,
        description: description,
      ),
    );
    await _afterInvoice(invoiceId);
  }

  Future<void> _afterInvoice(String? invoiceId) async {
    if (invoiceId == null || !mounted) return;
    _snack('Draft invoice created');
    unawaited(_load());
    context.push('${AppRoutes.invoices}/$invoiceId');
  }

  // ---------------------------------------------------------------------------
  // Invoices
  // ---------------------------------------------------------------------------

  Widget _invoicesTab(Project p) {
    final fee = p.budgetAmountValue;
    final invoiced = p.burn.invoicedAmount;
    return _scroll([
      ..._billingActions(p),
      if (p.isFixedFee && fee != null && invoiced != null) ...[
        Text(
          'Invoiced ${projectMoney(p, invoiced)} of the '
          '${projectMoney(p, fee)} fee',
          style: AppTypography.body,
        ),
        const SizedBox(height: 12),
      ],
      if (p.invoices.isEmpty)
        Text(
          'No invoices for this project yet.',
          style: AppTypography.body.copyWith(color: AppColors.textSecondary),
        )
      else
        for (final inv in p.invoices) _invoiceRow(inv),
    ]);
  }

  Widget _invoiceRow(ProjectInvoice inv) {
    final meta = [
      inv.statusLabel,
      if (inv.issueDate != null) shortDate(inv.issueDate!),
    ].join(' · ');
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: AppLayout.borderRadiusMd,
        border: Border.all(color: AppColors.border),
      ),
      child: InkWell(
        borderRadius: AppLayout.borderRadiusMd,
        onTap: () => context.push('${AppRoutes.invoices}/${inv.id}'),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      inv.invoiceNumber.isEmpty ? 'Invoice' : inv.invoiceNumber,
                      style: AppTypography.label,
                    ),
                    Text(
                      meta,
                      style: AppTypography.caption.copyWith(
                        color: inv.status?.color ?? AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(
                projectMoneyIn(
                  inv.currency ?? _project!.currency,
                  inv.totalAmount,
                ),
                style: AppTypography.label,
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Files and notes
  // ---------------------------------------------------------------------------

  Widget _filesTab(Project p) {
    return _scroll([
      if (p.attachments.isEmpty)
        Text(
          'No files yet. Attach a brief, a contract or a deliverable.',
          style: AppTypography.body.copyWith(color: AppColors.textSecondary),
        )
      else
        for (final a in p.attachments)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: AttachmentTile(attachment: a, onOpen: _openFile),
          ),
      const SizedBox(height: 12),
      Align(
        alignment: Alignment.centerLeft,
        child: AttachFileButton(isUploading: _uploading, onPressed: _upload),
      ),
    ]);
  }

  Future<void> _upload() async {
    if (_uploading) return;
    setState(() => _uploading = true);
    final result = await pickAndUploadAttachment(
      target: AttachmentTarget.project,
      recordId: widget.projectId,
    );
    if (!mounted) return;
    setState(() => _uploading = false);
    if (result.cancelled) return;
    if (!result.succeeded) {
      _snack(result.error!);
      return;
    }
    _applyThread(result.data);
  }

  /// The detail POST answers with the refreshed comments and attachments.
  void _applyThread(Map<String, dynamic>? data) {
    final comments = data?['comments'];
    final attachments = data?['attachments'];
    if (comments is! List && attachments is! List) {
      _load();
      return;
    }
    setState(() {
      _project = _project!.copyWith(
        comments: comments is List
            ? comments
                  .whereType<Map<String, dynamic>>()
                  .map(Comment.fromJson)
                  .toList()
            : null,
        attachments: attachments is List
            ? attachments
                  .whereType<Map<String, dynamic>>()
                  .map(Attachment.fromJson)
                  .toList()
            : null,
      );
    });
  }

  Future<void> _openFile(Attachment a) async {
    if (!a.hasFile) {
      _snack('That attachment has no file.');
      return;
    }
    final result = await downloadAttachment(
      url: ApiConfig.attachmentDownload(a.id),
      fileName: a.fileName,
    );
    if (!mounted || result.success) return;
    _snack(result.error ?? 'Could not download that file.');
  }

  Widget _notesTab(Project p) {
    return Column(
      children: [
        Expanded(
          child: p.comments.isEmpty
              ? const EmptyState(
                  icon: LucideIcons.fileText,
                  title: 'No comments yet',
                  description: 'Add a comment to keep the team in the loop',
                )
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    for (final c in p.comments)
                      NoteCard(
                        text: c.comment,
                        author: c.authorName,
                        timestamp: c.commentedOn,
                      ),
                  ],
                ),
        ),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppColors.surface,
            border: Border(top: BorderSide(color: AppColors.border)),
          ),
          child: SafeArea(
            top: false,
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _note,
                    enabled: !_addingNote,
                    minLines: 1,
                    maxLines: 4,
                    decoration: InputDecoration(
                      hintText: 'Add a comment...',
                      filled: true,
                      fillColor: AppColors.gray100,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  tooltip: 'Add comment',
                  onPressed: _addingNote ? null : _addNote,
                  icon: const Icon(LucideIcons.send, size: 20),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _addNote() async {
    final text = _note.text.trim();
    if (text.isEmpty) return;
    setState(() => _addingNote = true);
    final result = await _api.addComment(widget.projectId, text);
    if (!mounted) return;
    setState(() => _addingNote = false);
    if (result.error != null) {
      _snack(result.error!, danger: true);
      return;
    }
    _note.clear();
    _applyThread(result.data);
  }

  // ---------------------------------------------------------------------------
  // Edit and delete
  // ---------------------------------------------------------------------------

  Future<void> _edit() async {
    final saved = await context.push<bool>(
      AppRoutes.projectEditFor(widget.projectId),
    );
    if (saved == true && mounted) await _load();
  }

  Future<void> _confirmDelete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete this project?'),
        content: const Text(
          'Its tasks, time entries and invoices are kept, without the link '
          'to this project. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Delete', style: TextStyle(color: AppColors.danger600)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final error = await _api.delete(widget.projectId);
    if (!mounted) return;
    if (error != null) {
      _snack(error, danger: true);
      return;
    }
    _snack('Project deleted');
    context.pop();
  }
}
