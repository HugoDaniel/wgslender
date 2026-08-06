/**
 * A WGSL syntax mode for CodeMirror, as a `StreamLanguage`.
 *
 * This is highlighting only — every question that needs to understand the
 * program (diagnostics, hover, completion, go-to-definition) is answered by
 * the language server. The mode's job is to make the editor legible before
 * any wasm has finished loading, and to keep looking right while the user
 * types something the parser would reject.
 *
 * The word lists are lifted from the Zig sources rather than invented:
 * keywords from `src/Lexer.zig`, predeclared types from
 * `src/validator/TypeResolve.zig`, builtin functions from `src/Builtins.zig`
 * (regenerate with `grep -oE 'def\("[a-zA-Z_0-9]+"' src/Builtins.zig`).
 *
 * The one genuinely WGSL-specific rule here is that block comments **nest**
 * (§2.3) — `/* a /* b *​/ c *​/` is a single comment. That is why the parser
 * state carries a depth counter instead of a boolean.
 */
import { LanguageSupport, StreamLanguage } from '@codemirror/language';
import type { StreamParser, StringStream } from '@codemirror/language';

/** `src/Lexer.zig` `Tag.keyword_*` — the complete set, nothing more. */
const keywords = new Set([
  'alias', 'break', 'case', 'const', 'const_assert', 'continue', 'continuing',
  'default', 'diagnostic', 'discard', 'else', 'enable', 'fn', 'for', 'if',
  'let', 'loop', 'override', 'requires', 'return', 'struct', 'switch', 'var',
  'while',
]);

/**
 * Address spaces and access modes. Deliberately *not* keywords: WGSL leaves
 * them free for use as ordinary identifiers, and treating them as reserved
 * is the classic way a WGSL mode ends up highlighting valid code as broken.
 */
const modifiers = new Set([
  'function', 'private', 'push_constant', 'storage', 'uniform', 'workgroup',
  'read', 'read_write', 'write',
]);

/** Predeclared types that are not `vecN` / `matCxR` shorthands. */
const types = new Set([
  'bool', 'f16', 'f32', 'i32', 'u32',
  'array', 'atomic', 'ptr', 'sampler', 'sampler_comparison',
  'texture_1d', 'texture_2d', 'texture_2d_array', 'texture_3d',
  'texture_cube', 'texture_cube_array', 'texture_multisampled_2d',
  'texture_storage_1d', 'texture_storage_2d', 'texture_storage_2d_array',
  'texture_storage_3d', 'texture_depth_2d', 'texture_depth_2d_array',
  'texture_depth_cube', 'texture_depth_cube_array',
  'texture_depth_multisampled_2d', 'texture_external',
]);

/** `vec3`, `vec4f`, `mat2x3`, `mat4x4h`, … */
const shorthandType = /^(?:vec[234][fiuh]?|mat[234]x[234][fh]?)$/;

/** `src/Builtins.zig`. Subgroup/quad/f16 entries need an `enable`; listing
 * them costs nothing and keeps the mode honest about what the validator
 * knows. */
const builtins = new Set([
  'abs', 'acos', 'acosh', 'all', 'any', 'arrayLength', 'asin', 'asinh', 'atan',
  'atan2', 'atanh', 'atomicAdd', 'atomicAnd', 'atomicCompareExchangeWeak',
  'atomicExchange', 'atomicLoad', 'atomicMax', 'atomicMin', 'atomicOr',
  'atomicStore', 'atomicSub', 'atomicXor', 'bitcast', 'ceil', 'clamp', 'cos',
  'cosh', 'countLeadingZeros', 'countOneBits', 'countTrailingZeros', 'cross',
  'degrees', 'determinant', 'distance', 'dot', 'dot4I8Packed', 'dot4U8Packed',
  'dpdx', 'dpdxCoarse', 'dpdxFine', 'dpdy', 'dpdyCoarse', 'dpdyFine', 'exp',
  'exp2', 'extractBits', 'faceForward', 'firstLeadingBit', 'firstTrailingBit',
  'floor', 'fma', 'fract', 'frexp', 'fwidth', 'fwidthCoarse', 'fwidthFine',
  'insertBits', 'inverseSqrt', 'ldexp', 'length', 'log', 'log2', 'max', 'min',
  'mix', 'modf', 'normalize', 'pack2x16float', 'pack2x16snorm',
  'pack2x16unorm', 'pack4x8snorm', 'pack4x8unorm', 'pack4xI8', 'pack4xI8Clamp',
  'pack4xU8', 'pack4xU8Clamp', 'pow', 'quadBroadcast', 'quadSwapDiagonal',
  'quadSwapX', 'quadSwapY', 'quantizeToF16', 'radians', 'reflect', 'refract',
  'reverseBits', 'round', 'saturate', 'select', 'sign', 'sin', 'sinh',
  'smoothstep', 'sqrt', 'step', 'storageBarrier', 'subgroupAdd', 'subgroupAll',
  'subgroupAnd', 'subgroupAny', 'subgroupBallot', 'subgroupBroadcast',
  'subgroupBroadcastFirst', 'subgroupElect', 'subgroupExclusiveAdd',
  'subgroupExclusiveMul', 'subgroupInclusiveAdd', 'subgroupInclusiveMul',
  'subgroupMax', 'subgroupMin', 'subgroupMul', 'subgroupOr', 'subgroupShuffle',
  'subgroupShuffleDown', 'subgroupShuffleUp', 'subgroupShuffleXor',
  'subgroupXor', 'tan', 'tanh', 'textureBarrier', 'textureDimensions',
  'textureGather', 'textureGatherCompare', 'textureLoad', 'textureNumLayers',
  'textureNumLevels', 'textureNumSamples', 'textureSample',
  'textureSampleBaseClampToEdge', 'textureSampleBias', 'textureSampleCompare',
  'textureSampleCompareLevel', 'textureSampleGrad', 'textureSampleLevel',
  'textureStore', 'transpose', 'trunc', 'unpack2x16float', 'unpack2x16snorm',
  'unpack2x16unorm', 'unpack4x8snorm', 'unpack4x8unorm', 'unpack4xI8',
  'unpack4xU8', 'workgroupBarrier', 'workgroupUniformLoad',
]);

/**
 * Longest-match-first. A bare `2h` is not a WGSL literal — f16 needs a
 * fraction or an exponent — so the integer pattern only accepts `i`/`u`.
 */
const numberPatterns = [
  /^0[xX](?:[0-9a-fA-F]*\.[0-9a-fA-F]+|[0-9a-fA-F]+\.[0-9a-fA-F]*)(?:[pP][+-]?[0-9]+)?[hf]?/,
  /^0[xX][0-9a-fA-F]+[iu]?/,
  /^(?:[0-9]*\.[0-9]+|[0-9]+\.[0-9]*)(?:[eE][+-]?[0-9]+)?[hf]?/,
  /^[0-9]+[eE][+-]?[0-9]+[hf]?/,
  /^[0-9]+[iu]?/,
];

const identifier = /^[A-Za-z_][A-Za-z0-9_]*/;
const attribute = /^@[A-Za-z_][A-Za-z0-9_]*/;
const operator = /^[-+*/%<>=!&|^~]+/;
const punctuation = /^[{}()[\],;:.]/;
/** An identifier immediately followed by `(` is being called. */
const callAhead = /^[ \t]*\(/;

interface WgslState {
  /** Nesting depth of the block comment we are inside; 0 when in code. */
  commentDepth: number;
  /** The previous token was `.`, so this identifier names a member. */
  afterDot: boolean;
}

/**
 * Consume as much of the current line as belongs to the open block comment,
 * tracking `/*` and `*​/` so nesting closes in the right order.
 */
function blockComment(stream: StringStream, state: WgslState): string {
  while (!stream.eol()) {
    if (stream.match('*/')) {
      state.commentDepth -= 1;
      if (state.commentDepth === 0) break;
    } else if (stream.match('/*')) {
      state.commentDepth += 1;
    } else {
      stream.next();
    }
  }
  return 'comment';
}

export const wgslStreamParser: StreamParser<WgslState> = {
  // lsp-client reads `Language.name` to pick the `languageId` it sends in
  // `textDocument/didOpen`.
  name: 'wgsl',

  startState: (): WgslState => ({ commentDepth: 0, afterDot: false }),

  token(stream, state) {
    if (state.commentDepth > 0) return blockComment(stream, state);
    if (stream.eatSpace()) return null;

    if (stream.match('//')) {
      stream.skipToEnd();
      return 'comment';
    }
    if (stream.match('/*')) {
      state.commentDepth = 1;
      return blockComment(stream, state);
    }

    if (stream.match(attribute)) {
      state.afterDot = false;
      return 'attributeName';
    }

    for (const pattern of numberPatterns) {
      if (stream.match(pattern)) {
        state.afterDot = false;
        return 'number';
      }
    }

    if (stream.match(identifier)) {
      const word = stream.current();
      const isMember = state.afterDot;
      state.afterDot = false;

      if (isMember) return 'propertyName';
      if (word === 'true' || word === 'false') return 'bool';
      if (keywords.has(word)) return 'keyword';
      if (modifiers.has(word)) return 'modifier';
      if (types.has(word) || shorthandType.test(word)) return 'typeName';
      if (builtins.has(word)) return 'variableName.standard';
      if (stream.match(callAhead, false)) return 'variableName.function';
      return 'variableName';
    }

    if (stream.match(operator)) {
      state.afterDot = false;
      return 'operator';
    }
    if (stream.match(punctuation)) {
      state.afterDot = stream.current() === '.';
      return 'punctuation';
    }

    stream.next();
    state.afterDot = false;
    return null;
  },

  languageData: {
    commentTokens: { line: '//', block: { open: '/*', close: '*/' } },
    closeBrackets: { brackets: ['(', '[', '{', '<'] },
  },
};

export const wgslLanguage = StreamLanguage.define(wgslStreamParser);

/** The extension to hand CodeMirror. */
export function wgsl(): LanguageSupport {
  return new LanguageSupport(wgslLanguage);
}
