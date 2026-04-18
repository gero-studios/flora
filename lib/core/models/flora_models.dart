import 'package:flutter/material.dart';

enum MessageRole { user, assistant, system }

enum LogLevel { info, warning, error }

enum AssistantProviderType { codex, copilot }

/// Temporary kill switch for Codex while integration work is paused.
const bool codexIntegrationEnabled = false;

List<AssistantProviderType> enabledAssistantProviders() {
  if (codexIntegrationEnabled) {
    return AssistantProviderType.values;
  }
  return const [AssistantProviderType.copilot];
}

AssistantProviderType normalizeAssistantProvider(
  AssistantProviderType provider,
) {
  if (!codexIntegrationEnabled && provider == AssistantProviderType.codex) {
    return AssistantProviderType.copilot;
  }
  return provider;
}

AssistantProviderType assistantProviderFromKey(String? value) {
  switch ((value ?? '').trim().toLowerCase()) {
    case 'copilot':
      return AssistantProviderType.copilot;
    case 'codex':
      return normalizeAssistantProvider(AssistantProviderType.codex);
    default:
      return normalizeAssistantProvider(AssistantProviderType.codex);
  }
}

extension AssistantProviderTypeX on AssistantProviderType {
  String get key {
    switch (this) {
      case AssistantProviderType.codex:
        return 'codex';
      case AssistantProviderType.copilot:
        return 'copilot';
    }
  }

  String get label {
    switch (this) {
      case AssistantProviderType.codex:
        return 'Codex';
      case AssistantProviderType.copilot:
        return 'GitHub Copilot';
    }
  }
}

class FloraProject {
  const FloraProject({
    required this.name,
    required this.repoPath,
    required this.branch,
    required this.environment,
    required this.flutterVersion,
    required this.workspaceName,
    required this.runtimeStatus,
  });

  final String name;
  final String repoPath;
  final String branch;
  final String environment;
  final String flutterVersion;
  final String workspaceName;
  final String runtimeStatus;
}

class SidebarGroup {
  const SidebarGroup({required this.title, required this.items});

  final String title;
  final List<SidebarItem> items;
}

class SidebarItem {
  const SidebarItem({required this.label, required this.icon, this.badge});

  final String label;
  final IconData icon;
  final String? badge;
}

class ProjectFileEntry {
  const ProjectFileEntry({
    required this.label,
    required this.path,
    required this.depth,
    this.isFolder = false,
    this.isDirty = false,
    this.aiTouched = false,
  });

  final String label;
  final String path;
  final int depth;
  final bool isFolder;
  final bool isDirty;
  final bool aiTouched;
}

class PromptTemplate {
  const PromptTemplate({
    required this.title,
    required this.summary,
    required this.commandHint,
  });

  final String title;
  final String summary;
  final String commandHint;
}

class ChatContextChip {
  const ChatContextChip({required this.label, required this.tint});

  final String label;
  final Color tint;
}

class WidgetSelection {
  const WidgetSelection({
    required this.widgetId,
    required this.widgetName,
    required this.sourceFile,
    required this.line,
    required this.routeName,
    required this.ancestors,
    required this.stateBindings,
    required this.recentIssues,
    required this.constraints,
    required this.size,
    required this.semanticsLabel,
    required this.buildCount,
    required this.summary,
    required this.accentColor,
  });

  final String widgetId;
  final String widgetName;
  final String sourceFile;
  final int line;
  final String routeName;
  final List<String> ancestors;
  final List<String> stateBindings;
  final List<String> recentIssues;
  final String constraints;
  final String size;
  final String semanticsLabel;
  final int buildCount;
  final String summary;
  final Color accentColor;
}

class InspectorSelectionContext {
  const InspectorSelectionContext({
    required this.valueId,
    required this.widgetName,
    required this.description,
    required this.sourceFile,
    required this.line,
    required this.endLine,
    required this.column,
    required this.ancestorPath,
    required this.capturedAt,
  });

  final String? valueId;
  final String widgetName;
  final String description;
  final String? sourceFile;
  final int? line;
  final int? endLine;
  final int? column;
  final List<String> ancestorPath;
  final DateTime capturedAt;
}

class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.role,
    required this.content,
    this.timestamp,
    this.inspectorAttachment,
    this.model,
    this.reasoningEffort,
    this.assistantProvider,
    this.thoughts = const [],
    this.completionSummary,
    this.debugLines = const [],
  });

  final String id;
  final MessageRole role;
  final String content;
  final DateTime? timestamp;
  final InspectorSelectionContext? inspectorAttachment;
  final String? model;
  final String? reasoningEffort;
  final AssistantProviderType? assistantProvider;
  final List<String> thoughts;
  final String? completionSummary;
  final List<String> debugLines;
}

class RuntimeMetric {
  const RuntimeMetric({
    required this.label,
    required this.value,
    required this.context,
  });

  final String label;
  final String value;
  final String context;
}

class RuntimeLogEntry {
  const RuntimeLogEntry({
    required this.level,
    required this.timestamp,
    required this.message,
  });

  final LogLevel level;
  final String timestamp;
  final String message;
}

class DeploymentRun {
  const DeploymentRun({
    required this.target,
    required this.environment,
    required this.platform,
    required this.status,
    required this.initiator,
    required this.timestamp,
    required this.tint,
  });

  final String target;
  final String environment;
  final String platform;
  final String status;
  final String initiator;
  final String timestamp;
  final Color tint;
}

class PreflightCheck {
  const PreflightCheck({
    required this.label,
    required this.passed,
    required this.detail,
  });

  final String label;
  final bool passed;
  final String detail;
}
