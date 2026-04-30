// In-process JSON-RPC transport that bridges vscode-languageclient to
// wgslender-lsp's synchronous sendMessage(json) -> string[] WASM API.
//
// We avoid a Worker round-trip in the desktop host by speaking the
// MessageReader / MessageWriter contract directly: `write` hands the
// JSON to the WASM module, then synchronously dispatches every emitted
// response back to the reader's callback.

import {
  AbstractMessageReader,
  AbstractMessageWriter,
  DataCallback,
  Disposable,
  Message,
  MessageReader,
  MessageWriter,
} from 'vscode-languageclient';

class InProcessReader extends AbstractMessageReader implements MessageReader {
  private callback: DataCallback | undefined;

  listen(callback: DataCallback): Disposable {
    this.callback = callback;
    return { dispose: () => { this.callback = undefined; } };
  }

  emit(message: Message): void {
    this.callback?.(message);
  }
}

class InProcessWriter extends AbstractMessageWriter implements MessageWriter {
  constructor(
    private readonly send: (json: string) => string[],
    private readonly reader: InProcessReader,
  ) {
    super();
  }

  async write(msg: Message): Promise<void> {
    const responses = this.send(JSON.stringify(msg));
    for (const json of responses) {
      this.reader.emit(JSON.parse(json) as Message);
    }
  }

  end(): void {}
}

export interface InProcessTransports {
  reader: MessageReader;
  writer: MessageWriter;
}

export function createInProcessTransports(send: (json: string) => string[]): InProcessTransports {
  const reader = new InProcessReader();
  const writer = new InProcessWriter(send, reader);
  return { reader, writer };
}
