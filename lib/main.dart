import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:docx_to_text/docx_to_text.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<List<File>> _logTargets() async {
  final files = <File>[];

  try {
    final tempDir = Directory.systemTemp;
    files.add(File('${tempDir.path}\\files_to_text_crash.log'));
  } catch (_) {
    // Ignore.
  }

  try {
    final exeDir = File(Platform.resolvedExecutable).parent;
    files.add(File('${exeDir.path}\\files_to_text_crash.log'));
  } catch (_) {
    // Ignore.
  }

  final uniquePaths = <String>{};
  final uniqueFiles = <File>[];
  for (final file in files) {
    if (uniquePaths.add(file.path)) {
      uniqueFiles.add(file);
    }
  }
  return uniqueFiles;
}

Future<void> appendCrashLog(
    String message, {
      StackTrace? stack,
      Object? error,
    }) async {
  try {
    final targets = await _logTargets();
    final buffer = StringBuffer()
      ..writeln('===== ${DateTime.now().toIso8601String()} =====')
      ..writeln(message);

    if (error != null) {
      buffer.writeln('error: $error');
    }

    if (stack != null) {
      buffer.writeln('stack:');
      buffer.writeln(stack.toString());
    }

    buffer.writeln();

    final text = buffer.toString();

    for (final file in targets) {
      try {
        await file.writeAsString(
          text,
          mode: FileMode.append,
          flush: true,
        );
      } catch (_) {
        // Ignore per-target logging failures.
      }
    }

    if (kDebugMode) {
      debugPrint(text);
    }
  } catch (_) {
    // Never throw from logger.
  }
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
    unawaited(
      appendCrashLog(
        'FlutterError caught',
        error: details.exception,
        stack: details.stack,
      ),
    );
  };

  PlatformDispatcher.instance.onError = (error, stack) {
    unawaited(
      appendCrashLog(
        'PlatformDispatcher.onError caught',
        error: error,
        stack: stack,
      ),
    );
    return true;
  };

  runZonedGuarded(() {
    runApp(const FilesToTextApp());
  }, (error, stack) {
    unawaited(
      appendCrashLog(
        'runZonedGuarded caught',
        error: error,
        stack: stack,
      ),
    );
  });
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

enum _FirstHeaderMode {
  none,
  lightweight,
  strictContext,
  debugging,
  architecture,
  refactor,
  ultraStrict,
}

extension _FirstHeaderModeX on _FirstHeaderMode {
  String get prefsValue => name;

  String get label {
    switch (this) {
      case _FirstHeaderMode.none:
        return 'None';
      case _FirstHeaderMode.lightweight:
        return 'Lightweight';
      case _FirstHeaderMode.strictContext:
        return 'Strict context';
      case _FirstHeaderMode.debugging:
        return 'Debugging';
      case _FirstHeaderMode.architecture:
        return 'Architecture / review';
      case _FirstHeaderMode.refactor:
        return 'Safe refactor';
      case _FirstHeaderMode.ultraStrict:
        return 'Ultra strict';
    }
  }

  static _FirstHeaderMode fromPrefs(String? value) {
    for (final mode in _FirstHeaderMode.values) {
      if (mode.prefsValue == value) return mode;
    }
    return _FirstHeaderMode.strictContext;
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
  static const String _prefsFirstHeaderModeKey = 'first_header_mode';

  static const int _defaultChunkSize = 120000;

  bool _isLoading = false;
  bool _isChunking = false;
  String? _lastDir;

  final TextEditingController _chunkSizeController = TextEditingController();

  final List<_SelectedFile> _files = [];

  List<_ChunkPlan> _lastBuiltChunks = [];

  _FirstHeaderMode _firstHeaderMode = _FirstHeaderMode.strictContext;

  bool get _needsChunking => _lastBuiltChunks.length > 1;

  Future<void> _log(String message, {Object? error, StackTrace? stack}) {
    return appendCrashLog(
      message,
      error: error,
      stack: stack,
    );
  }

  @override
  void initState() {
    super.initState();
    unawaited(_log('App initState'));
    unawaited(_loadPrefs());
  }

  @override
  void dispose() {
    unawaited(_log('App dispose'));
    _chunkSizeController.dispose();
    super.dispose();
  }

  void _showSnackBar(String message) {
    unawaited(_log('SnackBar shown: $message'));

    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  bool _safeFileExists(String path) {
    try {
      return File(path).existsSync();
    } catch (_) {
      return false;
    }
  }

  bool _safeDirectoryExists(String path) {
    try {
      return Directory(path).existsSync();
    } catch (_) {
      return false;
    }
  }

  int _safeFileLength(String path) {
    try {
      final file = File(path);
      if (!file.existsSync()) return 0;
      return file.lengthSync();
    } catch (_) {
      return 0;
    }
  }

  String _safeFileName(String path) {
    try {
      final segments = File(path).uri.pathSegments;
      if (segments.isNotEmpty) {
        return segments.last;
      }
    } catch (_) {
      // Fall through to path-based fallback.
    }

    final normalized = path.replaceAll('\\', '/');
    final index = normalized.lastIndexOf('/');
    if (index == -1 || index == normalized.length - 1) {
      return path;
    }
    return normalized.substring(index + 1);
  }

  Future<void> _loadPrefs() async {
    await _log('_loadPrefs start');

    try {
      final prefs = await SharedPreferences.getInstance();
      final dir = prefs.getString(_prefsLastDirKey);
      final chunkSize = prefs.getInt(_prefsChunkSizeKey) ?? _defaultChunkSize;
      final firstHeaderModeValue = prefs.getString(_prefsFirstHeaderModeKey);

      await _log(
        '_loadPrefs loaded raw values',
        error:
        'dir=$dir, chunkSize=$chunkSize, firstHeaderModeValue=$firstHeaderModeValue',
      );

      if (!mounted) return;

      setState(() {
        if (dir != null && _safeDirectoryExists(dir)) {
          _lastDir = dir;
        }
        _chunkSizeController.text = chunkSize.toString();
        _firstHeaderMode = _FirstHeaderModeX.fromPrefs(firstHeaderModeValue);
      });

      await _log('_loadPrefs complete');
    } catch (e, st) {
      await _log('_loadPrefs failed', error: e, stack: st);

      if (!mounted) return;
      setState(() {
        _chunkSizeController.text = _defaultChunkSize.toString();
        _firstHeaderMode = _FirstHeaderMode.strictContext;
      });
      _showSnackBar('Failed to load preferences: $e');
    }
  }

  Future<void> _saveLastDir(String dir) async {
    await _log('_saveLastDir start: $dir');

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsLastDirKey, dir);
      if (!mounted) return;
      setState(() => _lastDir = dir);
      await _log('_saveLastDir complete: $dir');
    } catch (e, st) {
      await _log('_saveLastDir failed', error: e, stack: st);
      _showSnackBar('Failed to save last folder: $e');
    }
  }

  Future<void> _saveChunkSize(int size) async {
    await _log('_saveChunkSize start: $size');

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_prefsChunkSizeKey, size);
      await _log('_saveChunkSize complete: $size');
    } catch (e, st) {
      await _log('_saveChunkSize failed', error: e, stack: st);
      _showSnackBar('Failed to save chunk size: $e');
    }
  }

  Future<void> _saveFirstHeaderMode(_FirstHeaderMode mode) async {
    await _log('_saveFirstHeaderMode start: ${mode.prefsValue}');

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsFirstHeaderModeKey, mode.prefsValue);
      await _log('_saveFirstHeaderMode complete: ${mode.prefsValue}');
    } catch (e, st) {
      await _log('_saveFirstHeaderMode failed', error: e, stack: st);
      _showSnackBar('Failed to save first header mode: $e');
    }
  }

  int get _chunkSize {
    final parsed = int.tryParse(_chunkSizeController.text.trim());
    if (parsed == null || parsed < 1000) return _defaultChunkSize;
    return parsed;
  }

  Future<void> _pickFiles() async {
    await _log('_pickFiles start');
    setState(() => _isLoading = true);

    try {
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        type: FileType.any,
        dialogTitle: 'Select file(s) to copy as text',
        initialDirectory: _lastDir,
        withData: false,
      );

      await _log(
        '_pickFiles picker returned',
        error:
        result == null ? 'result=null' : 'fileCount=${result.files.length}',
      );

      if (result == null || result.files.isEmpty) return;

      final firstPath = result.files.first.path;
      await _log('_pickFiles firstPath: $firstPath');

      if (firstPath != null) {
        try {
          final parent = File(firstPath).parent.path;
          await _log('_pickFiles saving parent dir: $parent');
          await _saveLastDir(parent);
        } catch (e, st) {
          await _log(
            '_pickFiles failed resolving parent path',
            error: e,
            stack: st,
          );
        }
      }

      final pickedPaths = result.files
          .map((f) => f.path)
          .whereType<String>()
          .toList(growable: false);

      await _log('_pickFiles pickedPaths count=${pickedPaths.length}');
      await _addPaths(pickedPaths);
      await _log('_pickFiles complete');
    } catch (e, st) {
      await _log('_pickFiles failed', error: e, stack: st);
      _showSnackBar('Failed to select files: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
      await _log('_pickFiles finally: isLoading=false');
    }
  }

  Future<List<String>> _listNestedFiles(String selectedDir) async {
    await _log('_listNestedFiles start: $selectedDir');

    final nestedFiles = <String>[];
    final root = Directory(selectedDir);
    var entityCount = 0;
    var fileCount = 0;

    await for (final entity in root.list(recursive: true, followLinks: false)) {
      entityCount++;

      if (entityCount % 500 == 0) {
        await _log(
          '_listNestedFiles progress',
          error: 'entityCount=$entityCount, fileCount=$fileCount',
        );
      }

      if (entity is File) {
        try {
          nestedFiles.add(entity.path);
          fileCount++;
        } catch (e, st) {
          await _log(
            '_listNestedFiles failed while reading file path',
            error: e,
            stack: st,
          );
        }
      }
    }

    await _log(
      '_listNestedFiles complete',
      error: 'entityCount=$entityCount, fileCount=$fileCount',
    );

    return nestedFiles;
  }

  Future<void> _pickFolder() async {
    await _log('_pickFolder start');
    setState(() => _isLoading = true);

    try {
      final selectedDir = await FilePicker.platform.getDirectoryPath(
        dialogTitle: 'Select folder to include recursively',
        initialDirectory: _lastDir,
      );

      await _log('_pickFolder picker returned: $selectedDir');

      if (selectedDir == null || selectedDir.isEmpty) return;

      await _saveLastDir(selectedDir);

      final exists = _safeDirectoryExists(selectedDir);
      await _log('_pickFolder directory exists check: $exists');

      if (!exists) return;

      final nestedFiles = await _listNestedFiles(selectedDir);
      await _log('_pickFolder nestedFiles count=${nestedFiles.length}');
      await _addPaths(nestedFiles);
      await _log('_pickFolder complete');
    } catch (e, st) {
      await _log('_pickFolder failed', error: e, stack: st);
      _showSnackBar('Failed to select folder: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
      await _log('_pickFolder finally: isLoading=false');
    }
  }

  Future<void> _addPaths(List<String> paths) async {
    await _log('_addPaths start: incoming=${paths.length}');

    try {
      final existingPaths = _files.map((f) => f.path).toSet();
      final loaded = <_SelectedFile>[];
      var checked = 0;
      var skippedExisting = 0;
      var skippedMissing = 0;

      for (final path in paths) {
        checked++;

        if (checked % 500 == 0) {
          await _log(
            '_addPaths progress',
            error:
            'checked=$checked, loaded=${loaded.length}, skippedExisting=$skippedExisting, skippedMissing=$skippedMissing',
          );
        }

        if (existingPaths.contains(path)) {
          skippedExisting++;
          continue;
        }
        if (!_safeFileExists(path)) {
          skippedMissing++;
          continue;
        }

        loaded.add(
          _SelectedFile(
            path: path,
            name: _safeFileName(path),
          ),
        );
        existingPaths.add(path);
      }

      await _log(
        '_addPaths filtering complete',
        error:
        'checked=$checked, loaded=${loaded.length}, skippedExisting=$skippedExisting, skippedMissing=$skippedMissing',
      );

      if (loaded.isEmpty) return;

      setState(() {
        _files.addAll(loaded);
        _invalidateChunks();
      });

      await _log('_addPaths state updated: totalFiles=${_files.length}');
      await _ensureChunksBuilt();
      await _log('_addPaths complete');
    } catch (e, st) {
      await _log('_addPaths failed', error: e, stack: st);
      _showSnackBar('Failed while adding selected files: $e');
    }
  }

  Future<void> _removeFileAt(int index) async {
    await _log('_removeFileAt start: index=$index');

    if (index < 0 || index >= _files.length) return;

    setState(() {
      _files.removeAt(index);
      _invalidateChunks();
    });

    await _log('_removeFileAt state updated: totalFiles=${_files.length}');

    if (_files.isNotEmpty) {
      await _ensureChunksBuilt();
    } else if (mounted) {
      setState(() {});
    }

    await _log('_removeFileAt complete');
  }

  void _clear() {
    unawaited(_log('_clear invoked'));

    setState(() {
      _files.clear();
      _invalidateChunks();
    });
  }

  void _invalidateChunks() {
    unawaited(_log('_invalidateChunks'));
    _lastBuiltChunks = [];
  }

  Future<void> _onChunkSizeChanged(String _) async {
    await _log('_onChunkSizeChanged start: value=${_chunkSizeController.text}');

    _invalidateChunks();

    if (_files.isEmpty) {
      if (mounted) setState(() {});
      return;
    }

    await _ensureChunksBuilt();
    await _log('_onChunkSizeChanged complete');
  }

  Future<void> _onFirstHeaderModeChanged(_FirstHeaderMode? mode) async {
    await _log('_onFirstHeaderModeChanged start: ${mode?.prefsValue}');

    if (mode == null) return;

    await _saveFirstHeaderMode(mode);

    if (!mounted) return;
    setState(() {
      _firstHeaderMode = mode;
      _invalidateChunks();
    });

    if (_files.isNotEmpty) {
      await _ensureChunksBuilt();
    }

    await _log('_onFirstHeaderModeChanged complete: ${mode.prefsValue}');
  }

  String _extLower(String nameOrPath) {
    final dot = nameOrPath.lastIndexOf('.');
    if (dot == -1) return '';
    return nameOrPath.substring(dot + 1).toLowerCase();
  }

  Future<String> _readFileAsTextSmart(_SelectedFile f) async {
    final file = File(f.path);
    final ext = _extLower(f.name);
    final length = _safeFileLength(f.path);

    await _log(
      '_readFileAsTextSmart start',
      error: 'path=${f.path}, ext=$ext, length=$length',
    );

    final bytes = await file.readAsBytes();

    await _log(
      '_readFileAsTextSmart bytes loaded',
      error: 'path=${f.path}, bytes=${bytes.length}',
    );

    if (ext == 'docx') {
      await _log('_readFileAsTextSmart docxToText start: ${f.path}');
      final result = docxToText(bytes);
      await _log(
        '_readFileAsTextSmart docxToText complete',
        error: 'path=${f.path}, chars=${result.length}',
      );
      return result;
    }

    await _log('_readFileAsTextSmart utf8.decode start: ${f.path}');
    final result = utf8.decode(bytes, allowMalformed: true);
    await _log(
      '_readFileAsTextSmart utf8.decode complete',
      error: 'path=${f.path}, chars=${result.length}',
    );
    return result;
  }

  String _buildFirstFileHeader({
    required int totalFiles,
    required bool isChunkedOutput,
  }) {
    if (_firstHeaderMode == _FirstHeaderMode.none) {
      return '';
    }

    final sourceContext = totalFiles <= 1
        ? 'The pasted content starts with a single provided file.'
        : 'The pasted content starts with the first file from a selected set of $totalFiles files.';

    final scopeContext = isChunkedOutput
        ? 'Use this header only as analysis guidance. The chunk instructions above control chunk flow, waiting behavior, and how to treat multiple chunks together.'
        : 'Apply these instructions to the pasted content in this message.';

    switch (_firstHeaderMode) {
      case _FirstHeaderMode.none:
        return '';
      case _FirstHeaderMode.lightweight:
        return '''
CHATGPT FIRST-FILE HEADER:
$sourceContext
$scopeContext

Only use the provided content.
Do not assume missing context.
If important context is missing, say what is needed instead of guessing.

''';
      case _FirstHeaderMode.strictContext:
        return '''
CHATGPT FIRST-FILE HEADER:
$sourceContext
$scopeContext

Analyze only the provided content.
Do NOT assume missing files, functions, dependencies, or behavior.
If required context is missing, explicitly state what is missing.
Do NOT guess or fabricate implementations.

When answering, be precise and grounded in the provided content.
Reference specific parts of the content when possible.

''';
      case _FirstHeaderMode.debugging:
        return '''
CHATGPT FIRST-FILE HEADER:
$sourceContext
$scopeContext

Use a debugging-focused analysis style.

Rules:
- Only use the provided content.
- Do NOT assume hidden logic, missing dependencies, or unseen implementations.
- If the issue cannot be determined from the provided content alone, explain what additional context is required.

Focus on:
- Likely causes within the provided content
- Edge cases
- Incorrect assumptions in the logic

''';
      case _FirstHeaderMode.architecture:
        return '''
CHATGPT FIRST-FILE HEADER:
$sourceContext
$scopeContext

Use an architecture/review-focused analysis style.

Constraints:
- Only evaluate what is present.
- Do NOT assume missing files or systems.
- If something appears incomplete, call it out explicitly.

Focus on:
- Structure and organization
- Maintainability
- Potential risks or scalability concerns

''';
      case _FirstHeaderMode.refactor:
        return '''
CHATGPT FIRST-FILE HEADER:
$sourceContext
$scopeContext

Use a safe-refactor analysis style.

Rules:
- Only modify or evaluate what is shown.
- Do NOT introduce dependencies on unseen code.
- If a better solution requires additional context, explain what is needed instead of guessing.

Goal:
- Improve clarity, safety, and correctness
- Keep behavior consistent unless explicitly told otherwise

''';
      case _FirstHeaderMode.ultraStrict:
        return '''
CHATGPT FIRST-FILE HEADER:
$sourceContext
$scopeContext

STRICT MODE:

- Use ONLY the provided content.
- ZERO assumptions about missing files or behavior.
- If anything necessary is unclear or missing, stop and list what is needed.
- If the question cannot be fully answered from the provided content, respond with "Insufficient context" and explain why.

Do not speculate.
Do not infer unseen implementations.

''';
    }
  }

  Future<String> _buildSingleFileSection(
      _SelectedFile f, {
        required bool includeFirstHeader,
        required int totalFiles,
        required bool isChunkedOutput,
      }) async {
    await _log(
      '_buildSingleFileSection start',
      error:
      'path=${f.path}, includeFirstHeader=$includeFirstHeader, isChunkedOutput=$isChunkedOutput',
    );

    final buffer = StringBuffer();

    if (includeFirstHeader) {
      buffer.write(_buildFirstFileHeader(
        totalFiles: totalFiles,
        isChunkedOutput: isChunkedOutput,
      ));
    }

    buffer.writeln('===== ${f.path} =====');

    if (!_safeFileExists(f.path)) {
      buffer.writeln('[Missing file: ${f.path}]');
      await _log('_buildSingleFileSection missing file: ${f.path}');
      return buffer.toString();
    }

    try {
      final text = await _readFileAsTextSmart(f);
      buffer.writeln(text);
      await _log(
        '_buildSingleFileSection complete',
        error: 'path=${f.path}, chars=${text.length}',
      );
    } catch (e, st) {
      await _log(
        '_buildSingleFileSection failed reading file',
        error: e,
        stack: st,
      );
      buffer.writeln('[Failed to read ${f.path}: $e]');
    }

    return buffer.toString();
  }

  Future<String> _buildClipboardText() async {
    await _log('_buildClipboardText start');
    final buffer = StringBuffer();
    final totalFiles = _files.length;

    for (var i = 0; i < _files.length; i++) {
      await _log('_buildClipboardText section ${i + 1}/$totalFiles');

      final section = await _buildSingleFileSection(
        _files[i],
        includeFirstHeader: i == 0,
        totalFiles: totalFiles,
        isChunkedOutput: false,
      );
      buffer.write(section);

      if (i != _files.length - 1) {
        buffer.writeln();
        buffer.writeln();
      }
    }

    await _log('_buildClipboardText complete');
    return buffer.toString();
  }

  Future<List<_ChunkPlan>> _buildChunkPlans() async {
    await _log('_buildChunkPlans start');

    final chunkSize = _chunkSize;
    await _saveChunkSize(chunkSize);

    final sections = <_BuiltSection>[];
    final totalFiles = _files.length;

    await _log(
      '_buildChunkPlans config',
      error: 'chunkSize=$chunkSize, totalFiles=$totalFiles',
    );

    for (var i = 0; i < _files.length; i++) {
      final f = _files[i];
      await _log(
        '_buildChunkPlans building section ${i + 1}/$totalFiles',
        error: f.path,
      );

      final text = await _buildSingleFileSection(
        f,
        includeFirstHeader: i == 0,
        totalFiles: totalFiles,
        isChunkedOutput: true,
      );
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

    await _log('_buildChunkPlans complete: chunkCount=${chunks.length}');
    return chunks;
  }

  String _buildChunkPreamble({
    required int chunkIndex,
    required int totalChunks,
  }) {
    final isFinalChunk = chunkIndex == totalChunks - 1;

    if (isFinalChunk) {
      return '''
CHATGPT INPUT INSTRUCTIONS:
- This is chunk ${chunkIndex + 1} of $totalChunks.
- This is the final chunk.
- Treat this chunk together with all prior chunks in the set as one unified project, codebase, or document set.
- Preserve cross-file and cross-chunk relationships.
- My actual request/question will appear after this chunk in the same message.
- Wait to answer until after reading the request/question that follows this chunk.

''';
    }

    return '''
CHATGPT INPUT INSTRUCTIONS:
- This is chunk ${chunkIndex + 1} of $totalChunks.
- More chunks will be sent after this one.
- Treat this chunk together with all later chunks as one unified project, codebase, or document set.
- Preserve cross-file and cross-chunk relationships.
- Do not answer yet.
- Wait for the remaining chunks and my final request.

''';
  }

  String _renderChunkText({
    required _ChunkPlan chunk,
    required int chunkIndex,
    required int totalChunks,
  }) {
    final buffer = StringBuffer();
    buffer.write(_buildChunkPreamble(
      chunkIndex: chunkIndex,
      totalChunks: totalChunks,
    ));

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
    await _log('_copyToClipboard start');

    if (_files.isEmpty) return;

    try {
      final text = await _buildClipboardText();
      await _log('_copyToClipboard clipboard set start: chars=${text.length}');
      await Clipboard.setData(ClipboardData(text: text));

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Copied ${_files.length} file(s) to clipboard'),
          duration: const Duration(seconds: 2),
        ),
      );

      await _log('_copyToClipboard complete');
    } catch (e, st) {
      await _log('_copyToClipboard failed', error: e, stack: st);
      _showSnackBar('Failed to copy files: $e');
    }
  }

  Future<void> _ensureChunksBuilt() async {
    await _log(
      '_ensureChunksBuilt start',
      error:
      'fileCount=${_files.length}, cachedChunkCount=${_lastBuiltChunks.length}',
    );

    if (_files.isEmpty) return;
    if (_lastBuiltChunks.isNotEmpty) {
      await _log('_ensureChunksBuilt skipped due to cache');
      return;
    }

    setState(() => _isChunking = true);
    try {
      final chunks = await _buildChunkPlans();
      if (!mounted) return;
      setState(() {
        _lastBuiltChunks = chunks;
      });
      await _log('_ensureChunksBuilt complete: chunkCount=${chunks.length}');
    } catch (e, st) {
      await _log('_ensureChunksBuilt failed', error: e, stack: st);
      _showSnackBar('Failed to build chunks: $e');
    } finally {
      if (mounted) {
        setState(() => _isChunking = false);
      }
      await _log('_ensureChunksBuilt finally: isChunking=false');
    }
  }

  Future<void> _copyChunk(int chunkIndex) async {
    await _log('_copyChunk start: index=$chunkIndex');

    if (_files.isEmpty) return;

    try {
      await _ensureChunksBuilt();
      if (_lastBuiltChunks.isEmpty) return;
      if (chunkIndex < 0 || chunkIndex >= _lastBuiltChunks.length) return;

      final chunk = _lastBuiltChunks[chunkIndex];
      final text = _renderChunkText(
        chunk: chunk,
        chunkIndex: chunkIndex,
        totalChunks: _lastBuiltChunks.length,
      );

      await _log(
        '_copyChunk clipboard set start',
        error: 'index=$chunkIndex, chars=${text.length}',
      );
      await Clipboard.setData(ClipboardData(text: text));

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Copied chunk ${chunkIndex + 1} of ${_lastBuiltChunks.length}'),
          duration: const Duration(seconds: 2),
        ),
      );

      await _log('_copyChunk complete: index=$chunkIndex');
    } catch (e, st) {
      await _log('_copyChunk failed', error: e, stack: st);
      _showSnackBar('Failed to copy chunk: $e');
    }
  }

  Future<void> _openCopyChunkMenu() async {
    await _log('_openCopyChunkMenu start');

    try {
      await _ensureChunksBuilt();
      if (!mounted) return;

      if (_lastBuiltChunks.length <= 1) {
        await _log('_openCopyChunkMenu skipped: <=1 chunks');
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
                final isFinalChunk = index == _lastBuiltChunks.length - 1;

                return ListTile(
                  leading: Icon(
                    isFinalChunk ? Icons.flag_outlined : Icons.content_copy,
                  ),
                  title: Text(
                    isFinalChunk
                        ? 'Chunk ${index + 1} of ${_lastBuiltChunks.length} (final)'
                        : 'Chunk ${index + 1} of ${_lastBuiltChunks.length}',
                  ),
                  subtitle: Text('$fileCount file(s) • $charCount chars'),
                  onTap: () async {
                    await _log('_openCopyChunkMenu tapped chunk index=$index');
                    Navigator.of(context).pop();
                    await _copyChunk(index);
                  },
                );
              },
            ),
          );
        },
      );

      await _log('_openCopyChunkMenu complete');
    } catch (e, st) {
      await _log('_openCopyChunkMenu failed', error: e, stack: st);
      _showSnackBar('Failed to open chunk menu: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final totalBytes = _files.fold<int>(0, (sum, f) {
      return sum + _safeFileLength(f.path);
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
              firstHeaderMode: _firstHeaderMode,
              onChunkSizeChanged: _onChunkSizeChanged,
              onFirstHeaderModeChanged: _onFirstHeaderModeChanged,
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
    required this.firstHeaderMode,
    required this.onChunkSizeChanged,
    required this.onFirstHeaderModeChanged,
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
  final _FirstHeaderMode firstHeaderMode;
  final ValueChanged<String> onChunkSizeChanged;
  final ValueChanged<_FirstHeaderMode?> onFirstHeaderModeChanged;
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
            Wrap(
              spacing: 16,
              runSpacing: 12,
              crossAxisAlignment: WrapCrossAlignment.center,
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
                SizedBox(
                  width: 270,
                  child: DropdownButtonFormField<_FirstHeaderMode>(
                    initialValue: firstHeaderMode,
                    decoration: const InputDecoration(
                      labelText: 'First header mode',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    items: _FirstHeaderMode.values.map((mode) {
                      return DropdownMenuItem<_FirstHeaderMode>(
                        value: mode,
                        child: Text(mode.label),
                      );
                    }).toList(growable: false),
                    onChanged: onFirstHeaderModeChanged,
                  ),
                ),
                ConstrainedBox(
                  constraints: const BoxConstraints(minWidth: 240, maxWidth: 700),
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

  bool _safeFileExists(String path) {
    try {
      return File(path).existsSync();
    } catch (_) {
      return false;
    }
  }

  int _safeFileLength(String path) {
    try {
      final file = File(path);
      if (!file.existsSync()) return 0;
      return file.lengthSync();
    } catch (_) {
      return 0;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListView.separated(
        itemCount: files.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (context, i) {
          final f = files[i];
          final exists = _safeFileExists(f.path);
          final bytes = exists ? _safeFileLength(f.path) : 0;

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