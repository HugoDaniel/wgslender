package wasmabi

import (
	"bytes"
	"encoding/binary"
	"fmt"
	"math"
)

// A Layout describes one of the result envelopes the guest packs into linear
// memory: a run of little-endian u32 header words followed by the payloads
// whose lengths some of those words carry.
//
// The five layouts below are the complete set. Every export either returns one
// of them or, in the single case of wgslender_version, returns a pointer to
// static data that is not an envelope at all.
type Layout struct {
	// Words is the number of u32 header words.
	Words int
	// Payloads gives, in payload order, the index of the header word holding
	// each payload's length. Header words not listed here are scalars — counts
	// and sizes that mean something to the caller but contribute nothing to
	// the envelope's own length.
	Payloads []int
}

// The envelope layouts, named after the Zig helpers that write them
// (packLenPrefixed in src/ffi.zig, the rest in src/wasm.zig) so the two sides
// can be checked against each other by eye.
var (
	// PackLenPrefixed is [u32 json_len][json]: minify_json,
	// minify_and_reflect, reflect, and all twelve refactor ops.
	PackLenPrefixed = Layout{Words: 1, Payloads: []int{0}}

	// PackValidate is [u32 valid][u32 errors][u32 warnings][u32 json_len][json].
	PackValidate = Layout{Words: 4, Payloads: []int{3}}

	// PackLint is [u32 errors][u32 warnings][u32 json_len][json].
	PackLint = Layout{Words: 3, Payloads: []int{2}}

	// PackLintFix is
	// [u32 fixed_len][u32 errors][u32 warnings][u32 json_len][fixed][json].
	PackLintFix = Layout{Words: 4, Payloads: []int{0, 3}}

	// PackCompile is
	// [u32 wasm_len][u32 original_size][u32 err_json_len][wasm][err_json].
	// Note that word 1 is the *input* size, not a payload length.
	PackCompile = Layout{Words: 3, Payloads: []int{0, 2}}
)

// A Result is a decoded envelope. Its payloads are copies: nothing in it
// aliases guest memory, which is what makes it safe to keep after the ABI lock
// is released and the guest is free to move that memory again.
type Result struct {
	// Words is the header, verbatim and in order.
	Words []uint32
	// Payloads holds the variable-length sections in Layout.Payloads order.
	Payloads [][]byte
}

// reader is the part of api.Memory that envelope decoding needs. Narrowing it
// to one method is what lets the decoder be tested against hand-built bytes
// instead of a live guest.
type reader interface {
	Read(offset, byteCount uint32) ([]byte, bool)
}

// size returns the envelope's total byte length, which is the exact length
// wgslender_dealloc has to be given back. The guest frees with
// wasm_allocator.free(ptr[0..len]) (freeBuf in src/ffi.zig); a wrong length
// there is undefined behaviour inside the allocator, not a reported error.
func (l Layout) size(words []uint32) (uint32, error) {
	total := uint64(4 * l.Words)
	for _, i := range l.Payloads {
		total += uint64(words[i])
	}
	if total > math.MaxUint32 {
		return 0, fmt.Errorf("%w: envelope of %d bytes does not fit the guest's address space", ErrInternal, total)
	}
	return uint32(total), nil
}

// decode copies the envelope at ptr out of guest memory, and reports the total
// length to hand to wgslender_dealloc.
func (l Layout) decode(mem reader, ptr uint32) (Result, uint32, error) {
	header := uint32(4 * l.Words)
	raw, ok := mem.Read(ptr, header)
	if !ok {
		return Result{}, 0, fmt.Errorf("wgslender: envelope header at %#x (%d bytes) is out of range", ptr, header)
	}
	words := make([]uint32, l.Words)
	for i := range words {
		words[i] = binary.LittleEndian.Uint32(raw[4*i:])
	}

	total, err := l.size(words)
	if err != nil {
		return Result{}, 0, err
	}

	payloads := make([][]byte, len(l.Payloads))
	off := ptr + header
	for i, w := range l.Payloads {
		n := words[w]
		b, ok := mem.Read(off, n)
		if !ok {
			return Result{}, 0, fmt.Errorf("wgslender: envelope payload %d at %#x (%d bytes) is out of range", i, off, n)
		}
		payloads[i] = bytes.Clone(b)
		off += n
	}
	return Result{Words: words, Payloads: payloads}, total, nil
}
