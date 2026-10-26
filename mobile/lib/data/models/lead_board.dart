import 'package:flutter/material.dart';

import '../api/schema.g.dart' as api;

/// The lead pipeline board: leads grouped by the stages of one `LeadPipeline`.
///
/// Read from `GET /leads/pipelines/` (the picker) and
/// `GET /leads/kanban/?pipeline_id=` (the lanes). The kanban response carries
/// the stages as `columns` and, beside them, `unstaged`: the leads in no
/// pipeline at all. A lead is created with no stage, so that group is the only
/// way into a pipeline, and it is shown as the first lane, "No stage". Moving
/// a lead back there takes it out of its pipeline.

const _grey = Color(0xFF6B7280);

/// A `#RRGGBB` stage colour, or grey for anything else.
Color leadStageSwatch(String? hex) {
  final raw = (hex ?? '').replaceFirst('#', '');
  if (raw.length != 6) return _grey;
  final value = int.tryParse(raw, radix: 16);
  return value == null ? _grey : Color(0xFF000000 | value);
}

/// One pipeline, as the picker lists it.
class LeadPipelineSummary {
  const LeadPipelineSummary({required this.id, required this.name});

  final String id;
  final String name;

  /// Reads a `LeadPipelineList` row.
  factory LeadPipelineSummary.fromJson(Map<String, dynamic> json) {
    final w = api.LeadPipelineList.fromJson(json);
    return LeadPipelineSummary(
      id: w.id ?? '',
      name: w.name ?? 'Untitled pipeline',
    );
  }
}

/// One lead on the board. Only what a card shows; the detail screen is a tap
/// away.
class LeadBoardCard {
  const LeadBoardCard({
    required this.id,
    required this.name,
    this.company = '',
    this.rating = '',
    this.owner = '',
    this.followUpOverdue = false,
    this.canMove = false,
  });

  final String id;
  final String name;
  final String company;

  /// `HOT`, `WARM`, `COLD`, or empty.
  final String rating;

  /// The first assignee's name or email, or empty when nobody is assigned.
  final String owner;
  final bool followUpOverdue;

  /// The server's `can_move`: whether this viewer may move the lead. Only an
  /// explicit `true` counts, so a card from a payload without the field offers
  /// no move rather than one the server may refuse.
  final bool canMove;

  /// Reads a `LeadKanbanCard`.
  factory LeadBoardCard.fromJson(Map<String, dynamic> json) {
    final w = api.LeadKanbanCard.fromJson(json);
    final details = w.assignedTo?.firstOrNull?.userDetails;
    final ownerName = details?.name ?? '';
    final fullName = w.fullName?.trim() ?? '';
    return LeadBoardCard(
      id: w.id ?? '',
      name: fullName.isNotEmpty ? fullName : (w.title ?? 'Unnamed lead'),
      company: w.companyName ?? '',
      rating: w.rating ?? '',
      owner: ownerName.isNotEmpty ? ownerName : (details?.email ?? ''),
      followUpOverdue: w.isFollowUpOverdue == true,
      canMove: w.canMove == true,
    );
  }
}

/// One lane: a stage of the pipeline, or the "No stage" group.
class LeadBoardLane {
  const LeadBoardLane({
    required this.id,
    required this.name,
    this.color = _grey,
    this.count = 0,
    this.wipLimit,
    this.cards = const [],
    this.isUnstaged = false,
  });

  /// The stage id. Empty for the "No stage" lane, which is not a stage: a
  /// move there sends `stage_id: null`. See [moveStageId].
  final String id;
  final String name;
  final Color color;

  /// Every lead in the lane the caller may see. The API sends at most 100
  /// cards a lane, so this can be larger than `cards.length`.
  final int count;
  final int? wipLimit;
  final List<LeadBoardCard> cards;
  final bool isUnstaged;

  bool get isTruncated => count > cards.length;

  /// What a move into this lane sends as `stage_id`: the stage, or null for
  /// "No stage", which takes the lead out of its pipeline.
  String? get moveStageId => isUnstaged ? null : id;

  static List<LeadBoardCard> _cards(List<api.LeadKanbanCard>? rows) => [
    for (final row in rows ?? const <api.LeadKanbanCard>[])
      LeadBoardCard.fromJson(row.json),
  ];

  /// Reads a `LeadKanbanColumn`.
  factory LeadBoardLane.fromStageJson(Map<String, dynamic> json) {
    final w = api.LeadKanbanColumn.fromJson(json);
    final cards = _cards(w.leads);
    return LeadBoardLane(
      id: w.id ?? '',
      name: w.name ?? 'Stage',
      color: leadStageSwatch(w.color),
      count: w.leadCount ?? cards.length,
      wipLimit: w.wipLimit,
      cards: cards,
    );
  }

  /// Reads the kanban answer's `unstaged`, a `LeadKanbanUnstaged`.
  factory LeadBoardLane.unstaged(Map<String, dynamic>? json) {
    final w = api.LeadKanbanUnstaged.fromJson(json ?? const {});
    final cards = _cards(w.leads);
    return LeadBoardLane(
      id: '',
      name: 'No stage',
      count: w.leadCount ?? cards.length,
      cards: cards,
      isUnstaged: true,
    );
  }

  /// "No stage" first, then the stages in their `order`. Reads a
  /// `LeadKanbanResponse`.
  static List<LeadBoardLane> fromKanbanJson(Map<String, dynamic> json) {
    final w = api.LeadKanbanResponse.fromJson(json);
    final columns = [...?w.columns]
      ..sort((a, b) => (a.order ?? 0).compareTo(b.order ?? 0));
    return [
      LeadBoardLane.unstaged(w.unstaged?.json),
      for (final column in columns) LeadBoardLane.fromStageJson(column.json),
    ];
  }
}

/// The stage a lead is in, as the lead detail endpoint names it in
/// `pipeline_stage`. Null there when the lead is in no pipeline.
class LeadStageRef {
  const LeadStageRef({
    required this.name,
    required this.pipelineName,
    this.color = _grey,
  });

  final String name;
  final String pipelineName;
  final Color color;

  /// Reads a `LeadPipelineStageRef`, the detail's `pipeline_stage`.
  static LeadStageRef? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final w = api.LeadPipelineStageRef.fromJson(json);
    return LeadStageRef(
      name: w.name ?? 'Stage',
      pipelineName: w.pipeline?.name ?? '',
      color: leadStageSwatch(w.color),
    );
  }
}
