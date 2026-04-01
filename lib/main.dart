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
  static const String _prefsChunkSizeKey = 'chunk_size_chars';

  static const int _defaultChunkSize = 120000;

  bool _isLoading = false;
  bool _isChunking = false;
  String? _lastDir;

  final TextEditingController _chunkSizeController = TextEditingController();

  final List<_SelectedFile> _files = [];

  List<_ChunkPlan> _lastBuiltChunks = [];

  bool get _needsChunking => _lastBuiltChunks.length > 1;

  @override
  void initState() {
    super.initState();
    _loadPrefs();
  }

  @override
  void dispose() {
    _chunkSizeController.dispose();
    super.dispose();
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final dir = prefs.getString(_prefsLastDirKey);
    final chunkSize = prefs.getInt(_prefsChunkSizeKey) ?? _defaultChunkSize;

    if (!mounted) return;

    setState(() {
      if (dir != null && Directory(dir).existsSync()) {
        _lastDir = dir;
      }
      _chunkSizeController.text = chunkSize.toString();
    });
  }

  Future<void> _saveLastDir(String dir) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsLastDirKey, dir);
    if (!mounted) return;
    setState(() => _lastDir = dir);
  }

  Future<void> _saveChunkSize(int size) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_prefsChunkSizeKey, size);
  }

  int get _chunkSize {
    final parsed = int.tryParse(_chunkSizeController.text.trim());
    if (parsed == null || parsed < 1000) return _defaultChunkSize;
    return parsed;
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

      await _addPaths(pickedPaths);
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

      await _addPaths(nestedFiles);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _addPaths(List<String> paths) async {
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
      _invalidateChunks();
    });

    await _ensureChunksBuilt();
  }

  Future<void> _removeFileAt(int index) async {
    setState(() {
      _files.removeAt(index);
      _invalidateChunks();
    });

    if (_files.isNotEmpty) {
      await _ensureChunksBuilt();
    } else if (mounted) {
      setState(() {});
    }
  }

  void _clear() {
    setState(() {
      _files.clear();
      _invalidateChunks();
    });
  }

  void _invalidateChunks() {
    _lastBuiltChunks = [];
  }

  Future<void> _onChunkSizeChanged(String _) async {
    _invalidateChunks();

    if (_files.isEmpty) {
      if (mounted) setState(() {});
      return;
    }

    await _ensureChunksBuilt();
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

  Future<String> _buildSingleFileSection(_SelectedFile f) async {
    final buffer = StringBuffer();
    buffer.writeln('===== ${f.path} =====');

    final file = File(f.path);
    if (!file.existsSync()) {
      buffer.writeln('[Missing file: ${f.path}]');
      return buffer.toString();
    }

    try {
      final text = await _readFileAsTextSmart(f);
      buffer.writeln(text);
    } catch (e) {
      buffer.writeln('[Failed to read ${f.path}: $e]');
    }

    return buffer.toString();
  }

  Future<String> _buildClipboardText() async {
    final buffer = StringBuffer();

    for (var i = 0; i < _files.length; i++) {
      final section = await _buildSingleFileSection(_files[i]);
      buffer.write(section);

      if (i != _files.length - 1) {
        buffer.writeln();
        buffer.writeln();
      }
    }

    return buffer.toString();
  }

  Future<List<_ChunkPlan>> _buildChunkPlans() async {
    final chunkSize = _chunkSize;
    await _saveChunkSize(chunkSize);

    final sections = <_BuiltSection>[];
    for (final f in _files) {
      final text = await _buildSingleFileSection(f);
      sections.add(_BuiltSection(file: f, text: text));
    }

    final chunks = <_ChunkPlan>[];
    var currentSections = <_BuiltSection>[];
    var currentLength = 0;

    for (final section in sections) {
      final separatorLength = currentSections.isEmpty ? 0 : 2;
      final sectionLength = section.text.length;
      final projectedLength = currentLength + separatorLength + sectionLength;

      if (currentSections.isNotEmpty && projectedLength > chunkSize) {
        chunks.add(_ChunkPlan(sections: List<_BuiltSection>.from(currentSections)));
        currentSections = [section];
        currentLength = sectionLength;
        continue;
      }

      if (currentSections.isEmpty) {
        currentSections.add(section);
        currentLength = sectionLength;
      } else {
        currentSections.add(section);
        currentLength = projectedLength;
      }
    }

    if (currentSections.isNotEmpty) {
      chunks.add(_ChunkPlan(sections: List<_BuiltSection>.from(currentSections)));
    }

    return chunks;
  }

  String _renderChunkText({
    required _ChunkPlan chunk,
    required int chunkIndex,
    required int totalChunks,
  }) {
    final buffer = StringBuffer();
    buffer.writeln('===== CHUNK ${chunkIndex + 1}/$totalChunks =====');
    buffer.writeln();

    for (var i = 0; i < chunk.sections.length; i++) {
      buffer.write(chunk.sections[i].text);
      if (i != chunk.sections.length - 1) {
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

  Future<void> _ensureChunksBuilt() async {
    if (_files.isEmpty) return;

    if (_lastBuiltChunks.isNotEmpty) return;

    setState(() => _isChunking = true);
    try {
      final chunks = await _buildChunkPlans();
      if (!mounted) return;
      setState(() {
        _lastBuiltChunks = chunks;
      });
    } finally {
      if (mounted) {
        setState(() => _isChunking = false);
      }
    }
  }

  Future<void> _copyChunk(int chunkIndex) async {
    if (_files.isEmpty) return;

    await _ensureChunksBuilt();
    if (_lastBuiltChunks.isEmpty) return;
    if (chunkIndex < 0 || chunkIndex >= _lastBuiltChunks.length) return;

    final chunk = _lastBuiltChunks[chunkIndex];
    final text = _renderChunkText(
      chunk: chunk,
      chunkIndex: chunkIndex,
      totalChunks: _lastBuiltChunks.length,
    );

    await Clipboard.setData(ClipboardData(text: text));

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Copied chunk ${chunkIndex + 1} of ${_lastBuiltChunks.length}'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _openCopyChunkMenu() async {
    await _ensureChunksBuilt();
    if (!mounted) return;

    if (_lastBuiltChunks.length <= 1) {
      return;
    }

    await showModalBottomSheet<void>(
      context: context,
      builder: (context) {
        return SafeArea(
          child: ListView.separated(
            shrinkWrap: true,
            itemCount: _lastBuiltChunks.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final chunk = _lastBuiltChunks[index];
              final charCount = chunk.totalChars;
              final fileCount = chunk.sections.length;

              return ListTile(
                leading: const Icon(Icons.content_copy),
                title: Text('Chunk ${index + 1} of ${_lastBuiltChunks.length}'),
                subtitle: Text('$fileCount file(s) • $charCount chars'),
                onTap: () async {
                  Navigator.of(context).pop();
                  await _copyChunk(index);
                },
              );
            },
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final totalBytes = _files.fold<int>(0, (sum, f) {
      final file = File(f.path);
      if (!file.existsSync()) return sum;
      return sum + file.lengthSync();
    });

    final chunkStatus = _files.isEmpty
        ? 'No files selected'
        : _lastBuiltChunks.isEmpty
        ? 'Calculating chunks...'
        : _lastBuiltChunks.length == 1
        ? 'Everything fits in one copy'
        : 'Chunks ready: ${_lastBuiltChunks.length}';

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
              isChunking: _isChunking,
              lastDir: _lastDir,
              fileCount: _files.length,
              totalBytes: totalBytes,
              chunkSizeController: _chunkSizeController,
              chunkStatus: chunkStatus,
              hasChunkSource: _needsChunking,
              onChunkSizeChanged: _onChunkSizeChanged,
              onPickFiles: _isLoading ? null : _pickFiles,
              onPickFolder: _isLoading ? null : _pickFolder,
              onCopy: _files.isEmpty ? null : _copyToClipboard,
              onOpenCopyChunkMenu:
              (_files.isEmpty || _isChunking || !_needsChunking)
                  ? null
                  : _openCopyChunkMenu,
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
    required this.isChunking,
    required this.lastDir,
    required this.fileCount,
    required this.totalBytes,
    required this.chunkSizeController,
    required this.chunkStatus,
    required this.hasChunkSource,
    required this.onChunkSizeChanged,
    required this.onPickFiles,
    required this.onPickFolder,
    required this.onCopy,
    required this.onOpenCopyChunkMenu,
  });

  final bool isLoading;
  final bool isChunking;
  final String? lastDir;
  final int fileCount;
  final int totalBytes;
  final TextEditingController chunkSizeController;
  final String chunkStatus;
  final bool hasChunkSource;
  final ValueChanged<String> onChunkSizeChanged;
  final VoidCallback? onPickFiles;
  final VoidCallback? onPickFolder;
  final VoidCallback? onCopy;
  final VoidCallback? onOpenCopyChunkMenu;

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
        child: Column(
          children: [
            Wrap(
              spacing: 12,
              runSpacing: 12,
              crossAxisAlignment: WrapCrossAlignment.center,
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
                FilledButton.tonalIcon(
                  onPressed: onPickFolder,
                  icon: const Icon(Icons.folder_open),
                  label: const Text('Select folder'),
                ),
                OutlinedButton.icon(
                  onPressed: onCopy,
                  icon: const Icon(Icons.copy),
                  label: const Text('Copy all'),
                ),
                if (hasChunkSource)
                  OutlinedButton.icon(
                    onPressed: onOpenCopyChunkMenu,
                    icon: isChunking
                        ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                        : const Icon(Icons.arrow_drop_down_circle_outlined),
                    label: const Text('Copy chunk'),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                SizedBox(
                  width: 180,
                  child: TextField(
                    controller: chunkSizeController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Chunk size (chars)',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    onChanged: onChunkSizeChanged,
                  ),
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
                      const SizedBox(height: 4),
                      Text(
                        chunkStatus,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ],
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
  final Future<void> Function(int index) onRemoveAt;

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
              onPressed: () async => onRemoveAt(i),
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

class _BuiltSection {
  _BuiltSection({
    required this.file,
    required this.text,
  });

  final _SelectedFile file;
  final String text;
}

class _ChunkPlan {
  _ChunkPlan({
    required this.sections,
  });

  final List<_BuiltSection> sections;

  int get totalChars {
    var total = 0;
    for (var i = 0; i < sections.length; i++) {
      total += sections[i].text.length;
      if (i != sections.length - 1) {
        total += 2;
      }
    }
    return total;
  }
}