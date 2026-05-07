import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../app/theme/flora_theme.dart';
import '../../../core/models/flora_models.dart';
import '../../../core/services/copilot_cli_service.dart';
import '../../../core/services/codex_cli_service.dart';
import '../../../core/state/flora_providers.dart';

String _normalizeProjectPath(String value) {
  final normalized = p.normalize(p.absolute(value.trim()));
  return Platform.isWindows ? normalized.toLowerCase() : normalized;
}

bool _isPathInsideProjectRoot(String projectRoot, String candidatePath) {
  final normalizedRoot = _normalizeProjectPath(projectRoot);
  final normalizedPath = _normalizeProjectPath(candidatePath);
  return normalizedPath == normalizedRoot ||
      p.isWithin(normalizedRoot, normalizedPath);
}

String? _projectScopedPath(String? candidatePath, String? projectRoot) {
  if (projectRoot == null || projectRoot.trim().isEmpty) {
    return null;
  }
  if (candidatePath == null || candidatePath.trim().isEmpty) {
    return null;
  }
  return _isPathInsideProjectRoot(projectRoot, candidatePath)
      ? candidatePath
      : null;
}

bool _looksLikeDeicticTask(String value) {
  final normalized = value.trim().toLowerCase();
  if (normalized.isEmpty) {
    return false;
  }

  return RegExp(
    r'\b(this|that|it|this one|that one|selected|remove this|delete this|change this|fix this|update this|move this|hide this)\b',
  ).hasMatch(normalized);
}

InspectorSelectionContext? _projectScopedInspectorSelection(
  InspectorSelectionContext? selection,
  String? projectRoot,
) {
  if (selection == null) {
    return null;
  }
  if (projectRoot == null || projectRoot.trim().isEmpty) {
    return null;
  }

  final sourceFile = selection.sourceFile;
  if (sourceFile == null || sourceFile.trim().isEmpty) {
    return null;
  }

  return _isPathInsideProjectRoot(projectRoot, sourceFile) ? selection : null;
}

List<ChatMessage> _recentPromptHistory(List<ChatMessage> history) {
  final resolved = history.where((message) {
    if (message.isStreaming) {
      return false;
    }
    if (message.role == MessageRole.system) {
      return false;
    }
    return message.content.trim().isNotEmpty;
  }).toList();

  if (resolved.length <= 6) {
    return resolved;
  }
  return resolved.sublist(resolved.length - 6);
}

String _summarizeConversationEntry(String value, {int maxChars = 220}) {
  final normalized = value.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (normalized.length <= maxChars) {
    return normalized;
  }
  return '${normalized.substring(0, maxChars)}...';
}

List<String> _extractSuggestedFollowUps(String content) {
  final lines = content.split('\n');
  final candidates = <String>[];
  for (final line in lines) {
    final trimmed = line.trim();
    if (trimmed.isEmpty || trimmed.startsWith('```')) continue;
    String? candidate;
    if (trimmed.startsWith('- ') ||
        trimmed.startsWith('\u2022 ') ||
        trimmed.startsWith('* ')) {
      candidate = trimmed.substring(2).trim();
    } else if (RegExp(r'^\d+\.\s').hasMatch(trimmed)) {
      candidate = trimmed.replaceFirst(RegExp(r'^\d+\.\s+'), '');
    }
    if (candidate != null &&
        candidate.length > 8 &&
        candidate.length < 90 &&
        !candidate.contains('`')) {
      candidates.add(candidate);
    }
  }
  if (candidates.isEmpty) return const [];
  final start = candidates.length > 3 ? candidates.length - 3 : 0;
  return List.unmodifiable(candidates.sublist(start));
}

void _appendComposerText(WidgetRef ref, String text, {bool replace = false}) {
  final normalized = text.trim();
  if (normalized.isEmpty) {
    return;
  }

  final existing = ref.read(chatComposerTextProvider).trim();
  ref.read(chatComposerTextProvider.notifier).state =
      replace || existing.isEmpty ? normalized : '$existing\n\n$normalized';
}

String _projectRelativeLabel(String path, String? projectRoot) {
  if (projectRoot == null || projectRoot.trim().isEmpty) {
    return p.basename(path);
  }

  final normalizedRoot = p.normalize(projectRoot);
  final normalizedPath = p.normalize(path);
  if (normalizedPath == normalizedRoot) {
    return p.basename(path);
  }

  if (p.isWithin(normalizedRoot, normalizedPath)) {
    return p
        .relative(normalizedPath, from: normalizedRoot)
        .replaceAll('\\', '/');
  }

  return p.basename(path);
}

enum _ContextPanelSection { context, app, inspector, files }

class _ProviderStatusSnapshot {
  const _ProviderStatusSnapshot({
    required this.installed,
    required this.authenticated,
    required this.badgeLabel,
    required this.mode,
    required this.message,
  });

  final bool installed;
  final bool authenticated;
  final String badgeLabel;
  final String mode;
  final String message;
}

class ChatWorkspacePane extends ConsumerStatefulWidget {
  const ChatWorkspacePane({super.key});

  @override
  ConsumerState<ChatWorkspacePane> createState() => _ChatWorkspacePaneState();
}

class _ChatWorkspacePaneState extends ConsumerState<ChatWorkspacePane> {
  final _inputCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  final _inputFocus = FocusNode();
  Timer? _pendingScroll;
  String? _lastSubmittedText;
  DateTime? _lastSubmittedAt;

  @override
  void initState() {
    super.initState();
    _inputCtrl.text = ref.read(chatComposerTextProvider);
    _inputCtrl.addListener(_syncComposerDraftFromInput);
  }

  @override
  void dispose() {
    _pendingScroll?.cancel();
    _inputCtrl.removeListener(_syncComposerDraftFromInput);
    _inputCtrl.dispose();
    _scrollCtrl.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  void _syncComposerDraftFromInput() {
    final currentDraft = ref.read(chatComposerTextProvider);
    if (currentDraft == _inputCtrl.text) {
      return;
    }
    ref.read(chatComposerTextProvider.notifier).state = _inputCtrl.text;
  }

  String? _readFileExcerpt(
    String path, {
    required int? startLine,
    required int? endLine,
    int contextRadius = 4,
  }) {
    try {
      final raw = File(path).readAsStringSync();
      final lines = raw.split('\n');
      if (lines.isEmpty) {
        return null;
      }

      final anchorStart = startLine == null || startLine < 1 ? 1 : startLine;
      final anchorEnd = endLine == null || endLine < anchorStart
          ? anchorStart
          : endLine;

      final excerptStart = anchorStart - contextRadius < 1
          ? 1
          : anchorStart - contextRadius;
      final excerptEnd = anchorEnd + contextRadius > lines.length
          ? lines.length
          : anchorEnd + contextRadius;

      final excerpt = <String>[];
      for (
        var lineNumber = excerptStart;
        lineNumber <= excerptEnd;
        lineNumber++
      ) {
        excerpt.add(
          '${lineNumber.toString().padLeft(4)}: ${lines[lineNumber - 1]}',
        );
      }

      return excerpt.join('\n').trimRight();
    } catch (_) {
      return null;
    }
  }

  Future<_ProviderStatusSnapshot> _inspectProviderStatus(
    AssistantProviderType provider,
  ) async {
    if (provider == AssistantProviderType.codex) {
      final status = await CodexCliService.inspectStatus();
      return _ProviderStatusSnapshot(
        installed: status.installed,
        authenticated: status.authenticated,
        badgeLabel: status.badgeLabel,
        mode: status.mode.name,
        message: status.message,
      );
    }

    final status = await CopilotCliService.inspectStatus();
    return _ProviderStatusSnapshot(
      installed: status.installed,
      authenticated: status.authenticated,
      badgeLabel: status.badgeLabel,
      mode: status.mode.name,
      message: status.message,
    );
  }

  void _pushProviderStatus(
    AssistantProviderType provider,
    _ProviderStatusSnapshot status,
  ) {
    if (provider == AssistantProviderType.codex) {
      ref.read(codexInstalledProvider.notifier).state = status.installed;
      ref.read(codexAuthenticatedProvider.notifier).state =
          status.authenticated;
      ref.read(codexAuthLabelProvider.notifier).state = status.badgeLabel;
      return;
    }

    ref.read(copilotInstalledProvider.notifier).state = status.installed;
    ref.read(copilotAuthenticatedProvider.notifier).state =
        status.authenticated;
    ref.read(copilotAuthLabelProvider.notifier).state = status.badgeLabel;
  }

  Future<_ProviderStatusSnapshot> _syncProviderStatus(
    AssistantProviderType provider,
  ) async {
    final status = await _inspectProviderStatus(provider);
    _pushProviderStatus(provider, status);
    return status;
  }

  String _buildPrompt({
    required String text,
    required List<ChatMessage> history,
    required String projectRoot,
    required AssistantProviderType assistantProvider,
  }) {
    final activePath = _projectScopedPath(
      ref.read(activeFilePathProvider),
      projectRoot,
    );
    final inspectorSelection = _projectScopedInspectorSelection(
      ref.read(inspectorSelectionProvider),
      projectRoot,
    );
    final selectedSourcePath = _projectScopedPath(
      inspectorSelection?.sourceFile,
      projectRoot,
    );
    final selectedSourceExcerpt = selectedSourcePath == null
        ? null
        : _readFileExcerpt(
            selectedSourcePath,
            startLine: inspectorSelection?.line,
            endLine: inspectorSelection?.endLine,
          );
    final promptHistory = _recentPromptHistory(history);
    final systemBuffer = StringBuffer()
      ..writeln(
        'You are ${assistantProvider.label} running inside Flora, a Flutter desktop coding workspace.',
      )
      ..writeln('Work inside this project root: $projectRoot')
      ..writeln(
        'Treat the USER MESSAGE block as the only task to execute. All other blocks are supporting context.',
      )
      ..writeln(
        'Respond directly to the user request instead of acknowledging setup or restating instructions.',
      )
      ..writeln(
        'If the user asks for code or configuration changes, inspect and modify the relevant local files under the project root before answering.',
      )
      ..writeln(
        'Ignore Copilot-injected timestamps, environment notes, SQL reminders, and other boilerplate that are not part of the user task.',
      )
      ..writeln(
        'Never claim that no actionable task was provided when the Primary task field is non-empty.',
      )
      ..writeln(
        'If the Primary task uses words like this, that, it, selected, or here, resolve them against the selected Flutter Inspector context and source excerpt when available.',
      )
      ..writeln(
        'For ambiguous UI-edit requests, prefer the nearest visible, user-facing UI element around that selection instead of the narrowest leaf widget or exact source span unless the user explicitly asks for the exact widget or reference.',
      )
      ..writeln(
        'When the requested change target is clear enough, make the local file edit instead of only describing what should change.',
      )
      ..writeln(
        'Ignore any file, inspector, or conversation context that falls outside this project root.',
      )
      ..writeln(
        'Answer concisely and use fenced code blocks when code is helpful.',
      );

    final userBuffer = StringBuffer()
      ..writeln('Primary task:')
      ..writeln(text.trim());

    if (inspectorSelection != null && _looksLikeDeicticTask(text)) {
      userBuffer
        ..writeln()
        ..writeln(
          'Task resolution: words like "this", "that", or "it" usually refer to the nearest visible UI element around the selected Flutter Inspector context, not the most literal leaf widget or exact source span, unless the user explicitly asks for that exact reference.',
        );
    }

    if (activePath != null) {
      userBuffer
        ..writeln()
        ..writeln('Active file: $activePath');
    }

    if (inspectorSelection != null) {
      final sourceFile = inspectorSelection.sourceFile;
      final sourceDirectory = sourceFile == null ? null : p.dirname(sourceFile);
      final startLine = inspectorSelection.line;
      final endLine = inspectorSelection.endLine;
      final sourceRange = startLine == null
          ? null
          : (endLine != null && endLine >= startLine)
          ? '$startLine-$endLine'
          : '$startLine';

      userBuffer
        ..writeln()
        ..writeln('Active Flutter Inspector selection:')
        ..writeln('- Widget: ${inspectorSelection.widgetName}')
        ..writeln('- Description: ${inspectorSelection.description}')
        ..writeln('- Source file: ${sourceFile ?? 'unknown file'}');

      if (sourceDirectory != null && sourceDirectory.trim().isNotEmpty) {
        userBuffer.writeln('- Source directory: $sourceDirectory');
      }

      if (startLine != null) {
        userBuffer.writeln('- Source line start: $startLine');
      }

      if (endLine != null) {
        userBuffer.writeln('- Source line end: $endLine');
      }

      if (sourceRange != null) {
        userBuffer.writeln('- Source line range: $sourceRange');
      }

      if (selectedSourceExcerpt != null && selectedSourceExcerpt.isNotEmpty) {
        userBuffer
          ..writeln()
          ..writeln('Selected widget source excerpt:')
          ..writeln('```dart')
          ..writeln(selectedSourceExcerpt)
          ..writeln('```');
      }
    }

    if (promptHistory.isNotEmpty) {
      userBuffer
        ..writeln()
        ..writeln('Recent conversation (most recent last):');
      for (final message in promptHistory) {
        final role = switch (message.role) {
          MessageRole.user => 'User',
          MessageRole.assistant => 'Assistant',
          MessageRole.system => 'System',
        };
        userBuffer
          ..writeln('$role:')
          ..writeln(_summarizeConversationEntry(message.content))
          ..writeln();
      }
    }

    final promptBuffer = StringBuffer()
      ..writeln('--- SYSTEM INSTRUCTIONS ---')
      ..writeln(systemBuffer.toString().trimRight())
      ..writeln('--- END SYSTEM INSTRUCTIONS ---')
      ..writeln()
      ..writeln('--- USER MESSAGE ---')
      ..writeln(userBuffer.toString().trimRight())
      ..writeln('--- END USER MESSAGE ---');

    return promptBuffer.toString();
  }

  Future<void> _send() async {
    final text = _inputCtrl.text.trim();
    if (text.isEmpty) {
      return;
    }

    final now = DateTime.now();
    final recentDuplicate =
        _lastSubmittedText == text &&
        _lastSubmittedAt != null &&
        now.difference(_lastSubmittedAt!) < const Duration(seconds: 2);
    if (recentDuplicate) {
      return;
    }

    final projectRoot = ref.read(projectRootProvider);
    if (projectRoot == null || projectRoot.trim().isEmpty) {
      return;
    }

    _lastSubmittedText = text;
    _lastSubmittedAt = now;

    final selectedAssistant = ref.read(assistantProvider);
    final history = ref.read(chatHistoryProvider);
    final selectedModel = selectedAssistant == AssistantProviderType.codex
        ? ref.read(codexModelProvider)
        : ref.read(copilotModelProvider);
    final selectedReasoningEffort =
        selectedAssistant == AssistantProviderType.codex
        ? ref.read(codexReasoningEffortProvider)
        : ref.read(copilotReasoningEffortProvider);
    final selectedCopilotPermissionMode = ref.read(
      copilotPermissionModeProvider,
    );
    final inspectorSelection = _projectScopedInspectorSelection(
      ref.read(inspectorSelectionProvider),
      projectRoot,
    );
    final statusBeforeFuture = _inspectProviderStatus(selectedAssistant);
    final prompt = _buildPrompt(
      text: text,
      history: history,
      projectRoot: projectRoot,
      assistantProvider: selectedAssistant,
    );
    final assistantMessageId = '${DateTime.now().millisecondsSinceEpoch}_a';

    _inputCtrl.clear();

    final userMsg = ChatMessage(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      role: MessageRole.user,
      content: text,
      timestamp: DateTime.now(),
      inspectorAttachment: inspectorSelection,
      model: selectedModel,
      reasoningEffort: selectedReasoningEffort,
      assistantProvider: selectedAssistant,
    );
    final streamingMsg = ChatMessage(
      id: assistantMessageId,
      role: MessageRole.assistant,
      content: 'Thinking…',
      timestamp: now,
      inspectorAttachment: inspectorSelection,
      model: selectedModel,
      reasoningEffort: selectedReasoningEffort,
      assistantProvider: selectedAssistant,
      thoughts: const [],
      debugLines: const [],
      isStreaming: true,
    );

    ref
        .read(chatHistoryProvider.notifier)
        .update((state) => [...state, userMsg, streamingMsg]);
    ref
        .read(chatActiveRequestCountProvider.notifier)
        .update((count) => count + 1);
    _scrollToBottom(force: true);

    try {
      final statusBefore = await statusBeforeFuture;
      _pushProviderStatus(selectedAssistant, statusBefore);

      final startedAt = DateTime.now();

      final result = selectedAssistant == AssistantProviderType.codex
          ? await CodexCliService.execPrompt(
              prompt: prompt,
              workingDirectory: projectRoot,
              model: selectedModel,
              reasoningEffort: selectedReasoningEffort,
              onProgress: (update) =>
                  _handleProgressUpdate(assistantMessageId, update),
            )
          : await CopilotCliService.execPrompt(
              prompt: prompt,
              workingDirectory: projectRoot,
              model: selectedModel,
              reasoningEffort: selectedReasoningEffort,
              permissionMode: selectedCopilotPermissionMode,
              onProgress: (update) =>
                  _handleProgressUpdate(assistantMessageId, update),
            );
      final durationMs = DateTime.now().difference(startedAt).inMilliseconds;

      _ProviderStatusSnapshot? statusAfter;

      if (!result.success) {
        statusAfter = await _syncProviderStatus(selectedAssistant);
      }

      final successOutput = result.stdout.trim();
      final content = result.success
          ? (successOutput.isEmpty
                ? '${selectedAssistant.label} returned no output.'
                : successOutput)
          : (result.combinedOutput.trim().isEmpty
                ? '${selectedAssistant.label} returned no output.'
                : result.combinedOutput);
      final completionMessage = result.completionMessage?.trim() ?? '';
      final completionStatus = result.success
          ? '${selectedAssistant.label} completed in ${durationMs}ms (exit ${result.exitCode ?? 0}).'
          : '${selectedAssistant.label} failed in ${durationMs}ms (exit ${result.exitCode ?? -1}).';
      final modificationSummary = result.modifiedFiles.isEmpty
          ? ''
          : '\nModified ${result.modifiedFiles.length} file(s) (${result.linesAdded}+, ${result.linesRemoved}-).';
      final completionSummary =
          completionMessage.isNotEmpty && completionMessage != content.trim()
          ? '$completionStatus$modificationSummary\n$completionMessage'
          : '$completionStatus$modificationSummary';

      // Key execution facts are placed first so they remain visible within the
      // 16-line monospace cap in _MessageMetaBlock.  Event timeline entries
      // follow immediately after so the execution log is always reachable.
      final debugLines = <String>[
        'exec.success ${result.success}',
        'exec.exit ${result.exitCode ?? -1}',
        'exec.duration_ms $durationMs',
        'provider ${selectedAssistant.key}',
        'exec.strategy ${result.executionStrategy}',
        if (selectedAssistant == AssistantProviderType.copilot)
          'exec.permissions ${selectedCopilotPermissionMode.key}',
        'exec.user_request ${_truncateDebug(text, 180)}',
        if (result.submittedPrimaryTask != null)
          'exec.primary_task ${_truncateDebug(result.submittedPrimaryTask!, 180)}',
        'exec.model $selectedModel',
        'exec.reasoning $selectedReasoningEffort',
        if (result.taskFilePath != null)
          'exec.task_file ${p.basename(result.taskFilePath!)}',
        'exec.modified_files ${result.modifiedFiles.length}',
        'exec.diff_stats added=${result.linesAdded} removed=${result.linesRemoved}',
        ...result.modifiedFiles.take(4).map((file) => 'exec.file $file'),
        if (result.stderr.trim().isNotEmpty)
          'exec.stderr ${result.stderr.trim()}',
        ...result.eventTimeline.map((event) => 'event $event'),
        'connection.before installed=${statusBefore.installed} authenticated=${statusBefore.authenticated} mode=${statusBefore.mode}',
        'connection.before.label ${statusBefore.badgeLabel}',
        'exec.prompt_history_users ${promptHistoryCount(history)}',
        'exec.cwd $projectRoot',
        if (result.commandLine.trim().isNotEmpty)
          'exec.command ${result.commandLine}',
        if (statusAfter != null)
          'connection.after installed=${statusAfter.installed} authenticated=${statusAfter.authenticated} mode=${statusAfter.mode} label=${statusAfter.badgeLabel}',
      ];

      final assistantMsg = ChatMessage(
        id: assistantMessageId,
        role: MessageRole.assistant,
        content: content,
        timestamp: DateTime.now(),
        inspectorAttachment: inspectorSelection,
        model: selectedModel,
        reasoningEffort: selectedReasoningEffort,
        assistantProvider: selectedAssistant,
        completionSummary: completionSummary,
        debugLines: debugLines.take(40).toList(),
        thoughts: result.modelThoughts,
        isStreaming: false,
        suggestedFollowUps: result.success
            ? _extractSuggestedFollowUps(content)
            : const [],
      );
      _replaceChatMessage(assistantMessageId, (_) => assistantMsg);

      if (result.success) {
        ref
            .read(hotReloadTriggerProvider.notifier)
            .update((count) => count + 1);
      }
    } catch (error) {
      final assistantMsg = ChatMessage(
        id: assistantMessageId,
        role: MessageRole.assistant,
        content: '${selectedAssistant.label} request failed: $error',
        timestamp: DateTime.now(),
        inspectorAttachment: inspectorSelection,
        model: selectedModel,
        reasoningEffort: selectedReasoningEffort,
        assistantProvider: selectedAssistant,
        completionSummary:
            '${selectedAssistant.label} execution failed before completion.',
        debugLines: ['exception $error'],
        thoughts: const [],
        isStreaming: false,
      );
      _replaceChatMessage(assistantMessageId, (_) => assistantMsg);
    } finally {
      ref
          .read(chatActiveRequestCountProvider.notifier)
          .update((count) => count > 0 ? count - 1 : 0);
      _scrollToBottom(force: true);
    }
  }

  void _replaceChatMessage(
    String id,
    ChatMessage Function(ChatMessage message) transform,
  ) {
    final history = ref.read(chatHistoryProvider);
    final index = history.indexWhere((message) => message.id == id);
    if (index == -1) {
      return;
    }

    final updated = [...history];
    updated[index] = transform(updated[index]);
    ref.read(chatHistoryProvider.notifier).state = updated;
  }

  void _handleProgressUpdate(
    String assistantMessageId,
    AssistantExecutionUpdate update,
  ) {
    if (!mounted) {
      return;
    }

    _replaceChatMessage(
      assistantMessageId,
      (message) => message.copyWith(
        content: update.streamedContent?.trim().isNotEmpty == true
            ? update.streamedContent!
            : update.status,
        thoughts: update.thoughts,
        debugLines: update.events,
        isStreaming: !update.isFinal,
      ),
    );
    _scrollToBottom();
  }

  void _scrollToBottom({bool force = false}) {
    _pendingScroll?.cancel();
    _pendingScroll = Timer(
      force ? Duration.zero : const Duration(milliseconds: 70),
      () {
        if (!mounted) {
          return;
        }

        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!_scrollCtrl.hasClients) {
            return;
          }

          final position = _scrollCtrl.position;
          final distanceToBottom = position.maxScrollExtent - position.pixels;
          if (!force && distanceToBottom > 180) {
            return;
          }

          _scrollCtrl.animateTo(
            position.maxScrollExtent,
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOut,
          );
        });
      },
    );
  }

  int promptHistoryCount(List<ChatMessage> history) {
    return _recentPromptHistory(history).length;
  }

  String _truncateDebug(String value, int maxChars) {
    final normalized = value.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (normalized.length <= maxChars) {
      return normalized;
    }
    return '${normalized.substring(0, maxChars)}...';
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<String>(chatComposerTextProvider, (previous, next) {
      if (_inputCtrl.text == next) {
        return;
      }

      _inputCtrl.value = TextEditingValue(
        text: next,
        selection: TextSelection.collapsed(offset: next.length),
      );
    });

    final selectedAssistant = ref.watch(assistantProvider);
    final usingCodex = selectedAssistant == AssistantProviderType.codex;
    final providerInstalled = usingCodex
        ? ref.watch(codexInstalledProvider)
        : ref.watch(copilotInstalledProvider);
    final providerAuthenticated = usingCodex
        ? ref.watch(codexAuthenticatedProvider)
        : ref.watch(copilotAuthenticatedProvider);
    final projectRoot = ref.watch(projectRootProvider);

    return Container(
      color: FloraPalette.background,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: !providerInstalled || !providerAuthenticated
                ? _ProviderGate(
                    provider: selectedAssistant,
                    installed: providerInstalled,
                    authenticated: providerAuthenticated,
                  )
                : (projectRoot == null || projectRoot.trim().isEmpty)
                ? const _ProjectGate()
                : _ChatBody(
                    scrollCtrl: _scrollCtrl,
                    inputCtrl: _inputCtrl,
                    inputFocus: _inputFocus,
                    onSend: _send,
                  ),
          ),
        ],
      ),
    );
  }
}

class _ProviderGate extends ConsumerWidget {
  const _ProviderGate({
    required this.provider,
    required this.installed,
    required this.authenticated,
  });

  final AssistantProviderType provider;
  final bool installed;
  final bool authenticated;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final label = provider == AssistantProviderType.codex
        ? ref.watch(codexAuthLabelProvider)
        : ref.watch(copilotAuthLabelProvider);
    final providerLabel = provider.label;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              installed ? Icons.lock_outline : Icons.terminal,
              size: 28,
              color: FloraPalette.textDimmed,
            ),
            const SizedBox(height: 12),
            Text(
              installed
                  ? 'Sign in to $providerLabel CLI'
                  : '$providerLabel CLI required',
              style: const TextStyle(
                color: FloraPalette.textSecondary,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              authenticated
                  ? label
                  : provider == AssistantProviderType.codex
                  ? 'Open Settings to install Codex CLI and sign in with ChatGPT.'
                  : 'Open Settings to install Command Code CLI and sign in to your Command Code account.',
              style: const TextStyle(
                color: FloraPalette.textDimmed,
                fontSize: 11,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _ProjectGate extends StatelessWidget {
  const _ProjectGate();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.folder_open_outlined,
              size: 28,
              color: FloraPalette.textDimmed,
            ),
            SizedBox(height: 12),
            Text(
              'No project folder selected',
              style: TextStyle(
                color: FloraPalette.textSecondary,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
            SizedBox(height: 6),
            Text(
              'Open a project folder from Settings or the Explorer pane before starting chat.',
              style: TextStyle(color: FloraPalette.textDimmed, fontSize: 11),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _ChatBody extends ConsumerWidget {
  const _ChatBody({
    required this.scrollCtrl,
    required this.inputCtrl,
    required this.inputFocus,
    required this.onSend,
  });

  final ScrollController scrollCtrl;
  final TextEditingController inputCtrl;
  final FocusNode inputFocus;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final messages = ref.watch(chatHistoryProvider);
    final active = ref.watch(activeFilePathProvider);
    final root = ref.watch(projectRootProvider);
    final inspectorSelection = ref.watch(inspectorSelectionProvider);
    final scopedActive = _projectScopedPath(active, root);
    final scopedInspectorSelection = _projectScopedInspectorSelection(
      inspectorSelection,
      root,
    );
    final interactionMode = ref.watch(previewInteractionModeProvider);
    final selectedAssistant = ref.watch(assistantProvider);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
          child: _ChatContextFloater(
            projectRoot: root,
            activeFilePath: scopedActive,
            inspectorLabel: scopedInspectorSelection == null
                ? null
                : _formatInspectorSelectionLabel(scopedInspectorSelection),
            interactionMode: interactionMode,
            onClearActiveFile: scopedActive == null
                ? null
                : () => ref.read(activeFilePathProvider.notifier).state = null,
            onClearInspector: scopedInspectorSelection == null
                ? null
                : () => ref.read(inspectorSelectionProvider.notifier).state =
                      null,
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: messages.isEmpty
              ? Padding(
                  padding: const EdgeInsets.only(top: 32),
                  child: _EmptyChat(providerLabel: selectedAssistant.label),
                )
              : ListView.builder(
                  controller: scrollCtrl,
                  padding: const EdgeInsets.fromLTRB(0, 6, 0, 8),
                  itemCount: messages.length + _followUpCount(messages),
                  itemBuilder: (context, index) {
                    if (index == messages.length) {
                      final followUps = _lastAssistantFollowUps(messages);
                      return _SuggestedFollowUps(
                        suggestions: followUps,
                        onSelect: (text) {
                          inputCtrl.text = text;
                          inputFocus.requestFocus();
                        },
                      );
                    }
                    return _MessageTile(message: messages[index]);
                  },
                ),
        ),
        _InputBar(
          ctrl: inputCtrl,
          focus: inputFocus,
          onSend: onSend,
          placeholder: 'Ask ${selectedAssistant.label}...',
        ),
      ],
    );
  }

  String _formatInspectorSelectionLabel(InspectorSelectionContext selection) {
    final fileName = selection.sourceFile == null
        ? null
        : p.basename(selection.sourceFile!);
    final startLine = selection.line;
    final endLine = selection.endLine;
    final locationLabel = fileName == null
        ? 'no source location'
        : startLine == null
        ? fileName
        : (endLine != null && endLine >= startLine)
        ? '$fileName:$startLine-$endLine'
        : '$fileName:$startLine';
    return 'Selected ${selection.widgetName} ($locationLabel)';
  }
}

class _ChatContextFloater extends ConsumerStatefulWidget {
  const _ChatContextFloater({
    required this.projectRoot,
    required this.activeFilePath,
    required this.inspectorLabel,
    required this.interactionMode,
    required this.onClearActiveFile,
    required this.onClearInspector,
  });

  final String? projectRoot;
  final String? activeFilePath;
  final String? inspectorLabel;
  final PreviewInteractionMode interactionMode;
  final VoidCallback? onClearActiveFile;
  final VoidCallback? onClearInspector;

  @override
  ConsumerState<_ChatContextFloater> createState() =>
      _ChatContextFloaterState();
}

class _ChatContextFloaterState extends ConsumerState<_ChatContextFloater> {
  _ContextPanelSection? _openSection;

  void _toggleSection(_ContextPanelSection section) {
    setState(() {
      _openSection = _openSection == section ? null : section;
    });
  }

  Widget _buildExpandedPanel() {
    final selectedAssistant = ref.watch(assistantProvider);
    final usingCodex = selectedAssistant == AssistantProviderType.codex;
    final selectedModel = usingCodex
        ? ref.watch(codexModelProvider)
        : ref.watch(copilotModelProvider);
    final selectedReasoning = usingCodex
        ? ref.watch(codexReasoningEffortProvider)
        : ref.watch(copilotReasoningEffortProvider);
    final authLabel = usingCodex
        ? ref.watch(codexAuthLabelProvider)
        : ref.watch(copilotAuthLabelProvider);
    final activeRequests = ref.watch(chatActiveRequestCountProvider);
    final activeFileLabel = widget.activeFilePath == null
        ? 'No active file attached'
        : _projectRelativeLabel(widget.activeFilePath!, widget.projectRoot);

    switch (_openSection) {
      case _ContextPanelSection.context:
        return _ContextPanel(
          icon: Icons.auto_awesome_rounded,
          title: 'Current context',
          summary:
              'Use these live workspace details to steer the next prompt without restating your setup.',
          details: [
            _ContextInfoChip(
              label: 'Assistant',
              value: selectedAssistant.label,
            ),
            _ContextInfoChip(label: 'Model', value: selectedModel),
            _ContextInfoChip(label: 'Reasoning', value: selectedReasoning),
            _ContextInfoChip(label: 'Status', value: authLabel),
            _ContextInfoChip(
              label: 'Active runs',
              value: activeRequests == 0 ? 'Idle' : '$activeRequests running',
            ),
          ],
          actions: [
            _ContextQuickAction(
              icon: Icons.summarize_outlined,
              label: 'Summarize context',
              onTap: () => _appendComposerText(
                ref,
                'Summarize the current project context, taking the active file and selected UI target into account when they are relevant.',
              ),
            ),
            _ContextQuickAction(
              icon: Icons.route_outlined,
              label: 'Plan next change',
              onTap: () => _appendComposerText(
                ref,
                'Given the current project context, propose the next focused change that will move the work forward.',
              ),
            ),
          ],
          onClose: () => setState(() => _openSection = null),
        );
      case _ContextPanelSection.app:
        return _ContextPanel(
          icon: Icons.touch_app_outlined,
          title: 'App preview',
          summary: widget.interactionMode == PreviewInteractionMode.annotate
              ? 'Inspector mode is active. Use the running preview and selected target to drive UI edits.'
              : 'App interaction mode is active. Use the running preview when the current screen state matters.',
          details: [
            _ContextInfoChip(
              label: 'Mode',
              value: widget.interactionMode.label,
            ),
            _ContextInfoChip(
              label: 'Target',
              value: widget.inspectorLabel ?? 'No selected widget',
            ),
          ],
          actions: [
            _ContextQuickAction(
              icon: Icons.mobile_friendly_outlined,
              label: 'Use current app state',
              onTap: () => _appendComposerText(
                ref,
                widget.interactionMode == PreviewInteractionMode.annotate &&
                        widget.inspectorLabel != null
                    ? 'Use the current app preview and the selected UI target as the main context for this request.'
                    : 'Use the current running app preview as the main context for this request.',
              ),
            ),
            _ContextQuickAction(
              icon: Icons.brush_outlined,
              label: 'Ask for UI polish',
              onTap: () => _appendComposerText(
                ref,
                'Review the current app preview and suggest a focused UI polish pass covering spacing, hierarchy, and interaction details.',
              ),
            ),
          ],
          onClose: () => setState(() => _openSection = null),
        );
      case _ContextPanelSection.inspector:
        return _ContextPanel(
          icon: Icons.ads_click_outlined,
          title: 'Inspector target',
          summary: widget.inspectorLabel == null
              ? 'No inspector target is attached yet. Select a widget in the preview to make UI requests more precise.'
              : widget.inspectorLabel!,
          details: [
            _ContextInfoChip(
              label: 'Selection',
              value: widget.inspectorLabel ?? 'None',
            ),
          ],
          actions: [
            if (widget.inspectorLabel != null)
              _ContextQuickAction(
                icon: Icons.near_me_outlined,
                label: 'Use selected target',
                onTap: () => _appendComposerText(
                  ref,
                  'Focus on the currently selected UI target: ${widget.inspectorLabel}. Treat nearby visible UI around it as the primary editing surface.',
                ),
              ),
            if (widget.onClearInspector != null)
              _ContextQuickAction(
                icon: Icons.close_rounded,
                label: 'Clear target',
                destructive: true,
                onTap: widget.onClearInspector!,
              ),
          ],
          onClose: () => setState(() => _openSection = null),
        );
      case _ContextPanelSection.files:
        return _ContextPanel(
          icon: Icons.insert_drive_file_outlined,
          title: 'Files',
          summary: widget.activeFilePath == null
              ? (widget.projectRoot == null
                    ? 'No project is attached yet.'
                    : 'Project root: ${p.basename(widget.projectRoot!)}')
              : activeFileLabel,
          details: [
            if (widget.projectRoot != null)
              _ContextInfoChip(
                label: 'Project',
                value: p.basename(widget.projectRoot!),
              ),
            _ContextInfoChip(
              label: 'Active file',
              value: widget.activeFilePath == null ? 'None' : activeFileLabel,
            ),
          ],
          actions: [
            if (widget.activeFilePath != null)
              _ContextQuickAction(
                icon: Icons.notes_outlined,
                label: 'Focus active file',
                onTap: () => _appendComposerText(
                  ref,
                  'Focus on the active file: $activeFileLabel. Keep the work local to that file unless a nearby dependency clearly needs to change.',
                ),
              ),
            _ContextQuickAction(
              icon: Icons.folder_open_outlined,
              label: 'Use project files',
              onTap: () => _appendComposerText(
                ref,
                'Use the current project files as primary context and inspect the relevant implementation before proposing or making changes.',
              ),
            ),
            if (widget.onClearActiveFile != null)
              _ContextQuickAction(
                icon: Icons.close_rounded,
                label: 'Clear file',
                destructive: true,
                onTap: widget.onClearActiveFile!,
              ),
          ],
          onClose: () => setState(() => _openSection = null),
        );
      case null:
        return const SizedBox.shrink();
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasProject =
        widget.projectRoot != null && widget.projectRoot!.trim().isNotEmpty;
    final hasFiles = hasProject || widget.activeFilePath != null;
    final usingInspector =
        widget.interactionMode == PreviewInteractionMode.annotate ||
        widget.inspectorLabel != null;

    return Material(
      color: Colors.transparent,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'CONTEXT',
            style: TextStyle(
              color: FloraPalette.textSecondary,
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.1,
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _ContextPill(
                icon: Icons.blur_circular_outlined,
                text: 'Context',
                active: true,
                showDot: true,
                selected: _openSection == _ContextPanelSection.context,
                onTap: () => _toggleSection(_ContextPanelSection.context),
              ),
              _ContextPill(
                icon: Icons.touch_app_outlined,
                text: 'Use App',
                active: widget.interactionMode == PreviewInteractionMode.use,
                selected: _openSection == _ContextPanelSection.app,
                onTap: () => _toggleSection(_ContextPanelSection.app),
              ),
              _ContextPill(
                icon: Icons.ads_click_outlined,
                text: 'Inspector',
                active: usingInspector,
                selected: _openSection == _ContextPanelSection.inspector,
                onTap: () => _toggleSection(_ContextPanelSection.inspector),
              ),
              _ContextPill(
                icon: Icons.insert_drive_file_outlined,
                text: 'Files',
                active: hasFiles,
                showChevron: true,
                selected: _openSection == _ContextPanelSection.files,
                onTap: () => _toggleSection(_ContextPanelSection.files),
              ),
            ],
          ),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            child: _openSection == null
                ? const SizedBox.shrink()
                : Padding(
                    key: ValueKey(_openSection),
                    padding: const EdgeInsets.only(top: 10),
                    child: _buildExpandedPanel(),
                  ),
          ),
        ],
      ),
    );
  }
}

class _ContextPill extends StatelessWidget {
  const _ContextPill({
    required this.icon,
    required this.text,
    this.active = false,
    this.selected = false,
    this.showDot = false,
    this.showChevron = false,
    this.onTap,
  });

  final IconData icon;
  final String text;
  final bool active;
  final bool selected;
  final bool showDot;
  final bool showChevron;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final fillColor = selected
        ? FloraPalette.hoveredBg.withValues(alpha: 0.98)
        : active
        ? FloraPalette.inputBg.withValues(alpha: 0.78)
        : FloraPalette.inputBg.withValues(alpha: 0.58);
    final borderColor = selected
        ? FloraPalette.accent.withValues(alpha: 0.4)
        : FloraPalette.border;
    final tone = selected || active
        ? FloraPalette.textPrimary
        : FloraPalette.textSecondary;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(11),
        child: Container(
          constraints: const BoxConstraints(maxWidth: 220),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            color: fillColor,
            border: Border.all(color: borderColor),
            borderRadius: BorderRadius.circular(11),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 13, color: tone),
              const SizedBox(width: 7),
              Flexible(
                child: Text(
                  text,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: tone,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              if (showDot) ...[
                const SizedBox(width: 7),
                Container(
                  width: 7,
                  height: 7,
                  decoration: const BoxDecoration(
                    color: FloraPalette.accent,
                    shape: BoxShape.circle,
                  ),
                ),
              ],
              if (showChevron) ...[
                const SizedBox(width: 6),
                Icon(Icons.chevron_right, size: 14, color: tone),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ContextPanel extends StatelessWidget {
  const _ContextPanel({
    required this.icon,
    required this.title,
    required this.summary,
    required this.details,
    required this.actions,
    required this.onClose,
  });

  final IconData icon;
  final String title;
  final String summary;
  final List<Widget> details;
  final List<Widget> actions;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: FloraPalette.inputBg.withValues(alpha: 0.72),
        border: Border.all(color: FloraPalette.border),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 14, color: FloraPalette.textSecondary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    color: FloraPalette.textPrimary,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              InkWell(
                onTap: onClose,
                borderRadius: BorderRadius.circular(10),
                child: const Padding(
                  padding: EdgeInsets.all(4),
                  child: Icon(
                    Icons.close_rounded,
                    size: 14,
                    color: FloraPalette.textSecondary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            summary,
            style: const TextStyle(
              color: FloraPalette.textSecondary,
              fontSize: 11,
              height: 1.45,
            ),
          ),
          if (details.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(spacing: 8, runSpacing: 8, children: details),
          ],
          if (actions.isNotEmpty) ...[
            const SizedBox(height: 12),
            Wrap(spacing: 8, runSpacing: 8, children: actions),
          ],
        ],
      ),
    );
  }
}

class _ContextInfoChip extends StatelessWidget {
  const _ContextInfoChip({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minWidth: 116, maxWidth: 240),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: FloraPalette.background.withValues(alpha: 0.44),
        border: Border.all(color: FloraPalette.border),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label.toUpperCase(),
            style: const TextStyle(
              color: FloraPalette.textDimmed,
              fontSize: 9,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.9,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: FloraPalette.textPrimary,
              fontSize: 11,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

class _ContextQuickAction extends StatelessWidget {
  const _ContextQuickAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.destructive = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final accent = destructive ? FloraPalette.error : FloraPalette.accent;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: accent.withValues(alpha: 0.12),
            border: Border.all(color: accent.withValues(alpha: 0.22)),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 13, color: accent),
              const SizedBox(width: 7),
              Text(
                label,
                style: TextStyle(
                  color: destructive
                      ? FloraPalette.error
                      : FloraPalette.textPrimary,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyChat extends StatelessWidget {
  const _EmptyChat({required this.providerLabel});

  final String providerLabel;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            providerLabel,
            style: const TextStyle(
              color: FloraPalette.textDimmed,
              fontSize: 22,
              fontWeight: FontWeight.w300,
              letterSpacing: 2,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Ask anything about the selected Flutter project. You can keep sending requests while earlier runs finish.',
            style: TextStyle(color: FloraPalette.textDimmed, fontSize: 12),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

// ─── Follow-up helpers (used by _ChatBody) ───────────────────────────────────

int _followUpCount(List<ChatMessage> messages) {
  return _lastAssistantFollowUps(messages).isNotEmpty ? 1 : 0;
}

List<String> _lastAssistantFollowUps(List<ChatMessage> messages) {
  for (int i = messages.length - 1; i >= 0; i--) {
    final m = messages[i];
    if (m.role == MessageRole.assistant && !m.isStreaming) {
      return m.suggestedFollowUps;
    }
  }
  return const [];
}

// ─── Suggested Follow-ups widget ─────────────────────────────────────────────

class _SuggestedFollowUps extends StatelessWidget {
  const _SuggestedFollowUps({
    required this.suggestions,
    required this.onSelect,
  });

  final List<String> suggestions;
  final void Function(String text) onSelect;

  @override
  Widget build(BuildContext context) {
    if (suggestions.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'SUGGESTED FOLLOW-UPS',
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              color: FloraPalette.textSecondary,
              letterSpacing: 1.0,
            ),
          ),
          const SizedBox(height: 8),
          ...suggestions.map(
            (s) => Padding(
              padding: const EdgeInsets.only(bottom: 5),
              child: _FollowUpChip(text: s, onTap: () => onSelect(s)),
            ),
          ),
        ],
      ),
    );
  }
}

class _FollowUpChip extends StatelessWidget {
  const _FollowUpChip({required this.text, required this.onTap});

  final String text;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: FloraPalette.inputBg.withValues(alpha: 0.72),
          border: Border.all(color: FloraPalette.border),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                text,
                style: const TextStyle(
                  fontSize: 12,
                  color: FloraPalette.textPrimary,
                ),
              ),
            ),
            const SizedBox(width: 8),
            const Icon(
              Icons.north_east,
              size: 12,
              color: FloraPalette.textSecondary,
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Message tile ─────────────────────────────────────────────────────────────

class _MessageTile extends ConsumerWidget {
  const _MessageTile({required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isUser = message.role == MessageRole.user;
    final senderLabel = isUser
        ? 'You'
        : (message.assistantProvider?.label ?? 'Assistant');
    final initial = senderLabel[0].toUpperCase();
    final avatarColor = isUser ? const Color(0xFF5771D8) : FloraPalette.accent;
    final debugTitle =
        '${message.assistantProvider?.label ?? 'Assistant'} debug';
    final showCompletion =
        message.completionSummary != null &&
        message.completionSummary!.trim().isNotEmpty;
    final showThoughts = message.thoughts.isNotEmpty;
    final showDebug = message.debugLines.isNotEmpty && !message.isStreaming;

    return Container(
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: FloraPalette.border)),
      ),
      padding: const EdgeInsets.fromLTRB(12, 14, 12, 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: avatarColor,
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Text(
              initial,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      senderLabel,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: FloraPalette.textPrimary,
                      ),
                    ),
                    if (message.isStreaming) ...[
                      const SizedBox(width: 6),
                      Container(
                        width: 6,
                        height: 6,
                        decoration: const BoxDecoration(
                          color: FloraPalette.accent,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 4),
                      const Text(
                        'thinking…',
                        style: TextStyle(
                          fontSize: 10,
                          color: FloraPalette.textSecondary,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    ],
                    const Spacer(),
                    _MessageActionButton(
                      tooltip: 'Copy message',
                      icon: Icons.content_copy_outlined,
                      onTap: () => _copyMessage(context),
                    ),
                    const SizedBox(width: 4),
                    _MessageActionButton(
                      tooltip: isUser ? 'Reuse as draft' : 'Draft a follow-up',
                      icon: isUser ? Icons.edit_outlined : Icons.reply_outlined,
                      onTap: () =>
                          isUser ? _reuseAsDraft(ref) : _draftFollowUp(ref),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _formatTimestamp(message.timestamp),
                      style: const TextStyle(
                        fontSize: 10,
                        color: FloraPalette.textDimmed,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                _buildContent(message.content),
                if (message.inspectorAttachment != null) ...[
                  const SizedBox(height: 8),
                  _MessageInspectorAttachment(
                    selection: message.inspectorAttachment!,
                  ),
                ],
                if (showThoughts) ...[
                  const SizedBox(height: 8),
                  _MessageMetaBlock(
                    icon: Icons.psychology_alt_outlined,
                    title: message.isStreaming
                        ? 'Live thoughts'
                        : 'Condensed thoughts',
                    lines: message.thoughts,
                  ),
                ],
                if (showCompletion) ...[
                  const SizedBox(height: 8),
                  _MessageMetaBlock(
                    icon: Icons.task_alt_outlined,
                    title: 'Completion',
                    lines: [message.completionSummary!.trim()],
                  ),
                ],
                if (showDebug) ...[
                  const SizedBox(height: 8),
                  _MessageMetaBlock(
                    icon: Icons.bug_report_outlined,
                    title: debugTitle,
                    lines: message.debugLines,
                    monospace: true,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContent(String content) {
    final blockPattern = RegExp(r'```([\w+-]*)\n([\s\S]*?)```');
    final matches = blockPattern.allMatches(content).toList();
    if (matches.isEmpty) {
      return Text(content, style: _messageTextStyle());
    }

    final children = <Widget>[];
    var cursor = 0;

    for (final match in matches) {
      final leading = content.substring(cursor, match.start).trim();
      if (leading.isNotEmpty) {
        if (children.isNotEmpty) {
          children.add(const SizedBox(height: 8));
        }
        children.add(Text(leading, style: _messageTextStyle()));
      }

      final code = (match.group(2) ?? '').trimRight();
      if (code.isNotEmpty) {
        if (children.isNotEmpty) {
          children.add(const SizedBox(height: 8));
        }
        children.add(
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: FloraPalette.background,
              border: Border.all(color: FloraPalette.border),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(code, style: FloraTheme.mono(size: 11)),
          ),
        );
      }

      cursor = match.end;
    }

    final tail = content.substring(cursor).trim();
    if (tail.isNotEmpty) {
      if (children.isNotEmpty) {
        children.add(const SizedBox(height: 8));
      }
      children.add(Text(tail, style: _messageTextStyle()));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }

  TextStyle _messageTextStyle() {
    return const TextStyle(
      color: FloraPalette.textPrimary,
      fontSize: 13,
      height: 1.5,
    );
  }

  Future<void> _copyMessage(BuildContext context) async {
    final value = message.content.trim();
    if (value.isEmpty) {
      return;
    }

    await Clipboard.setData(ClipboardData(text: value));
    if (!context.mounted) {
      return;
    }

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(
          content: Text('Copied message to clipboard.'),
          duration: Duration(milliseconds: 1200),
        ),
      );
  }

  void _reuseAsDraft(WidgetRef ref) {
    _appendComposerText(ref, message.content, replace: true);
  }

  void _draftFollowUp(WidgetRef ref) {
    final snippet = _summarizeConversationEntry(message.content, maxChars: 140);
    _appendComposerText(
      ref,
      'Continue from this response and refine this point:\n$snippet',
    );
  }

  static String _formatTimestamp(DateTime? ts) {
    if (ts == null) return '';
    final h = ts.hour % 12 == 0 ? 12 : ts.hour % 12;
    final m = ts.minute.toString().padLeft(2, '0');
    final ampm = ts.hour >= 12 ? 'PM' : 'AM';
    return '$h:$m $ampm';
  }
}

class _MessageActionButton extends StatelessWidget {
  const _MessageActionButton({
    required this.tooltip,
    required this.icon,
    required this.onTap,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: Icon(icon, size: 14, color: FloraPalette.textSecondary),
          ),
        ),
      ),
    );
  }
}

class _MessageInspectorAttachment extends StatelessWidget {
  const _MessageInspectorAttachment({required this.selection});

  final InspectorSelectionContext selection;

  @override
  Widget build(BuildContext context) {
    final sourceLabel = selection.sourceFile == null
        ? 'unknown source'
        : p.basename(selection.sourceFile!);
    final startLine = selection.line;
    final endLine = selection.endLine;
    final locationLabel = startLine == null
        ? sourceLabel
        : (endLine != null && endLine >= startLine)
        ? '$sourceLabel:$startLine-$endLine'
        : '$sourceLabel:$startLine';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: FloraPalette.background.withValues(alpha: 0.72),
        border: Border.all(color: FloraPalette.border),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.ads_click_outlined,
                size: 12,
                color: FloraPalette.textSecondary,
              ),
              const SizedBox(width: 6),
              Text(
                selection.widgetName,
                style: const TextStyle(
                  color: FloraPalette.textPrimary,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              Text(
                locationLabel,
                style: FloraTheme.mono(
                  size: 10,
                  color: FloraPalette.textSecondary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            selection.description,
            style: const TextStyle(
              color: FloraPalette.textSecondary,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }
}

class _MessageMetaBlock extends StatelessWidget {
  const _MessageMetaBlock({
    required this.icon,
    required this.title,
    required this.lines,
    this.monospace = false,
  });

  final IconData icon;
  final String title;
  final List<String> lines;
  final bool monospace;

  @override
  Widget build(BuildContext context) {
    final maxVisibleLines = monospace ? 16 : 12;
    final visibleLines = lines
        .where((line) => line.trim().isNotEmpty)
        .take(maxVisibleLines)
        .toList(growable: true);

    if (lines.length > visibleLines.length) {
      visibleLines.add('... ${lines.length - visibleLines.length} more lines');
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: FloraPalette.background.withValues(alpha: 0.72),
        border: Border.all(color: FloraPalette.border),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 12, color: FloraPalette.textSecondary),
              const SizedBox(width: 6),
              Text(
                title,
                style: const TextStyle(
                  color: FloraPalette.textSecondary,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          for (final line in visibleLines)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text(
                line,
                style: monospace
                    ? FloraTheme.mono(
                        size: 10,
                        color: FloraPalette.textSecondary,
                      )
                    : const TextStyle(
                        color: FloraPalette.textPrimary,
                        fontSize: 11,
                      ),
              ),
            ),
        ],
      ),
    );
  }
}

class _InputBar extends ConsumerWidget {
  const _InputBar({
    required this.ctrl,
    required this.focus,
    required this.onSend,
    required this.placeholder,
  });

  final TextEditingController ctrl;
  final FocusNode focus;
  final VoidCallback onSend;
  final String placeholder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activeRequests = ref.watch(chatActiveRequestCountProvider);
    final selectedAssistant = ref.watch(assistantProvider);
    final projectRoot = ref.watch(projectRootProvider);
    final interactionMode = ref.watch(previewInteractionModeProvider);
    final activeFile = _projectScopedPath(
      ref.watch(activeFilePathProvider),
      projectRoot,
    );
    final inspectorSelection = _projectScopedInspectorSelection(
      ref.watch(inspectorSelectionProvider),
      projectRoot,
    );
    final usingCodex = selectedAssistant == AssistantProviderType.codex;
    final providerReady = usingCodex
        ? ref.watch(codexAuthenticatedProvider)
        : ref.watch(copilotAuthenticatedProvider);
    final onlineLabel = usingCodex ? 'Codex Online' : 'Command Code Online';

    void insertSnippet(String text, {bool replace = false}) {
      _appendComposerText(ref, text, replace: replace);
      focus.requestFocus();
    }

    final filePrompt = activeFile == null
        ? 'Use the current project files as context and inspect the most relevant implementation before making changes.'
        : 'Focus on the active file: ${_projectRelativeLabel(activeFile, projectRoot)}. Keep the work local to that file unless a nearby dependency clearly needs to change.';
    final appPrompt =
        interactionMode == PreviewInteractionMode.annotate &&
            inspectorSelection != null
        ? 'Use the running app preview and the selected UI target as the primary context for this request.'
        : 'Use the current app preview state as the primary context for this request.';

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      decoration: const BoxDecoration(
        color: FloraPalette.panelBg,
        border: Border(top: BorderSide(color: FloraPalette.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (activeRequests > 0)
            Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  '$activeRequests run${activeRequests == 1 ? '' : 's'} active. Send another request or keep editing the draft.',
                  style: const TextStyle(
                    color: FloraPalette.textSecondary,
                    fontSize: 10,
                  ),
                ),
              ),
            ),
          Container(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
            decoration: BoxDecoration(
              color: FloraPalette.inputBg.withValues(alpha: 0.74),
              border: Border.all(color: FloraPalette.border),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: ctrl,
                  focusNode: focus,
                  maxLines: 5,
                  minLines: 1,
                  style: const TextStyle(
                    color: FloraPalette.textPrimary,
                    fontSize: 13,
                    height: 1.45,
                  ),
                  decoration: InputDecoration(
                    hintText: placeholder,
                    filled: false,
                    contentPadding: EdgeInsets.zero,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                  ),
                  onSubmitted: (_) => onSend(),
                  textInputAction: TextInputAction.send,
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    _ComposerPill(
                      icon: Icons.blur_circular_outlined,
                      label: 'Context',
                      active: true,
                      onTap: () => insertSnippet(
                        'Use the current project context, active file, and selected UI target when they are relevant.',
                      ),
                    ),
                    const SizedBox(width: 6),
                    _ComposerPill(
                      icon: Icons.touch_app_outlined,
                      label: 'Use App',
                      active: interactionMode == PreviewInteractionMode.use,
                      onTap: () => insertSnippet(appPrompt),
                    ),
                    const SizedBox(width: 6),
                    _ComposerPill(
                      icon: Icons.insert_drive_file_outlined,
                      label: 'Files',
                      active: activeFile != null,
                      onTap: () => insertSnippet(filePrompt),
                    ),
                    const Spacer(),
                    Tooltip(
                      message: 'Clear draft',
                      child: InkWell(
                        onTap: () {
                          ctrl.clear();
                          ref.read(chatComposerTextProvider.notifier).state =
                              '';
                          focus.requestFocus();
                        },
                        borderRadius: BorderRadius.circular(18),
                        child: Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            color: FloraPalette.background.withValues(
                              alpha: 0.6,
                            ),
                            shape: BoxShape.circle,
                            border: Border.all(color: FloraPalette.border),
                          ),
                          child: const Icon(
                            Icons.close_rounded,
                            size: 18,
                            color: FloraPalette.textSecondary,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    InkWell(
                      onTap: onSend,
                      borderRadius: BorderRadius.circular(18),
                      child: Container(
                        width: 36,
                        height: 36,
                        decoration: const BoxDecoration(
                          color: FloraPalette.accent,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.arrow_outward_rounded,
                          size: 18,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Text(
                  '${selectedAssistant.label} uses context from your app and files to answer accurately.',
                  style: const TextStyle(
                    color: FloraPalette.textDimmed,
                    fontSize: 10,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: providerReady
                      ? FloraPalette.success
                      : FloraPalette.textDimmed,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                onlineLabel,
                style: TextStyle(
                  color: providerReady
                      ? FloraPalette.success
                      : FloraPalette.textSecondary,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ComposerPill extends StatelessWidget {
  const _ComposerPill({
    required this.icon,
    required this.label,
    this.active = false,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: label,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(999),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: active
                  ? FloraPalette.hoveredBg.withValues(alpha: 0.86)
                  : FloraPalette.background.withValues(alpha: 0.55),
              border: Border.all(color: FloraPalette.border),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 12, color: FloraPalette.textSecondary),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: const TextStyle(
                    color: FloraPalette.textSecondary,
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
