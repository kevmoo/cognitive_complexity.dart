import 'dart:io';
import 'package:checks/checks.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:test_descriptor/test_descriptor.dart' as d;

/// Builds a declaration whose cognitive complexity grows with [depth].
/// depth 1 scores 7 (below a threshold of 15), depth 3 scores 30 (above it).
String _decl(String name, int depth) {
  final buf = StringBuffer('int $name(int x) {\n');
  for (var i = 0; i < depth; i++) {
    final pad = '  ' * (i + 1);
    buf
      ..writeln('${pad}if (x > $i) {')
      ..writeln('$pad  for (var i = 0; i < x; i++) {')
      ..writeln('$pad    if (i % 2 == 0) x++; else x--;')
      ..writeln('$pad  }');
  }
  for (var i = depth - 1; i >= 0; i--) {
    buf.writeln('${'  ' * (i + 1)}}');
  }
  return (buf
        ..writeln('  return x;')
        ..writeln('}'))
      .toString();
}

Future<void> _runGit(String repoPath, List<String> args) async {
  final res = await Process.run('git', args, workingDirectory: repoPath);
  if (res.exitCode != 0) {
    fail('git ${args.join(" ")} failed:\n${res.stderr}');
  }
}

/// Creates a two-commit fixture repo at [repoPath]: six trivial declarations,
/// then f0..f2 become violations (score 30) while f3..f5 stay under the
/// threshold but still regress (score 7).
Future<void> _createFixtureRepo(String repoPath) async {
  await Directory(p.join(repoPath, 'lib')).create(recursive: true);

  await _runGit(repoPath, ['init', '-b', 'main']);
  await _runGit(repoPath, ['config', 'user.name', 'Tester']);
  await _runGit(repoPath, ['config', 'user.email', 'test@example.com']);
  await _runGit(repoPath, ['config', 'commit.gpgsign', 'false']);

  final src = p.join(repoPath, 'lib', 'a.dart');

  await File(src).writeAsString(
    [
      for (var i = 0; i < 6; i++) 'int f$i(int x) { return x + $i; }\n',
    ].join('\n'),
  );
  await _runGit(repoPath, ['add', '.']);
  await _runGit(repoPath, ['commit', '-m', 'base']);

  await File(src).writeAsString(
    [
      for (var i = 0; i < 3; i++) _decl('f$i', 3),
      for (var i = 3; i < 6; i++) _decl('f$i', 1),
    ].join('\n'),
  );
  await _runGit(repoPath, ['add', '.']);
  await _runGit(repoPath, ['commit', '-m', 'head']);
}

/// Counts markdown table rows (header rows included) in [report].
int _tableRowCount(String report) =>
    report.split('\n').where((l) => l.startsWith('| ')).length;

void main() {
  final binPath = File('bin/cognitive_complexity.dart').existsSync()
      ? p.normalize(p.absolute('bin/cognitive_complexity.dart'))
      : p.normalize(
          p.absolute(
            'packages/cognitive_complexity/bin/cognitive_complexity.dart',
          ),
        );

  group('--comment-output', () {
    late String repoPath;
    late String summaryPath;
    late String commentPath;

    /// Runs the scanner against the fixture repo, returning the result.
    Future<ProcessResult> runScanner(List<String> extraArgs) async {
      final res = await Process.run(
        Platform.resolvedExecutable,
        [
          binPath,
          '--git-diff=HEAD~1',
          '--fail-threshold=15',
          '--fail-on-increase',
          '--format=github',
          ...extraArgs,
          'lib',
        ],
        workingDirectory: repoPath,
        environment: {'GITHUB_STEP_SUMMARY': summaryPath},
      );
      // Surface scanner output when an assertion fails: without this a
      // scanner crash shows up as an opaque missing-file error.
      printOnFailure(
        'scanner exit code: ${res.exitCode}\n'
        '--- scanner stdout ---\n${res.stdout}\n'
        '--- scanner stderr ---\n${res.stderr}',
      );
      return res;
    }

    setUp(() async {
      repoPath = p.join(d.sandbox, 'repo');
      summaryPath = p.join(d.sandbox, 'summary.md');
      commentPath = p.join(d.sandbox, 'comment.md');
      await File(summaryPath).writeAsString('');
      await _createFixtureRepo(repoPath);
    });

    test('caps comment rows and keeps the full table in the step '
        'summary', () async {
      await runScanner([
        '--comment-output=$commentPath',
        '--max-comment-rows=2',
      ]);

      final comment = await File(commentPath).readAsString();
      final summary = await File(summaryPath).readAsString();

      // 2 header rows + 2 capped data rows.
      check(_tableRowCount(comment)).equals(4);
      // 2 header rows + all 6 changed declarations.
      check(_tableRowCount(summary)).equals(8);
      check(comment).contains('most significant of 6 changed declarations');
    });

    test('orders violations ahead of sub-threshold regressions', () async {
      await runScanner([
        '--comment-output=$commentPath',
        '--max-comment-rows=3',
      ]);

      final comment = await File(commentPath).readAsString();
      final shown = comment
          .split('\n')
          .where((l) => l.startsWith('| ') && l.contains('`f'))
          .toList();

      check(shown).length.equals(3);
      // Only the three violations may occupy a three-row budget.
      check(shown).every((line) => line.contains('🔴'));
    });

    test('omits the truncation footer when everything fits', () async {
      await runScanner([
        '--comment-output=$commentPath',
        '--max-comment-rows=50',
      ]);

      final comment = await File(commentPath).readAsString();
      check(comment).not((c) => c.contains('most significant of'));
    });

    test('annotates every changed declaration regardless of the '
        'cap', () async {
      final res = await runScanner([
        '--comment-output=$commentPath',
        '--max-comment-rows=1',
      ]);

      final out = res.stdout as String;
      // Capping the comment must not hide inline Files-changed annotations.
      check('::error'.allMatches(out).length).equals(3);
      check('::warning'.allMatches(out).length).equals(3);
    });

    test('writes no comment file when --comment-output is omitted', () async {
      await runScanner([]);

      check(File(commentPath).existsSync()).isFalse();
      check(await File(summaryPath).readAsString()).contains('| 🔴 |');
    });
  });
}
