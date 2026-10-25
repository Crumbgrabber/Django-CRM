import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/theme/theme.dart';
import '../../data/models/lookup_models.dart';
import '../../data/models/project.dart';
import '../../providers/lookup_provider.dart';
import '../../providers/projects_provider.dart';
import '../../routes/app_routes.dart';
import '../../widgets/common/loading.dart';
import 'project_parts.dart';

/// The projects list: search, a status and an account filter, and a card per
/// project with its budget burn. The web's table rows become cards at 390px
/// the same way.
class ProjectsListScreen extends ConsumerStatefulWidget {
  const ProjectsListScreen({super.key});

  @override
  ConsumerState<ProjectsListScreen> createState() => _ProjectsListScreenState();
}

class _ProjectsListScreenState extends ConsumerState<ProjectsListScreen> {
  final _search = TextEditingController();
  final _scroll = ScrollController();
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (!_scroll.hasClients) return;
      final p = _scroll.position;
      if (p.pixels >= p.maxScrollExtent - 400) {
        ref.read(projectsProvider.notifier).loadMore();
      }
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  ProjectFilters get _filters => ref.read(projectsProvider.notifier).filters;

  void _setFilters(ProjectFilters next) =>
      ref.read(projectsProvider.notifier).setFilters(next);

  void _onSearch(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      _setFilters(_filters.copyWith(search: value));
    });
  }

  Future<void> _pickAccount() async {
    final List<AccountLookup> accounts;
    try {
      accounts = await ref.read(accountsLookupProvider.future);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not load the accounts. Try again.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    if (!mounted) return;
    final picked = await showModalBottomSheet<AccountLookup?>(
      context: context,
      backgroundColor: AppColors.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.6,
        maxChildSize: 0.95,
        expand: false,
        builder: (_, controller) => ListView(
          controller: controller,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text('Filter by account', style: AppTypography.h3),
            ),
            for (final a in accounts)
              ListTile(
                minTileHeight: 48,
                title: Text(a.name, overflow: TextOverflow.ellipsis),
                onTap: () => Navigator.pop(ctx, a),
              ),
          ],
        ),
      ),
    );
    if (picked == null) return;
    _setFilters(
      _filters.copyWith(accountId: picked.id, accountName: picked.name),
    );
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(projectsProvider);
    // The notifier's, not the loaded page's: a reload in flight has no page,
    // and the chips must not jump back to All while it runs.
    final filters = ref.read(projectsProvider.notifier).filters;

    return Scaffold(
      backgroundColor: AppColors.surfaceDim,
      appBar: AppBar(
        title: const Text('Projects'),
        backgroundColor: AppColors.surface,
        elevation: 0,
        scrolledUnderElevation: 1,
        actions: [
          IconButton(
            icon: const Icon(LucideIcons.plus),
            tooltip: 'New project',
            onPressed: () => context.push(AppRoutes.projectNew),
          ),
        ],
      ),
      body: Column(
        children: [
          _filterBar(filters),
          Expanded(
            child: async.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, _) => EmptyState(
                icon: LucideIcons.circleAlert,
                title: 'Could not load projects',
                description: '$error'.replaceFirst('Exception: ', ''),
                actionLabel: 'Try again',
                onAction: () => ref.read(projectsProvider.notifier).refresh(),
              ),
              data: _list,
            ),
          ),
        ],
      ),
    );
  }

  Widget _filterBar(ProjectFilters filters) {
    return Container(
      color: AppColors.surface,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _search,
            onChanged: _onSearch,
            textInputAction: TextInputAction.search,
            decoration: const InputDecoration(
              hintText: 'Search projects',
              prefixIcon: Icon(LucideIcons.search, size: 18),
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _chip('All', filters.status == null, () {
                  _setFilters(filters.copyWith(status: null));
                }),
                for (final s in ProjectStatus.values)
                  _chip(s.label, filters.status == s.value, () {
                    _setFilters(filters.copyWith(status: s.value));
                  }),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: TextButton.icon(
                  style: TextButton.styleFrom(
                    minimumSize: const Size(0, 44),
                    alignment: Alignment.centerLeft,
                  ),
                  onPressed: _pickAccount,
                  icon: const Icon(LucideIcons.building2, size: 16),
                  label: Text(
                    filters.accountId == null
                        ? 'Any account'
                        : (filters.accountName ?? 'One account'),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              if (filters.accountId != null)
                IconButton(
                  tooltip: 'Any account',
                  icon: const Icon(LucideIcons.x, size: 18),
                  onPressed: () => _setFilters(
                    filters.copyWith(accountId: null, accountName: null),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _chip(String label, bool active, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(22),
        child: Container(
          constraints: const BoxConstraints(minHeight: 44),
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: active ? AppColors.primary600 : AppColors.surface,
            border: Border.all(
              color: active ? AppColors.primary600 : AppColors.gray300,
            ),
            borderRadius: BorderRadius.circular(22),
          ),
          child: Text(
            label,
            style: AppTypography.caption.copyWith(
              color: active ? Colors.white : AppColors.textSecondary,
            ),
          ),
        ),
      ),
    );
  }

  Widget _list(ProjectsListData data) {
    if (data.projects.isEmpty) {
      return EmptyState(
        icon: LucideIcons.folderKanban,
        title: data.filters.isEmpty
            ? 'No projects yet'
            : 'No matching projects',
        description: data.filters.isEmpty
            ? 'A project holds the tasks, time and invoices for one piece of '
                  'client work. Start one here or from a won deal.'
            : 'Clear a filter to see more.',
        actionLabel: data.filters.isEmpty ? 'New project' : null,
        onAction: data.filters.isEmpty
            ? () => context.push(AppRoutes.projectNew)
            : null,
      );
    }
    return RefreshIndicator(
      onRefresh: () => ref.read(projectsProvider.notifier).refresh(),
      child: ListView.builder(
        controller: _scroll,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(bottom: 96),
        itemCount: data.projects.length + (data.hasMore ? 1 : 0),
        itemBuilder: (context, i) {
          if (i >= data.projects.length) {
            return const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator()),
            );
          }
          return ProjectRow(project: data.projects[i]);
        },
      ),
    );
  }
}

/// One project as a card: name, client, status, due date and the budget
/// closest to running out.
class ProjectRow extends StatelessWidget {
  const ProjectRow({super.key, required this.project});

  final Project project;

  @override
  Widget build(BuildContext context) {
    final p = project;
    final headline = p.burn.headline;
    final meta = [
      p.billingType.label,
      if (p.dueDate != null) 'due ${shortDate(p.dueDate!)}',
      '${hoursLabel(p.burn.loggedHours)}h logged',
    ].join(' · ');
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: AppLayout.borderRadiusMd,
        border: Border.all(color: AppColors.border),
      ),
      child: InkWell(
        borderRadius: AppLayout.borderRadiusMd,
        onTap: () => context.push(AppRoutes.projectFor(p.id)),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      p.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: AppTypography.labelSmall.copyWith(fontSize: 14),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ProjectStatusPill(project: p),
                ],
              ),
              if (p.account != null) ...[
                const SizedBox(height: 2),
                Text(
                  p.account!.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTypography.caption.copyWith(
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
              const SizedBox(height: 6),
              Text(
                meta,
                style: AppTypography.caption.copyWith(
                  color: AppColors.textTertiary,
                ),
              ),
              if (headline != null) ...[
                const SizedBox(height: 8),
                BurnBar(
                  label: headline.kind == 'hours' ? 'Hours' : 'Amount',
                  used: headline.kind == 'hours'
                      ? '${hoursLabel(p.burn.loggedHours)}h of '
                            '${hoursLabel(p.budgetHoursValue ?? 0)}h'
                      : '${projectMoney(p, p.burn.billableValue)} of '
                            '${projectMoney(p, p.budgetAmountValue ?? 0)}',
                  percent: headline.percent,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
