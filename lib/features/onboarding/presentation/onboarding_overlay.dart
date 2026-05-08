import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../app/theme/flora_theme.dart';
import '../../../core/models/flora_models.dart';
import '../../../core/services/copilot_cli_service.dart';
import '../../../core/services/codex_cli_service.dart';
import '../../../core/state/flora_providers.dart';

enum _OnboardingStep { chooseProvider, setup }

class OnboardingOverlay extends ConsumerStatefulWidget {
  const OnboardingOverlay({super.key});

  @override
  ConsumerState<OnboardingOverlay> createState() => _OnboardingOverlayState();
}

class _OnboardingOverlayState extends ConsumerState<OnboardingOverlay> {
  _OnboardingStep _step = _OnboardingStep.chooseProvider;
  bool _busy = false;
  String _busyLabel = '';
  String _statusDetail = '';
  String _commandOutput = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _refreshProviderStatus(showBusy: false);
      }
    });
  }

  Future<void> _persistProviderSelection() async {
    final provider = normalizeAssistantProvider(ref.read(assistantProvider));
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('assistant_provider', provider.key);
  }

  Future<void> _completeOnboarding() async {
    await _persistProviderSelection();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('onboarding_complete', true);
    ref.read(onboardingCompleteProvider.notifier).state = true;
  }

  Future<void> _refreshProviderStatus({bool showBusy = true}) async {
    final provider = ref.read(assistantProvider);

    if (showBusy) {
      setState(() {
        _busy = true;
        _busyLabel = provider == AssistantProviderType.codex
            ? 'Checking Codex CLI...'
            : 'Checking Command Code CLI...';
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
    ref.read(copilotAuthenticatedProvider.notifier).state = status.authenticated;
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
      _busyLabel = 'Starting Command Code sign-in...';
      _statusDetail =
          'Opening Command Code login. On Windows this launches a terminal window so you can finish the browser flow there.';
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
              ? 'Command Code sign-in started.'
              : 'Command Code sign-in failed.')
          : result.combinedOutput;
    });
  }

  String _providerDescription(AssistantProviderType provider) {
    switch (provider) {
      case AssistantProviderType.codex:
        return 'Use Codex CLI with your ChatGPT account to run Flora tasks.';
      case AssistantProviderType.copilot:
        return 'Use Command Code with GitHub sign-in for Flora runs and model routing.';
    }
  }

  @override
  Widget build(BuildContext context) {
    final selectedProvider = normalizeAssistantProvider(
      ref.watch(assistantProvider),
    );
    final usingCodex = selectedProvider == AssistantProviderType.codex;
    final providerInstalled = usingCodex
        ? ref.watch(codexInstalledProvider)
        : ref.watch(copilotInstalledProvider);
    final providerAuthenticated = usingCodex
        ? ref.watch(codexAuthenticatedProvider)
        : ref.watch(copilotAuthenticatedProvider);
    final providerLabel = selectedProvider.label;
    final canFinish = providerInstalled && providerAuthenticated;
    final canAdvance =
        _step == _OnboardingStep.chooseProvider || canFinish;

    return Positioned.fill(
      child: Container(
        color: Colors.black.withValues(alpha: 0.6),
        alignment: Alignment.center,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: FloraPalette.panelBg,
              border: Border.all(color: FloraPalette.border),
              borderRadius: BorderRadius.circular(16),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x66000000),
                  blurRadius: 24,
                  offset: Offset(0, 18),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(
                      Icons.auto_awesome_rounded,
                      size: 18,
                      color: FloraPalette.textSecondary,
                    ),
                    const SizedBox(width: 8),
                    const Text(
                      'Welcome to Flora',
                      style: TextStyle(
                        color: FloraPalette.textPrimary,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    _StepBadge(
                      label: _step == _OnboardingStep.chooseProvider
                          ? 'Step 1 of 2'
                          : 'Step 2 of 2',
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  _step == _OnboardingStep.chooseProvider
                      ? 'Pick the assistant provider you want to use for tasks.'
                      : 'Install and sign in to $providerLabel so Flora can run tasks.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: FloraPalette.textSecondary,
                      ),
                ),
                const SizedBox(height: 16),
                if (_step == _OnboardingStep.chooseProvider)
                  _ProviderChooser(
                    selectedProvider: selectedProvider,
                    onSelect: _busy
                        ? null
                        : (value) {
                            ref.read(assistantProvider.notifier).state = value;
                            _refreshProviderStatus(showBusy: false);
                          },
                    descriptionBuilder: _providerDescription,
                  )
                else
                  _SetupPanel(
                    providerLabel: providerLabel,
                    usingCodex: usingCodex,
                    busy: _busy,
                    providerInstalled: providerInstalled,
                    providerAuthenticated: providerAuthenticated,
                    onInstall: _busy || providerInstalled
                        ? null
                        : () => _runProviderAction(
                              usingCodex
                                  ? 'Installing Codex CLI...'
                                  : 'Installing Command Code CLI...',
                              usingCodex
                                  ? CodexCliService.install
                                  : CopilotCliService.install,
                            ),
                    onSignInPrimary: _busy ||
                            !providerInstalled ||
                            providerAuthenticated
                        ? null
                        : (usingCodex
                            ? () => _runProviderAction(
                                  'Starting ChatGPT login...',
                                  CodexCliService.loginWithChatgpt,
                                )
                            : _runCopilotSignIn),
                    onSignInSecondary: _busy ||
                            !providerInstalled ||
                            providerAuthenticated ||
                            !usingCodex
                        ? null
                        : () => _runProviderAction(
                              'Starting device-code login...',
                              CodexCliService.loginWithDeviceCode,
                            ),
                    onRefresh: _busy ? null : _refreshProviderStatus,
                  ),
                const SizedBox(height: 16),
                if (_busy || _statusDetail.trim().isNotEmpty)
                  _InfoSurface(
                    title: _busy ? _busyLabel : 'Status',
                    body: _busy
                        ? (_statusDetail.trim().isEmpty
                            ? 'The command is running. Browser login may take a moment.'
                            : _statusDetail)
                        : _statusDetail,
                  ),
                if (_commandOutput.trim().isNotEmpty) ...[
                  const SizedBox(height: 12),
                  _InfoSurface(
                    title: 'Output',
                    body: _commandOutput,
                    monospace: true,
                  ),
                ],
                const SizedBox(height: 20),
                Row(
                  children: [
                    if (_step == _OnboardingStep.setup)
                      SizedBox(
                        height: 32,
                        child: OutlinedButton(
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(6),
                            ),
                          ),
                          onPressed: _busy
                              ? null
                              : () => setState(() {
                                    _step = _OnboardingStep.chooseProvider;
                                  }),
                          child: const Text(
                            'Back',
                            style: TextStyle(fontSize: 12),
                          ),
                        ),
                      ),
                    const Spacer(),
                    SizedBox(
                      height: 32,
                      child: FilledButton(
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 20),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(6),
                          ),
                        ),
                        onPressed: _busy || !canAdvance
                            ? null
                            : () async {
                                if (_step == _OnboardingStep.chooseProvider) {
                                  await _persistProviderSelection();
                                  if (mounted) {
                                    setState(() {
                                      _step = _OnboardingStep.setup;
                                    });
                                  }
                                  await _refreshProviderStatus(showBusy: false);
                                } else if (canFinish) {
                                  await _completeOnboarding();
                                }
                              },
                        child: Text(
                          _step == _OnboardingStep.chooseProvider
                              ? 'Continue'
                              : (canFinish ? 'Finish setup' : 'Complete setup'),
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ProviderChooser extends StatelessWidget {
  const _ProviderChooser({
    required this.selectedProvider,
    required this.onSelect,
    required this.descriptionBuilder,
  });

  final AssistantProviderType selectedProvider;
  final ValueChanged<AssistantProviderType>? onSelect;
  final String Function(AssistantProviderType provider) descriptionBuilder;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (final provider in enabledAssistantProviders())
          Container(
            margin: const EdgeInsets.only(bottom: 10),
            decoration: BoxDecoration(
              color: FloraPalette.background,
              border: Border.all(color: FloraPalette.border),
              borderRadius: BorderRadius.circular(10),
            ),
            child: RadioListTile<AssistantProviderType>(
              value: provider,
              groupValue: selectedProvider,
              activeColor: FloraPalette.accent,
              onChanged: onSelect == null
                  ? null
                  : (value) {
                      if (value == null) {
                        return;
                      }
                      onSelect!(value);
                    },
              title: Text(
                provider.label,
                style: const TextStyle(
                  color: FloraPalette.textPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              subtitle: Text(
                descriptionBuilder(provider),
                style: const TextStyle(
                  color: FloraPalette.textSecondary,
                  fontSize: 11,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _SetupPanel extends StatelessWidget {
  const _SetupPanel({
    required this.providerLabel,
    required this.usingCodex,
    required this.busy,
    required this.providerInstalled,
    required this.providerAuthenticated,
    required this.onInstall,
    required this.onSignInPrimary,
    required this.onSignInSecondary,
    required this.onRefresh,
  });

  final String providerLabel;
  final bool usingCodex;
  final bool busy;
  final bool providerInstalled;
  final bool providerAuthenticated;
  final VoidCallback? onInstall;
  final VoidCallback? onSignInPrimary;
  final VoidCallback? onSignInSecondary;
  final VoidCallback? onRefresh;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _ActionRow(
          title: 'Install $providerLabel CLI',
          subtitle: providerInstalled
              ? '$providerLabel CLI is installed.'
              : 'Install the CLI so Flora can run tasks.',
          action: FilledButton(
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(6),
              ),
            ),
            onPressed: onInstall,
            child: Text(
              providerInstalled ? 'Installed' : 'Install',
              style: const TextStyle(fontSize: 12),
            ),
          ),
        ),
        const SizedBox(height: 12),
        _ActionRow(
          title: 'Sign in',
          subtitle: providerAuthenticated
              ? '$providerLabel is ready for use.'
              : 'Authenticate so Flora can access your account.',
          action: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton(
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
                onPressed: onSignInPrimary,
                child: Text(
                  usingCodex ? 'Sign in with ChatGPT' : 'Sign in with GitHub',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
              if (usingCodex)
                OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(6),
                    ),
                  ),
                  onPressed: onSignInSecondary,
                  child: const Text(
                    'Use device code',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
              OutlinedButton(
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
                onPressed: onRefresh,
                child: const Text(
                  'Refresh status',
                  style: TextStyle(fontSize: 12),
                ),
              ),
            ],
          ),
        ),
        if (busy)
          const Padding(
            padding: EdgeInsets.only(top: 12),
            child: LinearProgressIndicator(minHeight: 2),
          ),
      ],
    );
  }
}

class _ActionRow extends StatelessWidget {
  const _ActionRow({
    required this.title,
    required this.subtitle,
    required this.action,
  });

  final String title;
  final String subtitle;
  final Widget action;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: FloraPalette.background,
        border: Border.all(color: FloraPalette.border),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: FloraPalette.textPrimary,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: const TextStyle(
                    color: FloraPalette.textSecondary,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          action,
        ],
      ),
    );
  }
}

class _StepBadge extends StatelessWidget {
  const _StepBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: FloraPalette.selectedBg.withValues(alpha: 0.4),
        border: Border.all(color: FloraPalette.border),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: FloraPalette.textSecondary,
          fontSize: 10,
          fontWeight: FontWeight.w600,
        ),
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
        borderRadius: BorderRadius.circular(10),
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
