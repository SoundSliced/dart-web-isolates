import 'package:flutter/material.dart';

// This import is the point of the case: it is a compile-time dependency on a
// file that only exists after the build hook has run.
import 'dwi_tasks.g.dart';

void main() {
  runApp(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: FutureBuilder<int>(
            future: DwiTasks.countPrimes(1000),
            builder: (context, snapshot) =>
                Text('${snapshot.data ?? 'pending'}'),
          ),
        ),
      ),
    ),
  );
}
