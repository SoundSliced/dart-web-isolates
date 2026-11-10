// Tests whether known static Dart function values can be mapped to task IDs
// without serializing the function value across a worker boundary.
int addOne(int x) => x + 1;

class Ops {
  static int twice(int x) => x * 2;
}

void main() {
  final registered = <int Function(int), String>{
    addOne: 'addOne',
    Ops.twice: 'twice',
  };
  final candidates = <int Function(int)>[addOne, Ops.twice];
  for (final selected in candidates) {
    print('${registered[selected]}:${selected(2)}');
  }
}
