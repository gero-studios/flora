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
      ],
      child: const FloraApp(),
    ),
  );
}
