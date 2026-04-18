import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../../../app/theme/flora_theme.dart';
import '../../../core/state/flora_providers.dart';

Future<void> _selectProjectRoot(WidgetRef ref) async {
  final directory = await getDirectoryPath(confirmButtonText: 'Open project');
  if (directory == null || directory.trim().isEmpty) {
    return;
  }

  final prefs = await SharedPreferences.getInstance();
  await prefs.setString('project_root', directory);

  ref.read(projectRootProvider.notifier).state = directory;
  ref.read(expandedFoldersProvider.notifier).state = {directory};
  ref.read(activeFilePathProvider.notifier).state = null;
}

/// Right pane — VS Code-style file explorer backed by dart:io.
class DebugDeploymentPane extends ConsumerWidget {
  const DebugDeploymentPane({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final root = ref.watch(projectRootProvider);

    return Container(
      color: FloraPalette.sidebarBg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _ExplorerHeader(projectName: root?.split(RegExp(r'[/\\]')).where((s) => s.isNotEmpty).last),
          const Divider(height: 1),
          Expanded(
            child: root == null
                ? const _NoProject()
                : _FileTree(root: root),
          ),
        ],
      ),
    );
  }
}

// --- Header -------------------------------------------------------------------

class _ExplorerHeader extends ConsumerWidget {
  const _ExplorerHeader({this.projectName});

  final String? projectName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      height: 28,
      color: FloraPalette.sidebarBg,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Row(
        children: [
          Text(
            projectName != null
                ? 'EXPLORER: ${projectName!.toUpperCase()}'
                : 'EXPLORER',
            style: const TextStyle(
              color: FloraPalette.textSecondary,
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.8,
            ),
          ),
          const Spacer(),
          InkWell(
            onTap: () => _selectProjectRoot(ref),
            borderRadius: BorderRadius.circular(2),
            child: const Padding(
              padding: EdgeInsets.all(4),
              child: Icon(
                Icons.folder_open_outlined,
                size: 14,
                color: FloraPalette.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// --- No Project ---------------------------------------------------------------

class _NoProject extends ConsumerWidget {
  const _NoProject();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.folder_open_outlined,
              size: 28,
              color: FloraPalette.textDimmed,
            ),
            const SizedBox(height: 10),
            const Text(
              'No folder open',
              style: TextStyle(
                color: FloraPalette.textSecondary,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 6),
            const Text(
              'Pick a project folder to browse files and power Codex chat.',
              style: TextStyle(color: FloraPalette.textDimmed, fontSize: 11),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: () => _selectProjectRoot(ref),
              child: const Text('Open Folder'),
            ),
          ],
        ),
      ),
    );
  }
}

// --- File Tree ----------------------------------------------------------------

class _FileTree extends ConsumerStatefulWidget {
  const _FileTree({required this.root});
  final String root;

  @override
  ConsumerState<_FileTree> createState() => _FileTreeState();
}

class _FileTreeState extends ConsumerState<_FileTree> {
  List<_TreeEntry> _entries = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load(widget.root, forceExpand: true);
  }

  @override
  void didUpdateWidget(_FileTree old) {
    super.didUpdateWidget(old);
    if (old.root != widget.root) _load(widget.root, forceExpand: true);
  }

  Future<void> _load(String root, {bool forceExpand = false}) async {
    setState(() { _loading = true; _error = null; });
    try {
      final expanded = {
        ...ref.read(expandedFoldersProvider),
        if (forceExpand) root,
      };
      ref.read(expandedFoldersProvider.notifier).state = expanded;
      final entries = await _buildTree(root, expanded);
      if (mounted) setState(() { _entries = entries; _loading = false; });
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _loading = false; });
    }
  }

  Future<List<_TreeEntry>> _buildTree(
    String root,
    Set<String> expanded, {
    int depth = 0,
  }) async {
    final dir = Directory(root);
    final result = <_TreeEntry>[];

    // _kIgnore patterns
    final List<FileSystemEntity> entities;
    try {
      entities = dir.listSync(followLinks: false)
        ..sort((a, b) {
          final aIsDir = a is Directory;
          final bIsDir = b is Directory;
          if (aIsDir != bIsDir) return aIsDir ? -1 : 1;
          return p.basename(a.path).compareTo(p.basename(b.path));
        });
    } catch (_) {
      return result;
    }

    for (final entity in entities) {
      final name = p.basename(entity.path);
      if (_hidden(name)) continue;

      if (entity is Directory) {
        final isOpen = expanded.contains(entity.path);
        result.add(_TreeEntry(
          path: entity.path,
          name: name,
          depth: depth,
          isDir: true,
          isExpanded: isOpen,
        ));
        if (isOpen) {
          result.addAll(await _buildTree(entity.path, expanded, depth: depth + 1));
        }
      } else {
        result.add(_TreeEntry(
          path: entity.path,
          name: name,
          depth: depth,
          isDir: false,
          isExpanded: false,
        ));
      }
    }
    return result;
  }

  bool _hidden(String name) =>
      name.startsWith('.') ||
      name == 'build' ||
      name == 'node_modules' ||
      name == '.dart_tool' ||
      name == '.flutter-plugins' ||
      name == '.flutter-plugins-dependencies';

  void _onTap(_TreeEntry entry) {
    if (entry.isDir) {
      final expanded = Set<String>.from(ref.read(expandedFoldersProvider));
      if (expanded.contains(entry.path)) {
        expanded.remove(entry.path);
        // Also remove all children to collapse subtree
        expanded.removeWhere((k) => k.startsWith(entry.path));
      } else {
        expanded.add(entry.path);
      }
      ref.read(expandedFoldersProvider.notifier).state = expanded;
      _rebuild(expanded);
    } else {
      ref.read(activeFilePathProvider.notifier).state = entry.path;
    }
  }

  Future<void> _rebuild(Set<String> expanded) async {
    setState(() => _loading = true);
    final entries = await _buildTree(widget.root, expanded);
    if (mounted) setState(() { _entries = entries; _loading = false; });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(
        child: SizedBox(
          width: 16, height: 16,
          child: CircularProgressIndicator(strokeWidth: 1.5),
        ),
      );
    }
    if (_error != null) {
      return Center(
        child: Text(_error!, style: const TextStyle(color: FloraPalette.error, fontSize: 11)),
      );
    }

    final activePath = ref.watch(activeFilePathProvider);

    return ListView.builder(
      itemCount: _entries.length,
      itemExtent: 22,
      itemBuilder: (ctx, i) {
        final e = _entries[i];
        return _EntryTile(
          entry: e,
          isActive: e.path == activePath,
          onTap: () => _onTap(e),
        );
      },
    );
  }
}

// --- Entry Tile ---------------------------------------------------------------

class _EntryTile extends StatefulWidget {
  const _EntryTile({
    required this.entry,
    required this.isActive,
    required this.onTap,
  });
  final _TreeEntry entry;
  final bool isActive;
  final VoidCallback onTap;

  @override
  State<_EntryTile> createState() => _EntryTileState();
}

class _EntryTileState extends State<_EntryTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final e = widget.entry;
    final bg = widget.isActive
        ? FloraPalette.selectedBg
        : _hovered
            ? FloraPalette.hoveredBg
            : Colors.transparent;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit:  (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          color: bg,
          padding: EdgeInsets.only(left: 8.0 + e.depth * 16.0),
          alignment: Alignment.centerLeft,
          child: Row(
            children: [
              if (e.isDir)
                Icon(
                  e.isExpanded ? Icons.keyboard_arrow_down : Icons.keyboard_arrow_right,
                  size: 14,
                  color: FloraPalette.textSecondary,
                )
              else
                const SizedBox(width: 14),
              const SizedBox(width: 3),
              Icon(
                e.isDir ? Icons.folder_outlined : _fileIcon(e.name),
                size: 13,
                color: e.isDir ? FloraPalette.warning : FloraPalette.textSecondary,
              ),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  e.name,
                  style: TextStyle(
                    color: widget.isActive
                        ? Colors.white
                        : FloraPalette.textPrimary,
                    fontSize: 12,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  IconData _fileIcon(String name) {
    final ext = p.extension(name).toLowerCase();
    return switch (ext) {
      '.dart'  => Icons.code,
      '.yaml' || '.yml' => Icons.settings_outlined,
      '.json'  => Icons.data_object_outlined,
      '.md'    => Icons.description_outlined,
      '.png' || '.jpg' || '.jpeg' || '.gif' || '.svg' => Icons.image_outlined,
      _        => Icons.insert_drive_file_outlined,
    };
  }
}

// --- Tree Entry Model ---------------------------------------------------------

class _TreeEntry {
  const _TreeEntry({
    required this.path,
    required this.name,
    required this.depth,
    required this.isDir,
    required this.isExpanded,
  });

  final String path;
  final String name;
  final int    depth;
  final bool   isDir;
  final bool   isExpanded;
}