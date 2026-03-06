import { invoke } from '@tauri-apps/api/core';
import { load } from '@tauri-apps/plugin-store';

export interface AppConfig {
  apiKey: string;
  baseUrl: string;
  model: string;
}

const STORE_FILE = 'settings.json';

const DEFAULT_BASE_URL = 'https://api.openai.com/v1';
const DEFAULT_MODEL = 'whisper-1';

const EMPTY_CONFIG: AppConfig = {
  apiKey: '',
  baseUrl: DEFAULT_BASE_URL,
  model: DEFAULT_MODEL,
};

async function getStore() {
  return load(STORE_FILE, { autoSave: false, defaults: {} });
}

function clean(value: unknown): string {
  return typeof value === 'string' ? value.trim() : '';
}

export function normalizeConfig(input: Partial<AppConfig> | null | undefined): AppConfig {
  const apiKey = clean(input?.apiKey);
  const baseUrlRaw = clean(input?.baseUrl) || DEFAULT_BASE_URL;
  const model = clean(input?.model) || DEFAULT_MODEL;

  return {
    apiKey,
    baseUrl: baseUrlRaw.replace(/\/+$/, ''),
    model,
  };
}

export function hasValidConfig(config: Partial<AppConfig> | null | undefined): config is AppConfig {
  if (!config) {
    return false;
  }

  const normalized = normalizeConfig(config);
  if (!normalized.apiKey || !normalized.model || !normalized.baseUrl) {
    return false;
  }

  try {
    const parsed = new URL(normalized.baseUrl);
    return parsed.protocol === 'http:' || parsed.protocol === 'https:';
  } catch {
    return false;
  }
}

export async function loadStoredConfig(): Promise<Partial<AppConfig> | null> {
  const store = await getStore();

  const apiKey = await store.get<string>('apiKey');
  const baseUrl = await store.get<string>('baseUrl');
  const model = await store.get<string>('model');

  const hasAnyState = Boolean(clean(apiKey) || clean(baseUrl) || clean(model));
  if (!hasAnyState) {
    return null;
  }

  return {
    apiKey: clean(apiKey),
    baseUrl: clean(baseUrl),
    model: clean(model),
  };
}

export async function loadConfig(): Promise<AppConfig | null> {
  const stored = await loadStoredConfig();
  if (!stored) {
    return null;
  }

  const normalized = normalizeConfig(stored);
  return hasValidConfig(normalized) ? normalized : null;
}

export async function loadInitialConfig(): Promise<AppConfig> {
  const stored = await loadStoredConfig();
  if (stored) {
    return normalizeConfig(stored);
  }

  const envConfig = await invoke<AppConfig>('get_env_config');
  return normalizeConfig(envConfig);
}

export async function saveConfig(config: AppConfig): Promise<void> {
  const normalized = normalizeConfig(config);
  const store = await getStore();

  await store.set('apiKey', normalized.apiKey);
  await store.set('baseUrl', normalized.baseUrl);
  await store.set('model', normalized.model);
  await store.save();
}

export function emptyConfig(): AppConfig {
  return { ...EMPTY_CONFIG };
}
