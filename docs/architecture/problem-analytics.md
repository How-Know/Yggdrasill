# Problem Analytics Direction

This note records the long-term direction for textbook problem snapshots,
future iPad solving logs, and aggregate analytics. Treat it as guidance, not a
locked contract: before implementing analytics-related changes, reread this
document and offer the user a few current options.

## Current Decision

The first step is an analytics-ready `homework_item_problems` table for
migrated textbook homework. It stores the exact problems assigned at issue time,
including original source metadata, display numbering, and crop/problem-bank
links. It does not yet create solving attempts, event logs, or aggregate stats.

## Why This Exists

Textbook homework can be selected by problem crop, page, or fallback text. Page
fallback is useful for old data, but it can accidentally render an entire page or
include set headers. `homework_item_problems` should become the canonical list
for new migrated textbook assignments.

Future iPad solving records should attach to a stable assigned-problem row and,
where possible, to the original problem identity (`crop_id` or
`pb_question_uid`). This allows later analytics such as:

- accuracy by original problem and student level bucket
- solve time and revision count by problem
- first-attempt correctness
- conditional recommendations such as "students who missed problem A often miss
  problem B"

## Operating Principles

- Keep raw solving logs append-only when they are introduced.
- Do not compute app-screen analytics by scanning raw logs at request time.
- Prefer summary tables or scheduled batch jobs for stats and recommendations.
- Keep fallback compatibility for old homework that lacks problem snapshots.
- Preserve assignment-time snapshots even if source crops are reprocessed later.

## Likely Future Tables

- `student_problem_attempts`: one row per student/problem attempt or final solve
  session.
- `student_problem_events`: optional append-only timeline for answer changes,
  hints, pauses, and corrections.
- `problem_stats_by_level`: per-problem aggregates by level bucket.
- `problem_pair_stats`: constrained pair aggregates for recommendations.

## Decision Points For Future AI

Before changing this area, propose 2-3 options to the user when relevant:

- minimum snapshot vs analytics-ready snapshot vs full solving-log scope
- `homework_item_problems` as canonical source vs legacy fallback source
- synchronous aggregate updates vs nightly/batch recomputation
- same-unit-only pair stats vs wider problem-bank pair stats

The current default is: `homework_item_problems` canonical for new data,
fallbacks for old data, raw logs later, summaries for analytics.
