import 'package:flutter/material.dart';

import '../api/schema.g.dart' as api;
import 'lead_board.dart';
import 'ticket.dart';

/// The ticket board: tickets grouped by status, or by the stages of one
/// ticket pipeline.
///
/// Read from `GET /cases/pipelines/` (the picker) and `GET /cases/kanban/`
/// (the lanes; `?pipeline_id=` for a pipeline's stages). In status mode each
/// lane's id is the status value and a move sends `{status}`; in pipeline mode
/// it is the stage id and a move sends `{stage_id}`.
///
/// The status-mode Duplicate lane is dropped. The board hides merged
/// duplicates, so that lane is always empty, and moving a ticket into it would
/// make the ticket vanish without a merge.

/// A pipeline as the picker lists it: the same `{id, name}` the lead board
/// reads.
typedef TicketPipelineSummary = LeadPipelineSummary;

/// One ticket on the board. Only what a card shows; the detail screen is a
/// tap away.
class TicketBoardCard {
  const TicketBoardCard({
    required this.id,
    required this.name,
    this.accountName = '',
    this.assignee = '',
    this.priority = TicketPriority.normal,
    this.slaBreached = false,
    this.slaAtRisk = false,
    this.canMove = false,
  });

  final String id;
  final String name;
  final String accountName;

  /// The first assignee's name or email, or empty when nobody is assigned.
  final String assignee;
  final TicketPriority priority;
  final bool slaBreached;
  final bool slaAtRisk;

  /// The server's `can_move`, the ticket write rule. The board lists by the
  /// wider read rule, so a watcher sees the tickets they follow and may move
  /// none of them. Only an explicit `true` counts, so a card from a payload
  /// without the field offers no move rather than one the server refuses.
  final bool canMove;

  /// Reads a `CaseKanbanCard`.
  factory TicketBoardCard.fromJson(Map<String, dynamic> json) {
    final w = api.CaseKanbanCard.fromJson(json);
    final details = w.assignedTo?.firstOrNull?.userDetails;
    final assigneeName = details?.name ?? '';
    final name = w.name?.trim() ?? '';
    return TicketBoardCard(
      id: w.id ?? '',
      name: name.isNotEmpty ? name : 'Untitled ticket',
      accountName: w.accountName ?? '',
      assignee: assigneeName.isNotEmpty ? assigneeName : details?.email ?? '',
      priority: TicketPriority.fromString(w.priority),
      slaBreached: w.isSlaBreached ?? false,
      slaAtRisk: w.isSlaAtRisk ?? false,
      canMove: w.canMove ?? false,
    );
  }
}

/// One lane: a status, or a stage of the open pipeline.
class TicketBoardLane {
  const TicketBoardLane({
    required this.id,
    required this.name,
    this.isStatus = true,
    this.color = const Color(0xFF6B7280),
    this.count = 0,
    this.wipLimit,
    this.cards = const [],
  });

  /// The status value in status mode, the stage id in pipeline mode.
  final String id;
  final String name;
  final bool isStatus;
  final Color color;

  /// Every ticket in the lane the caller may see. The API sends at most 100
  /// cards a lane, so this can be larger than `cards.length`.
  final int count;
  final int? wipLimit;
  final List<TicketBoardCard> cards;

  bool get isTruncated => count > cards.length;

  /// The `PATCH /cases/<id>/move/` body that lands a ticket in this lane.
  Map<String, dynamic> get moveBody =>
      isStatus ? {'status': id} : {'stage_id': id};

  /// Reads a `CaseKanbanColumn`.
  factory TicketBoardLane.fromJson(
    Map<String, dynamic> json, {
    required bool isStatus,
  }) {
    final w = api.CaseKanbanColumn.fromJson(json);
    final cards = [
      for (final c in w.cases ?? const <api.CaseKanbanCard>[])
        TicketBoardCard.fromJson(c.json),
    ];
    return TicketBoardLane(
      id: w.id ?? '',
      name: w.name ?? 'Stage',
      isStatus: isStatus,
      color: leadStageSwatch(w.color),
      count: w.caseCount ?? cards.length,
      wipLimit: w.wipLimit,
      cards: cards,
    );
  }

  /// The lanes in their `order`, without the status-mode Duplicate lane.
  static List<TicketBoardLane> fromKanbanJson(Map<String, dynamic> json) {
    final w = api.CaseKanbanResponse.fromJson(json);
    final isStatus = w.mode != 'pipeline';
    final columns =
        (w.columns ?? const <api.CaseKanbanColumn>[])
            .where((c) => !(isStatus && c.id == TicketStatus.duplicate.value))
            .toList()
          ..sort((a, b) => (a.order ?? 0).compareTo(b.order ?? 0));
    return [
      for (final c in columns)
        TicketBoardLane.fromJson(c.json, isStatus: isStatus),
    ];
  }
}
