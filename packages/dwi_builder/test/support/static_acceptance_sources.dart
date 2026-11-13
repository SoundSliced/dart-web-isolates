/// Sources stamped into the ADR-020 acceptance evidence, relative to
/// `packages/dwi_builder`.
///
/// Both acceptance tests hash every file here, so an evidence file identifies
/// the exact implementation, annotation contract and test suite it was run on.
const List<String> staticAcceptanceSources = <String>[
  '../dwi_annotations/lib/dwi_annotations.dart',
  'lib/src/descriptor.dart',
  'lib/src/discovery.dart',
  'lib/src/generator.dart',
  'test/browser_static_registry_test.dart',
  'test/build_test.dart',
  'test/discovery_test.dart',
  'test/generated_integration_test.dart',
  'test/generator_test.dart',
  'test/native_static_registry_test.dart',
  'test/support/browser_engines.dart',
  'test/support/browser_probe.dart',
  'test/support/fixture.dart',
  'test/support/static_acceptance_sources.dart',
];
