import 'dart:io';

import 'package:vm_service/utils.dart' as vm_service_utils;
import 'package:vm_service/vm_service.dart' as vm_service;
import 'package:vm_service/vm_service_io.dart';

import '../models/flora_models.dart';

class FlutterInspectorService {
  const FlutterInspectorService._();

  static const String _selectionObjectGroup = 'flora_inspector_selection_group';
  static const String _selectionModeExtension = 'ext.flutter.inspector.show';

  static Future<InspectorSelectionContext?> fetchSelectedSummaryWidget({
    required String vmServiceUrl,
  }) async {
    vm_service.VmService? service;
    String? isolateId;

    try {
      final uri = Uri.tryParse(vmServiceUrl);
      if (uri == null) {
        return null;
      }

      final wsUri = vm_service_utils.convertToWebSocketUrl(
        serviceProtocolUrl: uri,
      );
      service = await vmServiceConnectUri(wsUri.toString());

      final vm = await service.getVM();
      isolateId = _pickIsolateId(vm);
      if (isolateId == null) {
        return null;
      }

      final isolate = await service.getIsolate(isolateId);
      final extensions = isolate.extensionRPCs ?? const <String>[];
      if (!extensions.contains(
        'ext.flutter.inspector.getSelectedSummaryWidget',
      )) {
        return null;
      }

      final selectedResponse = await service.callServiceExtension(
        'ext.flutter.inspector.getSelectedSummaryWidget',
        isolateId: isolateId,
        args: <String, dynamic>{'objectGroup': _selectionObjectGroup},
      );

      final selectedNode = _asMap(selectedResponse.json?['result']);
      if (selectedNode == null || selectedNode.isEmpty) {
        return null;
      }

      final rawDescription =
          selectedNode['description']?.toString() ?? 'Unknown widget';
      final widgetName = _extractWidgetName(rawDescription);
      final valueId = selectedNode['valueId']?.toString();

      final creationLocation = _asMap(selectedNode['creationLocation']);
      final sourceFile = _normalizeSourcePath(
        creationLocation?['file']?.toString(),
      );
      final line = _asInt(creationLocation?['line']);
      final endLine = _estimateWidgetEndLine(
        sourceFile: sourceFile,
        startLine: line,
      );
      final column = _asInt(creationLocation?['column']);

      final ancestors = await _fetchAncestorPath(
        service: service,
        isolateId: isolateId,
        valueId: valueId,
      );

      return InspectorSelectionContext(
        valueId: valueId,
        widgetName: widgetName,
        description: rawDescription,
        sourceFile: sourceFile,
        line: line,
        endLine: endLine,
        column: column,
        ancestorPath: ancestors,
        capturedAt: DateTime.now(),
      );
    } on vm_service.RPCError {
      return null;
    } catch (_) {
      return null;
    } finally {
      if (service != null) {
        if (isolateId != null) {
          try {
            await service.callServiceExtension(
              'ext.flutter.inspector.disposeGroup',
              isolateId: isolateId,
              args: <String, dynamic>{'objectGroup': _selectionObjectGroup},
            );
          } catch (_) {
            // Ignore disposeGroup failures.
          }
        }

        try {
          await service.dispose();
        } catch (_) {
          // Ignore close failures.
        }
      }
    }
  }

  static Future<bool> setInspectorSelectionMode({
    required String vmServiceUrl,
    required bool enabled,
  }) async {
    final result = await _withConnectedInspector(
      vmServiceUrl: vmServiceUrl,
      action:
          (
            vm_service.VmService service,
            String isolateId,
            Set<String> extensions,
          ) async {
            if (!extensions.contains(_selectionModeExtension)) {
              return false;
            }

            await service.callServiceExtension(
              _selectionModeExtension,
              isolateId: isolateId,
              args: <String, dynamic>{'enabled': enabled ? 'true' : 'false'},
            );
            return true;
          },
    );

    return result ?? false;
  }

  static Future<T?> _withConnectedInspector<T>({
    required String vmServiceUrl,
    required Future<T> Function(
      vm_service.VmService service,
      String isolateId,
      Set<String> extensions,
    )
    action,
  }) async {
    vm_service.VmService? service;
    try {
      final uri = Uri.tryParse(vmServiceUrl);
      if (uri == null) {
        return null;
      }

      final wsUri = vm_service_utils.convertToWebSocketUrl(
        serviceProtocolUrl: uri,
      );
      service = await vmServiceConnectUri(wsUri.toString());

      final vm = await service.getVM();
      final isolateId = _pickIsolateId(vm);
      if (isolateId == null) {
        return null;
      }

      final isolate = await service.getIsolate(isolateId);
      final extensions = Set<String>.from(
        isolate.extensionRPCs ?? const <String>[],
      );
      return action(service, isolateId, extensions);
    } on vm_service.RPCError {
      return null;
    } catch (_) {
      return null;
    } finally {
      if (service != null) {
        try {
          await service.dispose();
        } catch (_) {
          // Ignore close failures.
        }
      }
    }
  }

  static int? _estimateWidgetEndLine({
    required String? sourceFile,
    required int? startLine,
  }) {
    if (sourceFile == null || startLine == null || startLine < 1) {
      return null;
    }

    try {
      final file = File(sourceFile);
      if (!file.existsSync()) {
        return null;
      }

      final lines = file.readAsLinesSync();
      if (startLine > lines.length) {
        return null;
      }

      final snippet = lines.sublist(startLine - 1).join('\n');
      final openParenIndex = _findOpenParen(snippet);
      if (openParenIndex < 0) {
        return startLine;
      }

      final closeParenIndex = _findMatchingParen(snippet, openParenIndex);
      if (closeParenIndex < 0) {
        return startLine;
      }

      final lineDelta = '\n'
          .allMatches(snippet.substring(0, closeParenIndex + 1))
          .length;
      return startLine + lineDelta;
    } catch (_) {
      return startLine;
    }
  }

  static int _findOpenParen(String text) {
    var inSingleQuote = false;
    var inDoubleQuote = false;
    var inLineComment = false;
    var inBlockComment = false;
    var escaped = false;

    for (var i = 0; i < text.length; i++) {
      final char = text[i];
      final next = i + 1 < text.length ? text[i + 1] : '';

      if (inLineComment) {
        if (char == '\n') {
          inLineComment = false;
        }
        continue;
      }

      if (inBlockComment) {
        if (char == '*' && next == '/') {
          inBlockComment = false;
          i++;
        }
        continue;
      }

      if (inSingleQuote) {
        if (!escaped && char == "'") {
          inSingleQuote = false;
        }
        escaped = !escaped && char == '\\';
        continue;
      }

      if (inDoubleQuote) {
        if (!escaped && char == '"') {
          inDoubleQuote = false;
        }
        escaped = !escaped && char == '\\';
        continue;
      }

      if (char == '/' && next == '/') {
        inLineComment = true;
        i++;
        continue;
      }

      if (char == '/' && next == '*') {
        inBlockComment = true;
        i++;
        continue;
      }

      if (char == "'") {
        inSingleQuote = true;
        escaped = false;
        continue;
      }

      if (char == '"') {
        inDoubleQuote = true;
        escaped = false;
        continue;
      }

      if (char == '(') {
        return i;
      }
    }

    return -1;
  }

  static int _findMatchingParen(String text, int openParenIndex) {
    var inSingleQuote = false;
    var inDoubleQuote = false;
    var inLineComment = false;
    var inBlockComment = false;
    var escaped = false;
    var depth = 0;

    for (var i = openParenIndex; i < text.length; i++) {
      final char = text[i];
      final next = i + 1 < text.length ? text[i + 1] : '';

      if (inLineComment) {
        if (char == '\n') {
          inLineComment = false;
        }
        continue;
      }

      if (inBlockComment) {
        if (char == '*' && next == '/') {
          inBlockComment = false;
          i++;
        }
        continue;
      }

      if (inSingleQuote) {
        if (!escaped && char == "'") {
          inSingleQuote = false;
        }
        escaped = !escaped && char == '\\';
        continue;
      }

      if (inDoubleQuote) {
        if (!escaped && char == '"') {
          inDoubleQuote = false;
        }
        escaped = !escaped && char == '\\';
        continue;
      }

      if (char == '/' && next == '/') {
        inLineComment = true;
        i++;
        continue;
      }

      if (char == '/' && next == '*') {
        inBlockComment = true;
        i++;
        continue;
      }

      if (char == "'") {
        inSingleQuote = true;
        escaped = false;
        continue;
      }

      if (char == '"') {
        inDoubleQuote = true;
        escaped = false;
        continue;
      }

      if (char == '(') {
        depth++;
        continue;
      }

      if (char == ')') {
        depth--;
        if (depth == 0) {
          return i;
        }
      }
    }

    return -1;
  }

  static Future<List<String>> _fetchAncestorPath({
    required vm_service.VmService service,
    required String isolateId,
    required String? valueId,
  }) async {
    if (valueId == null || valueId.isEmpty) {
      return const <String>[];
    }

    try {
      final chainResponse = await service.callServiceExtension(
        'ext.flutter.inspector.getParentChain',
        isolateId: isolateId,
        args: <String, dynamic>{
          'objectGroup': _selectionObjectGroup,
          'arg': valueId,
        },
      );

      final rawChain = chainResponse.json?['result'];
      if (rawChain is! List) {
        return const <String>[];
      }

      final ancestors = <String>[];
      for (final entry in rawChain) {
        final node = _asMap(_asMap(entry)?['node']);
        final description = node?['description']?.toString();
        if (description == null || description.trim().isEmpty) {
          continue;
        }
        ancestors.add(_extractWidgetName(description));
      }
      return ancestors;
    } on vm_service.RPCError {
      return const <String>[];
    }
  }

  static String? _pickIsolateId(vm_service.VM vm) {
    for (final isolate in vm.isolates ?? const <vm_service.IsolateRef>[]) {
      final id = isolate.id;
      if (id != null && id.isNotEmpty) {
        return id;
      }
    }
    return null;
  }

  static Map<String, dynamic>? _asMap(dynamic value) {
    if (value is Map<String, dynamic>) {
      return value;
    }
    if (value is Map) {
      return value.map((key, val) => MapEntry(key.toString(), val));
    }
    return null;
  }

  static int? _asInt(dynamic value) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    if (value is String) {
      return int.tryParse(value);
    }
    return null;
  }

  static String _extractWidgetName(String description) {
    final trimmed = description.trim();
    if (trimmed.isEmpty) {
      return 'UnknownWidget';
    }

    final match = RegExp(r'^[A-Za-z0-9_<>]+').firstMatch(trimmed);
    return (match?.group(0) ?? trimmed).trim();
  }

  static String? _normalizeSourcePath(String? rawPath) {
    if (rawPath == null || rawPath.trim().isEmpty) {
      return null;
    }

    final trimmed = rawPath.trim();
    if (trimmed.startsWith('file://')) {
      try {
        return Uri.parse(trimmed).toFilePath(windows: Platform.isWindows);
      } catch (_) {
        return trimmed;
      }
    }

    return trimmed;
  }
}
