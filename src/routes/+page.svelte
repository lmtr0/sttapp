<script lang="ts">
  import { invoke } from '@tauri-apps/api/core';
  import { onMount } from 'svelte';
  // libflac.js is a self-contained UMD/asm.js module — import it directly to
  // avoid Vite choking on the CJS require() calls inside the lib/ utilities.
  // @ts-ignore
  import Flac from 'libflacjs/dist/libflac.js';

  // ── Types ──────────────────────────────────────────────────────────────────

  type AppState = 'idle' | 'requesting-mic' | 'recording' | 'transcribing' | 'done' | 'error';

  interface Config {
    apiKey: string;
    baseUrl: string;
    model: string;
  }

  // ── State ──────────────────────────────────────────────────────────────────

  let appState = $state<AppState>('idle');
  let transcript = $state('');
  let errorMsg = $state('');
  let elapsedSeconds = $state(0);

  // ── Audio capture internals (not reactive — only touched in functions) ─────

  let config: Config | null = null;
  let audioContext: AudioContext | null = null;
  let workletNode: AudioWorkletNode | null = null;
  let sourceNode: MediaStreamAudioSourceNode | null = null;
  let mediaStream: MediaStream | null = null;
  let timerInterval: ReturnType<typeof setInterval> | null = null;

  // Accumulated raw PCM chunks from the AudioWorklet.
  const chunks: Float32Array[] = [];

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  onMount(async () => {
    config = await invoke<Config>('get_config');
    await startRecording();
  });

  // ── Recording ──────────────────────────────────────────────────────────────

  async function startRecording() {
    appState = 'requesting-mic';
    chunks.length = 0;
    elapsedSeconds = 0;

    try {
      mediaStream = await navigator.mediaDevices.getUserMedia({ audio: true, video: false });

      audioContext = new AudioContext({ sampleRate: 16000 });

      await audioContext.audioWorklet.addModule('/audio-processor.worklet.js');

      sourceNode = audioContext.createMediaStreamSource(mediaStream);
      workletNode = new AudioWorkletNode(audioContext, 'audio-capture-processor');

      workletNode.port.onmessage = (e: MessageEvent<Float32Array>) => {
        chunks.push(e.data);
      };

      // Connect graph: source → worklet → destination.
      // The destination connection is required to keep the graph active;
      // the worklet writes silence to its output so no audio plays back.
      sourceNode.connect(workletNode);
      workletNode.connect(audioContext.destination);

      appState = 'recording';
      timerInterval = setInterval(() => elapsedSeconds++, 1000);
    } catch (err) {
      appState = 'error';
      errorMsg = `Microphone error: ${String(err)}`;
    }
  }

  // ── Transcription ──────────────────────────────────────────────────────────

  async function stopAndTranscribe() {
    if (appState !== 'recording') return;
    appState = 'transcribing';

    if (timerInterval) {
      clearInterval(timerInterval);
      timerInterval = null;
    }

    // Stop the audio graph.
    workletNode?.port.postMessage('stop');
    sourceNode?.disconnect();
    workletNode?.disconnect();
    mediaStream?.getAudioTracks().forEach((t) => t.stop());

    // Capture the actual sample rate before closing the context.
    const sampleRate = audioContext?.sampleRate ?? 16000;
    await audioContext?.close();
    audioContext = null;

    try {
      // ── FLAC encoding (raw libflac.js API) ──────────────────────────────
      // The asm.js variant initialises synchronously, but guard against async
      // variants just in case.
      if (!Flac.isReady()) {
        await new Promise<void>((resolve) => Flac.on('ready', () => resolve()));
      }

      // Collect encoded FLAC bytes from the write callback.
      const encChunks: Uint8Array[] = [];
      const writeCallback = (buffer: Uint8Array) => {
        // libflac.js reuses the buffer — copy it before storing.
        encChunks.push(new Uint8Array(buffer));
      };

      const encoderId: number = Flac.create_libflac_encoder(
        sampleRate,
        1,     // channels (mono)
        16,    // bits per sample
        5,     // compression level (0–8)
        0,     // total_samples — unknown upfront
        false, // verify
        0,     // block_size — use default
      );
      if (encoderId === 0) throw new Error('Failed to create FLAC encoder');

      const initStatus: number = Flac.init_encoder_stream(encoderId, writeCallback);
      if (initStatus !== 0) throw new Error(`FLAC encoder init failed (status ${initStatus})`);

      // Convert each Float32 chunk → Int32 and feed to the encoder.
      // FLAC expects signed 16-bit values packed into 32-bit integers (little-endian).
      for (const chunk of chunks) {
        const int32 = new Int32Array(chunk.length);
        const view = new DataView(int32.buffer);
        for (let i = 0; i < chunk.length; i++) {
          view.setInt32(i * 4, chunk[i] * 0x7fff, true);
        }
        const ok: boolean = Flac.FLAC__stream_encoder_process_interleaved(
          encoderId,
          int32,
          chunk.length, // samples per channel (mono → same as total samples)
        );
        if (!ok) throw new Error('FLAC__stream_encoder_process_interleaved failed');
      }

      Flac.FLAC__stream_encoder_finish(encoderId);
      Flac.FLAC__stream_encoder_delete(encoderId);

      // Merge all encoded chunks into a single Uint8Array and wrap as a Blob.
      const totalBytes = encChunks.reduce((n, c) => n + c.byteLength, 0);
      const merged = new Uint8Array(totalBytes);
      let offset = 0;
      for (const c of encChunks) {
        merged.set(c, offset);
        offset += c.byteLength;
      }
      const flacBlob = new Blob([merged], { type: 'audio/flac' });

      // ── API call ─────────────────────────────────────────────────────────
      const formData = new FormData();
      formData.append('file', flacBlob, 'audio.flac');
      formData.append('model', config!.model);

      const response = await fetch(`${config!.baseUrl}/audio/transcriptions`, {
        method: 'POST',
        headers: { Authorization: `Bearer ${config!.apiKey}` },
        body: formData,
      });

      if (!response.ok) {
        const body = await response.text();
        throw new Error(`API ${response.status}: ${body}`);
      }

      const json = await response.json();
      // OpenAI and Groq both return { text: "..." }
      transcript = json.text ?? json.transcript ?? JSON.stringify(json);

      // Print to the terminal where the app was launched from.
      await invoke('print_to_stdout', { text: transcript });

      appState = 'done';
    } catch (err) {
      appState = 'error';
      errorMsg = String(err);
    }
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  async function recordAgain() {
    transcript = '';
    errorMsg = '';
    await startRecording();
  }

  function formatTime(s: number): string {
    const m = Math.floor(s / 60).toString().padStart(2, '0');
    const sec = (s % 60).toString().padStart(2, '0');
    return `${m}:${sec}`;
  }
</script>

<main>
  <h1>STT</h1>

  {#if appState === 'idle'}
    <p class="status">Initialising…</p>

  {:else if appState === 'requesting-mic'}
    <p class="status">Requesting microphone…</p>

  {:else if appState === 'recording'}
    <div class="indicator">
      <span class="dot"></span>
      Recording — {formatTime(elapsedSeconds)}
    </div>
    <button onclick={stopAndTranscribe}>Transcribe</button>

  {:else if appState === 'transcribing'}
    <p class="status">Transcribing…</p>

  {:else if appState === 'done'}
    <div class="transcript">{transcript}</div>
    <button onclick={recordAgain}>Record again</button>

  {:else if appState === 'error'}
    <p class="error">{errorMsg}</p>
    <button onclick={recordAgain}>Try again</button>
  {/if}
</main>

<style>
  :root {
    font-family: Inter, system-ui, sans-serif;
    font-size: 15px;
    line-height: 1.5;
    background: #0d0d0d;
    color: #e8e8e8;
  }

  main {
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    min-height: 100vh;
    gap: 1.5rem;
    padding: 2rem;
    box-sizing: border-box;
  }

  h1 {
    font-size: 1.1rem;
    font-weight: 600;
    letter-spacing: 0.15em;
    text-transform: uppercase;
    color: #555;
    margin: 0;
  }

  .status {
    color: #555;
    margin: 0;
  }

  /* Recording indicator */
  .indicator {
    display: flex;
    align-items: center;
    gap: 0.6rem;
    font-variant-numeric: tabular-nums;
    font-size: 1rem;
    color: #e8e8e8;
  }

  .dot {
    width: 10px;
    height: 10px;
    border-radius: 50%;
    background: #e03c3c;
    animation: pulse 1.2s ease-in-out infinite;
    flex-shrink: 0;
  }

  @keyframes pulse {
    0%, 100% { opacity: 1; }
    50%       { opacity: 0.25; }
  }

  /* Transcript output */
  .transcript {
    max-width: 560px;
    width: 100%;
    background: #1a1a1a;
    border: 1px solid #2a2a2a;
    border-radius: 8px;
    padding: 1rem 1.2rem;
    white-space: pre-wrap;
    word-break: break-word;
    font-size: 0.95rem;
    line-height: 1.6;
    color: #d4d4d4;
  }

  .error {
    color: #e05252;
    max-width: 480px;
    text-align: center;
    font-size: 0.875rem;
    margin: 0;
  }

  button {
    padding: 0.55rem 1.4rem;
    border: 1px solid #333;
    border-radius: 6px;
    background: #1a1a1a;
    color: #e8e8e8;
    font-size: 0.9rem;
    cursor: pointer;
    transition: background 0.15s, border-color 0.15s;
  }

  button:hover {
    background: #242424;
    border-color: #444;
  }

  button:active {
    background: #2e2e2e;
  }
</style>
