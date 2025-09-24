import 'dart:io';

import 'package:mason_logger/mason_logger.dart';
import 'package:path/path.dart' as p;
import 'package:scoped_deps/scoped_deps.dart';
import 'package:shorebird_cli/src/archive_analysis/archive_differ.dart';
import 'package:shorebird_cli/src/archive_analysis/file_set_diff.dart';
import 'package:shorebird_cli/src/logging/logging.dart';
import 'package:shorebird_cli/src/shorebird_documentation.dart';
import 'package:shorebird_cli/src/shorebird_env.dart';

/// {@template diff_status}
/// Describes the types of changes that have been detected between a patch
/// and its release.
/// {@endtemplate}
class DiffStatus {
  /// {@macro diff_status}
  const DiffStatus({
    required this.hasAssetChanges,
    required this.hasNativeChanges,
  });

  /// Whether the patch contains asset changes.
  final bool hasAssetChanges;

  /// Whether the patch contains native code changes.
  final bool hasNativeChanges;
}

/// Thrown when an unpatchable change is detected in an environment where the
/// user cannot be prompted to continue.
class UnpatchableChangeException implements Exception {}

/// Thrown when the user cancels after being prompted to continue.
class UserCancelledException implements Exception {}

/// A reference to a [PatchDiffChecker] instance.
ScopedRef<PatchDiffChecker> patchDiffCheckerRef = create(PatchDiffChecker.new);

/// The [PatchDiffChecker] instance available in the current zone.
PatchDiffChecker get patchDiffChecker => read(patchDiffCheckerRef);

/// {@template patch_verifier}
/// Verifies that a patch can successfully be applied to a release artifact.
/// {@endtemplate}
class PatchDiffChecker {
  /// Checks for differences that could cause issues when applying the
  /// [localArchive] patch to the [releaseArchive].
  Future<DiffStatus> confirmUnpatchableDiffsIfNecessary({
    required File localArchive,
    required File releaseArchive,
    required ArchiveDiffer archiveDiffer,
    required bool allowAssetChanges,
    required bool allowNativeChanges,
    bool confirmNativeChanges = true,
  }) async {
    final progress = logger.progress(
      'Verifying patch can be applied to release',
    );

    final contentDiffs = await archiveDiffer.changedFiles(
      releaseArchive.path,
      localArchive.path,
    );
    progress.complete();

    final status = DiffStatus(
      hasAssetChanges: archiveDiffer.containsPotentiallyBreakingAssetDiffs(
        contentDiffs,
      ),
      hasNativeChanges: archiveDiffer.containsPotentiallyBreakingNativeDiffs(
        contentDiffs,
      ),
    );

    if (status.hasNativeChanges && confirmNativeChanges) {
      logger
        ..warn(
          '''Your app contains native changes, which cannot be applied with a patch.''',
        )
        ..info(
          yellow.wrap(
            archiveDiffer.nativeFileSetDiff(contentDiffs).prettyString,
          ),
        )
        ..info(
          yellow.wrap(
            '''

If you don't know why you're seeing this error, visit our troubleshooting page at ${troubleshootingUrl.toLink()}''',
          ),
        );

      if (!allowNativeChanges) {
        if (!shorebirdEnv.canAcceptUserInput) {
          throw UnpatchableChangeException();
        }

        if (!logger.confirm('Continue anyway?')) {
          throw UserCancelledException();
        }
      }
    }

    if (status.hasAssetChanges) {
      logger
        ..warn(
          '''Your app contains asset changes, which will not be included in the patch.''',
        )
        ..info(
          yellow.wrap(
            archiveDiffer.assetsFileSetDiff(contentDiffs).prettyString,
          ),
        );

      // Save asset diff files
      await _saveAssetDiffs(
        releaseArchive: releaseArchive,
        localArchive: localArchive,
        archiveDiffer: archiveDiffer,
        contentDiffs: contentDiffs,
      );

      if (!allowAssetChanges) {
        if (!shorebirdEnv.canAcceptUserInput) {
          throw UnpatchableChangeException();
        }

        if (!logger.confirm('Continue anyway?')) {
          throw UserCancelledException();
        }
      }
    }

    return status;
  }

  /// Saves asset diff files to disk for detailed inspection.
  Future<void> _saveAssetDiffs({
    required File releaseArchive,
    required File localArchive,
    required ArchiveDiffer archiveDiffer,
    required FileSetDiff contentDiffs,
  }) async {
    final assetDiffs = archiveDiffer.assetsFileSetDiff(contentDiffs);
    if (assetDiffs.isEmpty) return;

    // Create output directory in project root
    final projectRoot = shorebirdEnv.getShorebirdProjectRoot();
    if (projectRoot == null) return;

    final outputDir = Directory(
      p.join(projectRoot.path, '.shorebird', 'asset_diffs'),
    );
    if (outputDir.existsSync()) {
      await outputDir.delete(recursive: true);
    }
    await outputDir.create(recursive: true);

    // Extract asset contents from both archives
    final releaseAssets = await archiveDiffer.extractAssetContents(
      releaseArchive,
    );
    final localAssets = await archiveDiffer.extractAssetContents(localArchive);

    // Create simple list of changed asset files
    final changedAssetsFile = File(
      p.join(outputDir.path, 'changed_assets.txt'),
    );
    final changedAssetsList = <String>[];

    // Create detailed summary file
    final summaryFile = File(
      p.join(outputDir.path, 'asset_changes_summary.txt'),
    );
    final summaryBuffer = StringBuffer()
      ..writeln('Asset File Changes Summary')
      ..writeln('Generated: ${DateTime.now().toIso8601String()}')
      ..writeln('Release Archive: ${releaseArchive.path}')
      ..writeln('Patch Archive: ${localArchive.path}')
      ..writeln('=' * 60)
      ..writeln();

    var totalChanges = 0;

    // Process added files
    if (assetDiffs.addedPaths.isNotEmpty) {
      summaryBuffer.writeln('ADDED FILES (${assetDiffs.addedPaths.length}):');
      for (final assetPath in assetDiffs.addedPaths) {
        changedAssetsList.add('ADDED: $assetPath');
        final sanitizedName = _sanitizeFileName(assetPath);
        final content = localAssets[assetPath];
        if (content != null) {
          // Create directory for this asset
          final assetDir = Directory(p.join(outputDir.path, sanitizedName));
          await assetDir.create(recursive: true);

          // Save the new file
          final newFile = File(p.join(assetDir.path, 'new'));
          await newFile.writeAsBytes(content);

          summaryBuffer.writeln(
            '  $assetPath (${content.length} bytes) -> ${assetDir.path}',
          );
          totalChanges++;
        }
      }
      summaryBuffer.writeln();
    }

    // Process changed files
    if (assetDiffs.changedPaths.isNotEmpty) {
      summaryBuffer.writeln(
        'CHANGED FILES (${assetDiffs.changedPaths.length}):',
      );
      for (final assetPath in assetDiffs.changedPaths) {
        changedAssetsList.add('CHANGED: $assetPath');
        final sanitizedName = _sanitizeFileName(assetPath);
        final oldContent = releaseAssets[assetPath];
        final newContent = localAssets[assetPath];

        if (oldContent != null && newContent != null) {
          // Create directory for this asset
          final assetDir = Directory(p.join(outputDir.path, sanitizedName));
          await assetDir.create(recursive: true);

          // Save both old and new versions
          final oldFile = File(p.join(assetDir.path, 'old'));
          final newFile = File(p.join(assetDir.path, 'new'));
          await oldFile.writeAsBytes(oldContent);
          await newFile.writeAsBytes(newContent);

          // Generate diff file
          final diffFile = File(p.join(assetDir.path, 'diff.txt'));
          await _generateDiffFile(
            oldFile: oldFile,
            newFile: newFile,
            diffFile: diffFile,
            assetPath: assetPath,
          );

          summaryBuffer
            ..writeln(
              '  $assetPath '
              '(${oldContent.length} -> ${newContent.length} bytes)',
            )
            ..writeln('    Directory: ${assetDir.path}')
            ..writeln('    Files: old, new, diff.txt');
          totalChanges++;
        }
      }
      summaryBuffer.writeln();
    }

    // Process removed files
    if (assetDiffs.removedPaths.isNotEmpty) {
      summaryBuffer.writeln(
        'REMOVED FILES (${assetDiffs.removedPaths.length}):',
      );
      for (final assetPath in assetDiffs.removedPaths) {
        changedAssetsList.add('REMOVED: $assetPath');
        final sanitizedName = _sanitizeFileName(assetPath);
        final content = releaseAssets[assetPath];
        if (content != null) {
          // Create directory for this asset
          final assetDir = Directory(p.join(outputDir.path, sanitizedName));
          await assetDir.create(recursive: true);

          // Save the old file
          final oldFile = File(p.join(assetDir.path, 'old'));
          await oldFile.writeAsBytes(content);

          summaryBuffer.writeln(
            '  $assetPath (${content.length} bytes) -> ${assetDir.path}',
          );
          totalChanges++;
        }
      }
      summaryBuffer.writeln();
    }

    summaryBuffer
      ..writeln('Total asset changes: $totalChanges')
      ..writeln()
      ..writeln('Files saved to: ${outputDir.path}');

    // Write the simple list of changed assets
    await changedAssetsFile.writeAsString(changedAssetsList.join('\n'));

    // Write the detailed summary
    await summaryFile.writeAsString(summaryBuffer.toString());

    logger.info(
      '''
📁 Asset diff files saved to: ${outputDir.path}
   📋 Changed assets list: ${changedAssetsFile.path}
   📊 Detailed summary: ${summaryFile.path}
   📂 Asset directories: Each changed asset has its own directory with:
      - old: Original file content
      - new: Updated file content  
      - diff.txt: Line-by-line changes
   Use these files to review exact changes in your assets.''',
    );
  }

  /// Sanitizes a file path to be safe for use as a filename.
  String _sanitizeFileName(String filePath) {
    return filePath
        .replaceAll('/', '_')
        .replaceAll(r'\', '_')
        .replaceAll(':', '_')
        .replaceAll(' ', '_')
        .replaceAll('<', '_')
        .replaceAll('>', '_')
        .replaceAll('|', '_')
        .replaceAll('?', '_')
        .replaceAll('*', '_')
        .replaceAll('"', '_');
  }

  /// Generates a diff file comparing two asset files.
  Future<void> _generateDiffFile({
    required File oldFile,
    required File newFile,
    required File diffFile,
    required String assetPath,
  }) async {
    final diffBuffer = StringBuffer()
      ..writeln('Asset File Diff: $assetPath')
      ..writeln('Generated: ${DateTime.now().toIso8601String()}')
      ..writeln('Old file: ${oldFile.path}')
      ..writeln('New file: ${newFile.path}')
      ..writeln('=' * 60)
      ..writeln();

    try {
      // Check if files are text-based for readable diff
      if (_isTextFile(assetPath)) {
        final oldLines = await oldFile.readAsLines();
        final newLines = await newFile.readAsLines();

        // Generate unified diff
        final diff = _generateUnifiedDiff(oldLines, newLines, assetPath);
        diffBuffer.write(diff);
      } else {
        // For binary files, just show size comparison
        final oldSize = await oldFile.length();
        final newSize = await newFile.length();

        diffBuffer
          ..writeln('Binary file comparison:')
          ..writeln('Old size: $oldSize bytes')
          ..writeln('New size: $newSize bytes')
          ..writeln('Size change: ${newSize - oldSize} bytes');

        if (oldSize != newSize) {
          diffBuffer.writeln(
            'Binary content differs (files have different sizes)',
          );
        } else {
          // Same size, but content might still differ
          final oldBytes = await oldFile.readAsBytes();
          final newBytes = await newFile.readAsBytes();
          var identical = true;
          for (var i = 0; i < oldBytes.length; i++) {
            if (oldBytes[i] != newBytes[i]) {
              identical = false;
              break;
            }
          }
          diffBuffer.writeln(
            identical
                ? 'Binary content is identical'
                : 'Binary content differs (same size, different content)',
          );
        }
      }
    } on Exception catch (e) {
      diffBuffer.writeln('Error generating diff: $e');
    }

    await diffFile.writeAsString(diffBuffer.toString());
  }

  /// Checks if a file is likely to be text-based for readable diffs.
  bool _isTextFile(String filePath) {
    final extension = p.extension(filePath).toLowerCase();
    const textExtensions = {
      '.txt',
      '.json',
      '.xml',
      '.yaml',
      '.yml',
      '.md',
      '.html',
      '.css',
      '.js',
      '.dart',
      '.java',
      '.kt',
      '.swift',
      '.m',
      '.h',
      '.cpp',
      '.c',
      '.properties',
      '.gradle',
      '.plist',
      '.strings',
      '.arb',
    };
    return textExtensions.contains(extension);
  }

  /// Generates a unified diff between two sets of lines.
  String _generateUnifiedDiff(
    List<String> oldLines,
    List<String> newLines,
    String fileName,
  ) {
    final buffer = StringBuffer()
      ..writeln('--- $fileName (old)')
      ..writeln('+++ $fileName (new)');

    // Simple line-by-line diff (not a full LCS algorithm,
    // but sufficient for most cases)

    var oldIndex = 0;
    var newIndex = 0;

    while (oldIndex < oldLines.length || newIndex < newLines.length) {
      if (oldIndex >= oldLines.length) {
        // Only new lines remain
        buffer.writeln('+${newLines[newIndex]}');
        newIndex++;
      } else if (newIndex >= newLines.length) {
        // Only old lines remain
        buffer.writeln('-${oldLines[oldIndex]}');
        oldIndex++;
      } else if (oldLines[oldIndex] == newLines[newIndex]) {
        // Lines are the same
        buffer.writeln(' ${oldLines[oldIndex]}');
        oldIndex++;
        newIndex++;
      } else {
        // Lines differ - show both
        buffer
          ..writeln('-${oldLines[oldIndex]}')
          ..writeln('+${newLines[newIndex]}');
        oldIndex++;
        newIndex++;
      }
    }

    return buffer.toString();
  }
}
