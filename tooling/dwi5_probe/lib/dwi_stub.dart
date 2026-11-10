// A stub that stands in for the host facade. The probe never executes these
// calls; it only asks the analyzer what it can resolve at the call site.
abstract final class Dwi {
  static Future<T> run<T>(Object? function, Object? input) {
    throw UnsupportedError('probe only');
  }
}
