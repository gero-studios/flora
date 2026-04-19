import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app/app.dart';
import 'core/models/flora_models.dart';
import 'core/services/copilot_cli_service.dart';
import 'core/services/codex_cli_service.dart';
import 'core/state/flora_providers.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final prefs = await SharedPreferences.getInstance();
  final storedKey = prefs.getString('openai_api_key');
  final storedProjectRoot = prefs.getString('project_root');
  final storedAssistantProvider = normalizeAssistantProvider(
    assistantProviderFromKey(prefs.getString('assistant_provider')),
  );
  final storedCodexModel = prefs.getString('codex_model') ?? 'gpt-5.4-mini';
  final storedCodexReasoningEffort =
      prefs.getString('codex_reasoning_effort') ?? 'medium';
  final storedCopilotModel = prefs.getString('copilot_model') ?? 'gpt-5.2';
  final storedCopilotReasoningEffort =
      prefs.getString('copilot_reasoning_effort') ?? 'medium';
  var storedCopilotPermissionMode = copilotPermissionModeFromKey(
    prefs.getString('copilot_permission_mode'),
  );
  if (storedCopilotPermissionMode == CopilotPermissionMode.readOnly) {
    // Prompt mode (-p) can no longer request permissions interactively, so a
    // persisted read-only setting causes all edit attempts to fail. Migrate to
    // workspace-write so Copilot can edit within the opened project.
    storedCopilotPermissionMode = CopilotPermissionMode.workspaceWrite;
  }
  final codexStatus = codexIntegrationEnabled
      ? await CodexCliService.inspectStatus()
      : const CodexCliStatus(
          installed: false,
          mode: CodexAuthMode.missing,
          message: 'Codex integration is temporarily disabled.',
        );
  final copilotStatus = await CopilotCliService.inspectStatus();

  runApp(
    ProviderScope(
      overrides: [
        openAIKeyInitialProvider.overrideWithValue(storedKey),
        projectRootInitialProvider.overrideWithValue(storedProjectRoot),
        assistantProviderInitialProvider.overrideWithValue(
          storedAssistantProvider,
        ),
        codexInstalledInitialProvider.overrideWithValue(codexStatus.installed),
        codexAuthenticatedInitialProvider.overrideWithValue(
          codexStatus.authenticated,
        ),
        codexAuthLabelInitialProvider.overrideWithValue(codexStatus.badgeLabel),
        copilotInstalledInitialProvider.overrideWithValue(
          copilotStatus.installed,
        ),
        copilotAuthenticatedInitialProvider.overrideWithValue(
          copilotStatus.authenticated,
        ),
        copilotAuthLabelInitialProvider.overrideWithValue(
          copilotStatus.badgeLabel,
        ),
        codexModelInitialProvider.overrideWithValue(storedCodexModel),
        codexReasoningEffortInitialProvider.overrideWithValue(
          storedCodexReasoningEffort,
        ),
        copilotModelInitialProvider.overrideWithValue(storedCopilotModel),
        copilotReasoningEffortInitialProvider.overrideWithValue(
          storedCopilotReasoningEffort,
        ),
        copilotPermissionModeInitialProvider.overrideWithValue(
          storedCopilotPermissionMode,
        ),
      ],
      child: const FloraApp(),
    ),
  );
}
