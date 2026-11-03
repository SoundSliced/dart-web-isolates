/// Which concurrency mechanism a backend uses.
enum DwiBackendKind {
  isolate,
  worker,
  unsupported,
}

/// Runtime capabilities reported by the selected backend.
class DwiCapabilities {
  const DwiCapabilities({
    required this.backend,
    required this.protocolVersion,
    this.transferables = false,
    this.workerCount = 0,
  });

  final DwiBackendKind backend;
  final int protocolVersion;
  final bool transferables;
  final int workerCount;

  Map<String, Object?> toMap() => <String, Object?>{
        'backend': backend.name,
        'protocolVersion': protocolVersion,
        'transferables': transferables,
        'workerCount': workerCount,
      };
}
