import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/flora_models.dart';
import 'codex_cli_service.dart';

enum CopilotAuthMode { missing, loggedOut, authenticated, unknown }

class CopilotCliStatus {
  const CopilotCliStatus({
    required this.installed,
    required this.mode,
    required this.message,
  });

  final bool installed;
  final CopilotAuthMode mode;
  final String message;

  bool get authenticated => mode == CopilotAuthMode.authenticated;

  String get badgeLabel {
    switch (mode) {
      case CopilotAuthMode.authenticated:
        return 'Command Code';
      case CopilotAuthMode.loggedOut:
        return 'Command Code signed out';
      case CopilotAuthMode.unknown:
        return 'Command Code unknown';
      case CopilotAuthMode.missing:
        return 'Command Code missing';
    }
  }
}

class CopilotCliService {
  const CopilotCliService._();

  static const Duration _statusCacheTtl = Duration(seconds: 8);
  static String get _commandCodeExecutable =>
      Platform.isWindows ? 'command-code.cmd' : 'command-code';
  static String get _npmExecutable => Platform.isWindows ? 'npm.cmd' : 'npm';

  static CopilotCliStatus? _cachedStatus;
  static DateTime? _cachedStatusAt;
  static Future<CopilotCliStatus>? _statusProbe;

  static Future<CopilotCliStatus> inspectStatus({bool forceRefresh = false}) {
    final now = DateTime.now();
    if (!forceRefresh &&
        _cachedStatus != null &&
        _cachedStatusAt != null &&
        now.difference(_cachedStatusAt!) <= _statusCacheTtl) {
      return Future.value(_cachedStatus!);
    }

    if (!forceRefresh && _statusProbe != null) {
      return _statusProbe!;
    }

    final probe = _inspectStatusUncached();
    _statusProbe = probe
        .then((status) {
          _cachedStatus = status;
          _cachedStatusAt = DateTime.now();
          return status;
        })
        .whenComplete(() {
          _statusProbe = null;
        });
    return _statusProbe!;
  }

  static void invalidateStatusCache() {
    _cachedStatus = null;
    _cachedStatusAt = null;
  }

  static Future<CopilotCliStatus> _inspectStatusUncached() async {
    try {
      final versionProbe = await Process.run(_commandCodeExecutable, const [
        '--version',
      ]);
      final versionText = _combineProcessOutput(versionProbe).trim();

      final installed = versionProbe.exitCode == 0;
      final statusText = versionText;

      if (!installed) {
        return CopilotCliStatus(
          installed: false,
          mode: CopilotAuthMode.missing,
          message: statusText.ifEmpty(
            'Command Code CLI is not installed. Install it with npm i -g command-code@latest.',
          ),
        );
      }

      final auth = await Process.run(_commandCodeExecutable, const ['status']);
      final authText = _combineProcessOutput(auth).trim();
      final authLower = authText.toLowerCase();

      if (auth.exitCode == 0) {
        return CopilotCliStatus(
          installed: true,
          mode: CopilotAuthMode.authenticated,
          message: authText.ifEmpty('Authenticated with Command Code.'),
        );
      }

      if (authLower.contains('not authenticated') ||
          authLower.contains('run "cmd login"') ||
          authLower.contains('run "command-code login"') ||
          authLower.contains('run cmd login') ||
          authLower.contains('run command-code login')) {
        return CopilotCliStatus(
          installed: true,
          mode: CopilotAuthMode.loggedOut,
          message: authText.ifEmpty(
            'Run command-code login to sign in with Command Code.',
          ),
        );
      }

      return CopilotCliStatus(
        installed: true,
        mode: CopilotAuthMode.unknown,
        message: authText.ifEmpty(
          statusText.ifEmpty('Command Code CLI is installed.'),
        ),
      );
    } on ProcessException catch (error) {
      return CopilotCliStatus(
        installed: false,
        mode: CopilotAuthMode.missing,
        message: error.message,
      );
    }
  }

  static Future<CodexCliCommandResult> install() async {
    final result = await _run(_npmExecutable, const [
      'i',
      '-g',
      'command-code@latest',
    ]);
    if (result.success) {
      invalidateStatusCache();
      return result;
    }

    if (Platform.isWindows && _looksLikeWindowsCopyLock(result)) {
      await Future<void>.delayed(const Duration(seconds: 2));
      final retry = await _run(_npmExecutable, const [
        'i',
        '-g',
        'command-code@latest',
      ]);

      if (retry.success) {
        invalidateStatusCache();
        return retry;
      }

      return CodexCliCommandResult(
        success: false,
        exitCode: retry.exitCode,
        stdout: retry.stdout,
        stderr: _appendInstallGuidance(retry.stderr),
        commandLine: retry.commandLine,
        eventTimeline: retry.eventTimeline,
        modelThoughts: retry.modelThoughts,
        completionMessage: retry.completionMessage,
        modifiedFiles: retry.modifiedFiles,
        linesAdded: retry.linesAdded,
        linesRemoved: retry.linesRemoved,
        executionStrategy: retry.executionStrategy,
        taskFilePath: retry.taskFilePath,
        submittedPrimaryTask: retry.submittedPrimaryTask,
      );
    }
    return result;
  }

  static bool _looksLikeWindowsCopyLock(CodexCliCommandResult result) {
    final text = result.combinedOutput.toLowerCase();
    return text.contains('ebusy') ||
        text.contains('resource busy or locked') ||
        text.contains('errno -4082');
  }

  static String _appendInstallGuidance(String stderr) {
    const guidance =
        'Windows is locking the Command Code package during npm install. Close any running Command Code terminals or processes, then run the install again.';
    final trimmed = stderr.trim();
    if (trimmed.isEmpty) {
      return guidance;
    }
    return '$trimmed\n\n$guidance';
  }

  static Future<CodexCliCommandResult> login({
    void Function(String detail)? onProgress,
  }) async {
    if (Platform.isWindows) {
      onProgress?.call(
        'Opening Command Code login in a terminal window. Complete sign-in there, then return to Flora and refresh status.',
      );
      final launch = await _run('cmd', const [
        '/c',
        'start',
        '',
        'cmd',
        '/k',
        'command-code.cmd login',
      ]);
      invalidateStatusCache();
      if (!launch.success) {
        return launch;
      }
      return const CodexCliCommandResult(
        success: true,
        exitCode: 0,
        stdout:
            'Opened a terminal window for Command Code login. Finish the browser flow there, then return to Flora and click Refresh Status.',
        stderr: '',
        commandLine: 'cmd /c start "" cmd /k "command-code.cmd login"',
      );
    }

    try {
      final process = await Process.start(_commandCodeExecutable, const [
        'login',
      ]);
      final stdoutBuffer = StringBuffer();
      final stderrBuffer = StringBuffer();
      final visibleLines = <String>[];

      void emitDetail(String line) {
        final trimmed = _stripAnsi(line).trim();
        if (trimmed.isEmpty) {
          return;
        }
        visibleLines.add(trimmed);
        onProgress?.call(_buildLoginProgress(visibleLines));
      }

      onProgress?.call(_buildLoginProgress(const []));

      final stdoutDone = process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            stdoutBuffer.writeln(line);
            emitDetail(line);
          })
          .asFuture<void>();
      final stderrDone = process.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            stderrBuffer.writeln(line);
            emitDetail(line);
          })
          .asFuture<void>();

      final exitCode = await process.exitCode;
      await Future.wait([stdoutDone, stderrDone]);

      return CodexCliCommandResult(
        success: exitCode == 0,
        exitCode: exitCode,
        stdout: _sanitizeCommandCodeText(stdoutBuffer.toString()),
        stderr: _sanitizeCommandCodeText(stderrBuffer.toString()),
        commandLine: 'command-code login',
      );
    } on ProcessException catch (error) {
      return CodexCliCommandResult(
        success: false,
        exitCode: null,
        stdout: '',
        stderr: error.message,
      );
    } finally {
      invalidateStatusCache();
    }
  }

  static Future<CodexCliCommandResult> logout() {
    return _run(_commandCodeExecutable, const ['logout']);
  }

  static String commandPreview({
    required String model,
    required String reasoningEffort,
    required CopilotPermissionMode permissionMode,
  }) {
    final arguments = [
      '--print',
      '<flora_compact_task_prompt_with_@brief>',
      '--add-dir',
      '<project root>',
      '--add-dir',
      '<temp task dir>',
      '--trust',
      '--skip-onboarding',
      '--verbose',
      ..._permissionArguments(permissionMode),
      '--model',
      model.trim().isEmpty ? 'gpt-5.4' : model.trim(),
    ];
    return _formatCommandLine(arguments);
  }

  static Future<CodexCliCommandResult> execPrompt({
    required String prompt,
    required String workingDirectory,
    String model = 'gpt-5.4',
    String reasoningEffort = 'medium',
    CopilotPermissionMode permissionMode = CopilotPermissionMode.workspaceWrite,
    void Function(AssistantExecutionUpdate update)? onProgress,
  }) async {
    final normalizedModel = model.trim().isEmpty ? 'gpt-5.4' : model.trim();
    final normalizedReasoningEffort = _normalizeReasoningEffort(
      reasoningEffort,
    );

    final firstAttempt = await _execPromptOnce(
      prompt: prompt,
      workingDirectory: workingDirectory,
      modelOverride: normalizedModel,
      reasoningEffort: normalizedReasoningEffort,
      permissionMode: permissionMode,
      onProgress: onProgress,
    );

    if (!_shouldRetryWithoutModelOverride(
      result: firstAttempt,
      requestedModel: normalizedModel,
    )) {
      return firstAttempt;
    }

    final retryNotice =
        'Requested model "$normalizedModel" is not available for this Command Code account. Flora retried once with the account default model.';
    final retryAttempt = await _execPromptOnce(
      prompt: prompt,
      workingDirectory: workingDirectory,
      modelOverride: null,
      reasoningEffort: normalizedReasoningEffort,
      permissionMode: permissionMode,
      onProgress: onProgress,
    );

    final retryReason = _firstMeaningfulLine(firstAttempt.combinedOutput);
    final retryEvents = <String>[
      'retry.model_override_rejected $normalizedModel',
      if (retryReason != null) 'retry.reason ${_truncate(retryReason, 180)}',
    ];

    if (retryAttempt.success) {
      final augmentedCompletion = _joinSections([
        retryNotice,
        retryAttempt.completionMessage,
      ]);
      return CodexCliCommandResult(
        success: true,
        exitCode: retryAttempt.exitCode,
        stdout: retryAttempt.stdout,
        stderr: _joinSections([retryAttempt.stderr, retryNotice]),
        commandLine: retryAttempt.commandLine,
        eventTimeline: [...retryEvents, ...retryAttempt.eventTimeline],
        modelThoughts: retryAttempt.modelThoughts,
        completionMessage: augmentedCompletion.isEmpty
            ? null
            : augmentedCompletion,
        modifiedFiles: retryAttempt.modifiedFiles,
        linesAdded: retryAttempt.linesAdded,
        linesRemoved: retryAttempt.linesRemoved,
        executionStrategy: retryAttempt.executionStrategy,
        taskFilePath: retryAttempt.taskFilePath,
        submittedPrimaryTask: retryAttempt.submittedPrimaryTask,
      );
    }

    return CodexCliCommandResult(
      success: false,
      exitCode: retryAttempt.exitCode ?? firstAttempt.exitCode,
      stdout: retryAttempt.stdout.isNotEmpty
          ? retryAttempt.stdout
          : firstAttempt.stdout,
      stderr: _joinSections([
        retryNotice,
        firstAttempt.stderr,
        retryAttempt.stderr,
      ]),
      commandLine: retryAttempt.commandLine,
      eventTimeline: [
        ...firstAttempt.eventTimeline,
        ...retryEvents,
        ...retryAttempt.eventTimeline,
      ],
      modelThoughts: retryAttempt.modelThoughts.isNotEmpty
          ? retryAttempt.modelThoughts
          : firstAttempt.modelThoughts,
      completionMessage:
          retryAttempt.completionMessage ?? firstAttempt.completionMessage,
      modifiedFiles: retryAttempt.modifiedFiles.isNotEmpty
          ? retryAttempt.modifiedFiles
          : firstAttempt.modifiedFiles,
      linesAdded: retryAttempt.linesAdded,
      linesRemoved: retryAttempt.linesRemoved,
      executionStrategy: retryAttempt.executionStrategy,
      taskFilePath: retryAttempt.taskFilePath ?? firstAttempt.taskFilePath,
      submittedPrimaryTask:
          retryAttempt.submittedPrimaryTask ??
          firstAttempt.submittedPrimaryTask,
    );
  }

  static Future<CodexCliCommandResult> _execPromptOnce({
    required String prompt,
    required String workingDirectory,
    required String reasoningEffort,
    required CopilotPermissionMode permissionMode,
    String? modelOverride,
    void Function(AssistantExecutionUpdate update)? onProgress,
  }) async {
    Directory? tempDir;

    try {
      tempDir = await Directory.systemTemp.createTemp('flora_copilot_');
      final taskFilePath = p.join(tempDir.path, 'flora_task.md');
      final taskFile = File(taskFilePath);
      final compactTaskBrief = _buildCompactTaskBrief(prompt);
      await taskFile.writeAsString(compactTaskBrief);

      // Copy the task brief into the project root so Command Code can always
      // find it even if --add-dir resolution fails on Windows.
      final workspaceCopyPath =
          p.join(workingDirectory, 'flora_task.md');
      try {
        await taskFile.copy(workspaceCopyPath);
      } catch (_) {}

      final submittedPrimaryTask = _extractPrimaryTask(prompt);
      // Normalize path separators because prompt-mode @file mentions and tool
      // path parsing are more reliable with forward slashes on Windows.
      final driverTaskPath = taskFilePath.replaceAll('\\', '/');
      final driverWorkingDirectory = workingDirectory.replaceAll('\\', '/');
      final driverPrompt = StringBuffer()
        ..writeln(
          'Open the task brief at $driverTaskPath and execute the Primary task from that file.',
        )
        ..writeln('Treat that file as the source of truth for the task.')
        ..writeln('Work only inside this project root: $driverWorkingDirectory')
        ..writeln(
          'Modify local files if needed instead of only describing the change.',
        )
        ..writeln(
          'Prefer create/edit file tools for local changes before using shell commands.',
        )
        ..writeln(
          'Preferred reasoning effort metadata from Flora: $reasoningEffort.',
        )
        ..writeln('Return a concise summary of the result when finished.');

      final permissionArguments = _permissionArguments(permissionMode);
      // Normalize --add-dir paths to forward slashes so Command Code
      // resolves workspace boundaries correctly on Windows.
      final normalizedWd = workingDirectory.replaceAll('\\', '/');
      final normalizedTmp = tempDir.path.replaceAll('\\', '/');

      final arguments = <String>[
        '--print',
        driverPrompt.toString().trimRight(),
        '--add-dir',
        normalizedWd,
        '--add-dir',
        normalizedTmp,
        '--trust',
        '--skip-onboarding',
        '--verbose',
        ...permissionArguments,
      ];
      if (modelOverride != null && modelOverride.trim().isNotEmpty) {
        arguments
          ..add('--model')
          ..add(modelOverride.trim());
      }

      final process = await Process.start(
        _commandCodeExecutable,
        arguments,
        workingDirectory: workingDirectory,
      );

      final commandLine = _formatCommandLine(arguments);
      final stdoutBuffer = StringBuffer();
      final stderrBuffer = StringBuffer();
      final eventTimeline = <String>[
        'prompt.original chars=${prompt.length}',
        'task_brief chars=${compactTaskBrief.length}',
      ];
      final modelThoughts = <String>[];
      final modifiedFiles = <String>[];
      var linesAdded = 0;
      var linesRemoved = 0;
      String completionMessage = '';
      String statusLine = 'Starting Command Code…';
      String liveContent = '';

      void emitProgress({
        String? status,
        String? streamedContent,
        bool isFinal = false,
      }) {
        if (status != null && status.trim().isNotEmpty) {
          statusLine = status.trim();
        }
        if (streamedContent != null) {
          liveContent = streamedContent;
        }

        onProgress?.call(
          AssistantExecutionUpdate(
            status: statusLine,
            thoughts: _tail(modelThoughts, 4),
            events: _tail(eventTimeline, 8),
            streamedContent: liveContent.isEmpty ? null : liveContent,
            isFinal: isFinal,
          ),
        );
      }

      final stdoutDone = process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            stdoutBuffer.writeln(line);
            final trimmed = line.trimRight();
            if (trimmed.isEmpty) {
              return;
            }
            completionMessage = [
              completionMessage,
              trimmed,
            ].where((part) => part.trim().isNotEmpty).join('\n').trim();
            emitProgress(
              status: 'Writing response…',
              streamedContent: completionMessage,
            );
          })
          .asFuture<void>();

      final stderrDone = process.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            stderrBuffer.writeln(line);
            final progressStatus = _captureVerboseProgressLine(
              line,
              eventTimeline,
              workingDirectory: workingDirectory,
              modifiedFiles: modifiedFiles,
            );
            emitProgress(status: progressStatus ?? 'Running Command Code…');
          })
          .asFuture<void>();

      emitProgress(status: 'Submitting prompt…');

      var heartbeatTick = 0;
      final heartbeatLabels = [
        'Waiting for Command Code…',
        'Command Code is working…',
        'Still processing…',
        'Running tools…',
        'Almost there…',
      ];
      final heartbeat = Timer.periodic(const Duration(seconds: 6), (_) {
        heartbeatTick = (heartbeatTick + 1) % heartbeatLabels.length;
        emitProgress(status: heartbeatLabels[heartbeatTick]);
      });

      final exitCode = await process.exitCode;
      heartbeat.cancel();
      await Future.wait([stdoutDone, stderrDone]);

      emitProgress(status: 'Wrapping up…', isFinal: true);

      final sanitizedStdout = _sanitizeCommandCodeText(stdoutBuffer.toString());
      final sanitizedStderr = _sanitizeCommandCodeText(stderrBuffer.toString());
      final sanitizedCompletion = _sanitizeCommandCodeText(
        completionMessage,
      ).trim();
      final resolvedStdout = sanitizedCompletion.isNotEmpty
          ? sanitizedCompletion
          : sanitizedStdout.trim();

      return CodexCliCommandResult(
        success: exitCode == 0,
        exitCode: exitCode,
        stdout: resolvedStdout,
        stderr: sanitizedStderr,
        commandLine: commandLine,
        eventTimeline: eventTimeline,
        modelThoughts: modelThoughts,
        completionMessage: sanitizedCompletion.isEmpty
            ? null
            : sanitizedCompletion,
        modifiedFiles: modifiedFiles,
        linesAdded: linesAdded,
        linesRemoved: linesRemoved,
        executionStrategy: 'command-code-print',
        taskFilePath: taskFilePath,
        submittedPrimaryTask: submittedPrimaryTask,
      );
    } on ProcessException catch (error) {
      return CodexCliCommandResult(
        success: false,
        exitCode: null,
        stdout: '',
        stderr: error.message,
        executionStrategy: 'command-code-print',
      );
    } finally {
      if (tempDir != null && await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
      try {
        final workspaceCopy =
            File(p.join(workingDirectory, 'flora_task.md'));
        if (await workspaceCopy.exists()) {
          await workspaceCopy.delete();
        }
      } catch (_) {}
    }
  }

  static Future<CodexCliCommandResult> _run(
    String executable,
    List<String> arguments,
  ) async {
    try {
      final result = await Process.run(executable, arguments);
      return CodexCliCommandResult(
        success: result.exitCode == 0,
        exitCode: result.exitCode,
        stdout: _sanitizeCommandCodeText(result.stdout?.toString() ?? ''),
        stderr: _sanitizeCommandCodeText(result.stderr?.toString() ?? ''),
      );
    } on ProcessException catch (error) {
      return CodexCliCommandResult(
        success: false,
        exitCode: null,
        stdout: '',
        stderr: error.message,
      );
    }
  }

  static String _combineProcessOutput(ProcessResult result) {
    final stdout = result.stdout?.toString() ?? '';
    final stderr = result.stderr?.toString() ?? '';
    return [
      if (stdout.trim().isNotEmpty) stdout.trim(),
      if (stderr.trim().isNotEmpty) stderr.trim(),
    ].join('\n\n');
  }

  static String _buildLoginProgress(List<String> lines) {
    final detailLines = <String>[
      'Command Code login is running.',
      'Complete the browser flow, then return to Flora and refresh status.',
    ];

    final recentLines = _tail(lines, 6);
    if (recentLines.isNotEmpty) {
      detailLines
        ..add('')
        ..addAll(recentLines);
    }

    return detailLines.join('\n');
  }

  static String? _captureVerboseProgressLine(
    String line,
    List<String> eventTimeline, {
    required String workingDirectory,
    required List<String> modifiedFiles,
  }) {
    final trimmed = _stripAnsi(line).trim();
    if (trimmed.isEmpty) {
      return null;
    }

    if (_isKnownCommandCodeCrashNoise(trimmed)) {
      return null;
    }

    final toolEvent = _parseVerboseToolEvent(
      trimmed,
      workingDirectory: workingDirectory,
    );
    if (toolEvent != null) {
      eventTimeline.add(
        '${toolEvent.timelineLabel} ${_truncate(toolEvent.target, 180)}',
      );
      if (toolEvent.isMutation) {
        _recordModifiedFile(modifiedFiles, toolEvent.target);
      }
      return toolEvent.statusLabel;
    }

    eventTimeline.add('stderr: ${_truncate(trimmed, 180)}');
    final normalized = trimmed.toLowerCase();

    if (normalized.startsWith('error:')) {
      return 'Command Code error…';
    }
    if (normalized.contains('thinking')) {
      return 'Thinking…';
    }
    if (normalized.contains('tool')) {
      return 'Running tools…';
    }
    if (normalized.contains('edit') ||
        normalized.contains('patch') ||
        normalized.contains('write')) {
      return 'Updating files…';
    }
    if (normalized.contains('read') || normalized.contains('search')) {
      return 'Inspecting project files…';
    }

    return _truncate(trimmed, 96);
  }

  static String _normalizeReasoningEffort(String input) {
    const allowed = {'low', 'medium', 'high', 'xhigh'};
    final effort = input.trim().toLowerCase();
    return allowed.contains(effort) ? effort : 'medium';
  }

  static String? _extractPrimaryTask(String prompt) {
    final match = RegExp(
      r'Primary task:\s*([\s\S]*?)(?:\n\n|\n[A-Z][^\n]*:|\n--- END USER MESSAGE ---|$)',
      caseSensitive: false,
    ).firstMatch(prompt);
    final raw = match?.group(1)?.trim();
    if (raw == null || raw.isEmpty) {
      return null;
    }
    return raw.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  static String _buildCompactTaskBrief(String prompt) {
    final systemSection = _extractPromptSection(prompt, 'SYSTEM INSTRUCTIONS');
    final userSection = _extractPromptSection(prompt, 'USER MESSAGE');
    final primaryTask =
        _extractPrimaryTask(prompt) ?? userSection.ifEmpty(prompt);
    final taskResolution = _extractNamedParagraph(
      userSection,
      'Task resolution:',
    );
    final activeFile = _extractSingleLineValue(userSection, 'Active file:');
    final inspectorMetadata = _extractBulletedBlock(
      userSection,
      'Active Flutter Inspector selection:',
    );
    final recentConversation = _extractRecentConversation(userSection);
    final hasInlineFileContents = userSection.contains('Open file contents:');
    final hasSourceExcerpt = userSection.contains(
      'Selected widget source excerpt:',
    );
    final needsInspectorResolution = systemSection.contains(
      'If the Primary task uses words like this, that, it, selected, or here',
    );

    final buffer = StringBuffer()
      ..writeln('Primary task:')
      ..writeln(primaryTask.trim());

    if (taskResolution != null ||
        (needsInspectorResolution && inspectorMetadata.isNotEmpty)) {
      buffer
        ..writeln()
        ..writeln('Task resolution:')
        ..writeln(
          taskResolution ??
              'Words like "this", "that", "it", "selected", or "here" refer to the Flutter Inspector metadata below.',
        );
    }

    if (activeFile != null) {
      buffer
        ..writeln()
        ..writeln('Active file: $activeFile');
    }

    if (inspectorMetadata.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('Active Flutter Inspector selection:');
      for (final line in inspectorMetadata) {
        buffer.writeln('- ${_truncate(line, 220)}');
      }
    }

    if (recentConversation.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('Recent conversation summary:');
      for (final entry in recentConversation) {
        buffer.writeln('- $entry');
      }
    }

    if (hasInlineFileContents || hasSourceExcerpt) {
      buffer
        ..writeln()
        ..writeln('Token-saving note:')
        ..writeln(
          'Inline file contents and source excerpts were omitted intentionally. Inspect local files only when needed.',
        );
    }

    return buffer.toString().trimRight();
  }

  static String _extractPromptSection(String prompt, String sectionName) {
    final escaped = RegExp.escape(sectionName);
    final match = RegExp(
      '--- $escaped ---\\s*([\\s\\S]*?)\\s*--- END $escaped ---',
      caseSensitive: false,
    ).firstMatch(prompt);
    return match?.group(1)?.trim() ?? '';
  }

  static String? _extractSingleLineValue(String text, String prefix) {
    for (final line in LineSplitter.split(text)) {
      if (line.startsWith(prefix)) {
        final value = line.substring(prefix.length).trim();
        return value.isEmpty ? null : value;
      }
    }
    return null;
  }

  static String? _extractNamedParagraph(String text, String heading) {
    final lines = LineSplitter.split(text).toList(growable: false);
    final startIndex = lines.indexWhere((line) => line.trim() == heading);
    if (startIndex == -1) {
      return null;
    }

    final collected = <String>[];
    for (var index = startIndex + 1; index < lines.length; index++) {
      final trimmed = lines[index].trim();
      if (trimmed.isEmpty || trimmed.startsWith('```')) {
        break;
      }
      collected.add(trimmed);
    }

    if (collected.isEmpty) {
      return null;
    }

    return collected.join(' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  static List<String> _extractBulletedBlock(String text, String heading) {
    final lines = LineSplitter.split(text).toList(growable: false);
    final startIndex = lines.indexWhere((line) => line.trim() == heading);
    if (startIndex == -1) {
      return const [];
    }

    final collected = <String>[];
    for (var index = startIndex + 1; index < lines.length; index++) {
      final trimmed = lines[index].trim();
      if (trimmed.isEmpty) {
        break;
      }
      if (!trimmed.startsWith('- ')) {
        break;
      }
      collected.add(trimmed.substring(2).trim());
    }

    return List<String>.unmodifiable(collected);
  }

  static List<String> _extractRecentConversation(String text) {
    final lines = LineSplitter.split(text).toList(growable: false);
    final startIndex = lines.indexWhere(
      (line) => line.trim() == 'Recent conversation (most recent last):',
    );
    if (startIndex == -1) {
      return const [];
    }

    final entries = <String>[];
    String? currentRole;
    var currentContent = <String>[];

    void flush() {
      if (currentRole == null || currentContent.isEmpty) {
        currentRole = null;
        currentContent = <String>[];
        return;
      }

      final content = currentContent
          .join(' ')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      if (content.isNotEmpty) {
        entries.add('$currentRole: ${_truncate(content, 180)}');
      }
      currentRole = null;
      currentContent = <String>[];
    }

    for (var index = startIndex + 1; index < lines.length; index++) {
      final trimmed = lines[index].trim();
      if (trimmed.isEmpty) {
        flush();
        continue;
      }

      if (trimmed == 'User:' ||
          trimmed == 'Assistant:' ||
          trimmed == 'System:') {
        flush();
        currentRole = trimmed.substring(0, trimmed.length - 1);
        continue;
      }

      if (currentRole != null) {
        currentContent.add(trimmed);
      }
    }

    flush();
    return _tail(entries, 2);
  }

  static List<String> _permissionArguments(CopilotPermissionMode mode) {
    final arguments = <String>[];

    switch (mode) {
      case CopilotPermissionMode.readOnly:
        break;
      case CopilotPermissionMode.workspaceWrite:
        arguments.add('--yolo');
        break;
      case CopilotPermissionMode.fullAuto:
        arguments.add('--yolo');
        break;
    }

    return arguments;
  }

  static String _formatCommandLine(List<String> arguments) {
    final escaped = arguments.map(_shellQuote).join(' ');
    return 'command-code $escaped';
  }

  static bool _shouldRetryWithoutModelOverride({
    required CodexCliCommandResult result,
    required String requestedModel,
  }) {
    if (requestedModel.trim().isEmpty || result.success) {
      return false;
    }

    final output = result.combinedOutput.toLowerCase();
    return output.contains('model_not_in_plan') ||
        output.contains('model not in plan') ||
        output.contains('available in pro and above') ||
        output.contains('model not available');
  }

  static String _joinSections(Iterable<String?> sections) {
    return sections
        .whereType<String>()
        .map((section) => section.trim())
        .where((section) => section.isNotEmpty)
        .join('\n\n');
  }

  static String? _firstMeaningfulLine(String value) {
    final sanitized = _sanitizeCommandCodeText(value);
    for (final line in LineSplitter.split(sanitized)) {
      final trimmed = line.trim();
      if (trimmed.isNotEmpty) {
        return trimmed;
      }
    }
    return null;
  }

  static String _sanitizeCommandCodeText(String value) {
    if (value.trim().isEmpty) {
      return '';
    }

    final cleanedLines = LineSplitter.split(value)
        .map((line) => _stripAnsi(line).trimRight())
        .where((line) => !_isKnownCommandCodeCrashNoise(line.trim()))
        .toList(growable: false);

    if (cleanedLines.every((line) => line.trim().isEmpty)) {
      return _stripAnsi(value).trim();
    }

    return cleanedLines.join('\n').trim();
  }

  static bool _isKnownCommandCodeCrashNoise(String line) {
    final normalized = line.trim().toLowerCase();
    if (normalized.isEmpty) {
      return false;
    }

    return normalized.contains('uv_handle_closing') ||
        normalized.contains(r'src\win\async.c');
  }

  static _VerboseToolEvent? _parseVerboseToolEvent(
    String line, {
    required String workingDirectory,
  }) {
    final match = RegExp(
      r'^(?:[✔✓]\s*)?(Read|View|Write|Edit|MultiEdit|Delete|Shell|PowerShell)\s*:\s*(.+)$',
      caseSensitive: false,
    ).firstMatch(line);
    if (match == null) {
      return null;
    }

    final kind = match.group(1)!.toLowerCase();
    final rawTarget = match.group(2)!.trim();
    final normalizedTarget = switch (kind) {
      'shell' || 'powershell' => rawTarget,
      _ => _normalizeReportedPath(rawTarget, workingDirectory),
    };

    return switch (kind) {
      'read' => _VerboseToolEvent(
        timelineLabel: 'tool.read',
        target: normalizedTarget,
        statusLabel: 'Reading project files…',
      ),
      'view' => _VerboseToolEvent(
        timelineLabel: 'tool.view',
        target: normalizedTarget,
        statusLabel: 'Reading task brief…',
      ),
      'write' => _VerboseToolEvent(
        timelineLabel: 'tool.write',
        target: normalizedTarget,
        statusLabel: 'Updating files…',
        isMutation: true,
      ),
      'edit' => _VerboseToolEvent(
        timelineLabel: 'tool.edit',
        target: normalizedTarget,
        statusLabel: 'Updating files…',
        isMutation: true,
      ),
      'multiedit' => _VerboseToolEvent(
        timelineLabel: 'tool.multiedit',
        target: normalizedTarget,
        statusLabel: 'Updating files…',
        isMutation: true,
      ),
      'delete' => _VerboseToolEvent(
        timelineLabel: 'tool.delete',
        target: normalizedTarget,
        statusLabel: 'Removing files…',
        isMutation: true,
      ),
      'shell' => _VerboseToolEvent(
        timelineLabel: 'tool.shell',
        target: normalizedTarget,
        statusLabel: 'Running shell…',
      ),
      'powershell' => _VerboseToolEvent(
        timelineLabel: 'tool.powershell',
        target: normalizedTarget,
        statusLabel: 'Running PowerShell…',
      ),
      _ => null,
    };
  }

  static String _normalizeReportedPath(
    String rawPath,
    String workingDirectory,
  ) {
    final trimmed = rawPath.trim();
    if (trimmed.isEmpty) {
      return trimmed;
    }

    final looksLikePath =
        trimmed.contains('/') ||
        trimmed.contains('\\') ||
        trimmed.startsWith('.') ||
        RegExp(r'^[A-Za-z]:').hasMatch(trimmed);
    if (!looksLikePath) {
      return trimmed;
    }

    final absolute = p.isAbsolute(trimmed)
        ? p.normalize(trimmed)
        : p.normalize(p.join(workingDirectory, trimmed));
    final normalizedRoot = p.normalize(workingDirectory);
    if (absolute == normalizedRoot) {
      return '.';
    }
    if (p.isWithin(normalizedRoot, absolute)) {
      return p.relative(absolute, from: normalizedRoot).replaceAll('\\', '/');
    }
    return absolute.replaceAll('\\', '/');
  }

  static void _recordModifiedFile(List<String> modifiedFiles, String path) {
    final normalized = path.trim();
    if (normalized.isEmpty || modifiedFiles.contains(normalized)) {
      return;
    }
    modifiedFiles.add(normalized);
  }

  static String _stripAnsi(String value) {
    return value.replaceAll(RegExp(r'\x1B\[[0-?]*[ -/]*[@-~]'), '');
  }

  static String _shellQuote(String value) {
    if (value.isEmpty) {
      return '""';
    }
    final needsQuote = value.contains(' ') || value.contains('"');
    if (!needsQuote) {
      return value;
    }
    return '"${value.replaceAll('"', r'\\"')}"';
  }

  static String _truncate(String value, int maxChars) {
    if (value.length <= maxChars) {
      return value;
    }
    return '${value.substring(0, maxChars)}...';
  }

  static List<String> _tail(List<String> items, int count) {
    if (items.length <= count) {
      return List<String>.unmodifiable(items);
    }
    return List<String>.unmodifiable(items.sublist(items.length - count));
  }
}

extension on String {
  String ifEmpty(String fallback) => trim().isEmpty ? fallback : this;
}

class _VerboseToolEvent {
  const _VerboseToolEvent({
    required this.timelineLabel,
    required this.target,
    required this.statusLabel,
    this.isMutation = false,
  });

  final String timelineLabel;
  final String target;
  final String statusLabel;
  final bool isMutation;
}
