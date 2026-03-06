<script lang="ts">
  import { emit } from '@tauri-apps/api/event';
  import { getCurrentWindow } from '@tauri-apps/api/window';
  import { onMount } from 'svelte';
  import {
    emptyConfig,
    hasValidConfig,
    loadInitialConfig,
    normalizeConfig,
    saveConfig,
    type AppConfig,
  } from '../../lib/config';

  // Preset models for the dropdown
  const PRESET_MODELS = [
    { value: 'whisper-1', label: 'whisper-1 (OpenAI)' },
    { value: 'whisper-large-v3', label: 'whisper-large-v3 (Groq)' },
    { value: 'whisper-large-v3-turbo', label: 'whisper-large-v3-turbo (Groq)' },
  ] as const;

  // State
  let config = $state<AppConfig>(emptyConfig());
  let loading = $state(true);
  let saving = $state(false);
  let showApiKey = $state(false);

  // Model selection state
  let selectedPreset = $state<string>('whisper-1');
  let useCustomModel = $state(false);
  let customModelValue = $state('');

  // Status message state
  let statusMessage = $state('');
  let statusType = $state<'success' | 'error' | ''>('');

  // Test connection state
  let testing = $state(false);
  let testResult = $state<{ success: boolean; message: string } | null>(null);

  onMount(async () => {
    try {
      config = await loadInitialConfig();
      initializeModelSelection(config.model);
    } catch (error) {
      showStatus(`Failed to load settings: ${String(error)}`, 'error');
    } finally {
      loading = false;
    }
  });

  function initializeModelSelection(model: string) {
    const preset = PRESET_MODELS.find((m) => m.value === model);
    if (preset) {
      selectedPreset = preset.value;
      useCustomModel = false;
      customModelValue = '';
    } else {
      selectedPreset = 'custom';
      useCustomModel = true;
      customModelValue = model;
    }
  }

  function handlePresetChange(event: Event) {
    const value = (event.target as HTMLSelectElement).value;
    selectedPreset = value;
    if (value === 'custom') {
      useCustomModel = true;
      customModelValue = config.model;
    } else {
      useCustomModel = false;
      config.model = value;
    }
    // Clear test result when config changes
    testResult = null;
  }

  function handleCustomModelChange(event: Event) {
    customModelValue = (event.target as HTMLInputElement).value;
    config.model = customModelValue;
    testResult = null;
  }

  function isFormValid(current: AppConfig): boolean {
    return hasValidConfig(current);
  }

  function showStatus(message: string, type: 'success' | 'error') {
    statusMessage = message;
    statusType = type;
  }

  function clearStatus() {
    statusMessage = '';
    statusType = '';
  }

  async function handleSave(event: SubmitEvent) {
    event.preventDefault();
    clearStatus();

    // Ensure model is set from custom input if using custom
    if (useCustomModel) {
      config.model = customModelValue;
    }

    const normalized = normalizeConfig(config);
    if (!isFormValid(normalized)) {
      showStatus('Please fill in all required fields.', 'error');
      return;
    }

    saving = true;
    try {
      await saveConfig(normalized);
      config = normalized;
      showStatus('Settings saved', 'success');
      await emit('config-updated');
    } catch (error) {
      showStatus(`Failed to save: ${String(error)}`, 'error');
    } finally {
      saving = false;
    }
  }

  async function testConnection() {
    // Ensure model is set from custom input if using custom
    if (useCustomModel) {
      config.model = customModelValue;
    }

    const normalized = normalizeConfig(config);
    if (!normalized.apiKey || !normalized.baseUrl) {
      testResult = { success: false, message: 'API key and base URL required' };
      return;
    }

    testing = true;
    testResult = null;
    clearStatus();

    try {
      const response = await fetch(`${normalized.baseUrl}/models`, {
        method: 'GET',
        headers: { Authorization: `Bearer ${normalized.apiKey}` },
      });

      if (response.ok) {
        testResult = { success: true, message: 'Connection successful' };
      } else {
        const status = response.status;
        let errorMsg = `HTTP ${status}`;
        if (status === 401) errorMsg = 'Invalid API key';
        else if (status === 403) errorMsg = 'Access forbidden';
        else if (status === 404) errorMsg = 'Endpoint not found';
        testResult = { success: false, message: errorMsg };
      }
    } catch (err) {
      const errStr = String(err);
      if (errStr.includes('fetch')) {
        testResult = { success: false, message: 'Network error' };
      } else {
        testResult = { success: false, message: errStr };
      }
    } finally {
      testing = false;
    }
  }

  async function closeWindow() {
    await getCurrentWindow().close();
  }

  // Track config changes to clear test result
  function handleConfigChange() {
    testResult = null;
  }
</script>

<div class="container">
  <header>
    <h1>Settings</h1>
    <button class="close-btn" onclick={closeWindow} aria-label="Close">
      <svg width="14" height="14" viewBox="0 0 14 14" fill="none">
        <path
          d="M1 1L13 13M1 13L13 1"
          stroke="currentColor"
          stroke-width="1.5"
          stroke-linecap="round"
        />
      </svg>
    </button>
  </header>

  {#if loading}
    <div class="loading">
      <span class="spinner"></span>
      <span>Loading...</span>
    </div>
  {:else}
    <form onsubmit={handleSave}>
      <div class="field">
        <label for="apiKey">API Key</label>
        <div class="input-row">
          <input
            id="apiKey"
            type={showApiKey ? 'text' : 'password'}
            bind:value={config.apiKey}
            oninput={handleConfigChange}
            autocomplete="off"
            spellcheck="false"
            placeholder="sk-..."
            required
          />
          <button
            type="button"
            class="toggle-btn"
            onclick={() => (showApiKey = !showApiKey)}
          >
            {#if showApiKey}
              <svg width="16" height="16" viewBox="0 0 16 16" fill="none">
                <path
                  d="M2 8s2.5-4 6-4 6 4 6 4-2.5 4-6 4-6-4-6-4Z"
                  stroke="currentColor"
                  stroke-width="1.25"
                  stroke-linecap="round"
                  stroke-linejoin="round"
                />
                <circle
                  cx="8"
                  cy="8"
                  r="1.5"
                  stroke="currentColor"
                  stroke-width="1.25"
                />
                <path
                  d="M3 13L13 3"
                  stroke="currentColor"
                  stroke-width="1.25"
                  stroke-linecap="round"
                />
              </svg>
            {:else}
              <svg width="16" height="16" viewBox="0 0 16 16" fill="none">
                <path
                  d="M2 8s2.5-4 6-4 6 4 6 4-2.5 4-6 4-6-4-6-4Z"
                  stroke="currentColor"
                  stroke-width="1.25"
                  stroke-linecap="round"
                  stroke-linejoin="round"
                />
                <circle
                  cx="8"
                  cy="8"
                  r="1.5"
                  stroke="currentColor"
                  stroke-width="1.25"
                />
              </svg>
            {/if}
          </button>
        </div>
      </div>

      <div class="field">
        <label for="baseUrl">Base URL</label>
        <input
          id="baseUrl"
          type="url"
          bind:value={config.baseUrl}
          oninput={handleConfigChange}
          autocomplete="off"
          spellcheck="false"
          placeholder="https://api.openai.com/v1"
          required
        />
      </div>

      <div class="field">
        <label for="model">Model</label>
        <div class="select-wrapper">
          <select id="model" value={selectedPreset} onchange={handlePresetChange}>
            {#each PRESET_MODELS as model}
              <option value={model.value}>{model.label}</option>
            {/each}
            <option value="custom">Custom...</option>
          </select>
          <svg class="select-arrow" width="12" height="12" viewBox="0 0 12 12" fill="none">
            <path
              d="M3 4.5L6 7.5L9 4.5"
              stroke="currentColor"
              stroke-width="1.25"
              stroke-linecap="round"
              stroke-linejoin="round"
            />
          </svg>
        </div>
        {#if useCustomModel}
          <input
            type="text"
            value={customModelValue}
            oninput={handleCustomModelChange}
            autocomplete="off"
            spellcheck="false"
            placeholder="Enter model name..."
            class="custom-model-input"
            required
          />
        {/if}
      </div>

      <div class="actions">
        <button
          type="button"
          class="secondary"
          onclick={testConnection}
          disabled={testing || !config.apiKey || !config.baseUrl}
        >
          {#if testing}
            <span class="spinner small"></span>
            Testing...
          {:else}
            Test Connection
          {/if}
        </button>
        <button
          type="submit"
          class="primary"
          disabled={saving || !isFormValid(config)}
        >
          {#if saving}
            <span class="spinner small"></span>
            Saving...
          {:else}
            Save
          {/if}
        </button>
      </div>

      {#if testResult}
        <div class="test-result" class:success={testResult.success} class:error={!testResult.success}>
          {#if testResult.success}
            <svg width="14" height="14" viewBox="0 0 14 14" fill="none">
              <path
                d="M2.5 7.5L5.5 10.5L11.5 3.5"
                stroke="currentColor"
                stroke-width="1.5"
                stroke-linecap="round"
                stroke-linejoin="round"
              />
            </svg>
          {:else}
            <svg width="14" height="14" viewBox="0 0 14 14" fill="none">
              <circle cx="7" cy="7" r="5.5" stroke="currentColor" stroke-width="1.25" />
              <path d="M7 4V7.5" stroke="currentColor" stroke-width="1.25" stroke-linecap="round" />
              <circle cx="7" cy="10" r="0.75" fill="currentColor" />
            </svg>
          {/if}
          <span>{testResult.message}</span>
        </div>
      {/if}

      {#if statusMessage}
        <div class="status" class:success={statusType === 'success'} class:error={statusType === 'error'}>
          {#if statusType === 'success'}
            <svg width="14" height="14" viewBox="0 0 14 14" fill="none">
              <path
                d="M2.5 7.5L5.5 10.5L11.5 3.5"
                stroke="currentColor"
                stroke-width="1.5"
                stroke-linecap="round"
                stroke-linejoin="round"
              />
            </svg>
          {:else if statusType === 'error'}
            <svg width="14" height="14" viewBox="0 0 14 14" fill="none">
              <circle cx="7" cy="7" r="5.5" stroke="currentColor" stroke-width="1.25" />
              <path d="M7 4V7.5" stroke="currentColor" stroke-width="1.25" stroke-linecap="round" />
              <circle cx="7" cy="10" r="0.75" fill="currentColor" />
            </svg>
          {/if}
          <span>{statusMessage}</span>
        </div>
      {/if}
    </form>
  {/if}
</div>

<style>
  :global(html),
  :global(body) {
    margin: 0;
    padding: 0;
    background: #111111;
    color: #e2e2e2;
    font-family: 'SF Mono', 'Geist Mono', 'Fira Code', ui-monospace, monospace;
    font-size: 13px;
    line-height: 1.4;
  }

  .container {
    display: flex;
    flex-direction: column;
    min-height: 100vh;
    padding: 1.25rem;
    box-sizing: border-box;
  }

  /* Header */
  header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    margin-bottom: 1.5rem;
    padding-bottom: 1rem;
    border-bottom: 1px solid rgba(255, 255, 255, 0.08);
  }

  h1 {
    margin: 0;
    font-size: 1rem;
    font-weight: 600;
    letter-spacing: 0.02em;
  }

  .close-btn {
    display: flex;
    align-items: center;
    justify-content: center;
    width: 28px;
    height: 28px;
    padding: 0;
    border: none;
    border-radius: 6px;
    background: transparent;
    color: #666;
    cursor: pointer;
    transition: background 0.15s, color 0.15s;
  }

  .close-btn:hover {
    background: rgba(255, 255, 255, 0.1);
    color: #999;
  }

  /* Loading state */
  .loading {
    display: flex;
    align-items: center;
    justify-content: center;
    gap: 0.75rem;
    flex: 1;
    color: #666;
    font-size: 0.85rem;
  }

  /* Form */
  form {
    display: flex;
    flex-direction: column;
    gap: 1.25rem;
  }

  .field {
    display: flex;
    flex-direction: column;
    gap: 0.5rem;
  }

  label {
    font-size: 0.8rem;
    font-weight: 500;
    color: #888;
    letter-spacing: 0.02em;
  }

  input,
  select {
    width: 100%;
    padding: 0.65rem 0.75rem;
    border: 1px solid rgba(255, 255, 255, 0.1);
    border-radius: 8px;
    background: #1a1a1a;
    color: #e2e2e2;
    font: inherit;
    font-size: 0.85rem;
    transition: border-color 0.15s, box-shadow 0.15s;
    box-sizing: border-box;
  }

  input::placeholder {
    color: #555;
  }

  input:focus,
  select:focus {
    outline: none;
    border-color: rgba(54, 87, 255, 0.5);
    box-shadow: 0 0 0 3px rgba(54, 87, 255, 0.15);
  }

  .input-row {
    display: flex;
    gap: 0.5rem;
  }

  .input-row input {
    flex: 1;
  }

  .toggle-btn {
    display: flex;
    align-items: center;
    justify-content: center;
    width: 40px;
    padding: 0;
    border: 1px solid rgba(255, 255, 255, 0.1);
    border-radius: 8px;
    background: #1a1a1a;
    color: #666;
    cursor: pointer;
    transition: border-color 0.15s, color 0.15s, background 0.15s;
    flex-shrink: 0;
  }

  .toggle-btn:hover {
    border-color: rgba(255, 255, 255, 0.2);
    color: #999;
    background: #222;
  }

  /* Select dropdown */
  .select-wrapper {
    position: relative;
  }

  select {
    appearance: none;
    padding-right: 2.25rem;
    cursor: pointer;
  }

  .select-arrow {
    position: absolute;
    right: 0.75rem;
    top: 50%;
    transform: translateY(-50%);
    color: #666;
    pointer-events: none;
  }

  .custom-model-input {
    margin-top: 0.5rem;
  }

  /* Actions */
  .actions {
    display: flex;
    gap: 0.75rem;
    margin-top: 0.5rem;
  }

  button.primary,
  button.secondary {
    display: flex;
    align-items: center;
    justify-content: center;
    gap: 0.5rem;
    flex: 1;
    padding: 0.65rem 1rem;
    border-radius: 8px;
    font: inherit;
    font-size: 0.85rem;
    font-weight: 500;
    cursor: pointer;
    transition: background 0.15s, border-color 0.15s, opacity 0.15s;
  }

  button.primary {
    border: 1px solid #3657ff;
    background: #3657ff;
    color: white;
  }

  button.primary:hover:not(:disabled) {
    background: #4a6aff;
    border-color: #4a6aff;
  }

  button.secondary {
    border: 1px solid rgba(255, 255, 255, 0.12);
    background: rgba(255, 255, 255, 0.05);
    color: #aaa;
  }

  button.secondary:hover:not(:disabled) {
    border-color: rgba(255, 255, 255, 0.2);
    background: rgba(255, 255, 255, 0.08);
    color: #ccc;
  }

  button:disabled {
    opacity: 0.5;
    cursor: not-allowed;
  }

  /* Spinner */
  .spinner {
    display: inline-block;
    width: 16px;
    height: 16px;
    border: 2px solid rgba(255, 255, 255, 0.2);
    border-top-color: currentColor;
    border-radius: 50%;
    animation: spin 0.8s linear infinite;
  }

  .spinner.small {
    width: 12px;
    height: 12px;
    border-width: 1.5px;
  }

  @keyframes spin {
    to {
      transform: rotate(360deg);
    }
  }

  /* Test result */
  .test-result {
    display: flex;
    align-items: center;
    gap: 0.5rem;
    padding: 0.65rem 0.75rem;
    border-radius: 8px;
    font-size: 0.8rem;
    animation: fadeIn 0.2s ease-out;
  }

  .test-result.success {
    background: rgba(74, 222, 128, 0.1);
    color: #4ade80;
    border: 1px solid rgba(74, 222, 128, 0.2);
  }

  .test-result.error {
    background: rgba(248, 113, 113, 0.1);
    color: #f87171;
    border: 1px solid rgba(248, 113, 113, 0.2);
  }

  /* Status message */
  .status {
    display: flex;
    align-items: center;
    gap: 0.5rem;
    font-size: 0.8rem;
    animation: fadeIn 0.2s ease-out;
  }

  .status.success {
    color: #4ade80;
  }

  .status.error {
    color: #f87171;
  }

  @keyframes fadeIn {
    from {
      opacity: 0;
      transform: translateY(-4px);
    }
    to {
      opacity: 1;
      transform: translateY(0);
    }
  }
</style>
