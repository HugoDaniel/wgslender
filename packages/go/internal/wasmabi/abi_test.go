package wasmabi

import (
	"bytes"
	"context"
	"encoding/binary"
	"errors"
	"maps"
	"math"
	"slices"
	"testing"

	"github.com/tetratelabs/wazero/api"
)

// guestExports is the ABI surface this package is written against, sorted.
// src/wasm.zig is the source of truth; a difference means the artifact moved
// under us.
var guestExports = []string{
	"wgslender_alloc",
	"wgslender_change_type_apply_by_id",
	"wgslender_change_type_by_id",
	"wgslender_compile",
	"wgslender_dealloc",
	"wgslender_find_references",
	"wgslender_lint",
	"wgslender_lint_fix",
	"wgslender_locate_declaration",
	"wgslender_locate_stable_id",
	"wgslender_locate_type",
	"wgslender_minify_and_reflect",
	"wgslender_minify_json",
	"wgslender_reflect",
	"wgslender_remove_declaration_apply_by_id",
	"wgslender_remove_declaration_by_id",
	"wgslender_rename",
	"wgslender_rename_apply",
	"wgslender_rename_by_id",
	"wgslender_stable_id_at_offset",
	"wgslender_validate",
	"wgslender_version",
	"wgslender_version_len",
}

// fakeMemory is a flat byte slice standing in for api.Memory, so envelope
// decoding can be exercised against bytes laid out by hand.
type fakeMemory []byte

func (m fakeMemory) Read(offset, byteCount uint32) ([]byte, bool) {
	end := uint64(offset) + uint64(byteCount)
	if end > uint64(len(m)) {
		return nil, false
	}
	return m[offset:end], true
}

// envelope lays out header words followed by payloads, the way the guest does.
func envelope(words []uint32, payloads ...[]byte) []byte {
	b := make([]byte, 0, 4*len(words))
	for _, w := range words {
		b = binary.LittleEndian.AppendUint32(b, w)
	}
	for _, p := range payloads {
		b = append(b, p...)
	}
	return b
}

// TestLayoutSize restates the dealloc column of the ABI table in
// docs/go-package-plan.md. The guest frees with wasm_allocator.free(ptr[0..len])
// (freeBuf in src/ffi.zig), where a wrong length is undefined behaviour rather
// than a reported error — so this arithmetic is worth pinning literally, and in
// particular worth pinning against the mistake of treating every header word as
// a payload length.
func TestLayoutSize(t *testing.T) {
	tests := []struct {
		name  string
		l     Layout
		words []uint32
		want  uint32
	}{
		{"len prefixed: 4 + json", PackLenPrefixed, []uint32{7}, 4 + 7},
		{"validate: 16 + json, three leading scalars", PackValidate, []uint32{1, 0, 0, 9}, 16 + 9},
		{"lint: 12 + json, two leading scalars", PackLint, []uint32{2, 3, 11}, 12 + 11},
		{"lint fix: 16 + fixed + json", PackLintFix, []uint32{5, 1, 2, 13}, 16 + 5 + 13},
		{"compile: 12 + wasm + errors, word 1 is the input size", PackCompile, []uint32{100, 999, 6}, 12 + 100 + 6},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := tt.l.size(tt.words)
			if err != nil {
				t.Fatalf("size(%v): %v", tt.words, err)
			}
			if got != tt.want {
				t.Errorf("size(%v) = %d, want %d", tt.words, got, tt.want)
			}
		})
	}
}

func TestLayoutSizeRejectsOverflow(t *testing.T) {
	// Two maximal payloads cannot coexist in a 32-bit address space; better to
	// say so than to hand the guest a truncated free length.
	_, err := PackLintFix.size([]uint32{math.MaxUint32, 0, 0, math.MaxUint32})
	if !errors.Is(err, ErrInternal) {
		t.Errorf("size overflow error = %v, want one wrapping ErrInternal", err)
	}
}

func TestLayoutDecode(t *testing.T) {
	tests := []struct {
		name     string
		l        Layout
		words    []uint32
		payloads [][]byte
	}{
		{
			name:     "len prefixed",
			l:        PackLenPrefixed,
			words:    []uint32{7},
			payloads: [][]byte{[]byte(`{"a":1}`)},
		},
		{
			name:     "validate keeps valid/errors/warnings as scalars",
			l:        PackValidate,
			words:    []uint32{0, 2, 1, 4},
			payloads: [][]byte{[]byte(`[{}]`)},
		},
		{
			name:     "lint",
			l:        PackLint,
			words:    []uint32{1, 3, 2},
			payloads: [][]byte{[]byte(`[]`)},
		},
		{
			name:     "lint fix carries the fixed source ahead of the report",
			l:        PackLintFix,
			words:    []uint32{9, 0, 1, 2},
			payloads: [][]byte{[]byte("fn main()"), []byte(`[]`)},
		},
		{
			name:     "compile skips the original size between its payloads",
			l:        PackCompile,
			words:    []uint32{4, 4096, 2},
			payloads: [][]byte{{0x00, 0x61, 0x73, 0x6d}, []byte(`[]`)},
		},
		{
			name:     "empty payload",
			l:        PackLenPrefixed,
			words:    []uint32{0},
			payloads: [][]byte{{}},
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			// Decode at a non-zero base, so an offset dropped somewhere in the
			// arithmetic cannot pass by accident.
			const base = 16
			mem := append(make(fakeMemory, base), envelope(tt.words, tt.payloads...)...)

			got, total, err := tt.l.decode(mem, base)
			if err != nil {
				t.Fatalf("decode: %v", err)
			}
			if !slices.Equal(got.Words, tt.words) {
				t.Errorf("Words = %v, want %v", got.Words, tt.words)
			}
			if len(got.Payloads) != len(tt.payloads) {
				t.Fatalf("got %d payloads, want %d", len(got.Payloads), len(tt.payloads))
			}
			for i, want := range tt.payloads {
				if !bytes.Equal(got.Payloads[i], want) {
					t.Errorf("payload %d = %q, want %q", i, got.Payloads[i], want)
				}
			}
			wantTotal, err := tt.l.size(tt.words)
			if err != nil {
				t.Fatalf("size: %v", err)
			}
			if total != wantTotal {
				t.Errorf("dealloc length = %d, want %d", total, wantTotal)
			}
		})
	}
}

func TestLayoutDecodeRejectsShortMemory(t *testing.T) {
	tests := []struct {
		name string
		mem  fakeMemory
	}{
		{"truncated header", fakeMemory{0x01, 0x02}},
		{"header promises a payload that is not there", fakeMemory(envelope([]uint32{64}))},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if _, _, err := PackLenPrefixed.decode(tt.mem, 0); err == nil {
				t.Error("decode accepted an envelope that runs past the end of memory")
			}
		})
	}
}

// TestGuestSurface pins the shape of the embedded artifact. None of it is
// negotiable from the Go side: a change here means `zig build wasm` produced
// something this package was not written against, and the failure should say so
// by name rather than turn up later as a mysterious trap.
func TestGuestSurface(t *testing.T) {
	a, err := shared()
	if err != nil {
		t.Fatalf("compiling the embedded wasm: %v", err)
	}

	// Freestanding: no WASI, no env, nothing to wire up at instantiation.
	if n := len(a.compiled.ImportedFunctions()); n != 0 {
		t.Errorf("imported functions = %d, want 0", n)
	}
	if n := len(a.compiled.ImportedMemories()); n != 0 {
		t.Errorf("imported memories = %d, want 0", n)
	}
	if n := len(a.compiled.ExportedMemories()); n != 1 {
		t.Errorf("exported memories = %d, want 1", n)
	}

	got := slices.Sorted(maps.Keys(a.compiled.ExportedFunctions()))
	if !slices.Equal(got, guestExports) {
		t.Errorf("exported functions have moved.\n got: %q\nwant: %q\n"+
			"if src/wasm.zig gained or renamed an export, update guestExports here "+
			"and the ABI table in docs/go-package-plan.md", got, guestExports)
	}
}

// TestWriteBufferAllocatesOneByteForEmpty exercises the rule against the real
// guest allocator: an empty input still needs a real, non-null allocation,
// because a null pointer is how the guest reports failure.
func TestWriteBufferAllocatesOneByteForEmpty(t *testing.T) {
	got, err := exec(t.Context(), func(ctx context.Context, mod api.Module) (region, error) {
		alloc, err := lookup(mod, allocFn)
		if err != nil {
			return region{}, err
		}
		dealloc, err := lookup(mod, deallocFn)
		if err != nil {
			return region{}, err
		}
		r, err := writeBuffer(ctx, mod, alloc, nil)
		if err != nil {
			return region{}, err
		}
		// Freeing with r.size is the whole point: give the allocator back the
		// length it handed out, not the zero length of the input.
		return r, freeRegions(ctx, dealloc, r)
	})
	if err != nil {
		t.Fatalf("writeBuffer(nil): %v", err)
	}
	if got.ptr == 0 {
		t.Error("writeBuffer(nil) returned a null pointer, which the guest uses to signal failure")
	}
	if got.size != 1 {
		t.Errorf("writeBuffer(nil).size = %d, want 1", got.size)
	}
}

// TestCallErrorRetiresInstance pins the recovery rule: a failed call throws its
// instance away rather than reusing a guest whose heap may be inconsistent, and
// the next caller transparently gets a fresh one.
func TestCallErrorRetiresInstance(t *testing.T) {
	a, err := shared()
	if err != nil {
		t.Fatalf("compiling the embedded wasm: %v", err)
	}

	if _, err := Version(t.Context()); err != nil {
		t.Fatalf("priming the instance: %v", err)
	}
	a.mu.Lock()
	live := a.mod != nil
	a.mu.Unlock()
	if !live {
		t.Fatal("no instance after a successful call")
	}

	if _, err := Call(t.Context(), "wgslender_not_an_export", PackLenPrefixed); err == nil {
		t.Fatal("Call on a missing export returned no error")
	}
	a.mu.Lock()
	retired := a.mod == nil
	a.mu.Unlock()
	if !retired {
		t.Error("a failed call left its instance in place; a trapped guest may have a corrupt heap")
	}

	if _, err := Version(t.Context()); err != nil {
		t.Errorf("Version after a failed call: %v", err)
	}
}

// TestBufferSize covers the guard on its own rather than through Call, because
// reaching it through Call would mean allocating four gigabytes on every run of
// the gate.
func TestBufferSize(t *testing.T) {
	for _, n := range []int{0, 1, 445} {
		got, err := bufferSize(n)
		if err != nil {
			t.Errorf("bufferSize(%d): %v", n, err)
		}
		if int(got) != n {
			t.Errorf("bufferSize(%d) = %d, want %d", n, got, n)
		}
	}

	// On a 32-bit platform every int already fits the guest, so there is
	// nothing to reject. The comparison is constant, so this still compiles
	// where the call below could not overflow.
	if math.MaxInt <= math.MaxUint32 {
		return
	}
	if _, err := bufferSize(math.MaxInt); !errors.Is(err, ErrSourceTooLarge) {
		t.Errorf("bufferSize(MaxInt) = %v, want one wrapping ErrSourceTooLarge", err)
	}
}
