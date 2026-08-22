## 0.2.4-wip

- Add `--comment-output` and `--max-comment-rows` CLI options: with
  `--format=github`, write a second report capped to the most significant rows
  (violations, then increases, then additions) for posting as a PR comment,
  while the step summary keeps the full table.
- Add `max-comment-rows` input to the GitHub Action (default `0` = unlimited)
  to keep sticky comments under GitHub's 65536-character body limit.
- Move package into pub workspace monorepo layout under `packages/cognitive_complexity`.
- Restore root `action.yml` and `skills/` structure for monorepo workspace.

## 0.2.3+2

- Streamline `README.md` into a focused, scannable TL;DR.
- Extract deep-dive reference documentation into modular guides under `doc/`:
  - `doc/scoring.md`: Scoring matrix, nesting multipliers, and Dart 3 AST rules.
  - `doc/cli.md`: Command-line options, git diff delta evaluation, and CI ratcheting.
  - `doc/data_flow.md`: Statement data-flow analysis, method extraction theory, and programmatic API.
  - `doc/github_actions.md`: Complete GitHub Action workflow setup, parameters, and fork security permissions.

## 0.2.3+1

- Add an example.
- Remove accidental export of internal `CognitiveComplexityVisitor` from
  `package:cognitive_complexity/cognitive_complexity.dart`.

## 0.2.3

- Fix `data_flow` crashing with `PathNotFoundException` when run as a
  standalone AOT executable (`dart run cognitive_complexity:data_flow@` /
  `dart install`), where SDK auto-discovery resolved to the app bundle
  (#21):
  - Fail fast with an actionable error (pass `--sdk-path`, set `DART_SDK`,
    or put an SDK on `PATH`) instead of handing the analyzer an unresolved
    SDK location.
  - Teach `PATH`-based discovery the Flutter checkout layout: a
    `flutter/bin/dart` wrapper script now resolves to
    `flutter/bin/cache/dart-sdk`.
  - Add a `FLUTTER_ROOT` discovery fallback.
  - Add a `--sdk-path` option to the `data_flow` CLI (plumbed to the
    existing `DataFlowAnalyzer.sdkPath` parameter); invalid explicit paths
    are rejected with a clear error.
- Fix `--fail-on-increase` ignoring `--fail-threshold`: when both are set,
  an increase now only fails the run if the new score exceeds the
  threshold. Sub-threshold increases are still reported (delta table, PR
  comment) but no longer block healthy changes such as added error
  handling. Without `--fail-threshold`, the strict any-increase ratchet is
  unchanged.
- Update the `dart-cognitive-complexity` agent skill:
  - Add explicit rule under Tier 1/2 prescribing that extracted private helper
    routines that do not read or mutate class instance state (`this`) must be
    declared as private top-level functions (or `static` methods) rather than
    instance methods.

## 0.2.2+2

- Refine the skill's 3-Tier Decomposition Rubric per empirical feedback
  (#19):
  - "Slice at natural seams" rule: enlarge slices to whole loops/state
    machines before classifying; solves coupled 2-variable state
    (`queue` + `visited`) without weakening the Tier 3 gate (stays at >= 3
    with recorded evidence).
  - Named records for private/file-local slices at any output count;
    dedicated `Result` dataclasses reserved for public API boundaries
    (aligns the rubric with the `data_flow` signature synthesizer).
  - Pattern E: loop-body extraction with explicit signal returns
    (`enum`/sealed) instead of boolean control-flow flags; ordered
    dispositions for control-flow escapes.
  - Domain-modeling exit: promoting coupled state to a real named, tested
    domain class is out of rubric scope — the gate bans `_Runner` facades,
    not real abstractions.
- No library or CLI code changes.

## 0.2.2+1

- Update the `dart-cognitive-complexity` agent skill: anti-goodhart 3-tier
  decomposition rubric with deterministic tier selection via the `data_flow`
  CLI, and a gated Tier 3 method-object reference
  (`references/method-object.md`) absorbed from `kevmoo/kevmoo_skills`.
- No library or CLI code changes.

## 0.2.2

- Introduce `data_flow` analysis tool and library (`package:cognitive_complexity/data_flow.dart`):
  - Added `DataFlowAnalyzer` to extract reaching definitions (inputs), variable mutations, and live outputs for arbitrary statement slices.
  - Added `SignatureSynthesizer` to automatically generate Dart 3 Record method signatures (`({TypeA a, TypeB b})`).
  - Added `data_flow` CLI with agent-first JSON formatting by default and formatted text reports.
  - Hardened slice analysis: pattern assignments (`(a, b) = (b, a)`), pattern
    variable declarations, labeled `break`/`continue` targeting outside the
    slice, `rethrow` whose `catch` lies outside the slice, mutations of
    captured variables inside nested closures, and constructor initializers.
  - Added `ControlFlowEscapeType.closureEscape`, `rethrowEscape`, and
    `constructorInitializerEscape`.
  - Signatures now propagate `await for` async-ness, use use-site static types
    (preserving promotion), include enclosing type parameters with their
    bounds, and sanitize/deduplicate record field names.
  - Liveness now follows loop back edges: a variable mutated in a slice inside
    a loop is reported as an output when it is read anywhere in that loop,
    even textually before the slice.

## 0.2.1

- Broaden `analyzer` compatibility to support versions `12.x` through `14.x`.

## 0.2.0

Scoring fixes aligning with the SonarSource Cognitive Complexity whitepaper
(v1.7) and its reference implementation (sonar-java):

- `else if` chains no longer deepen nesting: branch contents sit one level
  below the head `if` (previously each chain link added an extra level).
- `switch` statements/expressions and `catch` clauses now receive the
  standard nesting increment when nested (previously flat +1).
- Local function declarations no longer add a structural +1; like lambdas,
  they only deepen nesting.

Analyzer coverage and CLI fixes:

- Constructor initializers and parameter default values are now scored.
- Top-level functions named with pseudo-keywords (`show`, `on`, ...) are no
  longer skipped.
- Top-level getters/setters are reported with a `get `/`set ` prefix,
  matching class members.
- `--fail-on-increase` no longer flags newly added declarations (they have
  no baseline); they are governed by `--fail-threshold` alone.
- Directory exclusion (`.git`, `.dart_tool`, `build`) now matches whole path
  segments, so `.github/` and similar directories are scanned correctly.

## 0.1.0

- Initial version.
