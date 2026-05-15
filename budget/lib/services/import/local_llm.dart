/// Adapter contract for the on-device LLM used as a fallback when the
/// deterministic profile-driven pipeline can't make progress (no matching
/// profile, validation failure, or one-shot extraction). All calls are
/// off the hot path — known formats never invoke the LLM.
library;

/// Cooperative cancellation token. Concrete LocalLlm impls check
/// [isCancelled] periodically between tokens and abort cleanly.
class CancellationToken {
  bool _cancelled = false;
  void cancel() => _cancelled = true;
  bool get isCancelled => _cancelled;
}

class LocalLlmException implements Exception {
  final String message;
  const LocalLlmException(this.message);
  @override
  String toString() => 'LocalLlmException: $message';
}

abstract class LocalLlm {
  /// True once the model file is present on disk and loaded into memory.
  Future<bool> isAvailable();

  /// Lazily loads the model. Safe to call repeatedly. `onProgress` reports
  /// a 0..1 progress value, useful for the first-load spinner.
  Future<void> ensureLoaded({void Function(double progress)? onProgress});

  /// Releases the model from memory (file stays on disk).
  Future<void> unload();

  /// Runs a single instruction. When [grammar] is non-null it must be a
  /// GBNF grammar string; the implementation constrains generation to that
  /// grammar (used to guarantee valid JSON for profile authoring/repair).
  ///
  /// Throws [LocalLlmException] on model errors or [CancellationToken]
  /// activation; throws [TimeoutException] if [timeout] elapses.
  Future<String> complete({
    required String prompt,
    String? grammar,
    int? maxTokens,
    Duration? timeout,
    CancellationToken? cancel,
  });
}
