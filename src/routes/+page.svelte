<script lang="ts">
  import { invoke } from '@tauri-apps/api/core';
  import { listen } from '@tauri-apps/api/event';
  import { onMount } from 'svelte';
  import { writeText } from '@tauri-apps/plugin-clipboard-manager';
  // libflac.js is a self-contained UMD/asm.js module — import it directly to
  // avoid Vite choking on the CJS require() calls inside the lib/ utilities.
  // @ts-ignore
  import Flac from 'libflacjs/dist/libflac.js';

  // ── Types ──────────────────────────────────────────────────────────────────

  type AppState = 'idle' | 'requesting-mic' | 'recording' | 'transcribing' | 'done' | 'error';
  type PasteMode = 'normal' | 'plain';

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

    // Listen for F8 global shortcut emitted from Rust.
    await listen<{ pasteMode?: PasteMode }>('shortcut-pressed', (event) => {
      const pasteMode: PasteMode = event.payload?.pasteMode ?? 'normal';
      if (appState === 'recording') {
        stopAndTranscribe(pasteMode);
      } else if (appState === 'done' || appState === 'error') {
        recordAgain();
      }
    });

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

  async function stopAndTranscribe(pasteMode: PasteMode = 'normal') {
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

      // Copy transcript to clipboard.
      await writeText(transcript);

      // Paste transcript into the current active app window.
      await invoke('paste_active_window', { mode: pasteMode });

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
  {#if appState === 'idle'}
    <p class="status">Initialising…</p>

  {:else if appState === 'requesting-mic'}
    <p class="status">Requesting microphone…</p>

  {:else if appState === 'recording'}
    <div class="indicator">
      <span class="dot"></span>
      <span class="time">{formatTime(elapsedSeconds)}</span>
    </div>
    <button onclick={() => stopAndTranscribe('normal')}>Transcribe <kbd>F8</kbd></button>

  {:else if appState === 'transcribing'}
    <p class="status">Transcribing…</p>

  {:else if appState === 'done'}
    <div class="copied">
      <svg width="16" height="16" viewBox="0 0 16 16" fill="none">
        <path d="M2.5 8.5L6.5 12.5L13.5 4" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"/>
      </svg>
      Copied to clipboard
    </div>
    <button onclick={recordAgain}>Again <kbd>F8</kbd></button>

  {:else if appState === 'error'}
    <p class="error">{errorMsg}</p>
    <button onclick={recordAgain}>Retry <kbd>F8</kbd></button>
  {/if}
</main>

<style>
  :root {
    font-family: 'SF Mono', 'Geist Mono', 'Fira Code', ui-monospace, monospace;
    font-size: 13px;
    line-height: 1.4;
    color: #e2e2e2;
  }

  :global(html),
  :global(body) {
    background: transparent !important;
    margin: 0;
    padding: 0;
  }

  * {
    box-sizing: border-box;
    margin: 0;
    padding: 0;
  }

  main {
    display: flex;
    flex-direction: row;
    align-items: center;
    justify-content: center;
    gap: 1.25rem;
    width: 400px;
    height: 120px;
    padding: 0 1.5rem;
    background: #111111;
    border-radius: 16px;
    border: 1px solid rgba(255, 255, 255, 0.08);
    box-shadow:
      0 8px 32px rgba(0, 0, 0, 0.6),
      0 2px 8px rgba(0, 0, 0, 0.4),
      inset 0 1px 0 rgba(255, 255, 255, 0.06);
    overflow: hidden;
  }

  .status {
    color: #555;
    font-size: 0.85rem;
    letter-spacing: 0.03em;
  }

  /* Recording indicator */
  .indicator {
    display: flex;
    align-items: center;
    gap: 0.6rem;
  }

  .dot {
    width: 8px;
    height: 8px;
    border-radius: 50%;
    background: #e03c3c;
    animation: pulse 1.2s ease-in-out infinite;
    flex-shrink: 0;
  }

  .time {
    font-variant-numeric: tabular-nums;
    font-size: 1.1rem;
    font-weight: 500;
    color: #e2e2e2;
    letter-spacing: 0.05em;
  }

  @keyframes pulse {
    0%, 100% { opacity: 1; box-shadow: 0 0 0 0 rgba(224, 60, 60, 0.4); }
    50%       { opacity: 0.5; box-shadow: 0 0 0 4px rgba(224, 60, 60, 0); }
  }

  /* Copied confirmation */
  .copied {
    display: flex;
    align-items: center;
    gap: 0.5rem;
    color: #4ade80;
    font-size: 0.85rem;
    letter-spacing: 0.03em;
  }

  .error {
    color: #f87171;
    font-size: 0.78rem;
    max-width: 220px;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  button {
    display: flex;
    align-items: center;
    gap: 0.45rem;
    padding: 0.4rem 0.9rem;
    border: 1px solid rgba(255, 255, 255, 0.1);
    border-radius: 8px;
    background: rgba(255, 255, 255, 0.05);
    color: #c0c0c0;
    font-family: inherit;
    font-size: 0.82rem;
    cursor: pointer;
    transition: background 0.12s, border-color 0.12s, color 0.12s;
    white-space: nowrap;
  }

  button:hover {
    background: rgba(255, 255, 255, 0.1);
    border-color: rgba(255, 255, 255, 0.18);
    color: #e2e2e2;
  }

  button:active {
    background: rgba(255, 255, 255, 0.14);
  }

  kbd {
    display: inline-block;
    padding: 0.1rem 0.3rem;
    border: 1px solid rgba(255, 255, 255, 0.15);
    border-bottom-width: 2px;
    border-radius: 4px;
    background: rgba(255, 255, 255, 0.06);
    font-family: inherit;
    font-size: 0.72rem;
    color: #777;
    line-height: 1.4;
  }
</style>
