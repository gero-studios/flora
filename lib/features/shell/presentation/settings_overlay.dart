import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../app/theme/flora_theme.dart';
import '../../../core/models/flora_models.dart';
import '../../../core/services/copilot_cli_service.dart';
import '../../../core/services/codex_cli_service.dart';
import '../../../core/state/flora_providers.dart';

const _codexModelOptions = <String>[
  'gpt-5.4-mini',
  'gpt-5.4',
  'gpt-5.2',
  'gpt-5.2-mini',
  'gpt-5.3-codex',
  'gpt-5.1-codex-mini',
];

const _copilotModelOptions = <String>[
  'gpt-5.2',
  'gpt-5.4',
  'gpt-5.4-mini',
  'claude-sonnet-4',
  'claude-3.7-sonnet',
  'gemini-2.5-pro',
  'gemini-2.5-flash',
  'o4-mini',
];

const _codexReasoningEffortOptions = <String>[
  'none',
  'minimal',
  'low',
  'medium',
  'high',
  'xhigh',
];

const _copilotReasoningEffortOptions = <String>[
  'low',
  'medium',
  'high',
  'xhigh',
];

class SettingsOverlay extends ConsumerWidget {
  const SettingsOverlay({super.key, required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return GestureDetector(
      onTap: onClose,
      child: ColoredBox(
        color: Colors.black54,
        child: Center(
          child: GestureDetector(
            onTap: () {},
            child: _SettingsPanel(onClose: onClose),
          ),
        ),
      ),
    );
  }
}

class _SettingsPanel extends ConsumerStatefulWidget {
  const _SettingsPanel({required this.onClose});

  final VoidCallback onClose;

  @override
  ConsumerState<_SettingsPanel> createState() => _SettingsPanelState();
}

class _SettingsPanelState extends ConsumerState<_SettingsPanel> {
  late final TextEditingController _rootCtrl;

  bool _saving = false;
  bool _saved = false;
  bool _busy = false;
  String _busyLabel = '';
  String _statusDetail = '';
  String _commandOutput = '';

  @override
  void initState() {
    super.initState();
    _rootCtrl = TextEditingController(
      text: ref.read(projectRootProvider) ?? '',
    );
    _statusDetail = _currentProviderAuthLabel(ref.read(assistantProvider));

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refreshProviderStatus(showBusy: false);
    });
  }

  @override
  void dispose() {
    _rootCtrl.dispose();
    super.dispose();
  }

  String _currentProviderAuthLabel(AssistantProviderType provider) {
    switch (provider) {
      case AssistantProviderType.codex:
        return ref.read(codexAuthLabelProvider);
      case AssistantProviderType.copilot:
        return ref.read(copilotAuthLabelProvider);
    }
  }

  Future<void> _refreshProviderStatus({bool showBusy = true}) async {
    final provider = ref.read(assistantProvider);

    if (showBusy) {
      setState(() {
        _busy = true;
        _busyLabel = provider == AssistantProviderType.codex
            ? 'Checking Codex CLI...'
            : 'Checking GitHub Copilot CLI...';
      });
    }

    String statusMessage;
    if (provider == AssistantProviderType.codex) {
      final status = await CodexCliService.inspectStatus();
      _pushCodexStatus(status);
      statusMessage = status.message;
    } else {
      final status = await CopilotCliService.inspectStatus();
      _pushCopilotStatus(status);
      statusMessage = status.message;
    }

    if (!mounted) {
      return;
    }

    setState(() {
      _statusDetail = statusMessage;
      if (showBusy) {
        _busy = false;
        _busyLabel = '';
      }
    });
  }

  void _pushCodexStatus(CodexCliStatus status) {
    ref.read(codexInstalledProvider.notifier).state = status.installed;
    ref.read(codexAuthenticatedProvider.notifier).state = status.authenticated;
    ref.read(codexAuthLabelProvider.notifier).state = status.badgeLabel;
  }

  void _pushCopilotStatus(CopilotCliStatus status) {
    ref.read(copilotInstalledProvider.notifier).state = status.installed;
    ref.read(copilotAuthenticatedProvider.notifier).state =
        status.authenticated;
    ref.read(copilotAuthLabelProvider.notifier).state = status.badgeLabel;
  }

  Future<void> _runProviderAction(
    String busyLabel,
    Future<CodexCliCommandResult> Function() action,
  ) async {
    setState(() {
      _busy = true;
      _busyLabel = busyLabel;
      _commandOutput = '';
    });

    final result = await action();
    await _refreshProviderStatus(showBusy: false);

    if (!mounted) {
      return;
    }

    setState(() {
      _busy = false;
      _busyLabel = '';
      _commandOutput = result.combinedOutput.trim().isEmpty
          ? (result.success ? '$busyLabel completed.' : '$busyLabel failed.')
          : result.combinedOutput;
    });
  }

  Future<void> _runCopilotSignIn() async {
    setState(() {
      _busy = true;
      _busyLabel = 'Starting GitHub sign-in...';
      _statusDetail =
          'Opening the GitHub sign-in flow. Flora will mirror the latest login details here.';
      _commandOutput = '';
    });

    final result = await CopilotCliService.login(
      onProgress: (detail) {
        if (!mounted) {
          return;
        }

        setState(() {
          _statusDetail = detail;
        });
      },
    );
    await _refreshProviderStatus(showBusy: false);

    if (!mounted) {
      return;
    }

    setState(() {
      _busy = false;
      _busyLabel = '';
      _commandOutput = result.combinedOutput.trim().isEmpty
          ? (result.success
                ? 'GitHub sign-in completed.'
                : 'GitHub sign-in failed.')
          : result.combinedOutput;
    });
  }

  Future<void> _pickProjectRoot() async {
    final directory = await getDirectoryPath(confirmButtonText: 'Open project');
    if (directory == null || directory.trim().isEmpty) {
      return;
    }

    setState(() {
      _rootCtrl.text = directory;
      _saved = false;
    });
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _saved = false;
    });

    final prefs = await SharedPreferences.getInstance();
    final previousRoot = ref.read(projectRootProvider)?.trim() ?? '';
    final root = _rootCtrl.text.trim();
    final rootChanged = previousRoot != root;
    final selectedProvider = normalizeAssistantProvider(
      ref.read(assistantProvider),
    );
    final codexModel = ref.read(codexModelProvider).trim();
    final codexReasoningEffort = ref.read(codexReasoningEffortProvider).trim();
    final copilotModel = ref.read(copilotModelProvider).trim();
    final copilotReasoningEffort = ref
        .read(copilotReasoningEffortProvider)
        .trim();
    final copilotPermissionMode = ref.read(copilotPermissionModeProvider);

    await prefs.setString('assistant_provider', selectedProvider.key);

    await prefs.setString(
      'codex_model',
      codexModel.isEmpty ? 'gpt-5.4-mini' : codexModel,
    );
    await prefs.setString(
      'codex_reasoning_effort',
      codexReasoningEffort.isEmpty ? 'medium' : codexReasoningEffort,
    );
    await prefs.setString(
      'copilot_model',
      copilotModel.isEmpty ? 'gpt-5.2' : copilotModel,
    );
    await prefs.setString(
      'copilot_reasoning_effort',
      copilotReasoningEffort.isEmpty ? 'medium' : copilotReasoningEffort,
    );
    await prefs.setString('copilot_permission_mode', copilotPermissionMode.key);

    if (root.isEmpty) {
      await prefs.remove('project_root');
      ref.read(projectRootProvider.notifier).state = null;
      ref.read(expandedFoldersProvider.notifier).state = const {};
    } else {
      await prefs.setString('project_root', root);
      ref.read(projectRootProvider.notifier).state = root;
      ref.read(expandedFoldersProvider.notifier).state = {root};
    }
    ref.read(activeFilePathProvider.notifier).state = null;
    ref.read(inspectorSelectionProvider.notifier).state = null;
    if (rootChanged) {
      ref.read(chatHistoryProvider.notifier).state = const [];
    }

    if (!mounted) {
      return;
    }

    setState(() {
      _saving = false;
      _saved = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final selectedProvider = normalizeAssistantProvider(
      ref.watch(assistantProvider),
    );
    final usingCodex = selectedProvider == AssistantProviderType.codex;

    final codexInstalled = ref.watch(codexInstalledProvider);
    final codexAuthenticated = ref.watch(codexAuthenticatedProvider);
    final codexLabel = ref.watch(codexAuthLabelProvider);
    final codexModel = ref.watch(codexModelProvider);
    final codexReasoningEffort = ref.watch(codexReasoningEffortProvider);
    final copilotInstalled = ref.watch(copilotInstalledProvider);
    final copilotAuthenticated = ref.watch(copilotAuthenticatedProvider);
    final copilotLabel = ref.watch(copilotAuthLabelProvider);
    final copilotModel = ref.watch(copilotModelProvider);
    final copilotReasoningEffort = ref.watch(copilotReasoningEffortProvider);
    final copilotPermissionMode = ref.watch(copilotPermissionModeProvider);

    final providerInstalled = usingCodex ? codexInstalled : copilotInstalled;
    final providerAuthenticated = usingCodex
        ? codexAuthenticated
        : copilotAuthenticated;
    final providerLabel = usingCodex ? codexLabel : copilotLabel;

    final modelOptions = usingCodex ? _codexModelOptions : _copilotModelOptions;
    final reasoningOptions = usingCodex
        ? _codexReasoningEffortOptions
        : _copilotReasoningEffortOptions;

    final providerModel = usingCodex ? codexModel : copilotModel;
    final providerReasoningEffort = usingCodex
        ? codexReasoningEffort
        : copilotReasoningEffort;
    final installLabel = providerInstalled
        ? 'Already Installed'
        : (usingCodex ? 'Install Codex CLI' : 'Install Copilot CLI');
    final signInLabel = !providerInstalled
        ? (usingCodex ? 'Install Codex First' : 'Install Copilot First')
        : providerAuthenticated
        ? 'Already Signed In'
        : (usingCodex ? 'Sign In With ChatGPT' : 'Sign In With GitHub');

    final selectedModel = modelOptions.contains(providerModel)
        ? providerModel
        : modelOptions.first;
    final selectedReasoning = reasoningOptions.contains(providerReasoningEffort)
        ? providerReasoningEffort
        : reasoningOptions.first;

    return Container(
      width: 560,
      decoration: BoxDecoration(
        color: FloraPalette.panelBg,
        border: Border.all(color: FloraPalette.border),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 36,
            color: FloraPalette.sidebarBg,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                const Text(
                  'SETTINGS',
                  style: TextStyle(
                    color: FloraPalette.textSecondary,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.8,
                  ),
                ),
                const Spacer(),
                InkWell(
                  onTap: widget.onClose,
                  child: const Icon(
                    Icons.close,
                    size: 14,
                    color: FloraPalette.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const _SectionLabel('AI Provider'),
                const SizedBox(height: 6),
                Container(
                  height: 32,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  decoration: BoxDecoration(
                    color: FloraPalette.background,
                    border: Border.all(color: FloraPalette.border),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<AssistantProviderType>(
                      value: selectedProvider,
                      isExpanded: true,
                      iconSize: 16,
                      style: const TextStyle(
                        fontSize: 12,
                        color: FloraPalette.textPrimary,
                      ),
                      dropdownColor: FloraPalette.panelBg,
                      items: enabledAssistantProviders()
                          .map(
                            (provider) =>
                                DropdownMenuItem<AssistantProviderType>(
                                  value: provider,
                                  child: Text(provider.label),
                                ),
                          )
                          .toList(),
                      onChanged: _busy || _saving
                          ? null
                          : (value) {
                              if (value == null) {
                                return;
                              }
                              ref.read(assistantProvider.notifier).state =
                                  value;
                              setState(() {
                                _saved = false;
                                _statusDetail = _currentProviderAuthLabel(
                                  value,
                                );
                              });
                              _refreshProviderStatus(showBusy: false);
                            },
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                _SectionLabel(usingCodex ? 'Codex CLI' : 'GitHub Copilot CLI'),
                const SizedBox(height: 8),
                Row(
                  children: [
                    _StatusPill(
                      active: providerInstalled,
                      label: providerInstalled
                          ? providerLabel
                          : (usingCodex ? 'Codex missing' : 'Copilot missing'),
                    ),
                    const SizedBox(width: 8),
                    _StatusPill(
                      active: providerAuthenticated,
                      label: providerAuthenticated
                          ? 'Signed in'
                          : 'Not signed in',
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  usingCodex
                      ? 'Use your ChatGPT account with Codex CLI instead of storing an API key in Flora.'
                      : 'Use your GitHub account with Copilot CLI. This can route across multiple model families.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Model reference',
                            style: TextStyle(
                              fontSize: 11,
                              color: FloraPalette.textSecondary,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Container(
                            height: 32,
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            decoration: BoxDecoration(
                              color: FloraPalette.background,
                              border: Border.all(color: FloraPalette.border),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: DropdownButtonHideUnderline(
                              child: DropdownButton<String>(
                                value: selectedModel,
                                isExpanded: true,
                                iconSize: 16,
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: FloraPalette.textPrimary,
                                ),
                                dropdownColor: FloraPalette.panelBg,
                                items: modelOptions
                                    .map(
                                      (model) => DropdownMenuItem<String>(
                                        value: model,
                                        child: Text(model),
                                      ),
                                    )
                                    .toList(),
                                onChanged: _busy || _saving
                                    ? null
                                    : (value) {
                                        if (value == null) return;
                                        if (usingCodex) {
                                          ref
                                                  .read(
                                                    codexModelProvider.notifier,
                                                  )
                                                  .state =
                                              value;
                                        } else {
                                          ref
                                                  .read(
                                                    copilotModelProvider
                                                        .notifier,
                                                  )
                                                  .state =
                                              value;
                                        }
                                        setState(() => _saved = false);
                                      },
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Reasoning effort',
                            style: TextStyle(
                              fontSize: 11,
                              color: FloraPalette.textSecondary,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Container(
                            height: 32,
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            decoration: BoxDecoration(
                              color: FloraPalette.background,
                              border: Border.all(color: FloraPalette.border),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: DropdownButtonHideUnderline(
                              child: DropdownButton<String>(
                                value: selectedReasoning,
                                isExpanded: true,
                                iconSize: 16,
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: FloraPalette.textPrimary,
                                ),
                                dropdownColor: FloraPalette.panelBg,
                                items: reasoningOptions
                                    .map(
                                      (effort) => DropdownMenuItem<String>(
                                        value: effort,
                                        child: Text(effort),
                                      ),
                                    )
                                    .toList(),
                                onChanged: _busy || _saving
                                    ? null
                                    : (value) {
                                        if (value == null) return;
                                        if (usingCodex) {
                                          ref
                                                  .read(
                                                    codexReasoningEffortProvider
                                                        .notifier,
                                                  )
                                                  .state =
                                              value;
                                        } else {
                                          ref
                                                  .read(
                                                    copilotReasoningEffortProvider
                                                        .notifier,
                                                  )
                                                  .state =
                                              value;
                                        }
                                        setState(() => _saved = false);
                                      },
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                if (!usingCodex) ...[
                  const SizedBox(height: 8),
                  const Text(
                    'Execution permissions',
                    style: TextStyle(
                      fontSize: 11,
                      color: FloraPalette.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Container(
                    height: 32,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    decoration: BoxDecoration(
                      color: FloraPalette.background,
                      border: Border.all(color: FloraPalette.border),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<CopilotPermissionMode>(
                        value: copilotPermissionMode,
                        isExpanded: true,
                        iconSize: 16,
                        style: const TextStyle(
                          fontSize: 12,
                          color: FloraPalette.textPrimary,
                        ),
                        dropdownColor: FloraPalette.panelBg,
                        items:
                            const [
                                  CopilotPermissionMode.workspaceWrite,
                                  CopilotPermissionMode.fullAuto,
                                ]
                                .map(
                                  (mode) =>
                                      DropdownMenuItem<CopilotPermissionMode>(
                                        value: mode,
                                        child: Text(mode.label),
                                      ),
                                )
                                .toList(),
                        onChanged: _busy || _saving
                            ? null
                            : (value) {
                                if (value == null) return;
                                ref
                                        .read(
                                          copilotPermissionModeProvider
                                              .notifier,
                                        )
                                        .state =
                                    value;
                                setState(() => _saved = false);
                              },
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'GitHub Copilot prompt mode does not request permissions interactively. Flora therefore uses pre-approved execution modes here. ${copilotPermissionMode.description}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
                const SizedBox(height: 6),
                Text(
                  usingCodex
                      ? 'Exact Codex reference passed to exec: codex exec - -m $selectedModel --config model_reasoning_effort="$selectedReasoning" --json --ephemeral --full-auto --sandbox workspace-write --skip-git-repo-check --cd <project root> --output-last-message <temp file>'
                      : 'Exact Copilot reference passed to exec: ${CopilotCliService.commandPreview(model: selectedModel, reasoningEffort: selectedReasoning, permissionMode: copilotPermissionMode)}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    SizedBox(
                      height: 28,
                      child: OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(6),
                          ),
                        ),
                        onPressed: _busy || providerInstalled
                            ? null
                            : () => _runProviderAction(
                                usingCodex
                                    ? 'Installing Codex CLI...'
                                    : 'Installing GitHub Copilot CLI...',
                                usingCodex
                                    ? CodexCliService.install
                                    : CopilotCliService.install,
                              ),
                        child: Text(
                          installLabel,
                          style: const TextStyle(fontSize: 11),
                        ),
                      ),
                    ),
                    SizedBox(
                      height: 28,
                      child: FilledButton(
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(6),
                          ),
                        ),
                        onPressed:
                            _busy || !providerInstalled || providerAuthenticated
                            ? null
                            : usingCodex
                            ? () => _runProviderAction(
                                'Waiting for ChatGPT sign-in...',
                                CodexCliService.loginWithChatgpt,
                              )
                            : _runCopilotSignIn,
                        child: Text(
                          signInLabel,
                          style: const TextStyle(fontSize: 11),
                        ),
                      ),
                    ),
                    if (usingCodex)
                      SizedBox(
                        height: 28,
                        child: OutlinedButton(
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(6),
                            ),
                          ),
                          onPressed: _busy
                              ? null
                              : () => _runProviderAction(
                                  'Starting device-code login...',
                                  CodexCliService.loginWithDeviceCode,
                                ),
                          child: const Text(
                            'Device Code',
                            style: TextStyle(fontSize: 11),
                          ),
                        ),
                      ),
                    if (usingCodex)
                      SizedBox(
                        height: 28,
                        child: OutlinedButton(
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(6),
                            ),
                          ),
                          onPressed: _busy
                              ? null
                              : () => _runProviderAction(
                                  'Signing out...',
                                  CodexCliService.logout,
                                ),
                          child: const Text(
                            'Sign Out',
                            style: TextStyle(fontSize: 11),
                          ),
                        ),
                      ),
                    SizedBox(
                      height: 28,
                      child: OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(6),
                          ),
                        ),
                        onPressed: _busy ? null : _refreshProviderStatus,
                        child: const Text(
                          'Refresh Status',
                          style: TextStyle(fontSize: 11),
                        ),
                      ),
                    ),
                  ],
                ),
                if (_busy || _statusDetail.trim().isNotEmpty) ...[
                  const SizedBox(height: 12),
                  _InfoSurface(
                    title: _busy ? _busyLabel : 'Status',
                    body: _busy
                        ? (_statusDetail.trim().isEmpty
                              ? 'The command is running. Browser login may take a moment.'
                              : _statusDetail)
                        : _statusDetail,
                  ),
                ],
                if (_commandOutput.trim().isNotEmpty) ...[
                  const SizedBox(height: 12),
                  _InfoSurface(
                    title: 'Command Output',
                    body: _commandOutput,
                    monospace: true,
                  ),
                ],
                const SizedBox(height: 24),
                const _SectionLabel('Project Root Folder'),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(
                      child: Container(
                        height: 32,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        decoration: BoxDecoration(
                          color: FloraPalette.background,
                          border: Border.all(color: FloraPalette.border),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        alignment: Alignment.centerLeft,
                        child: TextField(
                          controller: _rootCtrl,
                          style: FloraTheme.mono(size: 12),
                          decoration: const InputDecoration(
                            hintText: r'C:\Users\you\my_flutter_project',
                            border: InputBorder.none,
                            isDense: true,
                            contentPadding: EdgeInsets.zero,
                          ),
                          onChanged: (_) => setState(() => _saved = false),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      height: 32,
                      child: OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(6),
                          ),
                        ),
                        onPressed: _busy || _saving ? null : _pickProjectRoot,
                        child: const Text(
                          'Browse...',
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  'This folder powers the Explorer, AI assistant working directory, and one-click flutter preview.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 24),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    if (_saved)
                      const Padding(
                        padding: EdgeInsets.only(right: 12),
                        child: Row(
                          children: [
                            Icon(
                              Icons.check,
                              size: 14,
                              color: FloraPalette.success,
                            ),
                            SizedBox(width: 4),
                            Text(
                              'Saved',
                              style: TextStyle(
                                color: FloraPalette.success,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                    SizedBox(
                      height: 32,
                      child: OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(6),
                          ),
                        ),
                        onPressed: _busy || _saving ? null : widget.onClose,
                        child: const Text(
                          'Close',
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      height: 32,
                      child: FilledButton(
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(6),
                          ),
                        ),
                        onPressed: _busy || _saving ? null : _save,
                        child: Text(
                          _saving ? 'Saving...' : 'Save',
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.active, required this.label});

  final bool active;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: active
            ? FloraPalette.selectedBg.withValues(alpha: 0.7)
            : FloraPalette.background,
        border: Border.all(color: FloraPalette.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: active ? FloraPalette.success : FloraPalette.textDimmed,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: const TextStyle(
              color: FloraPalette.textPrimary,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoSurface extends StatelessWidget {
  const _InfoSurface({
    required this.title,
    required this.body,
    this.monospace = false,
  });

  final String title;
  final String body;
  final bool monospace;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: FloraPalette.background,
        border: Border.all(color: FloraPalette.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              color: FloraPalette.textSecondary,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          SelectableText(
            body,
            style: monospace
                ? FloraTheme.mono(size: 11)
                : Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: FloraPalette.textPrimary,
                  ),
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        color: FloraPalette.textSecondary,
        fontSize: 11,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.5,
      ),
    );
  }
}
