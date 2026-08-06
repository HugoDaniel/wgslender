// Package wasmabi is the boundary between Go and the WGSLender WebAssembly
// module. It owns the embedded artifact, the wazero runtime, the single guest
// instance every call runs on, and the copy-in/copy-out discipline that
// instance requires.
//
// Nothing here knows what a shader is. This package moves bytes across the ABI
// and decodes envelope headers; meaning lives in the wgslender package.
package wasmabi

import (
	"context"
	"crypto/sha256"
	_ "embed"
	"errors"
	"fmt"
	"math"
	"sync"

	"github.com/tetratelabs/wazero"
	"github.com/tetratelabs/wazero/api"
)

// guestWasm is the same artifact packages/js-npm ships, byte for byte. It has
// to be a copy rather than a reference because go:embed cannot reach outside
// the module; TestWasmMatchesNpm is what keeps the two in step.
//
//go:embed wgslender.wasm
var guestWasm []byte

// Guest exports this package calls directly. The rest are named by their
// callers and pinned by TestGuestSurface.
const (
	allocFn      = "wgslender_alloc"
	deallocFn    = "wgslender_dealloc"
	versionFn    = "wgslender_version"
	versionLenFn = "wgslender_version_len"
)

// ErrInternal reports a failure the guest cannot describe: it answered with a
// null pointer, which it does only when an allocation fails or a length
// overflows u32. Everything a *shader* can get wrong arrives as data inside an
// envelope instead, so this error never means "bad input".
var ErrInternal = errors.New("wgslender: internal wasm failure")

// ErrSourceTooLarge reports an input that does not fit the guest's 32-bit
// address space. It is detected on the host, before anything is allocated.
var ErrSourceTooLarge = errors.New("wgslender: input too large")

// abi holds the process-wide guest: one compiled module and one instance,
// serialised by mu.
//
// One instance is one single-threaded Zig allocator. Calling it from two
// goroutines at once is not a data race in Go's sense — Go sees only an opaque
// function call — it is guest heap corruption, which surfaces as traps and,
// worse, as plausible wrong answers from an instance that has stopped being
// trustworthy without saying so. The mutex is therefore a correctness
// requirement, not a throughput tradeoff.
type abi struct {
	rt       wazero.Runtime
	compiled wazero.CompiledModule

	mu  sync.Mutex
	mod api.Module // guarded by mu; nil before the first call and after a retirement
}

// shared compiles the embedded module on first use. Compiling costs ~127 ms
// and instantiating ~32 µs, which is the entire reason those are separate
// steps here.
var shared = sync.OnceValues(newABI)

func newABI() (*abi, error) {
	// Compilation is pure CPU work with no I/O and happens once per process,
	// so it deliberately does not adopt the first caller's context: one
	// caller's cancellation must not poison the module for every later one.
	ctx := context.Background()
	rt := wazero.NewRuntime(ctx)
	compiled, err := rt.CompileModule(ctx, guestWasm)
	if err != nil {
		_ = rt.Close(ctx)
		return nil, fmt.Errorf("wgslender: compiling the embedded wasm: %w", err)
	}
	return &abi{rt: rt, compiled: compiled}, nil
}

// moduleLocked returns the live instance, creating one if there is none.
// The caller must hold a.mu.
func (a *abi) moduleLocked(ctx context.Context) (api.Module, error) {
	if a.mod != nil {
		return a.mod, nil
	}
	// An empty name keeps the instance out of wazero's module registry, so
	// re-instantiating after a retirement cannot collide with the name the
	// previous one held.
	mod, err := a.rt.InstantiateModule(ctx, a.compiled, wazero.NewModuleConfig().WithName(""))
	if err != nil {
		return nil, fmt.Errorf("wgslender: instantiating the wasm module: %w", err)
	}
	a.mod = mod
	return mod, nil
}

// retireLocked throws the instance away. Any error out of a guest call means
// the guest may have trapped part-way through an allocation, and a corrupt Zig
// heap does not announce itself — it goes on answering, plausibly and wrongly.
// A fresh instance costs ~32 µs, so there is nothing to gamble for.
// The caller must hold a.mu.
func (a *abi) retireLocked(ctx context.Context) {
	if a.mod == nil {
		return
	}
	_ = a.mod.Close(ctx)
	a.mod = nil
}

// exec runs fn against the shared instance under the ABI lock, retiring the
// instance if fn fails. Every guest call in this package goes through here, so
// that the retire-on-error rule has exactly one implementation to audit.
func exec[T any](ctx context.Context, fn func(context.Context, api.Module) (T, error)) (T, error) {
	var zero T
	a, err := shared()
	if err != nil {
		return zero, err
	}

	a.mu.Lock()
	defer a.mu.Unlock()

	mod, err := a.moduleLocked(ctx)
	if err != nil {
		return zero, err
	}
	v, err := fn(ctx, mod)
	if err != nil {
		a.retireLocked(ctx)
		return zero, err
	}
	return v, nil
}

// An ArgKind distinguishes the two shapes a guest argument can take.
type ArgKind int

const (
	// KindScalar is a single i32 passed by value.
	KindScalar ArgKind = iota
	// KindBuffer is a byte slice, which the guest receives as two i32s: a
	// pointer into linear memory and a length.
	KindBuffer
)

// An Arg is one entry in a guest call's argument list.
type Arg struct {
	kind   ArgKind
	scalar uint32
	buf    []byte
}

// Scalar returns an argument passed to the guest verbatim as one i32.
func Scalar(v uint32) Arg { return Arg{kind: KindScalar, scalar: v} }

// Buffer returns an argument whose bytes are copied into guest memory before
// the call and freed after it. It fills two of the guest's i32 parameters,
// pointer then length.
func Buffer(b []byte) Arg { return Arg{kind: KindBuffer, buf: b} }

// region is one guest allocation, recorded with the length it was made with —
// which is the length dealloc must be given back, not the length of whatever
// was written into it.
type region struct {
	ptr  uint32
	size uint32
}

// Call copies every Buffer argument into guest memory, invokes the export
// named fn, and decodes its result envelope according to l.
//
// The returned Result owns its bytes. Everything is copied out of linear
// memory before the lock is released, because the guest may move that memory
// on the very next call.
func Call(ctx context.Context, fn string, l Layout, args ...Arg) (Result, error) {
	// Reject oversized input up front, on the host, so that a caller's mistake
	// costs nothing more than an error — in particular, so it does not travel
	// through exec and retire a perfectly healthy instance.
	for _, arg := range args {
		if arg.kind != KindBuffer {
			continue
		}
		if _, err := bufferSize(len(arg.buf)); err != nil {
			return Result{}, err
		}
	}
	return exec(ctx, func(ctx context.Context, mod api.Module) (Result, error) {
		return invoke(ctx, mod, fn, l, args)
	})
}

func invoke(ctx context.Context, mod api.Module, fn string, l Layout, args []Arg) (Result, error) {
	target, err := lookup(mod, fn)
	if err != nil {
		return Result{}, err
	}
	alloc, err := lookup(mod, allocFn)
	if err != nil {
		return Result{}, err
	}
	dealloc, err := lookup(mod, deallocFn)
	if err != nil {
		return Result{}, err
	}

	// Every error from here on retires the instance (see exec), and retiring
	// reclaims all of its linear memory at once. That is why the failure paths
	// below free nothing: there is nothing left to free.
	params := make([]uint64, 0, 2*len(args))
	inputs := make([]region, 0, len(args))
	for _, arg := range args {
		if arg.kind == KindScalar {
			params = append(params, uint64(arg.scalar))
			continue
		}
		r, err := writeBuffer(ctx, mod, alloc, arg.buf)
		if err != nil {
			return Result{}, err
		}
		inputs = append(inputs, r)
		params = append(params, uint64(r.ptr), uint64(len(arg.buf)))
	}

	ptr, err := call1(ctx, target, fn, params...)
	if err != nil {
		return Result{}, err
	}
	if ptr == 0 {
		// The guest's only ABI-level error channel.
		return Result{}, fmt.Errorf("%w: %s returned a null result", ErrInternal, fn)
	}

	// Take the memory view now, after the call: the guest allocates while it
	// runs, and a growing linear memory invalidates any view taken earlier.
	res, total, err := l.decode(mod.Memory(), ptr)
	if err != nil {
		return Result{}, err
	}

	// Give back the inputs and the envelope in one pass. Result already owns
	// copies of everything worth keeping, so nothing here is still referenced.
	if err := freeRegions(ctx, dealloc, append(inputs, region{ptr: ptr, size: total})...); err != nil {
		return Result{}, err
	}
	return res, nil
}

// writeBuffer copies b into a fresh guest allocation and returns the region to
// free afterwards.
//
// An empty slice still allocates one byte. Zig's allocator may return any
// pointer at all for a zero-length request — including 0, which is the value
// this ABI reserves for "allocation failed" — so asking for zero bytes risks an
// answer the host cannot tell from an error. Asking for one byte cannot. The
// length passed to the guest stays 0; the length passed to dealloc must be the
// 1 that was allocated. The npm package does the same (_writeString in
// packages/js-npm/lib/_core.cjs).
func writeBuffer(ctx context.Context, mod api.Module, alloc api.Function, b []byte) (region, error) {
	size, err := bufferSize(len(b))
	if err != nil {
		return region{}, err
	}
	if size == 0 {
		size = 1
	}
	ptr, err := call1(ctx, alloc, allocFn, uint64(size))
	if err != nil {
		return region{}, err
	}
	if ptr == 0 {
		return region{}, fmt.Errorf("%w: allocating %d guest bytes", ErrInternal, size)
	}
	if len(b) > 0 && !mod.Memory().Write(ptr, b) {
		return region{}, fmt.Errorf("wgslender: writing %d bytes at %#x is out of range", len(b), ptr)
	}
	return region{ptr: ptr, size: size}, nil
}

// bufferSize narrows a host slice length to the u32 the guest takes, or
// reports that it does not fit the guest's address space. The guest cannot
// detect this for us: it would receive a truncated length and quietly operate
// on the wrong bytes.
func bufferSize(n int) (uint32, error) {
	if uint64(n) > math.MaxUint32 {
		return 0, fmt.Errorf("%w: %d bytes", ErrSourceTooLarge, n)
	}
	return uint32(n), nil
}

func freeRegions(ctx context.Context, dealloc api.Function, rs ...region) error {
	for _, r := range rs {
		if _, err := dealloc.Call(ctx, uint64(r.ptr), uint64(r.size)); err != nil {
			return fmt.Errorf("wgslender: freeing %d bytes at %#x: %w", r.size, r.ptr, err)
		}
	}
	return nil
}

// lookup returns the named guest export. A miss means the embedded artifact is
// not the one this package was written against, so it names what is missing
// rather than panicking on a nil function.
func lookup(mod api.Module, name string) (api.Function, error) {
	fn := mod.ExportedFunction(name)
	if fn == nil {
		return nil, fmt.Errorf("wgslender: the embedded wasm exports no %s", name)
	}
	return fn, nil
}

// call1 invokes a guest function that returns exactly one i32. Every export in
// this ABI has that shape except wgslender_dealloc, which returns nothing.
func call1(ctx context.Context, fn api.Function, name string, params ...uint64) (uint32, error) {
	res, err := fn.Call(ctx, params...)
	if err != nil {
		return 0, fmt.Errorf("wgslender: calling %s: %w", name, err)
	}
	if len(res) != 1 {
		return 0, fmt.Errorf("wgslender: %s returned %d values, want 1", name, len(res))
	}
	return uint32(res[0]), nil
}

// Version returns the version string compiled into the guest.
//
// Unlike every other result, this one points at static data inside linear
// memory rather than at an allocation, so it must never be freed.
func Version(ctx context.Context) (string, error) {
	return exec(ctx, func(ctx context.Context, mod api.Module) (string, error) {
		ptrFn, err := lookup(mod, versionFn)
		if err != nil {
			return "", err
		}
		lenFn, err := lookup(mod, versionLenFn)
		if err != nil {
			return "", err
		}
		ptr, err := call1(ctx, ptrFn, versionFn)
		if err != nil {
			return "", err
		}
		n, err := call1(ctx, lenFn, versionLenFn)
		if err != nil {
			return "", err
		}
		raw, ok := mod.Memory().Read(ptr, n)
		if !ok {
			return "", fmt.Errorf("wgslender: version string at %#x (%d bytes) is out of range", ptr, n)
		}
		return string(raw), nil
	})
}

var checksum = sync.OnceValue(func() [32]byte { return sha256.Sum256(guestWasm) })

// Checksum returns the SHA-256 of the embedded wasm. The wgslender package
// pins it against packages/js-npm/wgslender.wasm; that pin is the only thing
// stopping the two copies from drifting apart unnoticed.
func Checksum() [32]byte { return checksum() }
