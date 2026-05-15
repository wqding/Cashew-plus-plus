/// Android implementation of [TextExtractor] for raster images (PNG/JPEG).
/// Uses Google ML Kit on-device text recognition — no network call required.
///
/// For PDFs use [SyncfusionPdfExtractor] instead.
library;

import 'dart:io';
import 'dart:math' show max;
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:budget/services/import/text_extractor.dart'
    as import_contract;
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:path_provider/path_provider.dart';

class MlkitTextExtractor implements import_contract.TextExtractor {
  @override
  Future<import_contract.ExtractedText> extractFromImage(
      Uint8List bytes) async {
    // ML Kit works best when reading from a file path.
    final tmpDir = await getTemporaryDirectory();
    final tmpFile = File(
        '${tmpDir.path}/mlkit_import_${DateTime.now().millisecondsSinceEpoch}.jpg');
    tmpFile.writeAsBytesSync(bytes);
    try {
      final inputImage = InputImage.fromFilePath(tmpFile.path);
      final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
      late final RecognizedText result;
      try {
        result = await recognizer.processImage(inputImage);
      } finally {
        recognizer.close();
      }

      final importBlocks = result.blocks
          .map((b) => import_contract.TextBlock(
                text: b.text,
                bbox: b.boundingBox != null
                    ? Rect.fromLTRB(
                        b.boundingBox!.left,
                        b.boundingBox!.top,
                        b.boundingBox!.right,
                        b.boundingBox!.bottom,
                      )
                    : null,
                pageIndex: 0,
              ))
          .toList();

      final fullText = _reconstructText(result.blocks);

      return import_contract.ExtractedText(
        fullText: fullText,
        blocks: importBlocks,
        source: import_contract.ExtractionSource.mlkit,
      );
    } finally {
      if (tmpFile.existsSync()) tmpFile.deleteSync();
    }
  }

  @override
  Future<import_contract.ExtractedText> extractFromPdf(Uint8List bytes) {
    throw const import_contract.NoTextLayerException(
      'MlkitTextExtractor does not support PDFs — use SyncfusionPdfExtractor.',
    );
  }

  /// Stitches ML Kit text blocks into lines ordered by vertical position.
  ///
  /// Lines within ~1.5× the median line height are grouped (§8.1 y-proximity
  /// rule). Within a group, elements are ordered left-to-right.
  String _reconstructText(List<TextBlock> blocks) {
    final lineElements = <_LineElement>[];
    for (final block in blocks) {
      for (final line in block.lines) {
        final bb = line.boundingBox;
        final centerY = bb != null ? (bb.top + bb.bottom) / 2.0 : 0.0;
        final height = bb != null ? (bb.bottom - bb.top).toDouble() : 20.0;
        lineElements.add(_LineElement(
          text: line.text,
          centerY: centerY,
          height: height,
          left: bb?.left ?? 0.0,
        ));
      }
    }

    if (lineElements.isEmpty) return '';

    lineElements.sort((a, b) {
      final yDiff = a.centerY.compareTo(b.centerY);
      return yDiff != 0 ? yDiff : a.left.compareTo(b.left);
    });

    final heights = lineElements.map((e) => e.height).toList()..sort();
    final medianHeight = heights[heights.length ~/ 2];
    final groupTolerance = max(medianHeight * 1.5, 10.0);

    final groups = <List<_LineElement>>[];
    List<_LineElement>? current;
    double? groupY;

    for (final el in lineElements) {
      if (current == null || (el.centerY - groupY!).abs() > groupTolerance) {
        current = [el];
        groupY = el.centerY;
        groups.add(current);
      } else {
        current.add(el);
        groupY = (groupY! + el.centerY) / 2.0;
      }
    }

    final buffer = StringBuffer();
    for (final group in groups) {
      group.sort((a, b) => a.left.compareTo(b.left));
      buffer.writeln(group.map((e) => e.text).join('  '));
    }
    return buffer.toString().trimRight();
  }
}

class _LineElement {
  final String text;
  final double centerY;
  final double height;
  final double left;
  const _LineElement({
    required this.text,
    required this.centerY,
    required this.height,
    required this.left,
  });
}
