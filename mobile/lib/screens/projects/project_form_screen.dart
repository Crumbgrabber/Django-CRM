import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/theme/theme.dart';
import '../../data/models/custom_field_definition.dart';
import '../../data/models/deal.dart' show Currency;
import '../../data/models/lookup_models.dart';
import '../../data/models/project.dart';
import '../../providers/auth_provider.dart';
import '../../providers/lookup_provider.dart';
import '../../providers/org_modules_provider.dart';
import '../../providers/projects_provider.dart';
import '../../routes/app_routes.dart';
import '../../widgets/forms/custom_fields_section.dart';
import '../../widgets/forms/multi_select_sheet.dart';
import '../../widgets/forms/unsaved_changes.dart';
import 'project_parts.dart';

/// New and edit project, and a new project filled from a won deal.
///
/// The checks are the API's, repeated so a refusal lands beside the field:
/// a name and an account, budgets and rates of 0 or more, a due date not
/// before the start, one rate per person. The server enforces each of them.
class ProjectFormScreen extends ConsumerStatefulWidget {
  const ProjectFormScreen({super.key, this.projectId, this.fromDealId});

  /// Edit this project. Null for a new one.
  final String? projectId;

  /// Fill a new project from this deal's draft.
  final String? fromDealId;

  bool get isEdit => projectId != null;

  @override
  ConsumerState<ProjectFormScreen> createState() => _ProjectFormScreenState();
}

class _RateRow {
  _RateRow({this.profileId, String rate = ''})
    : rate = TextEditingController(text: rate);

  String? profileId;
  final TextEditingController rate;
}

class _ProjectFormScreenState extends ConsumerState<ProjectFormScreen> {
  final _name = TextEditingController();
  final _budgetHours = TextEditingController();
  final _budgetAmount = TextEditingController();
  final _hourlyRate = TextEditingController();
  final _retainerFee = TextEditingController();
  final _retainerHours = TextEditingController();
  final _retainerOverage = TextEditingController();
  final _retainerCarried = TextEditingController();
  bool _retainerRollover = false;
  final _description = TextEditingController();

  String? _accountId;
  ProjectRef? _accountRef;
  String? _dealId;
  ProjectRef? _dealRef;
  String _status = ProjectStatus.active.value;
  ProjectBillingType _billingType = ProjectBillingType.timeAndMaterials;
  late String _currency;
  DateTime? _startDate;
  DateTime? _dueDate;
  List<String> _assignedTo = [];
  List<String> _tagIds = [];
  final List<_RateRow> _rates = [];
  Map<String, dynamic> _customFields = {};
  Map<String, String> _customFieldErrors = const {};

  bool _loading = false;
  String? _loadError;

  /// The project being edited, for what a member sees but may not change.
  Project? _loaded;
  bool _saving = false;
  bool _tried = false;
  String? _error;
  String? _baseline;

  @override
  void initState() {
    super.initState();
    _currency =
        ref.read(selectedOrgProvider)?.defaultCurrency ?? Currency.usd.value;
    if (widget.isEdit) {
      _loadProject();
    } else if (widget.fromDealId != null) {
      _loadDraft();
    } else {
      _baseline = _snapshot();
    }
  }

  @override
  void dispose() {
    for (final c in [
      _name,
      _budgetHours,
      _budgetAmount,
      _hourlyRate,
      _retainerFee,
      _retainerHours,
      _retainerOverage,
      _retainerCarried,
      _description,
    ]) {
      c.dispose();
    }
    for (final r in _rates) {
      r.rate.dispose();
    }
    super.dispose();
  }

  Future<void> _loadProject() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    var notFound = false;
    final p = await ref
        .read(projectsProvider.notifier)
        .getProject(widget.projectId!, onNotFound: () => notFound = true);
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (p == null) {
        _loadError = notFound
            ? 'It may have been deleted, or you may not have access to it.'
            : 'Check your connection and try again.';
        return;
      }
      _loaded = p;
      _name.text = p.name;
      _accountId = p.account?.id;
      _accountRef = p.account;
      _dealId = p.deal?.id;
      _dealRef = p.deal;
      _status = p.rawStatus;
      _billingType = p.billingType;
      if (p.currency.isNotEmpty) _currency = p.currency;
      _budgetHours.text = p.budgetHours ?? '';
      _budgetAmount.text = p.budgetAmount ?? '';
      _hourlyRate.text = p.hourlyRate ?? '';
      _retainerFee.text = p.retainerFee ?? '';
      _retainerHours.text = p.retainerHours ?? '';
      _retainerOverage.text = p.retainerOverageRate ?? '';
      _retainerCarried.text = p.retainerCarriedHours ?? '';
      _retainerRollover = p.retainerRollover;
      _startDate = p.startDate;
      _dueDate = p.dueDate;
      _assignedTo = p.assignedToIds;
      _tagIds = List.of(p.tagIds);
      _description.text = p.description;
      _customFields = Map.of(p.customFields);
      for (final r in p.rates) {
        _rates.add(_RateRow(profileId: r.profileId, rate: r.hourlyRate ?? ''));
      }
      _baseline = _snapshot();
    });
  }

  Future<void> _loadDraft() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    final result = await ref
        .read(projectsProvider.notifier)
        .draftFromDeal(widget.fromDealId!);
    if (!mounted) return;
    setState(() {
      _loading = false;
      final d = result.draft;
      if (d == null) {
        _loadError = result.error;
        return;
      }
      _name.text = d.name;
      _accountId = d.account?.id;
      _accountRef = d.account;
      _dealId = d.deal?.id ?? widget.fromDealId;
      _dealRef = d.deal;
      if ((d.currency ?? '').isNotEmpty) _currency = d.currency!;
      _assignedTo = List.of(d.assignedToIds);
      _billingType = d.billingType;
      _budgetAmount.text = d.budgetAmount ?? '';
      _baseline = _snapshot();
    });
  }

  // ---------------------------------------------------------------------------
  // Checks and payload
  // ---------------------------------------------------------------------------

  /// Why a decimal field cannot be sent, or null. Digits and a decimal point
  /// only, so a negative reads as "Enter 0 or more." rather than as a typo.
  static String? _decimalProblem(String text) {
    final t = text.trim();
    if (t.isEmpty) return null;
    if (t.startsWith('-') && parseDecimalText(t.substring(1)) != null) {
      return 'Enter 0 or more.';
    }
    if (parseDecimalText(t) == null) return 'Enter a number.';
    return null;
  }

  String? get _nameProblem =>
      _tried && _name.text.trim().isEmpty ? 'A project needs a name.' : null;

  String? get _accountProblem =>
      _tried && _accountId == null ? 'Pick the client account.' : null;

  String? get _dateProblem =>
      _startDate != null && _dueDate != null && _dueDate!.isBefore(_startDate!)
      ? 'The due date cannot be before the start date.'
      : null;

  /// A row with no person is an unused row and is dropped, as on the web;
  /// one with a person needs a rate of 0 or more.
  bool get _carriedChanged {
    final typed = parseDecimalText(_retainerCarried.text) ?? 0;
    return typed != (_loaded?.retainerCarriedValue ?? 0);
  }

  bool get _isRetainer => _billingType == ProjectBillingType.retainer;

  /// The two retainer rules the API enforces, worded as it words them: a
  /// monthly fee of at least 0.01, and a rate once an allowance is set.
  String? get _feeProblem {
    final typed = _decimalProblem(_retainerFee.text);
    if (typed != null) return typed;
    final fee = parseDecimalText(_retainerFee.text);
    if (fee != null && fee < 0.01) return 'Enter at least 0.01.';
    if (_tried && fee == null) return 'Set the monthly fee.';
    return null;
  }

  String? get _overageProblem {
    final typed = _decimalProblem(_retainerOverage.text);
    if (typed != null) return typed;
    if (_tried &&
        _retainerHours.text.trim().isNotEmpty &&
        _retainerOverage.text.trim().isEmpty) {
      return 'Set the rate for hours over the allowance.';
    }
    return null;
  }

  bool get _retainerValid =>
      !_isRetainer ||
      (_feeProblem == null &&
          _overageProblem == null &&
          _decimalProblem(_retainerHours.text) == null &&
          _decimalProblem(_retainerCarried.text) == null);

  String? _rateProblem(_RateRow r) {
    if (r.profileId == null) return null;
    if (r.rate.text.trim().isEmpty) return _tried ? 'Enter a rate.' : null;
    return _decimalProblem(r.rate.text);
  }

  bool _valid(List<CustomFieldDefinition> defs) {
    final problems = customFieldProblems(defs, _customFields);
    setState(() {
      _tried = true;
      _customFieldErrors = problems;
    });
    return _name.text.trim().isNotEmpty &&
        _accountId != null &&
        _dateProblem == null &&
        _decimalProblem(_budgetHours.text) == null &&
        _decimalProblem(_budgetAmount.text) == null &&
        _decimalProblem(_hourlyRate.text) == null &&
        _retainerValid &&
        _rates.every((r) => _rateProblem(r) == null) &&
        problems.isEmpty;
  }

  static String? _dateParam(DateTime? d) =>
      d == null ? null : DateFormat('yyyy-MM-dd').format(d);

  /// Two decimal places, as the web sends them; null for blank.
  static String? _decimalParam(String text) {
    final t = text.trim();
    if (t.isEmpty) return null;
    return parseDecimalText(t)?.toStringAsFixed(2) ?? t;
  }

  bool get _isAdmin => ref.read(isOrgAdminProvider);

  /// A retainer's status decides which months are billed, so the API takes it
  /// from an admin only.
  bool get _statusLocked =>
      widget.isEdit && !_isAdmin && _loaded?.isRetainer == true;

  /// Money fields go only from an admin: the API ignores them from anyone
  /// else. The account is a member's to set on a new project only, and the
  /// deal goes only while Deals is on, or an edit would clear the link.
  Map<String, dynamic> _payload(List<CustomFieldDefinition> defs) {
    final admin = _isAdmin;
    return {
      'name': _name.text.trim(),
      if (!widget.isEdit || admin) 'account': _accountId,
      if (ref.read(moduleOnProvider('deals'))) 'deal': _dealId,
      if (!_statusLocked) 'status': _status,
      if (admin) ...{
        'billing_type': _billingType.value,
        'currency': _currency,
        'budget_hours': _decimalParam(_budgetHours.text),
        'budget_amount': _decimalParam(_budgetAmount.text),
        'hourly_rate': _decimalParam(_hourlyRate.text),
        if (_isRetainer) ...{
          'retainer_fee': _decimalParam(_retainerFee.text),
          'retainer_hours': _decimalParam(_retainerHours.text),
          // Always explicit: an omitted box would not clear a rollover.
          'retainer_rollover': _retainerRollover,
          'retainer_overage_rate': _decimalParam(_retainerOverage.text),
          // Only a change the admin made: the stored figure moves when a month
          // is billed, and the loaded one would write the old value back.
          if (widget.isEdit && _carriedChanged)
            'retainer_carried_hours':
                _decimalParam(_retainerCarried.text) ?? '0.00',
        },
        'rates': [
          for (final r in _rates)
            if (r.profileId != null)
              {
                'profile': r.profileId,
                'hourly_rate': _decimalParam(r.rate.text),
              },
        ],
      },
      'start_date': _dateParam(_startDate),
      'due_date': _dateParam(_dueDate),
      'assigned_to': _assignedTo,
      'tags': _tagIds,
      'description': _description.text.trim(),
      if (defs.isNotEmpty)
        'custom_fields': sendableCustomFields(defs, _customFields),
    };
  }

  List<CustomFieldDefinition> get _defs =>
      ref.read(customFieldDefinitionsProvider('Project')).value ?? const [];

  /// `toString` rather than `jsonEncode`: the payload is plain values, and
  /// the same builder makes every snapshot, so key order is stable.
  String _snapshot() => '${_payload(const [])}$_customFields';

  bool get _dirty => _baseline != null && _snapshot() != _baseline;

  Future<void> _save() async {
    final defs = _defs;
    if (!_valid(defs)) {
      setState(() => _error = 'Check the marked fields.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final notifier = ref.read(projectsProvider.notifier);
    final payload = _payload(defs);
    final result = widget.isEdit
        ? await notifier.saveChanges(widget.projectId!, payload)
        : await notifier.create(payload);
    if (!mounted) return;
    setState(() => _saving = false);
    if (result.error != null) {
      setState(() => _error = result.error);
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(widget.isEdit ? 'Project saved' : 'Project created'),
        behavior: SnackBarBehavior.floating,
      ),
    );
    if (widget.isEdit) {
      context.pop(true);
    } else if (result.id != null) {
      // Replace rather than push: back from the new project should not land
      // on a form that would create it a second time.
      context.pushReplacement(AppRoutes.projectFor(result.id!));
    } else {
      context.pop(true);
    }
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final title = widget.isEdit ? 'Edit project' : 'New project';
    if (_loading || _loadError != null) {
      return Scaffold(
        appBar: AppBar(title: Text(title)),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        widget.isEdit
                            ? 'Could not load this project'
                            : 'Could not fill the form from that deal',
                        style: AppTypography.h3,
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _loadError!,
                        textAlign: TextAlign.center,
                        style: AppTypography.body.copyWith(
                          color: AppColors.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 16),
                      OutlinedButton(
                        onPressed: widget.isEdit ? _loadProject : _loadDraft,
                        child: const Text('Try again'),
                      ),
                    ],
                  ),
                ),
              ),
      );
    }

    final defs =
        ref.watch(customFieldDefinitionsProvider('Project')).value ??
        const <CustomFieldDefinition>[];
    return UnsavedChangesGuard(
      hasUnsavedChanges: () => _dirty,
      isSaving: _saving,
      child: Scaffold(
        backgroundColor: AppColors.surfaceDim,
        appBar: AppBar(
          title: Text(title),
          backgroundColor: AppColors.surface,
          elevation: 0,
          scrolledUnderElevation: 1,
          leading: IconButton(
            icon: const Icon(LucideIcons.chevronLeft),
            tooltip: 'Back',
            onPressed: () => leaveForm(context, hasUnsavedChanges: _dirty),
          ),
        ),
        body: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.only(bottom: 24),
                children: [
                  if (_error != null)
                    Container(
                      width: double.infinity,
                      color: AppColors.danger50,
                      padding: const EdgeInsets.all(12),
                      child: Text(
                        _error!,
                        style: AppTypography.caption.copyWith(
                          color: AppColors.danger700,
                        ),
                      ),
                    ),
                  _basics(),
                  if (ref.watch(isOrgAdminProvider))
                    _billing()
                  else if (_loaded != null)
                    _moneyReadOnly(_loaded!),
                  _dates(),
                  _people(),
                  if (ref.watch(isOrgAdminProvider)) _rateCard(),
                  _extras(),
                  if (defs.isNotEmpty)
                    _card('Custom fields', [
                      CustomFieldsSection(
                        heading: false,
                        definitions: defs,
                        values: _customFields,
                        errors: _customFieldErrors,
                        onChanged: (next, errors) => setState(() {
                          _customFields = next;
                          _customFieldErrors = errors;
                        }),
                      ),
                    ]),
                ],
              ),
            ),
            _saveBar(),
          ],
        ),
      ),
    );
  }

  Widget _basics() {
    final accounts = ref.watch(accountsLookupProvider).value ?? const [];
    final dealsOn = ref.watch(moduleOnProvider('deals'));
    final deals = dealsOn
        ? ref.watch(opportunitiesLookupProvider).value ?? const []
        : const <EntityLookup>[];
    return _card('Project', [
      TextField(
        controller: _name,
        textCapitalization: TextCapitalization.sentences,
        onChanged: (_) => setState(() {}),
        decoration: InputDecoration(
          labelText: 'Name',
          errorText: _nameProblem,
          border: const OutlineInputBorder(),
        ),
      ),
      const SizedBox(height: 12),
      if (widget.isEdit && !ref.watch(isOrgAdminProvider))
        _readOnly(
          'Account',
          _accountRef?.name.isNotEmpty == true ? _accountRef!.name : 'Account',
        )
      else
        DropdownButtonFormField<String>(
          key: ValueKey('account-$_accountId-${accounts.length}'),
          initialValue: _accountId,
          isExpanded: true,
          decoration: InputDecoration(
            labelText: 'Account',
            errorText: _accountProblem,
            border: const OutlineInputBorder(),
          ),
          items: [
            for (final a in accounts)
              DropdownMenuItem(
                value: a.id,
                child: Text(a.name, overflow: TextOverflow.ellipsis),
              ),
            // The project's own account stays an option when the lookup does
            // not offer it (an inactive account), or the field would clear it.
            if (_accountId != null && !accounts.any((a) => a.id == _accountId))
              DropdownMenuItem(
                value: _accountId,
                child: Text(
                  _accountRef?.name.isNotEmpty == true
                      ? _accountRef!.name
                      : 'Current account',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: (v) => setState(() => _accountId = v),
        ),
      if (dealsOn) ...[
        const SizedBox(height: 12),
        DropdownButtonFormField<String?>(
          key: ValueKey('deal-$_dealId-${deals.length}'),
          initialValue: _dealId,
          isExpanded: true,
          decoration: const InputDecoration(
            labelText: 'Deal (optional)',
            border: OutlineInputBorder(),
          ),
          items: [
            const DropdownMenuItem<String?>(value: null, child: Text('None')),
            for (final d in deals)
              DropdownMenuItem<String?>(
                value: d.id,
                child: Text(d.label, overflow: TextOverflow.ellipsis),
              ),
            if (_dealId != null && !deals.any((d) => d.id == _dealId))
              DropdownMenuItem<String?>(
                value: _dealId,
                child: Text(
                  _dealRef?.name.isNotEmpty == true
                      ? _dealRef!.name
                      : 'Current deal',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: (v) => setState(() => _dealId = v),
        ),
      ],
      const SizedBox(height: 12),
      DropdownButtonFormField<String>(
        initialValue: _status,
        isExpanded: true,
        decoration: const InputDecoration(
          labelText: 'Status',
          border: OutlineInputBorder(),
        ),
        items: [
          for (final s in ProjectStatus.values)
            DropdownMenuItem(value: s.value, child: Text(s.label)),
          if (ProjectStatus.fromValue(_status) == null)
            DropdownMenuItem(value: _status, child: Text(_status)),
        ],
        onChanged: _statusLocked
            ? null
            : (v) => setState(() => _status = v ?? _status),
      ),
    ]);
  }

  /// What a member sees of the money fields on an edit: the values, and no
  /// way to change them.
  Widget _moneyReadOnly(Project p) {
    String amount(String? text) {
      final n = decimalOrNull(text);
      return n == null ? 'Not set' : projectMoney(p, n);
    }

    final hours = decimalOrNull(p.budgetHours);
    return _card('Billing and budget', [
      Text(
        'Only an admin can change these.',
        style: AppTypography.caption.copyWith(color: AppColors.textSecondary),
      ),
      const SizedBox(height: 12),
      _readOnly('Billing type', p.billingType.label),
      const SizedBox(height: 12),
      if (p.isRetainer) ...[
        _readOnly('Monthly fee', amount(p.retainerFee)),
        const SizedBox(height: 12),
        _readOnly(
          'Hours included each month',
          p.retainerHoursValue == null
              ? 'Not set'
              : '${hoursLabel(p.retainerHoursValue!)}h',
        ),
        const SizedBox(height: 12),
        _readOnly('Roll unused hours over', p.retainerRollover ? 'Yes' : 'No'),
        const SizedBox(height: 12),
        _readOnly(
          'Rate for hours over the allowance',
          amount(p.retainerOverageRate),
        ),
        const SizedBox(height: 12),
      ],
      _readOnly('Currency', p.currency.isEmpty ? 'Not set' : p.currency),
      const SizedBox(height: 12),
      _readOnly(
        'Budget hours',
        hours == null ? 'Not set' : '${hoursLabel(hours)}h',
      ),
      const SizedBox(height: 12),
      _readOnly('Budget amount', amount(p.budgetAmount)),
      const SizedBox(height: 12),
      _readOnly('Default hourly rate', amount(p.hourlyRate)),
      for (final r in p.rates) ...[
        const SizedBox(height: 12),
        _readOnly(
          'Rate for ${r.name.isEmpty ? 'someone' : r.name}',
          amount(r.hourlyRate),
        ),
      ],
    ]);
  }

  Widget _readOnly(String label, String value) => InputDecorator(
    decoration: InputDecoration(
      labelText: label,
      enabled: false,
      border: const OutlineInputBorder(),
    ),
    child: Text(value, style: AppTypography.body),
  );

  Widget _billing() {
    final codes = [for (final c in Currency.values) c.value];
    return _card('Billing and budget', [
      DropdownButtonFormField<ProjectBillingType>(
        initialValue: _billingType,
        isExpanded: true,
        decoration: const InputDecoration(
          labelText: 'Billing type',
          border: OutlineInputBorder(),
        ),
        items: [
          for (final t in ProjectBillingType.values)
            DropdownMenuItem(value: t, child: Text(t.label)),
        ],
        onChanged: (v) => setState(() => _billingType = v ?? _billingType),
      ),
      const SizedBox(height: 12),
      DropdownButtonFormField<String>(
        initialValue: _currency,
        isExpanded: true,
        decoration: const InputDecoration(
          labelText: 'Currency',
          border: OutlineInputBorder(),
        ),
        items: [
          for (final c in codes) DropdownMenuItem(value: c, child: Text(c)),
          if (!codes.contains(_currency))
            DropdownMenuItem(value: _currency, child: Text(_currency)),
        ],
        onChanged: (v) => setState(() => _currency = v ?? _currency),
      ),
      const SizedBox(height: 12),
      if (_isRetainer) ..._retainerFields(),
      _decimalField(_budgetHours, 'Budget hours', suffix: 'h'),
      const SizedBox(height: 12),
      _decimalField(
        _budgetAmount,
        _billingType == ProjectBillingType.fixedFee
            ? 'Fee (budget amount)'
            : 'Budget amount',
        prefix: Currency.symbolFor(_currency),
      ),
      const SizedBox(height: 12),
      _decimalField(
        _hourlyRate,
        'Default hourly rate',
        prefix: Currency.symbolFor(_currency),
        helper:
            'Time logged here takes the person\'s own rate below, else '
            'this one.',
      ),
    ]);
  }

  List<Widget> _retainerFields() {
    final symbol = Currency.symbolFor(_currency);
    return [
      _decimalField(
        _retainerFee,
        'Monthly fee',
        prefix: symbol,
        error: _feeProblem,
      ),
      const SizedBox(height: 12),
      _decimalField(
        _retainerHours,
        'Hours included each month',
        suffix: 'h',
        helper: 'Leave blank to bill the fee alone, with no hours over.',
      ),
      const SizedBox(height: 12),
      // The card paints its own background, so the tile needs a Material of
      // its own to draw on.
      Material(
        type: MaterialType.transparency,
        child: SwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          title: const Text('Roll unused hours over'),
          value: _retainerRollover,
          onChanged: (v) => setState(() => _retainerRollover = v),
        ),
      ),
      const SizedBox(height: 4),
      _decimalField(
        _retainerOverage,
        'Rate for hours over the allowance',
        prefix: symbol,
        error: _overageProblem,
      ),
      const SizedBox(height: 12),
      if (widget.isEdit) ...[
        _decimalField(
          _retainerCarried,
          'Carried hours',
          suffix: 'h',
          helper: 'Unused hours carried into the next invoice.',
        ),
        const SizedBox(height: 12),
      ],
    ];
  }

  Widget _decimalField(
    TextEditingController c,
    String label, {
    String? prefix,
    String? suffix,
    String? helper,
    String? error,
  }) {
    return TextField(
      controller: c,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      onChanged: (_) => setState(() {}),
      decoration: InputDecoration(
        labelText: label,
        prefixText: prefix,
        suffixText: suffix,
        helperText: helper,
        helperMaxLines: 3,
        errorText: error ?? _decimalProblem(c.text),
        border: const OutlineInputBorder(),
      ),
    );
  }

  Widget _dates() {
    return _card('Dates', [
      _dateField('Start date', _startDate, (d) => _startDate = d),
      const SizedBox(height: 12),
      _dateField('Due date', _dueDate, (d) => _dueDate = d),
      if (_dateProblem != null) ...[
        const SizedBox(height: 6),
        Text(
          _dateProblem!,
          style: AppTypography.caption.copyWith(color: AppColors.danger700),
        ),
      ],
    ]);
  }

  Widget _dateField(
    String label,
    DateTime? value,
    void Function(DateTime?) assign,
  ) {
    return InkWell(
      onTap: () async {
        final picked = await showDatePicker(
          context: context,
          initialDate: value ?? DateTime.now(),
          firstDate: DateTime(2000),
          lastDate: DateTime(2100),
        );
        if (picked != null) setState(() => assign(picked));
      },
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          suffixIcon: value == null
              ? null
              : IconButton(
                  tooltip: 'Clear $label',
                  icon: const Icon(LucideIcons.x, size: 18),
                  onPressed: () => setState(() => assign(null)),
                ),
        ),
        child: Text(
          value == null ? 'Not set' : shortDate(value),
          style: AppTypography.body.copyWith(
            color: value == null
                ? AppColors.textSecondary
                : AppColors.textPrimary,
          ),
        ),
      ),
    );
  }

  String _userName(String id) {
    for (final u in ref.read(usersProvider)) {
      if (u.id == id) return u.displayName;
    }
    return 'Someone';
  }

  Widget _people() {
    final users = ref.watch(usersProvider);
    final names = [
      for (final id in _assignedTo)
        users.where((u) => u.id == id).firstOrNull?.displayName ?? 'Someone',
    ];
    return _card('People', [
      _pickerTile(
        icon: LucideIcons.users,
        text: names.isEmpty ? 'Nobody assigned' : names.join(', '),
        onTap: () async {
          final picked = await MultiSelectSheet.show<UserLookup>(
            context: context,
            title: 'Assign people',
            items: users,
            initialSelection: [
              for (final u in users)
                if (_assignedTo.contains(u.id)) u,
            ],
            labelOf: (u) => u.displayName,
            searchText: (u) => '${u.displayName} ${u.email}',
            emptyMessage: 'No active members',
          );
          if (picked != null) {
            // Ids the lookup does not list (an inactive member) are kept.
            final listed = {for (final u in users) u.id};
            setState(
              () => _assignedTo = [
                for (final id in _assignedTo)
                  if (!listed.contains(id)) id,
                for (final u in picked) u.id,
              ],
            );
          }
        },
      ),
    ]);
  }

  Widget _rateCard() {
    final users = ref.watch(usersProvider);
    return _card('Rates per person', [
      Text(
        'A person\'s own hourly rate on this project. Leave someone out to '
        'use the default rate.',
        style: AppTypography.caption.copyWith(color: AppColors.textSecondary),
      ),
      for (final row in _rates) ...[
        const SizedBox(height: 12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 3,
              child: DropdownButtonFormField<String>(
                initialValue: row.profileId,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Person',
                  border: OutlineInputBorder(),
                ),
                items: [
                  for (final u in users)
                    if (u.id == row.profileId ||
                        !_rates.any((r) => r.profileId == u.id))
                      DropdownMenuItem(
                        value: u.id,
                        child: Text(
                          u.displayName,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  if (row.profileId != null &&
                      !users.any((u) => u.id == row.profileId))
                    DropdownMenuItem(
                      value: row.profileId,
                      child: Text(_userName(row.profileId!)),
                    ),
                ],
                onChanged: (v) => setState(() => row.profileId = v),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              flex: 2,
              child: TextField(
                controller: row.rate,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  labelText: 'Rate',
                  prefixText: Currency.symbolFor(_currency),
                  errorText: row.profileId == null ? null : _rateProblem(row),
                  errorMaxLines: 2,
                  border: const OutlineInputBorder(),
                ),
              ),
            ),
            IconButton(
              tooltip: 'Remove rate',
              icon: const Icon(LucideIcons.trash2, size: 18),
              onPressed: () {
                setState(() => _rates.remove(row));
                // After the frame, once its field has left the tree.
                WidgetsBinding.instance.addPostFrameCallback(
                  (_) => row.rate.dispose(),
                );
              },
            ),
          ],
        ),
      ],
      const SizedBox(height: 8),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          style: TextButton.styleFrom(minimumSize: const Size(0, 44)),
          onPressed: _rates.length >= users.length && users.isNotEmpty
              ? null
              : () => setState(() => _rates.add(_RateRow())),
          icon: const Icon(LucideIcons.plus, size: 16),
          label: const Text('Add a rate'),
        ),
      ),
    ]);
  }

  Widget _extras() {
    final tags = ref.watch(tagsProvider);
    final tagNames = [
      for (final id in _tagIds)
        tags.where((t) => t.id == id).firstOrNull?.name ?? 'Tag',
    ];
    return _card('Details', [
      TextField(
        controller: _description,
        maxLines: 4,
        minLines: 2,
        textCapitalization: TextCapitalization.sentences,
        onChanged: (_) => setState(() {}),
        decoration: const InputDecoration(
          labelText: 'Description',
          border: OutlineInputBorder(),
        ),
      ),
      const SizedBox(height: 12),
      _pickerTile(
        icon: LucideIcons.tag,
        text: tagNames.isEmpty ? 'No tags' : tagNames.join(', '),
        onTap: () async {
          final picked = await MultiSelectSheet.show<TagLookup>(
            context: context,
            title: 'Tags',
            items: tags,
            initialSelection: [
              for (final t in tags)
                if (_tagIds.contains(t.id)) t,
            ],
            labelOf: (t) => t.name,
            searchText: (t) => t.name,
            emptyMessage: 'No tags',
          );
          if (picked != null) {
            final listed = {for (final t in tags) t.id};
            setState(
              () => _tagIds = [
                for (final id in _tagIds)
                  if (!listed.contains(id)) id,
                for (final t in picked) t.id,
              ],
            );
          }
        },
      ),
    ]);
  }

  Widget _pickerTile({
    required IconData icon,
    required String text,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        constraints: const BoxConstraints(minHeight: 48),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          border: Border.all(color: AppColors.gray300),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Icon(icon, size: 18, color: AppColors.textSecondary),
            const SizedBox(width: 10),
            Expanded(child: Text(text, style: AppTypography.body)),
            Icon(
              LucideIcons.chevronRight,
              size: 18,
              color: AppColors.textTertiary,
            ),
          ],
        ),
      ),
    );
  }

  Widget _saveBar() {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border(top: BorderSide(color: AppColors.gray200)),
      ),
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: SafeArea(
        top: false,
        child: SizedBox(
          width: double.infinity,
          height: 48,
          child: FilledButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(widget.isEdit ? 'Save project' : 'Create project'),
          ),
        ),
      ),
    );
  }

  Widget _card(String title, List<Widget> children) {
    return Container(
      margin: const EdgeInsets.only(top: 8),
      color: AppColors.surface,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title,
            style: AppTypography.caption.copyWith(
              color: AppColors.textSecondary,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 12),
          ...children,
        ],
      ),
    );
  }
}
