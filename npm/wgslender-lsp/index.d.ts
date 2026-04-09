export interface InitializeOptions {
  /** Pre-compiled WebAssembly module. */
  wasmModule?: WebAssembly.Module;
  /** URL to the .wasm file. */
  wasmURL?: string | URL;
}

/** Compatible with @codemirror/lsp-client Transport. */
export interface Transport {
  send(message: string): void;
  subscribe(handler: (value: string) => void): void;
  unsubscribe(handler: (value: string) => void): void;
}

/** Initialize the WASM LSP module. Must be called before other functions. */
export function initialize(options?: InitializeOptions): Promise<void>;

/** Check if the WASM module is initialized. */
export function isInitialized(): boolean;

/** Send a JSON-RPC message and return response(s). */
export function sendMessage(json: string): string[];

/** Create a Transport compatible with @codemirror/lsp-client. */
export function createTransport(): Transport;
