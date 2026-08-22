import 'dart:io';
import 'complexity_analyzer.dart';
import 'delta_analyzer.dart';

/// Formats and emits diagnostic reports specifically for GitHub Actions CI/CD.
class GitHubReporter {
  final StringSink _stdoutSink;
  final File? _summaryFile;

  GitHubReporter({StringSink? stdoutSink, this._summaryFile})
    : _stdoutSink = stdoutSink ?? stdout;

  /// Generates diagnostic workflow annotations and updates step summary table.
  void printReport({
    List<FunctionComplexity>? regularResults,
    DeltaSummary? deltaSummary,
    int? failThreshold,
    bool failOnIncrease = false,
  }) {
    final summaryBuf = StringBuffer();
    summaryBuf.writeln('<!-- complexity-comment-marker -->');
    summaryBuf.writeln('# 📊 Cognitive Complexity Analysis');
    summaryBuf.writeln();

    if (deltaSummary != null) {
      _reportDelta(deltaSummary, failThreshold, failOnIncrease, summaryBuf);
    } else if (regularResults != null) {
      _reportRegular(regularResults, failThreshold, summaryBuf);
    }

    if (_summaryFile != null) {
      try {
        _summaryFile.writeAsStringSync(
          summaryBuf.toString(),
          mode: FileMode.append,
        );
      } catch (e) {
        stderr.writeln('Warning: Failed to write to step summary file: $e');
      }
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
        // Anchor only the declaration line: GitHub renders annotations below
        // the last line of the range, so a whole-body range would place the
        // message after the closing brace instead of under the signature.
        _stdoutSink.writeln(
          '::error file=${res.filePath},line=${res.startLine},'
          'title=High Cognitive Complexity '
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
  ) {
    final net = summary.netDelta;
    final sign = net > 0 ? '+' : '';
    final violations = summary.countViolations(
      failThreshold: failThreshold,
      failOnIncrease: failOnIncrease,
    );
    summaryBuf.writeln(
      '**Net Delta**: $sign$net | **Added**: ${summary.countAdded} | '
      '**Increased**: ${summary.countIncreased} | '
      '**Improved**: ${summary.countImproved} | **Violations**: $violations',
    );
    summaryBuf.writeln();

    if (summary.deltas.isEmpty) {
      summaryBuf.writeln('No modified Dart declarations detected.');
      return;
    }

    _renderDeltaTable(summary, failThreshold, failOnIncrease, summaryBuf);
  }

  void _renderDeltaTable(
    DeltaSummary summary,
    int? failThreshold,
    bool failOnIncrease,
    StringBuffer summaryBuf,
  ) {
    summaryBuf.writeln('| Status | Declaration | Location | Delta | Score |');
    summaryBuf.writeln('| :---: | :--- | :--- | :---: | :---: |');

    for (final d in summary.deltas) {
      if (d.status == DeltaStatus.unchanged) {
        continue;
      }

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

      summaryBuf.writeln(
        '| $icon | `${d.name}` | `$loc` | `$deltaStr` | $scoreStr |',
      );

      _emitDiagnostic(d, failThreshold, failOnIncrease);
    }
  }

  String _getDeltaIcon(ComplexityDelta d, bool isViolation) {
    if (isViolation) return '🔴';
    if (d.status == DeltaStatus.increased) return '🟡';
    if (d.status == DeltaStatus.improved) return '🟢';
    if (d.status == DeltaStatus.added) return '🔵';
    return '⚪';
  }

  /// Anchors annotations to the declaration line only: GitHub renders them
  /// below the last line of the range, so a whole-body range would place the
  /// message after the closing brace instead of under the signature.
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
        'title=Cognitive Complexity Violation::'
        '${d.name} was $reason to score ${d.newScore}.',
      );
    } else if (d.status == DeltaStatus.increased) {
      _stdoutSink.writeln(
        '::warning file=${d.filePath},line=${d.startLine},'
        'title=Cognitive Complexity Increased '
        '(+${d.delta})::${d.name} increased from ${d.oldScore} to '
        '${d.newScore} (+${d.delta} points).',
      );
    }
  }
}
