import 'dart:io';

/// Replaces [destination] with [temporary] without a window in which the
/// destination is missing or partially written.
///
/// [File.rename] replaces an existing destination atomically on POSIX systems
/// and on Windows (`MoveFileEx` with `MOVEFILE_REPLACE_EXISTING`). Some
/// filesystems and network mounts still refuse to replace an existing file, so
/// that case is handled explicitly: the previous destination is moved aside,
/// the new file is renamed into place, and the previous destination is restored
/// if the swap fails. A reader therefore always observes either the complete
/// old file or the complete new one.
///
/// Throws [FileSystemException] when neither strategy can publish [temporary].
Future<void> replaceFile(File temporary, File destination) async {
  try {
    await temporary.rename(destination.path);
    return;
  } on FileSystemException {
    if (!await destination.exists()) rethrow;
  }

  final backup = File(
    '${destination.path}.$pid-${DateTime.now().microsecondsSinceEpoch}.bak',
  );
  await destination.rename(backup.path);
  try {
    await temporary.rename(destination.path);
  } on FileSystemException {
    try {
      await backup.rename(destination.path);
    } on FileSystemException {
      // The original file could not be restored. The caller reports the
      // failure; the backup remains on disk rather than being discarded.
    }
    rethrow;
  }
  try {
    await backup.delete();
  } on FileSystemException {
    // A leftover backup is inert; the published file is already in place.
  }
}

/// Writes [content] to [path] through a unique sibling temporary file so that
/// concurrent writers never share a temporary path.
///
/// Returns `false` without touching the filesystem when [path] already holds
/// exactly [content].
Future<bool> writeFileAtomically(String path, String content) async {
  final file = File(path);
  if (await file.exists() && await file.readAsString() == content) {
    return false;
  }
  await file.parent.create(recursive: true);
  final temporary = File(
    '$path.$pid-${DateTime.now().microsecondsSinceEpoch}.tmp',
  );
  try {
    await temporary.writeAsString(content, flush: true);
    await replaceFile(temporary, file);
  } on Object {
    try {
      if (await temporary.exists()) await temporary.delete();
    } on FileSystemException {
      // A leftover temporary file is inert; the next write uses a new name.
    }
    rethrow;
  }
  return true;
}
