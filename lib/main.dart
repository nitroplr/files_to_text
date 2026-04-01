import 'dart:convert';
import 'dart:io';

import 'package:docx_to_text/docx_to_text.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const FilesToTextApp());
}

class FilesToTextApp extends StatelessWidget {
  const FilesToTextApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Files to Text',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const FilesToTextPage(),
    );
  }
}

class FilesToTextPage extends StatefulWidget {
  const FilesToTextPage({super.key});

  @override
  State<FilesToTextPage> createState() => _FilesToTextPageState();
}

class _FilesToTextPageState extends State<FilesToTextPage> {
  static const String _prefsLastDirKey = 'last_dir';

  bool _isLoading = false;
  String? _lastDir;

  /// Each selected file (we store path/name only; content is read fresh on copy).
  final List<_SelectedFile> _files = [];

  @override
  void initState() {
    super.initState();
    _loadLastDir();
  }

  Future<void> _loadLastDir() async {
    final prefs = await SharedPreferences.getInstance();
    final dir = prefs.getString(_prefsLastDirKey);

    if (dir != null && Directory(dir).existsSync()) {
      setState(() => _lastDir = dir);
    }
  }

  Future<void> _saveLastDir(String dir) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsLastDirKey, dir);
    setState(() => _lastDir = dir);
  }

  Future<void> _pickFiles() async {
    setState(() => _isLoading = true);

    try {
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        type: FileType.any,
        dialogTitle: 'Select file(s) to copy as text',
        initialDirectory: _lastDir,
        withData: false,
      );

      if (result == null || result.files.isEmpty) return;

      final firstPath = result.files.first.path;
      if (firstPath != null) {
        final parent = File(firstPath).parent.path;
        await _saveLastDir(parent);
      }

      final pickedPaths = result.files
          .map((f) => f.path)
          .whereType<String>()
          .toList(growable: false);

      _addPaths(pickedPaths);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _pickFolder() async {
    setState(() => _isLoading = true);

    try {
      final selectedDir = await FilePicker.platform.getDirectoryPath(
        dialogTitle: 'Select folder to include recursively',
        initialDirectory: _lastDir,
      );

      if (selectedDir == null || selectedDir.isEmpty) return;

      await _saveLastDir(selectedDir);

      final root = Directory(selectedDir);
      if (!root.existsSync()) return;

      final nestedFiles = root
          .listSync(recursive: true, followLinks: false)
          .whereType<File>()
          .map((f) => f.path)
          .toList();

      _addPaths(nestedFiles);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _addPaths(List<String> paths) {
    final existingPaths = _files.map((f) => f.path).toSet();
    final loaded = <_SelectedFile>[];

    for (final path in paths) {
      if (existingPaths.contains(path)) continue;

      final file = File(path);
      if (!file.existsSync()) continue;

      loaded.add(_SelectedFile(
        path: path,
        name: file.uri.pathSegments.isNotEmpty
            ? file.uri.pathSegments.last
            : path,
      ));
      existingPaths.add(path);
    }

    if (loaded.isEmpty) return;

    setState(() {
      _files.addAll(loaded);
    });
  }

  void _removeFileAt(int index) {
    setState(() {
      _files.removeAt(index);
    });
  }

  void _clear() {
    setState(_files.clear);
  }

  String _extLower(String nameOrPath) {
    final dot = nameOrPath.lastIndexOf('.');
    if (dot == -1) return '';
    return nameOrPath.substring(dot + 1).toLowerCase();
  }

  Future<String> _readFileAsTextSmart(_SelectedFile f) async {
    final file = File(f.path);
    final bytes = await file.readAsBytes();

    final ext = _extLower(f.name);
    if (ext == 'docx') {
      return docxToText(bytes);
    }

    return utf8.decode(bytes, allowMalformed: true);
  }

  /// Build text by reading each file from disk at the moment of copying.
  Future<String> _buildClipboardText() async {
    final buffer = StringBuffer();

    for (var i = 0; i < _files.length; i++) {
      final f = _files[i];

      buffer.writeln('===== ${f.path} =====');

      final file = File(f.path);
      if (!file.existsSync()) {
        buffer.writeln('[Missing file: ${f.path}]');
      } else {
        try {
          final text = await _readFileAsTextSmart(f);
          buffer.writeln(text);
        } catch (e) {
          buffer.writeln('[Failed to read ${f.path}: $e]');
        }
      }

      if (i != _files.length - 1) {
        buffer.writeln();
        buffer.writeln();
      }
    }

    return buffer.toString();
  }

  Future<void> _copyToClipboard() async {
    if (_files.isEmpty) return;

    final text = await _buildClipboardText();
    await Clipboard.setData(ClipboardData(text: text));

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Copied ${_files.length} file(s) to clipboard'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final totalBytes = _files.fold<int>(0, (sum, f) {
      final file = File(f.path);
      if (!file.existsSync()) return sum;
      return sum + file.lengthSync();
    });

    return Scaffold(
      appBar: AppBar(
        title: const Text('Files to Text'),
        actions: [
          IconButton(
            tooltip: 'Clear selection',
            onPressed: _files.isEmpty ? null : _clear,
            icon: const Icon(Icons.clear_all),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            _TopBar(
              isLoading: _isLoading,
              lastDir: _lastDir,
              fileCount: _files.length,
              totalBytes: totalBytes,
              onPickFiles: _isLoading ? null : _pickFiles,
              onPickFolder: _isLoading ? null : _pickFolder,
              onCopy: _files.isEmpty ? null : _copyToClipboard,
            ),
            const SizedBox(height: 16),
            Expanded(
              child: _files.isEmpty
                  ? _EmptyState(
                onPickFiles: _isLoading ? null : _pickFiles,
                onPickFolder: _isLoading ? null : _pickFolder,
              )
                  : _FileList(
                files: _files,
                onRemoveAt: _removeFileAt,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.isLoading,
    required this.lastDir,
    required this.fileCount,
    required this.totalBytes,
    required this.onPickFiles,
    required this.onPickFolder,
    required this.onCopy,
  });

  final bool isLoading;
  final String? lastDir;
  final int fileCount;
  final int totalBytes;
  final VoidCallback? onPickFiles;
  final VoidCallback? onPickFolder;
  final VoidCallback? onCopy;

  String _formatBytes(int bytes) {
    const kb = 1024;
    const mb = 1024 * 1024;
    const gb = 1024 * 1024 * 1024;
    if (bytes >= gb) return '${(bytes / gb).toStringAsFixed(2)} GB';
    if (bytes >= mb) return '${(bytes / mb).toStringAsFixed(2)} MB';
    if (bytes >= kb) return '${(bytes / kb).toStringAsFixed(2)} KB';
    return '$bytes B';
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            FilledButton.icon(
              onPressed: onPickFiles,
              icon: isLoading
                  ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
                  : const Icon(Icons.insert_drive_file_outlined),
              label: Text(isLoading ? 'Loading…' : 'Select files'),
            ),
            const SizedBox(width: 12),
            FilledButton.tonalIcon(
              onPressed: onPickFolder,
              icon: const Icon(Icons.folder_open),
              label: const Text('Select folder'),
            ),
            const SizedBox(width: 12),
            OutlinedButton.icon(
              onPressed: onCopy,
              icon: const Icon(Icons.copy),
              label: const Text('Copy to clipboard'),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Selected: $fileCount file(s) • ${_formatBytes(totalBytes)}',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    lastDir == null
                        ? 'Last folder: (none yet)'
                        : 'Last folder: $lastDir',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.onPickFiles,
    required this.onPickFolder,
  });

  final VoidCallback? onPickFiles;
  final VoidCallback? onPickFolder;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.description_outlined, size: 48),
                const SizedBox(height: 12),
                Text(
                  'Select one or more files, or select a folder to include all nested files recursively, then copy them as labeled text for pasting into ChatGPT.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  alignment: WrapAlignment.center,
                  children: [
                    FilledButton.icon(
                      onPressed: onPickFiles,
                      icon: const Icon(Icons.insert_drive_file_outlined),
                      label: const Text('Select files'),
                    ),
                    FilledButton.tonalIcon(
                      onPressed: onPickFolder,
                      icon: const Icon(Icons.folder_open),
                      label: const Text('Select folder'),
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

class _FileList extends StatelessWidget {
  const _FileList({
    required this.files,
    required this.onRemoveAt,
  });

  final List<_SelectedFile> files;
  final void Function(int index) onRemoveAt;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListView.separated(
        itemCount: files.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (context, i) {
          final f = files[i];
          final file = File(f.path);
          final exists = file.existsSync();
          final bytes = exists ? file.lengthSync() : 0;

          return ListTile(
            leading: const Icon(Icons.insert_drive_file_outlined),
            title: Text(
              f.path,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              '${f.name}\n${exists ? "Bytes: $bytes" : "Missing file"}',
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: IconButton(
              tooltip: 'Remove from selection',
              onPressed: () => onRemoveAt(i),
              icon: const Icon(Icons.delete_outline),
            ),
          );
        },
      ),
    );
  }
}

class _SelectedFile {
  _SelectedFile({
    required this.path,
    required this.name,
  });

  final String path;
  final String name;
}