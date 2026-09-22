part of '../server.dart';

/// Android emulator lifecycle tools.
///
/// The rest of this server can drive an Android emulator but assumes one
/// already exists and is booted. These tools close that gap so an agent can
/// bring an emulator up on its own before testing a feature, with no manual
/// SDK setup.
///
/// The work is delegated to the bundled `scripts/android-env` shell script,
/// which handles SDK provisioning, AVD creation and boot waiting. It is driven
/// with `--json` so both success and failure come back structured.
extension _AndroidEmulatorHandlers on FlutterMcpServer {
  /// Locate the `android-env` script.
  ///
  /// Prefers the copy bundled with this package so behaviour is predictable,
  /// and falls back to one on PATH for users who installed it separately.
  String? _findAndroidEnv() {
    final candidates = <String>[];

    // Next to a compiled executable. This is the case that matters in
    // practice: the server usually runs with the current directory set to
    // whichever project is being tested, not to this package.
    try {
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      candidates.add('$exeDir/scripts/android-env');
      candidates.add('$exeDir/android-env');
    } catch (_) {
      // resolvedExecutable is always available in practice; be defensive.
    }

    // Stable install location, populated when the binary is installed.
    final home =
        Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
    if (home != null) {
      candidates.add('$home/.flutter-skill/scripts/android-env');
    }

    // Source checkout: bin/../scripts.
    try {
      final scriptPath = Platform.script.toFilePath();
      final projectRoot = Directory(scriptPath).parent.parent.path;
      candidates.add('$projectRoot/scripts/android-env');
    } catch (_) {
      // Platform.script is not always a file path (e.g. compiled snapshots).
    }

    // Running from the package root.
    candidates.add('${Directory.current.path}/scripts/android-env');

    for (final c in candidates) {
      if (File(c).existsSync()) return c;
    }

    // Installed on PATH by `android-env install`.
    final which = Platform.isWindows ? 'where' : 'which';
    try {
      final r = Process.runSync(which, ['android-env']);
      if (r.exitCode == 0) {
        final found = r.stdout.toString().trim().split('\n').first.trim();
        if (found.isNotEmpty && File(found).existsSync()) return found;
      }
    } catch (_) {
      // No `which`/`where` available.
    }

    return null;
  }

  /// Run android-env and return its combined output plus exit code.
  ///
  /// The script is bash, so Windows needs Git Bash on PATH. Long operations
  /// (a first-time SDK install downloads well over a GB) are given the
  /// caller's timeout rather than a fixed one.
  Future<Map<String, dynamic>> _runAndroidEnv(
    List<String> args,
    Duration timeout,
  ) async {
    final script = _findAndroidEnv();
    if (script == null) {
      return {
        'success': false,
        'error': 'Could not find the android-env script. Expected it at '
            'scripts/android-env inside this package, or on PATH.',
      };
    }

    final String exe;
    final List<String> fullArgs;
    if (Platform.isWindows) {
      exe = 'bash';
      fullArgs = [script, ...args];
    } else {
      exe = script;
      fullArgs = args;
    }

    Process proc;
    try {
      proc = await Process.start(
        exe,
        fullArgs,
        // Nothing may prompt: the script treats a non-tty stdin as unattended.
        environment: {'ANDROID_ENV_YES': '1'},
        includeParentEnvironment: true,
      );
    } catch (e) {
      final hint = Platform.isWindows
          ? ' On Windows this needs Git Bash available as `bash`.'
          : '';
      return {
        'success': false,
        'error': 'Could not run $exe: $e.$hint',
      };
    }

    final stdoutBuf = StringBuffer();
    final stderrBuf = StringBuffer();
    final outDone =
        proc.stdout.transform(utf8.decoder).forEach(stdoutBuf.write);
    final errDone =
        proc.stderr.transform(utf8.decoder).forEach(stderrBuf.write);

    int exitCode;
    try {
      exitCode = await proc.exitCode.timeout(timeout);
    } on TimeoutException {
      proc.kill(ProcessSignal.sigterm);
      return {
        'success': false,
        'error': 'android-env ${args.join(' ')} exceeded '
            '${timeout.inSeconds}s and was terminated.',
        'stdout': stdoutBuf.toString(),
        'stderr': stderrBuf.toString(),
      };
    }

    await Future.wait([outDone, errDone]);

    return {
      'success': exitCode == 0,
      'exit_code': exitCode,
      'stdout': stdoutBuf.toString(),
      'stderr': stderrBuf.toString(),
    };
  }

  /// Pull the JSON object out of the script's stdout.
  ///
  /// `ensure --json` prints one JSON object, but progress lines from a
  /// first-time SDK install can precede it, so the last JSON-looking line
  /// wins rather than assuming the whole of stdout is JSON.
  Map<String, dynamic>? _parseAndroidEnvJson(String stdout) {
    final lines = stdout.trim().split('\n');
    for (final line in lines.reversed) {
      final t = line.trim();
      if (!t.startsWith('{') || !t.endsWith('}')) continue;
      try {
        final decoded = jsonDecode(t);
        if (decoded is Map<String, dynamic>) return decoded;
      } catch (_) {
        // Not JSON after all; keep looking backwards.
      }
    }
    return null;
  }

  /// Strip ANSI colour codes so human-readable output is usable in a result.
  String _stripAnsi(String s) =>
      s.replaceAll(RegExp(r'\x1B\[[0-9;]*[A-Za-z]'), '');

  Future<dynamic> _handleAndroidEmulatorTools(
      String name, Map<String, dynamic> args) async {
    if (name == 'android_emulator_ensure') {
      final avdName = args['avd_name'] as String?;
      final timeoutSeconds = (args['timeout_seconds'] as num?)?.toInt() ?? 900;

      final cmd = <String>['ensure'];
      if (avdName != null && avdName.isNotEmpty) cmd.add(avdName);
      cmd.add('--json');
      // Give the script a slightly smaller boot budget than our own process
      // timeout so it reports a clean JSON failure instead of being killed.
      final bootBudget = timeoutSeconds > 60 ? timeoutSeconds - 30 : 30;
      cmd.add('--timeout=$bootBudget');

      final run = await _runAndroidEnv(cmd, Duration(seconds: timeoutSeconds));
      if (run.containsKey('error') && !run.containsKey('stdout')) {
        return run; // Could not launch at all.
      }

      final parsed = _parseAndroidEnvJson(run['stdout'] as String? ?? '');
      if (parsed != null) {
        return {
          ...parsed,
          if (parsed['success'] != true)
            'details': _stripAnsi(run['stderr'] as String? ?? '').trim(),
        };
      }

      return {
        'success': false,
        'error': 'android-env ensure produced no JSON result.',
        'stdout': _stripAnsi(run['stdout'] as String? ?? '').trim(),
        'stderr': _stripAnsi(run['stderr'] as String? ?? '').trim(),
      };
    }

    if (name == 'android_emulator_start') {
      final avdName = args['avd_name'] as String?;
      final wait = args['wait'] as bool? ?? true;
      final timeoutSeconds = (args['timeout_seconds'] as num?)?.toInt() ?? 300;

      final cmd = <String>['start'];
      if (avdName != null && avdName.isNotEmpty) cmd.add(avdName);
      if (wait) {
        cmd.add('--wait');
        cmd.add('--timeout=${timeoutSeconds > 30 ? timeoutSeconds - 15 : 30}');
      }

      final run = await _runAndroidEnv(
        cmd,
        Duration(seconds: wait ? timeoutSeconds : 30),
      );
      final out = _stripAnsi(run['stdout'] as String? ?? '').trim();
      final err = _stripAnsi(run['stderr'] as String? ?? '').trim();
      return {
        'success': run['success'] == true,
        'avd_name': avdName,
        'waited_for_boot': wait,
        if (out.isNotEmpty) 'output': out,
        if (err.isNotEmpty) 'error': err,
      };
    }

    if (name == 'android_emulator_stop') {
      final avdName = args['avd_name'] as String?;
      final cmd = <String>['stop'];
      if (avdName != null && avdName.isNotEmpty) cmd.add(avdName);

      final run = await _runAndroidEnv(cmd, const Duration(seconds: 120));
      final out = _stripAnsi(run['stdout'] as String? ?? '').trim();
      final err = _stripAnsi(run['stderr'] as String? ?? '').trim();
      return {
        'success': run['success'] == true,
        'stopped': avdName ?? 'all',
        if (out.isNotEmpty) 'output': out,
        if (err.isNotEmpty) 'error': err,
      };
    }

    if (name == 'android_emulator_list') {
      final run = await _runAndroidEnv(['list'], const Duration(seconds: 30));
      final out = _stripAnsi(run['stdout'] as String? ?? '');
      // Drop the header line; whatever remains is one AVD name per line.
      final avds = out
          .split('\n')
          .map((l) => l.trim())
          .where((l) =>
              l.isNotEmpty &&
              !l.startsWith('Available') &&
              !l.startsWith('No AVDs'))
          .toList();
      final err = _stripAnsi(run['stderr'] as String? ?? '').trim();
      return {
        'success': run['success'] == true,
        'avds': avds,
        'count': avds.length,
        // Without this a missing android-env script looked like "no emulators".
        if (run['success'] != true)
          'error': (run['error'] as String?) ??
              (err.isNotEmpty ? err : 'android-env list failed'),
      };
    }

    if (name == 'android_emulator_delete') {
      final avdName = args['avd_name'] as String?;
      final confirm = args['confirm'] as bool? ?? false;
      if (avdName == null || avdName.isEmpty) {
        return {'success': false, 'error': 'avd_name is required'};
      }
      if (!confirm) {
        return {
          'success': false,
          'error': 'Deleting an emulator is destructive. '
              'Pass confirm: true to proceed.',
        };
      }

      final run = await _runAndroidEnv(
        ['delete', avdName, '-y'],
        const Duration(seconds: 120),
      );
      final out = _stripAnsi(run['stdout'] as String? ?? '').trim();
      final err = _stripAnsi(run['stderr'] as String? ?? '').trim();
      return {
        'success': run['success'] == true,
        'deleted': avdName,
        if (out.isNotEmpty) 'output': out,
        if (err.isNotEmpty) 'error': err,
      };
    }

    return null; // Not handled by this group
  }
}
