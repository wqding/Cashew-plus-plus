/// Android implementation of [TextExtractor] for text-native PDF files.
/// Uses Syncfusion Flutter PDF (community license) to extract the embedded
/// text layer. Throws [NoTextLayerException] if no text is found (scanned PDF).
///
/// For images use [MlkitTextExtractor] instead.
library;

import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:budget/services/import/text_extractor.dart'
    as import_contract;
import 'package:syncfusion_flutter_pdf/pdf.dart';

class SyncfusionPdfExtractor implements import_contract.TextExtractor {
  @override
  Future<import_contract.ExtractedText> extractFromImage(Uint8List bytes) {
    throw const import_contract.NoTextLayerException(
      'SyncfusionPdfExtractor only handles PDFs — use MlkitTextExtractor for images.',
    );
  }

  @override
  Future<import_contract.ExtractedText> extractFromPdf(
      Uint8List bytes) async {
    final document = PdfDocument(inputBytes: bytes);
    try {
      final allBlocks = <import_contract.TextBlock>[];
      final textBuffer = StringBuffer();
      bool anyTextFound = false;

      for (int pageIdx = 0;
          pageIdx < document.pages.count;
          pageIdx++) {
        final page = document.pages[pageIdx];
        final extractor = PdfTextExtractor(document);

        // Extract lines with bounds so ProfileInterpreter can do
        // column-level reconstruction if needed.
        final lines = extractor.extractTextLines(
          startPageIndex: pageIdx,
          endPageIndex: pageIdx,
        );

        if (lines.isEmpty) continue;

        for (final line in lines) {
          final text = line.text.trim();
          if (text.isEmpty) continue;
          anyTextFound = true;

          final b = line.bounds;
          allBlocks.add(import_contract.TextBlock(
            text: text,
            bbox: Rect.fromLTWH(b.left, b.top, b.width, b.height),
            pageIndex: pageIdx,
          ));
          textBuffer.writeln(text);
        }

        if (pageIdx < document.pages.count - 1) {
          // Page separator so section regexes don't span page boundaries.
          textBuffer.writeln('--- PAGE ${pageIdx + 2} ---');
        }
      }

      if (!anyTextFound) {
        throw const import_contract.NoTextLayerException(
          'This PDF appears to be image-only (scanned). '
          'Re-export as a text PDF or screenshot each page.',
        );
      }

      return import_contract.ExtractedText(
        fullText: textBuffer.toString(),
        blocks: allBlocks,
        source: import_contract.ExtractionSource.syncfusion,
      );
    } finally {
      document.dispose();
    }
  }
}
