/**
 * AudioWorklet processor for capturing raw PCM samples from the microphone.
 * Runs on the dedicated audio rendering thread.
 * Sends Float32Array chunks to the main thread via this.port.
 */
class AudioCaptureProcessor extends AudioWorkletProcessor {
  constructor() {
    super();
    this._active = true;

    this.port.onmessage = ({ data }) => {
      if (data === 'stop') {
        this._active = false;
      }
    };
  }

  /**
   * Called by the browser for every 128-sample render quantum.
   * At 16 kHz, each call covers ~8 ms of audio.
   * Returns false to signal the node should be removed from the graph.
   */
  process(inputs) {
    if (!this._active) {
      return false;
    }

    const channel = inputs[0]?.[0];
    if (channel && channel.length > 0) {
      // Copy and transfer the buffer to avoid an extra allocation on the main thread.
      const copy = new Float32Array(channel);
      this.port.postMessage(copy, [copy.buffer]);
    }

    return true;
  }
}

registerProcessor('audio-capture-processor', AudioCaptureProcessor);
