/// Not annotated. Called only by an annotated task, so it must be kept.
String transitiveTop(String x) => _deepest(x);

String _deepest(String x) => '$x SENT_TRANSITIVE_c4a';
