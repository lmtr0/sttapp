import 'package:sttapp/services/config_repository.dart';
import 'package:sttapp/services/hosted_backend_client.dart';
import 'package:sttapp/services/transcription_service.dart';
import 'package:sttapp_audio/sttapp_audio.dart';
import 'dart:typed_data';

final class TranscriptionCoordinator {
  const TranscriptionCoordinator({
    required this.manual,
    required this.hosted,
    required this.hostedSession,
  });

  final TranscriptionService manual;
  final HostedBackendClient hosted;
  final HostedSessionManager hostedSession;

  Future<String> transcribe({
    required AudioClip clip,
    required ProviderSetupState setup,
    required TranscriptionConfig manualConfig,
  }) async {
    final bytes = await clip.toFlacBytes();
    return transcribeFlacBytes(
      flacBytes: bytes,
      setup: setup,
      manualConfig: manualConfig,
    );
  }

  Future<String> transcribeFlacBytes({
    required Uint8List flacBytes,
    required ProviderSetupState setup,
    required TranscriptionConfig manualConfig,
  }) async {
    switch (setup.providerMode) {
      case TranscriptionProviderMode.manual:
        return manual.transcribeFlacBytes(flacBytes, manualConfig);
      case TranscriptionProviderMode.hosted:
        final model = setup.hostedModel;
        if (model == null || model.isEmpty) {
          throw const ConfigException('A hosted model is required.');
        }
        return hostedSession.authorized(
          (token) => hosted.transcribe(token, flacBytes, model),
        );
      case TranscriptionProviderMode.unset:
        throw const ConfigException('Choose a transcription provider.');
    }
  }
}
