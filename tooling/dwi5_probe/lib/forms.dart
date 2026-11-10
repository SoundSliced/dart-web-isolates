// The six DWI-5 function forms, written as a consumer might write them.
// Nothing here is supported public API; `Dwi.run` is a stub.
import 'dwi_stub.dart';

int addOne(int x) => x + 1;

class MathOps {
  static int twice(int x) => x * 2;

  int triple(int x) => x * 3;
}

class Connection {
  Object? socket;
}

void cases(bool flag, Connection connection, MathOps ops) {
  final int offset = 3;
  final int Function(int) chosen = flag ? addOne : MathOps.twice;

  // 1. Static top-level function reference.
  Dwi.run<int>(addOne, 1);

  // 2. Static method reference.
  Dwi.run<int>(MathOps.twice, 2);

  // 3. Closure with a serializable capture.
  Dwi.run<int>((int x) => x + offset, 3);

  // 4. Closure with a non-serializable capture (an object graph).
  Dwi.run<int>((int x) => x + connection.hashCode, 4);

  // 5. Dynamically chosen function value.
  Dwi.run<int>(chosen, 5);

  // 6. Inline expression body.
  Dwi.run<int>(() {
    final int y = offset;
    return y + 1;
  }, 6);

  // Control: an instance method tear-off captures the receiver.
  Dwi.run<int>(ops.triple, 7);
}
