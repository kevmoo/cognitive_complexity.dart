import 'dart:io';
import 'complexity_analyzer.dart';
import 'delta_analyzer.dart';

/// Formats and emits diagnostic reports specifically for GitHub Actions CI/CD.
class GitHubReporter {
  final StringSink _stdoutSink;
  final File? _summaryFile;
  final File? _commentFile;
  final int _maxCommentRows;

  GitHubReporter({
    StringSink? stdoutSink,
    this._summaryFile,
    this._commentFile,
    this._maxCommentRows = 0,
  }) : _stdoutSink = stdoutSink ?? stdout;

  /// Generates diagnostic workflow annotations and updates step summary table.
  ///
  /// The step summary always receives the complete table. When [_commentFile]
  /// is configured, a second rendering is written there with the most
  /// significant rows first, capped at [_maxCommentRows]. GitHub rejects
  /// issue-comment bodies over 65536 characters, so posting an uncapped table
  /// on a large diff silently fails.
  void printReport({
    List<FunctionComplexity>? regularResults,
    DeltaSummary? deltaSummary,
    int? failThreshold,
    bool failOnIncrease = false,
  }) {
    final summaryBuf = _newBuffer();
    final commentBuf = _commentFile == null ? null : _newBuffer();

    if (deltaSummary != null) {
      _reportDelta(
        deltaSummary,
        failThreshold,
        failOnIncrease,
        summaryBuf,
        commentBuf,
      );
    } else if (regularResults != null) {
      _reportRegular(regularResults, failThreshold, summaryBuf);
    }

    _write(_summaryFile, summaryBuf, 'step summary', append: true);
    if (commentBuf != null) {
      _write(_commentFile, commentBuf, 'comment output', append: false);
    }
  }

  StringBuffer _newBuffer() => StringBuffer()
    ..writeln('<!-- complexity-comment-marker -->')
    ..writeln('# 📊 Cognitive Complexity Analysis')
    ..writeln();

  void _write(
    File? file,
    StringBuffer buf,
    String label, {
    required bool append,
  }) {
    if (file == null) return;
    try {
      file.writeAsStringSync(
        buf.toString(),
        mode: append ? FileMode.append : FileMode.write,
      );
    } catch (e) {
      stderr.writeln('Warning: Failed to write to $label file: $e');
    }
  }

  void _reportRegular(
    List<FunctionComplexity> results,
    int? failThreshold,
    StringBuffer summaryBuf,
  ) {
    if (results.isEmpty) {
      summaryBuf.writeln('No Dart declarations analyzed.');
      return;
    }

    summaryBuf.writeln('| Status | Declaration | Location | Score |');
    summaryBuf.writeln('| :---: | :--- | :--- | :---: |');

    for (final res in results) {
      final isViolation = failThreshold != null && res.score > failThreshold;
      final statusIcon = isViolation ? '🔴' : '🟢';
      final loc = '${res.filePath}:L${res.startLine}-${res.endLine}';
      summaryBuf.writeln(
        '| $statusIcon | `${res.name}` | `$loc` | **${res.score}** |',
      );

      if (isViolation) {
        _stdoutSink.writeln(
          '::error file=${res.filePath},line=${res.startLine},'
          'endLine=${res.endLine},title=High Cognitive Complexity '
          '(${res.score} > $failThreshold)::${res.name} has score '
          '${res.score} which exceeds failure threshold of $failThreshold.',
        );
      }
    }
  }

  void _reportDelta(
    DeltaSummary summary,
    int? failThreshold,
    bool failOnIncrease,
    StringBuffer summaryBuf,
    StringBuffer? commentBuf,
  ) {
    final net = summary.netDelta;
    final sign = net > 0 ? '+' : '';
    final violations = summary.countViolations(
      failThreshold: failThreshold,
      failOnIncrease: failOnIncrease,
    );
    final header =
        '**Net Delta**: $sign$net | **Added**: ${summary.countAdded} | '
        '**Increased**: ${summary.countIncreased} | '
        '**Improved**: ${summary.countImproved} | **Violations**: $violations';
    for (final buf in [summaryBuf, ?commentBuf]) {
      buf
        ..writeln(header)
        ..writeln();
    }

    final changed = summary.deltas
        .where((d) => d.status != DeltaStatus.unchanged)
        .toList();

    // Annotations are emitted once for every changed declaration, independent
    // of how many rows each table renders. Capping the comment must not hide
    // an inline warning from the Files-changed view.
    for (final d in changed) {
      _emitDiagnostic(d, failThreshold, failOnIncrease);
    }

    if (summary.deltas.isEmpty) {
      for (final buf in [summaryBuf, ?commentBuf]) {
        buf.writeln('No modified Dart declarations detected.');
      }
      return;
    }

    _renderDeltaTable(changed, failThreshold, failOnIncrease, summaryBuf);

    if (commentBuf != null) {
      _renderCappedComment(changed, failThreshold, failOnIncrease, commentBuf);
    }
  }

  /// Renders the sticky-comment table: most significant rows first, capped at
  /// [_maxCommentRows], with a footer pointing at the full step summary when
  /// rows were omitted.
  void _renderCappedComment(
    List<ComplexityDelta> changed,
    int? failThreshold,
    bool failOnIncrease,
    StringBuffer commentBuf,
  ) {
    final ranked = [...changed]
      ..sort((a, b) {
        final byRank = _rank(
          b,
          failThreshold,
          failOnIncrease,
        ).compareTo(_rank(a, failThreshold, failOnIncrease));
        if (byRank != 0) return byRank;
        return (b.newScore ?? 0).compareTo(a.newScore ?? 0);
      });

    final capped = _maxCommentRows > 0 && ranked.length > _maxCommentRows
        ? ranked.sublist(0, _maxCommentRows)
        : ranked;

    _renderDeltaTable(capped, failThreshold, failOnIncrease, commentBuf);

    if (capped.length < ranked.length) {
      commentBuf
        ..writeln()
        ..writeln(
          '_Showing the $_maxCommentRows most significant of '
          '${ranked.length} changed declarations. '
          'See the workflow Step Summary for the full table._',
        );
    }
  }

  /// Display priority for the capped comment: violations, then regressions,
  /// then additions, then everything else.
  int _rank(ComplexityDelta d, int? failThreshold, bool failOnIncrease) {
    if (d.isViolation(
      failThreshold: failThreshold,
      failOnIncrease: failOnIncrease,
    )) {
      return 3;
    }
    if (d.status == DeltaStatus.increased) return 2;
    if (d.status == DeltaStatus.added) return 1;
    return 0;
  }

  void _renderDeltaTable(
    List<ComplexityDelta> deltas,
    int? failThreshold,
    bool failOnIncrease,
    StringBuffer buf,
  ) {
    buf.writeln('| Status | Declaration | Location | Delta | Score |');
    buf.writeln('| :---: | :--- | :--- | :---: | :---: |');

    for (final d in deltas) {
      final isVio = d.isViolation(
        failThreshold: failThreshold,
        failOnIncrease: failOnIncrease,
      );
      final icon = _getDeltaIcon(d, isVio);
      final loc = '${d.filePath}:L${d.startLine}-${d.endLine}';
      final deltaStr = d.delta > 0 ? '+${d.delta}' : '${d.delta}';
      final scoreStr = d.oldScore != null && d.newScore != null
          ? '${d.oldScore} -> **${d.newScore}**'
          : '**${d.newScore ?? "Deleted"}**';

      buf.writeln('| $icon | `${d.name}` | `$loc` | `$deltaStr` | $scoreStr |');
    }
  }

  String _getDeltaIcon(ComplexityDelta d, bool isViolation) {
    if (isViolation) return '🔴';
    if (d.status == DeltaStatus.increased) return '🟡';
    if (d.status == DeltaStatus.improved) return '🟢';
    if (d.status == DeltaStatus.added) return '🔵';
    return '⚪';
  }

  void _emitDiagnostic(ComplexityDelta d, int? failThreshold, bool failInc) {
    final isVio = d.isViolation(
      failThreshold: failThreshold,
      failOnIncrease: failInc,
    );

    if (isVio && d.newScore != null) {
      final reason = d.status == DeltaStatus.added
          ? 'newly introduced with high complexity'
          : 'increased in complexity (+${d.delta} points)';
      _stdoutSink.writeln(
        '::error file=${d.filePath},line=${d.startLine},'
        'endLine=${d.endLine},title=Cognitive Complexity Violation::'
        '${d.name} was $reason to score ${d.newScore}.',
      );
    } else if (d.status == DeltaStatus.increased) {
      _stdoutSink.writeln(
        '::warning file=${d.filePath},line=${d.startLine},'
        'endLine=${d.endLine},title=Cognitive Complexity Increased '
        '(+${d.delta})::${d.name} increased from ${d.oldScore} to '
        '${d.newScore} (+${d.delta} points).',
      );
    }
  }
}
