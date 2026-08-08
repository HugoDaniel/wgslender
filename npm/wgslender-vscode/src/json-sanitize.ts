// JSON.stringify emits an unpaired surrogate as a `\ud800`-style escape
// (well-formed stringify, ES2019). The Zig std.json parser inside the
// LSP WASM rejects a message containing one, and a rejected message is
// dropped wholesale — so a document holding a single lone surrogate
// (pasted binary, a truncated emoji from an odd clipboard) would
// silently stop syncing: every later request answers against stale
// text. Replace the escape with U+FFFD before the JSON reaches the WASM.
//
// Only unpaired surrogates ever appear escaped: stringify writes valid
// astral pairs as raw UTF-8, and a literal backslash-u sequence in the
// source text arrives with its backslash doubled. An odd-length
// backslash run therefore identifies a real escape; an even run is
// literal text and must stay untouched.
export function sanitizeLoneSurrogateEscapes(json: string): string {
  return json.replace(
    /(\\+)u([dD][89a-fA-F][0-9a-fA-F]{2})/g,
    (match, slashes: string) =>
      slashes.length % 2 === 1 ? `${slashes.slice(0, -1)}\\ufffd` : match,
  );
}
