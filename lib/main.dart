import 'dart:convert';
import 'dart:io';

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

  /// Each selected file + its decoded text.
  final List<_SelectedFile> _files = [];

  @override
  void initState() {
    super.initState();
    _loadLastDir();
  }

  Future<void> _loadLastDir() async {
    final prefs = await SharedPreferences.getInstance();
    final dir = prefs.getString(_prefsLastDirKey);

    // If it no longer exists, ignore it.
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
        withData: false, // we read from disk for large files
      );

      if (result == null || result.files.isEmpty) return;

      // Update last directory based on first picked file.
      final firstPath = result.files.first.path;
      if (firstPath != null) {
        final parent = File(firstPath).parent.path;
        await _saveLastDir(parent);
      }

      // Read files in the returned order.
      final pickedPaths = result.files
          .map((f) => f.path)
          .whereType<String>()
          .toList(growable: false);

      final loaded = <_SelectedFile>[];
      for (final path in pickedPaths) {
        final file = File(path);
        if (!file.existsSync()) continue;

        final bytes = await file.readAsBytes();

        // "Exact text" is tricky if files aren't UTF-8; this:
        // - decodes UTF-8
        // - allows malformed sequences without crashing
        final text = utf8.decode(bytes, allowMalformed: true);

        loaded.add(_SelectedFile(
          path: path,
          name: file.uri.pathSegments.isNotEmpty
              ? file.uri.pathSegments.last
              : path,
          text: text,
          byteLength: bytes.length,
        ));
      }

      setState(() {
        _files
          ..addAll(loaded);
      });
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _clear() {
    setState(_files.clear);
  }

  String _buildClipboardText() {
    final buffer = StringBuffer();

    for (var i = 0; i < _files.length; i++) {
      final f = _files[i];

      buffer.writeln('===== ${f.name} =====');
      buffer.writeln(f.text);

      // Separate files with a blank line (but don't add trailing whitespace spam)
      if (i != _files.length - 1) buffer.writeln('\n');
    }

    return buffer.toString();
  }

  Future<void> _copyToClipboard() async {
    if (_files.isEmpty) return;

    final text = _buildClipboardText();
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
    final totalBytes = _files.fold<int>(0, (sum, f) => sum + f.byteLength);

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
              onCopy: _files.isEmpty ? null : _copyToClipboard,
            ),
            const SizedBox(height: 16),

            Expanded(
              child: _files.isEmpty
                  ? _EmptyState(onPick: _isLoading ? null : _pickFiles)
                  : _FileList(files: _files),
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
    required this.onCopy,
  });

  final bool isLoading;
  final String? lastDir;
  final int fileCount;
  final int totalBytes;
  final VoidCallback? onPickFiles;
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
                  : const Icon(Icons.folder_open),
              label: Text(isLoading ? 'Loading…' : 'Select files'),
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
  const _EmptyState({required this.onPick});

  final VoidCallback? onPick;

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
                  'Select one or more files, then copy them as labeled text for pasting into ChatGPT.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: onPick,
                  icon: const Icon(Icons.folder_open),
                  label: const Text('Select files'),
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
  const _FileList({required this.files});

  final List<_SelectedFile> files;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListView.separated(
        itemCount: files.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (context, i) {
          final f = files[i];
          final preview = f.text.length <= 400 ? f.text : f.text.substring(0, 400);

          return ListTile(
            leading: const Icon(Icons.insert_drive_file_outlined),
            title: Text(f.name),
            subtitle: Text(
              '${f.path}\n'
                  'Chars: ${f.text.length} • Bytes: ${f.byteLength}\n'
                  'Preview:\n$preview',
              maxLines: 6,
              overflow: TextOverflow.ellipsis,
            ),
            isThreeLine: true,
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
    required this.text,
    required this.byteLength,
  });

  final String path;
  final String name;
  final String text;
  final int byteLength;
}
