# QuickNote local voice refinement

Model: SenseVoiceSmall, quantized ONNX conversion by the sherpa-onnx project.
Original authors: FunAudioLLM / Alibaba Group.

- Original model: https://huggingface.co/FunAudioLLM/SenseVoiceSmall
- Conversion: https://github.com/k2-fsa/sherpa-onnx/releases/tag/asr-models
- Archive: sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17.tar.bz2
- Archive SHA-256: 7d1efa2138a65b0b488df37f8b89e3d91a60676e416f515b952358d83dfd347e
- Runtime: sherpa-onnx 1.13.7; ONNX Runtime 1.28.1, pinned by Swift Package Manager.

The model weights have their own MODEL_LICENSE; do not conflate this with
the sherpa-onnx Apache-2.0 or ONNX Runtime MIT code licenses. Preserve these
notices when distributing the application. Review the model license before
public/commercial release; this integration is not a legal clearance.

Run `bash scripts/prepare-offline-speech.sh` before building. The model binaries
are not committed to Git. Audio is processed in memory, never written or uploaded.
