# dwi_protocol

Wire envelopes, message types and error payloads for DWI integrations.

Add `dwi_protocol` to build or inspect wire messages. For app tasks use
[dwi](https://pub.dev/packages/dwi).

Run `dart run example/dwi_protocol_example.dart` from the checkout to
encode and decode a request and an error. The advanced example correlates
a success response with its request ID. Keep the envelope version, type and
ID intact when relaying a message. Consult the API reference for lifecycle,
stream and channel message types. An envelope represents a message.
Sending it and settling the corresponding call are backend responsibilities.

[Advanced example source](https://github.com/SoundSliced/dart-web-isolates/tree/main/packages/dwi_protocol/example/dwi_protocol_advanced.dart)

[Source and issue tracker](https://github.com/SoundSliced/dart-web-isolates)
