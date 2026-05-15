/// Adapter contract for OCR (images) and embedded-text extraction (PDFs).
/// Concrete implementations live under `services/import/android/` (and later
/// `ios/`, `web/`). The pipeline never imports a concrete implementation.
library;

import 'dart:typed_data';
import 'dart:ui' show Rect;

class TextBlock {
  final String text;
  final Rect? bbox;
  final int? pageIndex;

  const TextBlock({required this.text, this.bbox, this.pageIndex});
}

enum ExtractionSource { mlkit, syncfusion, ocrPdf, mock }

class ExtractedText {
  final String fullText;
  final List<TextBlock> blocks;
  final ExtractionSource source;

  const ExtractedText({
    required this.fullText,
    required this.blocks,
    required this.source,
  });
}

/// Thrown by [TextExtractor.extractFromPdf] when the PDF has no embedded
/// text layer (image-only / scanned). The caller decides whether to OCR
/// each rendered page; v1 rejects with a user-facing message.
class NoTextLayerException implements Exception {
  final String message;
  const NoTextLayerException([this.message = 'PDF has no readable text']);

  @override
  String toString() => 'NoTextLayerException: $message';
}

abstract class TextExtractor {
  /// OCR'd text from a raster image (PNG/JPEG). Returns bounding boxes when
  /// the underlying engine supplies them.
  Future<ExtractedText> extractFromImage(Uint8List bytes);

  /// Embedded text layer from a PDF. Throws [NoTextLayerException] if the
  /// PDF is image-only.
  Future<ExtractedText> extractFromPdf(Uint8List bytes);
}
