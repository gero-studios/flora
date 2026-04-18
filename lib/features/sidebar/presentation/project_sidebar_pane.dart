import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:webview_windows/webview_windows.dart';

import '../../../app/theme/flora_theme.dart';
import '../../../core/models/flora_models.dart';
import '../../../core/services/flutter_inspector_service.dart';
import '../../../core/state/flora_providers.dart';

class ProjectSidebarPane extends ConsumerStatefulWidget {
  const ProjectSidebarPane({super.key});

  @override
  ConsumerState<ProjectSidebarPane> createState() => _ProjectSidebarPaneState();
}

class _ProjectSidebarPaneState extends ConsumerState<ProjectSidebarPane> {
  final WebviewController _appWebview = WebviewController();
  final WebviewController _devToolsWebview = WebviewController();
  final FocusNode _previewFocusNode = FocusNode(
    debugLabel: 'preview-pane-shortcuts',
  );

  final TextEditingController _urlCtrl = TextEditingController();
  final TextEditingController _runCommandCtrl = TextEditingController(
    text: 'flutter run -d web-server --web-hostname 127.0.0.1',
  );

  Process? _flutterProcess;
  Process? _devToolsProcess;
  StreamSubscription<String>? _stdoutSub;
  StreamSubscription<String>? _stderrSub;
  StreamSubscription<String>? _devToolsStdoutSub;
  StreamSubscription<String>? _devToolsStderrSub;
  Timer? _inspectorSyncTimer;
  bool _inspectorSyncBusy = false;

  bool _appWebviewInitialized = false;
  bool _devToolsWebviewInitialized = false;
  bool _loadingPreview = false;
  bool _loadingDevTools = false;
  bool _runningFlutter = false;
  String? _error;
  String _status = 'Idle';
  final List<String> _logs = <String>[];

  String? _appUrl;
  String? _vmServiceUrl;
  String? _devToolsUrl;
  _PreviewTab _activeTab = _PreviewTab.app;
  _PreviewBuildType _selectedBuildType = _PreviewBuildType.web;
  String? _lastProjectRoot;
  bool _showSettings = false;
  bool _devToolsSelectorEnabled = false;
  bool _ctrlToggleArmed = false;
  bool _inspectorDefaultsApplied = false;

  @override
  void initState() {
    super.initState();
    _lastProjectRoot = ref.read(projectRootProvider);
    _runCommandCtrl.text = _runCommandForBuildType(_selectedBuildType);
  }

  @override
  void dispose() {
    _stdoutSub?.cancel();
    _stderrSub?.cancel();
    _devToolsStdoutSub?.cancel();
    _devToolsStderrSub?.cancel();

    _flutterProcess?.kill();
    _devToolsProcess?.kill();
    _inspectorSyncTimer?.cancel();

    if (_appWebviewInitialized) {
      _appWebview.dispose();
    }
    if (_devToolsWebviewInitialized) {
      _devToolsWebview.dispose();
    }

    _urlCtrl.dispose();
    _runCommandCtrl.dispose();
    _previewFocusNode.dispose();
    ref.read(inspectorSelectionProvider.notifier).state = null;
    super.dispose();
  }

  Future<void> _loadApp(String url) async {
    if (url.trim().isEmpty) {
      return;
    }

    setState(() {
      _error = null;
      _loadingPreview = true;
      _status = 'Loading app preview...';
    });

    try {
      if (!_appWebviewInitialized) {
        await _appWebview.initialize();
        _appWebviewInitialized = true;
      }

      await _appWebview.loadUrl(url);
      _appUrl = url;

      if (_vmServiceUrl != null && _devToolsProcess == null) {
        unawaited(_ensureDevToolsRunning(_vmServiceUrl!));
      }

      if (!mounted) {
        return;
      }

      setState(() {
        _status = 'App preview connected';
      });
      _requestPreviewFocus();
      unawaited(_applyInspectorDefaults());
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = error.toString();
        _status = 'Preview failed to load';
      });
    } finally {
      if (mounted) {
        setState(() {
          _loadingPreview = false;
        });
      }
    }
  }

  Future<void> _loadDevTools(String url) async {
    if (url.trim().isEmpty) {
      return;
    }

    setState(() {
      _error = null;
      _loadingDevTools = true;
      _status = 'Loading DevTools...';
    });

    try {
      if (!_devToolsWebviewInitialized) {
        await _devToolsWebview.initialize();
        _devToolsWebviewInitialized = true;
      }

      await _devToolsWebview.loadUrl(url);
      _devToolsUrl = url;
      ref.read(devToolsUrlProvider.notifier).state = url;

      if (!mounted) {
        return;
      }

      setState(() {
        _status = 'DevTools connected';
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = error.toString();
        _status = 'DevTools failed to load';
      });
    } finally {
      if (mounted) {
        setState(() {
          _loadingDevTools = false;
        });
      }
    }
  }

  Future<void> _runAndLoadPreview() async {
    final root = ref.read(projectRootProvider);
    if (root == null || root.trim().isEmpty) {
      setState(() {
        _error = 'Choose a project folder first.';
        _status = 'Missing project root';
      });
      return;
    }

    if (_runningFlutter) {
      return;
    }

    setState(() {
      _error = null;
      _runningFlutter = true;
      _status = 'Starting ${_selectedBuildType.label} run...';
      _appUrl = null;
      _vmServiceUrl = null;
      _devToolsUrl = null;
      _inspectorDefaultsApplied = false;
      _devToolsSelectorEnabled = false;
      _ctrlToggleArmed = false;
      _activeTab = _PreviewTab.app;
      _logs
        ..clear()
        ..add(_runCommandCtrl.text);
    });

    try {
      final parts = _runCommandCtrl.text.trim().split(RegExp(r'\s+'));
      final executable = parts.isNotEmpty ? parts.first : 'flutter';
      final rawArgs = parts.length > 1 ? parts.sublist(1) : <String>[];
      final args = await _prepareRunArgs(executable, rawArgs);

      if (!mounted) {
        return;
      }

      setState(() {
        _logs
          ..clear()
          ..add('$executable ${args.join(' ')}');
      });

      final process = await Process.start(
        executable,
        args,
        workingDirectory: root,
        runInShell: true,
      );
      _flutterProcess = process;

      _stdoutSub = process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(_handleFlutterLine);
      _stderrSub = process.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(_handleFlutterLine);

      unawaited(
        process.exitCode.then((exitCode) {
          if (!mounted) {
            return;
          }
          setState(() {
            _runningFlutter = false;
            _status = 'flutter run exited with code $exitCode';
          });
          _vmServiceUrl = null;
          _stopInspectorSync();
        }),
      );
    } on ProcessException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _runningFlutter = false;
        _error = error.message;
        _status = 'Failed to start flutter run';
      });
    }
  }

  String _runCommandForBuildType(_PreviewBuildType buildType) {
    switch (buildType) {
      case _PreviewBuildType.web:
        return 'flutter run -d web-server --web-hostname 127.0.0.1';
      case _PreviewBuildType.app:
        return 'flutter run -d windows';
      case _PreviewBuildType.mobile:
        return 'flutter run -d android';
    }
  }

  void _setBuildType(_PreviewBuildType buildType) {
    if (_selectedBuildType == buildType) {
      return;
    }

    setState(() {
      _selectedBuildType = buildType;
      _runCommandCtrl.text = _runCommandForBuildType(buildType);
      _status = 'Build type set to ${buildType.label}';
    });
  }

  void _handleProjectRootChanged(String? nextRoot) {
    if (_lastProjectRoot == nextRoot) {
      return;
    }

    _lastProjectRoot = nextRoot;
    _setBuildType(_PreviewBuildType.web);
    if (_runningFlutter) {
      unawaited(_stopFlutterRun());
    }
  }

  Future<List<String>> _prepareRunArgs(
    String executable,
    List<String> rawArgs,
  ) async {
    final args = List<String>.from(rawArgs);
    if (!_looksLikeFlutterExecutable(executable) || !_targetsWebServer(args)) {
      return args;
    }

    _removeFlagWithOptionalValue(args, '--web-port');

    if (!_hasFlag(args, '--web-hostname')) {
      args.addAll(<String>['--web-hostname', '127.0.0.1']);
    }

    final selectedPort = await _pickAvailablePort();
    args.addAll(<String>['--web-port', '$selectedPort']);
    _status = 'Selected free preview port $selectedPort';
    return args;
  }

  bool _looksLikeFlutterExecutable(String executable) {
    final lower = executable.toLowerCase();
    return lower == 'flutter' ||
        lower.endsWith(r'\flutter.bat') ||
        lower.endsWith('/flutter') ||
        lower.endsWith('/flutter.bat');
  }

  bool _targetsWebServer(List<String> args) {
    for (var i = 0; i < args.length; i++) {
      final arg = args[i];
      if ((arg == '-d' || arg == '--device-id') && i + 1 < args.length) {
        if (args[i + 1].trim().toLowerCase() == 'web-server') {
          return true;
        }
      }
      if (arg.toLowerCase().startsWith('--device-id=')) {
        final value = arg.split('=').skip(1).join('=').trim().toLowerCase();
        if (value == 'web-server') {
          return true;
        }
      }
    }
    return false;
  }

  bool _hasFlag(List<String> args, String flag) {
    for (final arg in args) {
      if (arg == flag || arg.startsWith('$flag=')) {
        return true;
      }
    }
    return false;
  }

  void _removeFlagWithOptionalValue(List<String> args, String flag) {
    for (var i = 0; i < args.length; i++) {
      final arg = args[i];
      if (arg == flag) {
        args.removeAt(i);
        if (i < args.length && !args[i].startsWith('-')) {
          args.removeAt(i);
        }
        return;
      }
      if (arg.startsWith('$flag=')) {
        args.removeAt(i);
        return;
      }
    }
  }

  Future<int> _pickAvailablePort() async {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = socket.port;
    await socket.close();
    return port;
  }

  void _handleFlutterLine(String rawLine) {
    final line = rawLine.trimRight();
    if (line.isEmpty || !mounted) {
      return;
    }

    setState(() {
      _logs.add(line);
      if (_logs.length > 12) {
        _logs.removeRange(0, _logs.length - 12);
      }
    });

    final urlMatch = RegExp(r'https?://\S+').firstMatch(line);
    final url = urlMatch?.group(0);
    final lower = line.toLowerCase();
    final isDevToolsLine = _looksLikeDevToolsLine(lower, line, url);

    if (lower.contains('vm service') && url != null) {
      final detectedVmServiceUrl = _normalizeDetectedUrl(url);
      if (detectedVmServiceUrl != null) {
        final changedSession = _vmServiceUrl != detectedVmServiceUrl;
        _vmServiceUrl = detectedVmServiceUrl;
        if (changedSession) {
          _inspectorDefaultsApplied = false;
          _devToolsSelectorEnabled = false;
          _ctrlToggleArmed = false;
        }
        _status = 'VM service detected. Starting DevTools...';
        unawaited(_ensureDevToolsRunning(_vmServiceUrl!));
        _startInspectorSync();
        unawaited(_applyInspectorDefaults());
      }
    }

    // DevTools links often include localhost URLs too. Handle those first so
    // they are never mistaken for the actual app preview URL.
    if (url != null && isDevToolsLine) {
      final candidate = _normalizeDetectedUrl(url);
      if (candidate != null) {
        _status = 'DevTools URL detected. Loading inspector...';
        unawaited(_loadDevTools(candidate));
      }
      return;
    }

    if (url != null && _looksLikeAppPreviewLine(lower, line)) {
      final candidate = _normalizeDetectedUrl(url);
      if (candidate != null && candidate != _appUrl) {
        _status = 'App URL detected. Loading embedded preview...';
        unawaited(_loadApp(candidate));
        return;
      }
    }

    if (lower.contains('to hot restart changes') ||
        lower.contains('flutter run key commands')) {
      setState(() {
        _status = 'Flutter app running';
      });
    }
  }

  String? _normalizeDetectedUrl(String raw) {
    final cleaned = raw.replaceAll(RegExp(r'[),;]+$'), '');
    return cleaned.startsWith('http://') || cleaned.startsWith('https://')
        ? cleaned
        : null;
  }

  bool _looksLikeAppPreviewLine(String lower, String raw) {
    return !lower.contains('devtools') &&
        !raw.contains('?uri=') &&
        (lower.contains('is being served at') ||
            lower.contains('serving at') ||
            lower.contains('local:') ||
            lower.contains('application available at'));
  }

  bool _looksLikeDevToolsLine(String lower, String raw, String? url) {
    return lower.contains('devtools') ||
        lower.contains('debugger and profiler') ||
        raw.contains('?uri=') ||
        (url?.contains('?uri=') ?? false);
  }

  Future<void> _ensureDevToolsRunning(String vmServiceUrl) async {
    if (_devToolsProcess != null) {
      return;
    }

    try {
      final process = await Process.start('dart', <String>[
        'devtools',
        '--machine',
        '--vm-uri',
        vmServiceUrl,
      ], runInShell: true);
      _devToolsProcess = process;

      _devToolsStdoutSub = process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(_handleDevToolsLine);
      _devToolsStderrSub = process.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(_handleDevToolsLine);

      unawaited(
        process.exitCode.then((_) {
          _devToolsProcess = null;
        }),
      );
    } catch (_) {
      // Fall back to manual URL entry if launching devtools fails.
    }
  }

  void _handleDevToolsLine(String rawLine) {
    final line = rawLine.trim();
    if (line.isEmpty || !mounted) {
      return;
    }

    setState(() {
      _logs.add('[devtools] $line');
      if (_logs.length > 12) {
        _logs.removeRange(0, _logs.length - 12);
      }
    });

    try {
      final decoded = jsonDecode(line);
      if (decoded is Map<String, dynamic>) {
        final params = decoded['params'];
        if (params is Map<String, dynamic>) {
          final uri = params['devToolsUri'] as String?;
          if (uri != null) {
            _urlCtrl.text = uri;
            unawaited(_loadDevTools(uri));
            return;
          }
        }
      }
    } catch (_) {
      // Not JSON output.
    }

    final url = RegExp(r'https?://\S+').firstMatch(line)?.group(0);
    if (url != null && url.contains('?uri=')) {
      final normalized = _normalizeDetectedUrl(url);
      if (normalized != null) {
        _urlCtrl.text = normalized;
        unawaited(_loadDevTools(normalized));
      }
    }
  }

  Future<void> _sendFlutterCommand(String command) async {
    final process = _flutterProcess;
    if (process == null) {
      return;
    }

    process.stdin.writeln(command);
    setState(() {
      _status = 'Sent "$command" to flutter run';
    });
  }

  void _requestPreviewFocus() {
    if (!_previewFocusNode.hasFocus) {
      _previewFocusNode.requestFocus();
    }
  }

  Future<void> _applyInspectorDefaults() async {
    final vmServiceUrl = _vmServiceUrl;
    if (vmServiceUrl == null || _inspectorDefaultsApplied) {
      return;
    }

    final inspectorActivated =
        await FlutterInspectorService.setInspectorSelectionMode(
          vmServiceUrl: vmServiceUrl,
          enabled: true,
        );
    final selectorConfigured =
        await FlutterInspectorService.setInspectorSelectionMode(
          vmServiceUrl: vmServiceUrl,
          enabled: false,
        );

    if (!mounted) {
      return;
    }

    setState(() {
      _inspectorDefaultsApplied = true;
      _devToolsSelectorEnabled = false;
      _status = (inspectorActivated || selectorConfigured)
          ? 'Inspector ready. Selector OFF (press Ctrl to toggle).'
          : 'Inspector ready. Press Ctrl to toggle selector mode.';
    });
    _requestPreviewFocus();
  }

  Future<void> _toggleDevToolsSelector() async {
    final vmServiceUrl = _vmServiceUrl;
    if (!_runningFlutter || vmServiceUrl == null) {
      return;
    }

    final nextEnabled = !_devToolsSelectorEnabled;
    final toggled = await FlutterInspectorService.setInspectorSelectionMode(
      vmServiceUrl: vmServiceUrl,
      enabled: nextEnabled,
    );

    if (!mounted) {
      return;
    }

    setState(() {
      if (!toggled) {
        _status = 'Selector toggle is unavailable for this app session.';
        return;
      }

      _devToolsSelectorEnabled = nextEnabled;
      _status = _devToolsSelectorEnabled
          ? 'DevTools selector ON (press Ctrl to toggle).'
          : 'DevTools selector OFF (press Ctrl to toggle).';
    });
  }

  KeyEventResult _onPreviewKeyEvent(FocusNode node, KeyEvent event) {
    if (_showSettings || !_runningFlutter) {
      return KeyEventResult.ignored;
    }

    final isControlKey =
        event.logicalKey == LogicalKeyboardKey.controlLeft ||
        event.logicalKey == LogicalKeyboardKey.controlRight ||
        event.logicalKey == LogicalKeyboardKey.control;
    if (!isControlKey) {
      return KeyEventResult.ignored;
    }

    if (event is KeyDownEvent) {
      if (_ctrlToggleArmed) {
        return KeyEventResult.handled;
      }
      _ctrlToggleArmed = true;
      unawaited(_toggleDevToolsSelector());
      return KeyEventResult.handled;
    }

    if (event is KeyUpEvent) {
      _ctrlToggleArmed = false;
      return KeyEventResult.handled;
    }

    return KeyEventResult.handled;
  }

  void _startInspectorSync() {
    if (_inspectorSyncTimer != null) {
      return;
    }

    _inspectorSyncTimer = Timer.periodic(
      const Duration(milliseconds: 1200),
      (_) => unawaited(_pollInspectorSelection()),
    );
    unawaited(_pollInspectorSelection());
  }

  Future<void> _pollInspectorSelection() async {
    final vmServiceUrl = _vmServiceUrl;
    if (_inspectorSyncBusy || vmServiceUrl == null || !mounted) {
      return;
    }

    _inspectorSyncBusy = true;
    try {
      final selection =
          await FlutterInspectorService.fetchSelectedSummaryWidget(
            vmServiceUrl: vmServiceUrl,
          );
      if (!mounted || selection == null) {
        return;
      }

      final current = ref.read(inspectorSelectionProvider);
      if (_sameInspectorSelection(current, selection)) {
        return;
      }

      ref.read(inspectorSelectionProvider.notifier).state = selection;
    } finally {
      _inspectorSyncBusy = false;
    }
  }

  bool _sameInspectorSelection(
    InspectorSelectionContext? a,
    InspectorSelectionContext? b,
  ) {
    if (a == null || b == null) {
      return false;
    }

    return a.valueId == b.valueId &&
        a.sourceFile == b.sourceFile &&
        a.line == b.line &&
        a.endLine == b.endLine &&
        a.column == b.column &&
        a.widgetName == b.widgetName;
  }

  void _stopInspectorSync() {
    _inspectorSyncTimer?.cancel();
    _inspectorSyncTimer = null;
    _inspectorSyncBusy = false;
    _inspectorDefaultsApplied = false;
    _devToolsSelectorEnabled = false;
    _ctrlToggleArmed = false;
    ref.read(inspectorSelectionProvider.notifier).state = null;
  }

  Future<void> _stopFlutterRun() async {
    final process = _flutterProcess;
    if (process == null) {
      return;
    }

    setState(() {
      _status = 'Stopping flutter run...';
      _runningFlutter = false;
    });

    process.kill();
    _devToolsProcess?.kill();

    await _stdoutSub?.cancel();
    await _stderrSub?.cancel();
    await _devToolsStdoutSub?.cancel();
    await _devToolsStderrSub?.cancel();

    _stdoutSub = null;
    _stderrSub = null;
    _devToolsStdoutSub = null;
    _devToolsStderrSub = null;
    _flutterProcess = null;
    _devToolsProcess = null;
    _vmServiceUrl = null;
    _stopInspectorSync();

    if (!mounted) {
      return;
    }

    setState(() {
      _status = 'Flutter run stopped';
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(hotReloadTriggerProvider, (previous, next) {
      if (next > (previous ?? 0)) {
        _sendFlutterCommand('r');
      }
    });
    ref.listen<String?>(projectRootProvider, (previous, next) {
      _handleProjectRootChanged(next);
    });

    final hasProjectRoot = (ref.watch(projectRootProvider) ?? '')
        .trim()
        .isNotEmpty;

    return Focus(
      focusNode: _previewFocusNode,
      autofocus: true,
      onKeyEvent: _onPreviewKeyEvent,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: _requestPreviewFocus,
        child: Container(
          color: FloraPalette.background, // Match apple clean background
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                height: 32, // Apple slightly taller toolbar
                decoration: const BoxDecoration(
                  color: FloraPalette.panelBg,
                  border: Border(
                    bottom: BorderSide(color: FloraPalette.border, width: 0.5),
                  ),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Row(
                  children: [
                    const Text(
                      'PREVIEW',
                      style: TextStyle(
                        color: FloraPalette.textPrimary,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.5,
                      ),
                    ),
                    if (_runningFlutter) ...[
                      const SizedBox(width: 8),
                      Text(
                        _devToolsSelectorEnabled
                            ? 'selector:on'
                            : 'selector:off',
                        style: FloraTheme.mono(
                          size: 10,
                          color: FloraPalette.textDimmed,
                        ),
                      ),
                    ],
                    const SizedBox(width: 12),
                    _BuildTypePill(
                      buildType: _selectedBuildType,
                      onSelected: _runningFlutter ? null : _setBuildType,
                    ),
                    const SizedBox(width: 12),

                    // Condense the main actions into this toolbar directly
                    if (hasProjectRoot) ...[
                      if (!_runningFlutter)
                        InkWell(
                          onTap: _runAndLoadPreview,
                          child: const _ToolbarIcon(
                            Icons.play_arrow,
                            color: FloraPalette.success,
                          ),
                        )
                      else
                        InkWell(
                          onTap: _stopFlutterRun,
                          child: const _ToolbarIcon(
                            Icons.stop,
                            color: FloraPalette.error,
                          ),
                        ),

                      if (_runningFlutter) ...[
                        const SizedBox(width: 8),
                        InkWell(
                          onTap: () => _sendFlutterCommand('r'),
                          child: const _ToolbarIcon(
                            Icons.bolt,
                            tooltip: 'Hot Reload',
                          ),
                        ),
                        InkWell(
                          onTap: () => _sendFlutterCommand('R'),
                          child: const _ToolbarIcon(
                            Icons.restart_alt,
                            tooltip: 'Hot Restart',
                          ),
                        ),
                        InkWell(
                          onTap: _toggleDevToolsSelector,
                          child: _ToolbarIcon(
                            _devToolsSelectorEnabled
                                ? Icons.ads_click
                                : Icons.ads_click_outlined,
                            tooltip: _devToolsSelectorEnabled
                                ? 'Disable selector (Ctrl)'
                                : 'Enable selector (Ctrl)',
                          ),
                        ),
                      ],
                    ],

                    const Spacer(),

                    if (_appWebviewInitialized || _devToolsWebviewInitialized)
                      InkWell(
                        onTap: _loadingPreview || _loadingDevTools
                            ? null
                            : () {
                                if (_activeTab == _PreviewTab.app &&
                                    _appWebviewInitialized) {
                                  _appWebview.reload();
                                }
                                if (_activeTab == _PreviewTab.devTools &&
                                    _devToolsWebviewInitialized) {
                                  _devToolsWebview.reload();
                                }
                              },
                        child: const _ToolbarIcon(
                          Icons.refresh,
                          tooltip: 'Reload Webview',
                        ),
                      ),

                    const SizedBox(width: 4),
                    InkWell(
                      onTap: () =>
                          setState(() => _showSettings = !_showSettings),
                      child: _ToolbarIcon(
                        _showSettings
                            ? Icons.keyboard_arrow_up
                            : Icons.settings_outlined,
                        tooltip: 'Preview Settings',
                      ),
                    ),
                  ],
                ),
              ),

              if (_showSettings)
                Container(
                  color: FloraPalette.sidebarBg,
                  padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          _BuildTypePill(
                            buildType: _selectedBuildType,
                            onSelected: _runningFlutter ? null : _setBuildType,
                            expanded: true,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: TextField(
                              controller: _runCommandCtrl,
                              readOnly: true,
                              style: FloraTheme.mono(size: 11),
                              decoration: const InputDecoration(
                                hintText:
                                    'e.g., flutter run -d web-server --web-hostname 127.0.0.1',
                                isDense: true,
                                contentPadding: EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 6,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _urlCtrl,
                              style: FloraTheme.mono(size: 11),
                              decoration: const InputDecoration(
                                hintText:
                                    'DevTools URL (optional manual override)',
                                isDense: true,
                                contentPadding: EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 6,
                                ),
                              ),
                              onSubmitted: _loadDevTools,
                            ),
                          ),
                          const SizedBox(width: 6),
                          _TinyButton(
                            label: 'Load DevTools',
                            onTap: _loadingDevTools
                                ? null
                                : () => _loadDevTools(_urlCtrl.text.trim()),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          _status,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: FloraPalette.textSecondary),
                        ),
                      ),
                    ],
                  ),
                ),

              if (!_showSettings && _status != 'Idle' && _status.isNotEmpty)
                Container(
                  color: FloraPalette.panelBg,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  alignment: Alignment.centerLeft,
                  child: Text(
                    _status,
                    style: const TextStyle(
                      fontSize: 10,
                      color: FloraPalette.textSecondary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),

              Expanded(child: _buildBody()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_activeTab == _PreviewTab.app && _loadingPreview) {
      return const Center(
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(
            strokeWidth: 1.5,
            color: FloraPalette.accent,
          ),
        ),
      );
    }

    if (_activeTab == _PreviewTab.devTools && _loadingDevTools) {
      return const Center(
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(
            strokeWidth: 1.5,
            color: FloraPalette.accent,
          ),
        ),
      );
    }

    if (_error != null) {
      return _Placeholder(
        icon: Icons.error_outline,
        title: 'Preview error',
        subtitle: _error!,
        logs: _logs,
        color: FloraPalette.error,
      );
    }

    if (_activeTab == _PreviewTab.app && !_appWebviewInitialized) {
      return _Placeholder(
        icon: Icons.play_circle_outline,
        title: 'No app preview',
        subtitle:
            'Run with the default web-server command to keep the app inside Flora.',
        logs: _logs,
      );
    }

    if (_activeTab == _PreviewTab.devTools && !_devToolsWebviewInitialized) {
      return _Placeholder(
        icon: Icons.bug_report_outlined,
        title: 'No DevTools session',
        subtitle:
            'Run & Load first, then open DevTools for Inspector and widget debug toggles.',
        logs: _logs,
      );
    }

    return Column(
      children: [
        Container(
          height: 30,
          color: FloraPalette.panelBg,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            children: [
              _TabChip(
                label: 'App',
                active: _activeTab == _PreviewTab.app,
                onTap: () => setState(() => _activeTab = _PreviewTab.app),
              ),
              const SizedBox(width: 6),
              _TabChip(
                label: 'DevTools',
                active: _activeTab == _PreviewTab.devTools,
                onTap: () => setState(() => _activeTab = _PreviewTab.devTools),
              ),
              const Spacer(),
              if (_activeTab == _PreviewTab.app && _appUrl != null)
                Flexible(
                  child: Text(
                    _appUrl!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: FloraTheme.mono(
                      size: 10,
                      color: FloraPalette.textDimmed,
                    ),
                  ),
                ),
              if (_activeTab == _PreviewTab.devTools && _devToolsUrl != null)
                Flexible(
                  child: Text(
                    _devToolsUrl!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: FloraTheme.mono(
                      size: 10,
                      color: FloraPalette.textDimmed,
                    ),
                  ),
                ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: Webview(
            _activeTab == _PreviewTab.app ? _appWebview : _devToolsWebview,
            permissionRequested: (url, kind, isUser) =>
                WebviewPermissionDecision.allow,
          ),
        ),
      ],
    );
  }
}

enum _PreviewTab { app, devTools }

enum _PreviewBuildType { web, app, mobile }

extension on _PreviewBuildType {
  String get label {
    switch (this) {
      case _PreviewBuildType.web:
        return 'Web';
      case _PreviewBuildType.app:
        return 'App';
      case _PreviewBuildType.mobile:
        return 'Mobile';
    }
  }
}

class _BuildTypePill extends StatelessWidget {
  const _BuildTypePill({
    required this.buildType,
    required this.onSelected,
    this.expanded = false,
  });

  final _PreviewBuildType buildType;
  final void Function(_PreviewBuildType)? onSelected;
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    final button = PopupMenuButton<_PreviewBuildType>(
      enabled: onSelected != null,
      tooltip: 'Select build type',
      onSelected: onSelected,
      itemBuilder: (context) => _PreviewBuildType.values
          .map(
            (type) => PopupMenuItem<_PreviewBuildType>(
              value: type,
              child: Text(type.label),
            ),
          )
          .toList(),
      child: Container(
        height: expanded ? 32 : 22,
        padding: EdgeInsets.symmetric(horizontal: expanded ? 10 : 8),
        decoration: BoxDecoration(
          color: FloraPalette.panelBg,
          border: Border.all(color: FloraPalette.border),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.developer_mode_outlined,
              size: 12,
              color: FloraPalette.textDimmed,
            ),
            const SizedBox(width: 4),
            Text(
              'Build: ${buildType.label}',
              style: TextStyle(
                color: onSelected == null
                    ? FloraPalette.textDimmed
                    : FloraPalette.textSecondary,
                fontSize: expanded ? 11 : 10,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 2),
            const Icon(
              Icons.keyboard_arrow_down,
              size: 12,
              color: FloraPalette.textDimmed,
            ),
          ],
        ),
      ),
    );

    if (!expanded) {
      return button;
    }

    return Expanded(child: button);
  }
}

class _TabChip extends StatelessWidget {
  const _TabChip({
    required this.label,
    required this.active,
    required this.onTap,
  });

  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(2),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: active ? FloraPalette.accent : FloraPalette.background,
          border: Border.all(color: FloraPalette.border),
          borderRadius: BorderRadius.circular(2),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: active ? Colors.white : FloraPalette.textSecondary,
            fontSize: 10,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

class _TinyButton extends StatelessWidget {
  const _TinyButton({required this.label, required this.onTap});

  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(2),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: !enabled ? FloraPalette.border : FloraPalette.panelBg,
          border: Border.all(color: FloraPalette.border),
          borderRadius: BorderRadius.circular(2),
        ),
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: enabled ? FloraPalette.textPrimary : FloraPalette.textDimmed,
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

class _ToolbarIcon extends StatelessWidget {
  const _ToolbarIcon(this.icon, {this.tooltip, this.color});
  final IconData icon;
  final String? tooltip;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    Widget child = Container(
      padding: const EdgeInsets.all(4),
      margin: const EdgeInsets.symmetric(horizontal: 2),
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(6)),
      child: Icon(icon, size: 16, color: color ?? FloraPalette.textSecondary),
    );
    if (tooltip != null) {
      child = Tooltip(message: tooltip!, child: child);
    }
    return child;
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.logs,
    this.color,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final List<String> logs;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 28, color: color ?? FloraPalette.textDimmed),
            const SizedBox(height: 10),
            Text(
              title,
              style: const TextStyle(
                color: FloraPalette.textSecondary,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 6),
            Text(
              subtitle,
              style: const TextStyle(
                color: FloraPalette.textDimmed,
                fontSize: 11,
              ),
              textAlign: TextAlign.center,
            ),
            if (logs.isNotEmpty) ...[
              const SizedBox(height: 14),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: FloraPalette.background,
                  border: Border.all(color: FloraPalette.border),
                ),
                child: SelectableText(
                  logs.join('\n'),
                  style: FloraTheme.mono(
                    size: 10,
                    color: FloraPalette.textSecondary,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
