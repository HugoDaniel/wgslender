// Package wasmabi is the boundary between Go and the WGSLender WebAssembly
// module. It owns the embedded artifact, the wazero runtime, the pool of guest
// instances calls run on, and the copy-in/copy-out discipline those instances
// require.
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
	"runtime"
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

// An instance is one guest: a wazero module, and the exported functions this
// package calls on it.
//
// Both halves are per-instance because neither is shareable. The guest's
// allocator is single-threaded, so two calls into one module at once corrupt
// its heap; and wazero's api.Module.ExportedFunction does not return a handle
// but builds a call engine, with a stack of its own, on every invocation —
// which is both why the handles are cached here and why the cache cannot be
// shared between instances.
type instance struct {
	mod api.Module
	fns map[string]api.Function
}

// fn returns the named export, looking it up at most once per instance.
//
// Caching matters more than it looks. Every ExportedFunction cloned a fresh
// execution stack, and there are six guest calls behind one minify: looking
// them up afresh each time cost 58 kB per Minify, against 2.6 kB once they are
// kept.
func (i *instance) fn(name string) (api.Function, error) {
	if f, ok := i.fns[name]; ok {
		return f, nil
	}
	f := i.mod.ExportedFunction(name)
	if f == nil {
		return nil, fmt.Errorf("wgslender: the embedded wasm exports no %s", name)
	}
	i.fns[name] = f
	return f, nil
}

// memoryLimit is how much linear memory a pooled instance may keep.
//
// Guest memory only ever grows: it is a Zig arena that reaches the high-water
// mark of the largest shader it has seen and stays there. A fresh instance
// settles at about 1.8 MB and rises by roughly 70 bytes per byte of source, so
// this limit is reached by a shader of about 90 kB — far larger than anything
// typical, and small enough that one outlier cannot leave a pool full of
// instances holding tens of megabytes each for the rest of the process.
//
// Exceeding it is not an error. The instance is closed instead of pooled, and
// the next caller gets a small one for the ~32 µs an instantiation costs.
const memoryLimit = 8 << 20

// oversized reports whether this instance has grown too large to keep.
func (i *instance) oversized() bool {
	return i.mod.Memory().Size() > memoryLimit
}

// close releases the instance's linear memory.
//
// It has to be explicit: wazero threads every instance onto a list rooted in
// the runtime — anonymous ones included — so an instance merely dropped stays
// reachable, and its memory stays resident, for the life of the process. That
// is also why the pool below is a channel rather than a sync.Pool: a sync.Pool
// discards its contents at GC without telling anyone, and every discarded
// instance would be a permanent leak.
func (i *instance) close(ctx context.Context) {
	_ = i.mod.Close(ctx)
}

// abi holds the process-wide guest: one compiled module, and the instances
// calls run on.
//
// The pool is two channels rather than one, and neither is a sync.Pool. Idle
// instances are one; permission to build another is the other. Their combined
// count is invariant — an instance exists exactly where a permit does not — so
// idle plus permits plus borrowed always equals poolSize, and neither channel
// can block on send.
type abi struct {
	rt       wazero.Runtime
	compiled wazero.CompiledModule

	// idle holds instances nobody is using.
	idle chan *instance
	// permits holds the right to create an instance, one token per instance
	// that does not yet exist. It is what bounds the pool.
	permits chan struct{}
}

// poolSize is how many instances may exist at once.
//
// One per processor is the ceiling worth having: the calls are CPU-bound with
// no I/O, so an instance beyond that has nothing to run on. The cap of eight on
// top of that keeps a large machine from turning a burst of goroutines into
// hundreds of megabytes of guest memory, and gives up very little — eight-way
// minification measured 7.2× the throughput of one.
//
// Instances are built lazily and reused in preference to being built, so a
// program that never calls concurrently never pays for more than one.
func poolSize() int {
	return max(1, min(runtime.GOMAXPROCS(0), 8))
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
	n := poolSize()
	a := &abi{
		rt:       rt,
		compiled: compiled,
		idle:     make(chan *instance, n),
		permits:  make(chan struct{}, n),
	}
	for range n {
		a.permits <- struct{}{}
	}
	return a, nil
}

// instantiate builds one guest.
func (a *abi) instantiate(ctx context.Context) (*instance, error) {
	// An empty name keeps the instance out of wazero's module registry, so
	// instances cannot collide over a name — neither with each other, nor with
	// one that was retired a moment ago.
	mod, err := a.rt.InstantiateModule(ctx, a.compiled, wazero.NewModuleConfig().WithName(""))
	if err != nil {
		return nil, fmt.Errorf("wgslender: instantiating the wasm module: %w", err)
	}
	inst := &instance{mod: mod, fns: make(map[string]api.Function, 8)}
	// The two exports every call needs, resolved once and up front so that a
	// mismatched artifact is reported here rather than half-way through a call.
	for _, name := range [...]string{allocFn, deallocFn} {
		if _, err := inst.fn(name); err != nil {
			inst.close(ctx)
			return nil, err
		}
	}
	return inst, nil
}

// acquire borrows an instance, building one if none is idle and the pool has
// room for another.
func (a *abi) acquire(ctx context.Context) (*instance, error) {
	// Checked before the selects rather than inside them, because a select
	// whose cases are both ready picks at random: a caller who has already
	// given up must be turned away even when an instance is sitting there free.
	if err := ctx.Err(); err != nil {
		return nil, fmt.Errorf("wgslender: %w", err)
	}
	// Reuse before create, and for the same reason: the blocking select below
	// would choose at random between an idle instance and a permit to build
	// one, so a program calling sequentially would build a whole pool it never
	// uses two of.
	select {
	case inst := <-a.idle:
		return inst, nil
	default:
	}
	select {
	case inst := <-a.idle:
		return inst, nil
	case <-a.permits:
		inst, err := a.instantiate(ctx)
		if err != nil {
			// Give the permit back. Keeping it would shrink the pool by one for
			// the rest of the process over a transient failure.
			a.permits <- struct{}{}
			return nil, err
		}
		return inst, nil
	case <-ctx.Done():
		return nil, fmt.Errorf("wgslender: %w", ctx.Err())
	}
}

// release returns a borrowed instance to the pool, or retires it.
//
// It retires on any error, because an error means the guest may have trapped
// part-way through an allocation, and a corrupt Zig heap does not announce
// itself — it goes on answering, plausibly and wrongly. A fresh instance costs
// ~32 µs, so there is nothing to gamble for.
func (a *abi) release(ctx context.Context, inst *instance, healthy bool) {
	if !healthy || inst.oversized() {
		inst.close(ctx)
		a.permits <- struct{}{}
		return
	}
	a.idle <- inst
}

// exec runs fn against a borrowed instance. Every guest call in this package
// goes through here, so that the borrow-and-retire rules have exactly one
// implementation to audit.
func exec[T any](ctx context.Context, fn func(context.Context, *instance) (T, error)) (T, error) {
	var zero T
	a, err := shared()
	if err != nil {
		return zero, err
	}
	inst, err := a.acquire(ctx)
	if err != nil {
		return zero, err
	}
	v, err := fn(ctx, inst)
	a.release(ctx, inst, err == nil)
	if err != nil {
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
	// KindText is a string, passed exactly like KindBuffer but written into
	// guest memory straight from the string's own bytes.
	KindText
)

// An Arg is one entry in a guest call's argument list.
type Arg struct {
	kind   ArgKind
	scalar uint32
	buf    []byte
	str    string
}

// Scalar returns an argument passed to the guest verbatim as one i32.
func Scalar(v uint32) Arg { return Arg{kind: KindScalar, scalar: v} }

// Buffer returns an argument whose bytes are copied into guest memory before
// the call and freed after it. It fills two of the guest's i32 parameters,
// pointer then length.
func Buffer(b []byte) Arg { return Arg{kind: KindBuffer, buf: b} }

// Text is [Buffer] for a string. Converting the string to a byte slice first
// would copy it once on the host only for the guest copy to happen anyway;
// this writes the guest copy straight from the string.
func Text(s string) Arg { return Arg{kind: KindText, str: s} }

// dataLen is the byte length the guest will be told about.
func (a Arg) dataLen() int {
	if a.kind == KindText {
		return len(a.str)
	}
	return len(a.buf)
}

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
// memory before the instance is released, because the guest may move that
// memory on the very next call.
func Call(ctx context.Context, fn string, l Layout, args ...Arg) (Result, error) {
	// Reject oversized input up front, on the host, so that a caller's mistake
	// costs nothing more than an error — in particular, so it does not travel
	// through exec and retire a perfectly healthy instance.
	for _, arg := range args {
		if arg.kind == KindScalar {
			continue
		}
		if _, err := bufferSize(arg.dataLen()); err != nil {
			return Result{}, err
		}
	}
	return exec(ctx, func(ctx context.Context, inst *instance) (Result, error) {
		return invoke(ctx, inst, fn, l, args)
	})
}

func invoke(ctx context.Context, inst *instance, fn string, l Layout, args []Arg) (Result, error) {
	target, err := inst.fn(fn)
	if err != nil {
		return Result{}, err
	}
	alloc, err := inst.fn(allocFn)
	if err != nil {
		return Result{}, err
	}
	dealloc, err := inst.fn(deallocFn)
	if err != nil {
		return Result{}, err
	}

	// Every error from here on retires the instance (see release), and retiring
	// reclaims all of its linear memory at once. That is why the failure paths
	// below free nothing: there is nothing left to free.
	params := make([]uint64, 0, 2*len(args))
	inputs := make([]region, 0, len(args))
	for _, arg := range args {
		if arg.kind == KindScalar {
			params = append(params, uint64(arg.scalar))
			continue
		}
		r, err := writeArg(ctx, inst, alloc, arg)
		if err != nil {
			return Result{}, err
		}
		inputs = append(inputs, r)
		params = append(params, uint64(r.ptr), uint64(arg.dataLen()))
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
	res, total, err := l.decode(inst.mod.Memory(), ptr)
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

// writeArg copies a Buffer or Text argument into a fresh guest allocation and
// returns the region to free afterwards.
//
// Empty data still allocates one byte. Zig's allocator may return any
// pointer at all for a zero-length request — including 0, which is the value
// this ABI reserves for "allocation failed" — so asking for zero bytes risks an
// answer the host cannot tell from an error. Asking for one byte cannot. The
// length passed to the guest stays 0; the length passed to dealloc must be the
// 1 that was allocated. The npm package does the same (_writeString in
// packages/js-npm/lib/_core.cjs).
func writeArg(ctx context.Context, inst *instance, alloc api.Function, arg Arg) (region, error) {
	n := arg.dataLen()
	size, err := bufferSize(n)
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
	if n > 0 {
		ok := false
		if arg.kind == KindText {
			ok = inst.mod.Memory().WriteString(ptr, arg.str)
		} else {
			ok = inst.mod.Memory().Write(ptr, arg.buf)
		}
		if !ok {
			return region{}, fmt.Errorf("wgslender: writing %d bytes at %#x is out of range", n, ptr)
		}
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
	return exec(ctx, func(ctx context.Context, inst *instance) (string, error) {
		ptrFn, err := inst.fn(versionFn)
		if err != nil {
			return "", err
		}
		lenFn, err := inst.fn(versionLenFn)
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
		raw, ok := inst.mod.Memory().Read(ptr, n)
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
