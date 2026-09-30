import 'dart:io';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:dio/dio.dart';
import 'package:archive/archive_io.dart';
import 'package:drift/drift.dart' as drift;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../database.dart';
import '../utils/crypto.dart';
import '../content_version.dart';
import 'diagram_storage.dart';

/// Top-level so it can run in a background isolate via compute(): decrypt the
/// AES blob, then JSON-decode. Keeps ~21MB of AES + parse off the UI thread.
dynamic _decryptAndDecodeBytes(Uint8List bytes) {
  return jsonDecode(DataCrypto.decryptBytes(bytes));
}

class SyncProgress {
  /// 0.0 → 1.0
  final double progress;
  /// Human-readable label shown under the bar.
  final String label;
  /// True when this is the final tick.
  final bool done;
  const SyncProgress(this.progress, this.label, {this.done = false});
}

class SyncService {
  final AppDatabase db;
  /// Timeouts are mandatory here, not optional tuning.
  ///
  /// A bare `Dio()` has NO connect timeout, so it inherits the OS behaviour: an
  /// Android TCP connect to an unreachable host retries SYNs for a minute or
  /// more, and behind a captive portal or on a dying signal it can stall
  /// indefinitely. The splash awaits this call, so the app sat on "Checking for
  /// updates..." forever with no way past it — reported from the field, and the
  /// surrounding try/catch could not help because nothing ever threw.
  ///
  /// `receiveTimeout` is Dio's per-chunk idle limit, not a total budget, so a
  /// slow 78 MB download on 2G still succeeds; only a genuinely stalled socket
  /// trips it.
  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 8),
    receiveTimeout: const Duration(seconds: 30),
    sendTimeout: const Duration(seconds: 30),
  ));

  /// Hard ceiling on the release-metadata lookup. Cheap call, so if it has not
  /// answered in this long the network is not usable and offline is the correct
  /// assumption.
  static const Duration _checkDeadline = Duration(seconds: 10);

  /// Listenable progress stream consumed by the splash screen.
  final ValueNotifier<SyncProgress> progress =
      ValueNotifier(const SyncProgress(0, "Initializing..."));

  static const String _repoOwner = "lognjais";
  static const String _repoName = "questionx";
  static const String _versionKey = "db_version_tag";
  /// Fingerprint of the bundled banks that were last imported into the DB.
  static const String _contentKey = "bundled_content_version";
  static const String _lastCheckKey = "db_last_check_ms";
  static const Duration _checkInterval = Duration(hours: 6);

  /// Test hook: the network options above are load-bearing, not tuning.
  @visibleForTesting
  BaseOptions get httpOptions => _dio.options;

  SyncService(this.db);

  void _emit(double p, String label, {bool done = false}) {
    progress.value = SyncProgress(p.clamp(0.0, 1.0), label, done: done);
  }

  Future<void> initializeData() async {
    _emit(0.02, "Initializing...");
    final prefs = await SharedPreferences.getInstance();
    final currentVersion = prefs.getString(_versionKey);

    await DiagramStorage.ensureReady();
    final diagramCount = await DiagramStorage.countFiles();
    final questionCount = await db.countQuestions();

    // The bundled, encrypted bank is the VERIFIED content shipped with this
    // build, so it is authoritative — load it from assets and do NOT let an
    // older OTA release overwrite it. (Previously first launch imported straight
    // from the OTA zip, which silently shipped stale content over the bundled
    // bank.)
    //
    // Import on an empty database, and ALSO whenever this build carries
    // different questions from the ones already imported. Without the second
    // case the bundled bank was read only into an empty database, so an APK
    // carrying corrected questions changed nothing for anyone who already had
    // the app installed: NEET_2024_Zoo_184 was fixed in v1.7.6 and still showed
    // the old, garbled text after upgrading, because the database kept its copy
    // until an OTA release happened to fire.
    final importedContent = prefs.getString(_contentKey);
    final contentChanged =
        questionCount > 0 && importedContent != kBundledContentVersion;
    if (contentChanged) {
      debugPrint("📦 Bundled content changed "
          "($importedContent -> $kBundledContentVersion) — re-importing.");
    }

    if (questionCount == 0 || contentChanged) {
      _emit(0.30, "Loading question bank...");
      await _loadFromAssets();
      await prefs.setString(_contentKey, kBundledContentVersion);
      try {
        // Only fetch figures when they are actually absent. On a content
        // re-import the user already has them on disk, and data.zip is ~78 MB.
        if (await _diagramsIncomplete(diagramCount)) {
          _emit(0.45, "Downloading diagrams...");
          final tag = await _checkForUpdates(null); // latest release tag
          if (tag != null) {
            await _downloadDiagramsOnly(tag);
            await prefs.setString(_versionKey, tag);
          }
          await prefs.setInt(
              _lastCheckKey, DateTime.now().millisecondsSinceEpoch);
        }
      } catch (e) {
        debugPrint("⚠️ Diagram fetch failed ($e). Text is fully "
            "usable; diagrams will retry on the next launch.");
      }
      _emit(1.0, "Ready", done: true);
      return;
    }

    // SUBSEQUENT LAUNCHES: periodic OTA update (content + diagrams) and a
    // self-heal if the diagrams dir was wiped while a version is recorded.
    final diagramsMissing =
        currentVersion != null && await _diagramsIncomplete(diagramCount);
    try {
      if (_shouldCheckOnline(prefs) || diagramsMissing) {
        _emit(0.05, "Checking for updates...");
        final latestTag = await _checkForUpdates(
          diagramsMissing ? null : currentVersion,
        );
        await prefs.setInt(_lastCheckKey, DateTime.now().millisecondsSinceEpoch);

        if (latestTag != null) {
          await _downloadAndSync(latestTag);
          await prefs.setString(_versionKey, latestTag);
        }
      } else {
        debugPrint("✅ Database is ready (Version: $currentVersion).");
      }
    } catch (e) {
      debugPrint("⚠️ Online check failed ($e). Proceeding with current bank.");
    }
    _emit(1.0, "Ready", done: true);
  }

  /// Whether the on-disk diagram set is missing figures this bank references.
  ///
  /// The old test was `diagramCount == 0`, which only caught a completely wiped
  /// directory. It could not catch a `data.zip` that shipped a *partial* set:
  /// v1.7.3 and v1.7.4 contained all 6,150 JEE figures and zero NEET ones, so
  /// every NEET question with a diagram rendered "Error loading diagram" while
  /// the count sat at 6,150 and looked perfectly healthy. A count comparison
  /// cannot catch it either — the artifact ships more images (6,310) than the
  /// banks actually reference (4,348).
  ///
  /// So check identity instead, on an exam-stratified sample: cheap (a few dozen
  /// stat calls), and it flags the realistic failure of losing a whole family.
  Future<bool> _diagramsIncomplete(int diagramCount) async {
    if (diagramCount == 0) {
      debugPrint("🩹 Diagrams directory is empty — forcing re-sync.");
      return true;
    }
    try {
      final sample = await db.sampleDiagramFilenames();
      if (sample.isEmpty) return false;
      final absent = <String>[];
      for (final name in sample) {
        if (await DiagramStorage.fileFor(name) == null) absent.add(name);
      }
      if (absent.isEmpty) return false;
      debugPrint("🩹 ${absent.length}/${sample.length} sampled diagrams absent "
          "(e.g. ${absent.take(3).join(', ')}) — forcing re-sync.");
      return true;
    } catch (e) {
      // Never let a health check block startup.
      debugPrint("⚠️ Diagram completeness check failed ($e).");
      return false;
    }
  }

  bool _shouldCheckOnline(SharedPreferences prefs) {
    final lastMs = prefs.getInt(_lastCheckKey);
    if (lastMs == null) return true;
    final last = DateTime.fromMillisecondsSinceEpoch(lastMs);
    return DateTime.now().difference(last) >= _checkInterval;
  }

  Future<String?> _checkForUpdates(String? currentVersion) async {
    const url =
        "https://api.github.com/repos/$_repoOwner/$_repoName/releases/latest";
    final response = await _dio.get(url).timeout(_checkDeadline);

    if (response.statusCode == 200) {
      final latestTag = response.data['tag_name'];
      if (currentVersion == null || latestTag != currentVersion) {
        debugPrint("🚀 New Update Found: $latestTag");
        return latestTag;
      }
    }
    return null;
  }

  Future<void> _downloadAndSync(String tag) async {
    final dir = await getApplicationDocumentsDirectory();
    final zipPath = "${dir.path}/data.zip";

    final downloadUrl =
        "https://github.com/$_repoOwner/$_repoName/releases/download/$tag/data.zip";

    // Phase 1: download (0.05 → 0.60).
    _emit(0.05, "Downloading content...");
    await _dio.download(
      downloadUrl,
      zipPath,
      onReceiveProgress: (received, total) {
        if (total <= 0) return;
        final frac = received / total;
        final mb = (received / 1024 / 1024).toStringAsFixed(1);
        final totalMb = (total / 1024 / 1024).toStringAsFixed(0);
        _emit(0.05 + 0.55 * frac, "Downloading content... $mb / $totalMb MB");
      },
    );

    final zipFile = File(zipPath);

    // Phase 2: extract diagrams (0.60 → 0.85).
    try {
      _emit(0.60, "Unpacking diagrams...");
      final imgCount = await DiagramStorage.unpackZipFrom(zipFile);
      if (imgCount > 0) {
        debugPrint("🖼️ Extracted $imgCount diagram(s).");
        _emit(0.85, "Unpacked $imgCount diagrams");
      } else {
        _emit(0.85, "No new diagrams");
      }
    } catch (e) {
      debugPrint("⚠️ Diagram extraction failed: $e");
    }

    // Phase 3: process JSON datasets into the DB (0.85 → 0.99).
    // CRITICAL: nuke all existing question rows first. We need this because a
    // new release can both ADD records and DROP records (e.g. v1.3.0 trimmed
    // 4K JEE rows from v1.2.0). Without a delete pass, dropped records keep
    // showing up to the user because `insertOrReplace` only touches IDs
    // present in the new payload.
    _emit(0.85, "Indexing questions...");
    final inputStream = InputFileStream(zipPath);
    final archive = ZipDecoder().decodeBuffer(inputStream);
    final jsonFiles = archive.files
        .where((f) => f.isFile &&
            (f.name.endsWith(".json") || f.name.endsWith(".json.enc")))
        .where((f) => !f.name.startsWith('.') && !f.name.contains("__MACOSX"))
        .toList();

    // Decode + validate the ENTIRE payload BEFORE touching the live DB. A
    // corrupt/partial download must never leave the user with an empty bank.
    // Supports both plaintext (current release) and encrypted .json.enc payloads.
    final decoded = <MapEntry<String, List<dynamic>>>[];
    for (var i = 0; i < jsonFiles.length; i++) {
      final file = jsonFiles[i];
      final raw = file.content as List<int>;
      final jsonData = file.name.endsWith('.enc')
          ? await compute(_decryptAndDecodeBytes, Uint8List.fromList(raw))
          : await compute(jsonDecode, utf8.decode(raw));
      final list = _asQuestionList(jsonData);
      if (list == null || list.isEmpty) {
        throw StateError("Empty/invalid dataset in ${file.name} — aborting sync");
      }
      decoded.add(MapEntry(_examNameForFile(file.name), list));
      _emit(0.85 + (0.10 / jsonFiles.length) * (i + 1),
          "Validated ${_friendlyName(file.name)}");
    }
    if (decoded.isEmpty) {
      throw StateError("No datasets in update payload — keeping current bank");
    }

    // Everything validated → swap atomically so a mid-write failure rolls back.
    _emit(0.96, "Updating question bank...");
    await db.transaction(() async {
      await db.deleteAllQuestions();
      for (final entry in decoded) {
        await _insertBatch(entry.value, entry.key);
      }
    });

    await zipFile.delete();
    debugPrint("🎉 Sync Complete!");
  }

  /// Downloads the release `data.zip` and extracts ONLY the diagrams — the
  /// question bank is left untouched (used on first launch, where the bundled
  /// bank is authoritative). Same download/extract primitives as
  /// [_downloadAndSync], minus the DB re-import.
  Future<void> _downloadDiagramsOnly(String tag) async {
    final dir = await getApplicationDocumentsDirectory();
    final zipPath = "${dir.path}/data.zip";
    final downloadUrl =
        "https://github.com/$_repoOwner/$_repoName/releases/download/$tag/data.zip";

    await _dio.download(
      downloadUrl,
      zipPath,
      onReceiveProgress: (received, total) {
        if (total <= 0) return;
        final frac = received / total;
        final mb = (received / 1024 / 1024).toStringAsFixed(1);
        final totalMb = (total / 1024 / 1024).toStringAsFixed(0);
        _emit(0.45 + 0.45 * frac, "Downloading diagrams... $mb / $totalMb MB");
      },
    );

    final zipFile = File(zipPath);
    try {
      _emit(0.92, "Unpacking diagrams...");
      final imgCount = await DiagramStorage.unpackZipFrom(zipFile);
      debugPrint("🖼️ First-launch: extracted $imgCount diagram(s).");
    } catch (e) {
      debugPrint("⚠️ Diagram extraction failed: $e");
    }
    if (await zipFile.exists()) await zipFile.delete();
  }

  static String _friendlyName(String filename) {
    final lower = filename.toLowerCase();
    if (lower.contains("neet")) return "NEET questions";
    if (lower.contains("jee")) return "JEE questions";
    return filename;
  }

  Future<void> _loadFromAssets() async {
    for (final asset in const ['assets/neet.json.enc', 'assets/jee.json.enc']) {
      try {
        final bd = await rootBundle.load(asset);
        final bytes =
            bd.buffer.asUint8List(bd.offsetInBytes, bd.lengthInBytes);
        // Decrypt + decode off the UI isolate.
        final jsonData = await compute(_decryptAndDecodeBytes, bytes);
        await _insertBatch(jsonData, _examNameForFile(asset));
      } catch (e) {
        debugPrint("❌ Asset Load Error ($asset): $e");
      }
    }
  }

  static String _examNameForFile(String filename) {
    return filename.toLowerCase().contains("neet") ? "NEET" : "JEE Main";
  }

  /// Per-record exam-name mapping. JEE records carry `exam: "JEE_Main"` or
  /// `"JEE_Advanced"`, so a single jee.json populates both display buckets.
  /// Falls back to the file-level label for records lacking the field
  /// (e.g. all NEET rows, which we keep grouped under "NEET").
  static String _examNameForRecord(Map<String, dynamic> q, String fileLabel) {
    final raw = q['exam'];
    if (raw is String) {
      if (raw == 'JEE_Advanced') return 'JEE Advanced';
      if (raw == 'JEE_Main') return 'JEE Main';
    }
    return fileLabel;
  }

  /// Extracts the question list from either a bare List or a {"questions": [...]}
  /// wrapper. Returns null for anything else.
  List<dynamic>? _asQuestionList(dynamic jsonData) {
    if (jsonData is Map && jsonData['questions'] is List) {
      return jsonData['questions'] as List<dynamic>;
    }
    if (jsonData is List) return jsonData;
    return null;
  }

  Future<void> _insertBatch(dynamic jsonData, String examSource) async {
    List<dynamic> list;
    if (jsonData is Map && jsonData.containsKey('questions')) {
      list = jsonData['questions'];
    } else if (jsonData is List) {
      list = jsonData;
    } else {
      return;
    }

    await db.batch((batch) {
      for (var q in list) {
        batch.insert(
          db.questions,
          QuestionsCompanion.insert(
            id: q['id'] ?? DateTime.now().millisecondsSinceEpoch.toString(),
            examName: _examNameForRecord(q, examSource),
            year: q['year'] is int
                ? q['year']
                : int.tryParse(q['year'].toString()) ?? 2024,
            subject: q['subject'] ?? "General",
            topic: q['topic'] ?? "General",
            difficulty: q['difficulty'] ?? "Medium",
            questionLatex: q['question_latex'] ?? "",
            questionSvg: drift.Value(q['question_svg']),
            optionsJson: jsonEncode(q['options']),
            answerKey: drift.Value(q['answer_key']),
            solution: drift.Value(q['solution']),
            solutionSvg: drift.Value(q['solution_svg']),
          ),
          mode: drift.InsertMode.insertOrReplace,
        );
      }
    });
  }
}
