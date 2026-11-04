/// Version information shared by generated code and the worker manifest.
library;

/// The version of `dwi_builder` that produced an artefact.
const String dwiBuilderVersion = '0.3.0';

/// The worker-manifest schema version. Bumped when the JSON shape changes.
const int dwiWorkerManifestProtocol = 1;

/// The default served worker path used by `DwiConfig`.
const String dwiDefaultWorkerScript = 'dwi/worker.dart.js';
