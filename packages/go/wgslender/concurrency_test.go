package wgslender_test

import (
	"context"
	"crypto/sha256"
	"errors"
	"fmt"
	"sync"
	"testing"
	"time"

	"github.com/HugoDaniel/wgslender/packages/go/wgslender"
)

// A stressOp is one call whose answer depends on nothing but its input, so the
// answer it gives under contention can be checked against the answer it gives
// with nothing else running.
//
// run returns a digest rather than the result itself: the point is only whether
// two runs agree, and a digest keeps a failure message readable when the result
// is a shader or a WebAssembly module.
type stressOp struct {
	name string
	run  func(context.Context) (string, error)
}

// stressOps covers every family in the package, because they do not share a
// failure mode. Minification, validation and compilation each drive the guest
// allocator differently — different envelope shapes, different peak sizes —
// and interleaving one family with itself would not exercise that.
func stressOps(t *testing.T) []stressOp {
	t.Helper()
	// Resolved here, on the test goroutine, because offsetOf can Fatal and
	// the closures below run inside worker goroutines, where Fatal is not
	// allowed to be called.
	lum := offsetOf(t, demoWGSL, "luminance")
	return []stressOp{
		{"Version", func(ctx context.Context) (string, error) {
			return wgslender.Version(ctx)
		}},
		{"Minify", func(ctx context.Context) (string, error) {
			r, err := wgslender.Minify(ctx, demoWGSL, nil)
			if err != nil {
				return "", err
			}
			return fmt.Sprintf("%d→%d %s", r.OriginalSize, r.MinifiedSize, r.Code), nil
		}},
		{"MinifyAndReflect", func(ctx context.Context) (string, error) {
			r, err := wgslender.MinifyAndReflect(ctx, renderWGSL, nil)
			if err != nil {
				return "", err
			}
			return fmt.Sprintf("%s | %d bindings, %d entry points",
				r.Code, len(r.Reflection.Bindings), len(r.Reflection.EntryPoints)), nil
		}},
		{"Validate", func(ctx context.Context) (string, error) {
			v, err := wgslender.Validate(ctx, invalidWGSL, wgslender.DefaultStrictness)
			if err != nil {
				return "", err
			}
			return fmt.Sprintf("valid=%t errors=%d warnings=%d diagnostics=%d",
				v.Valid, v.ErrorCount, v.WarningCount, len(v.Diagnostics)), nil
		}},
		{"Lint", func(ctx context.Context) (string, error) {
			r, err := wgslender.Lint(ctx, warningWGSL, &wgslender.LintConfig{
				Extends: []wgslender.Pack{wgslender.PackRecommended},
			})
			if err != nil {
				return "", err
			}
			return fmt.Sprintf("errors=%d warnings=%d fixable=%d diagnostics=%d",
				r.ErrorCount, r.WarningCount, r.FixableCount, len(r.Diagnostics)), nil
		}},
		{"Reflect", func(ctx context.Context) (string, error) {
			r, err := wgslender.Reflect(ctx, demoWGSL)
			if err != nil {
				return "", err
			}
			return fmt.Sprintf("%d bindings, %d structs, %d entry points",
				len(r.Bindings), len(r.Structs), len(r.EntryPoints)), nil
		}},
		{"Compile", func(ctx context.Context) (string, error) {
			c, err := wgslender.Compile(ctx, demoWGSL, nil)
			if err != nil {
				return "", err
			}
			return fmt.Sprintf("%d bytes from %d, sha %x",
				len(c.WASM), c.OriginalSize, sha256.Sum256(c.WASM)), nil
		}},
		{"RenameApply", func(ctx context.Context) (string, error) {
			a, err := wgslender.RenameApply(ctx, demoWGSL, lum, "lum")
			if err != nil {
				return "", err
			}
			return fmt.Sprintf("%d edits | %s", len(a.Edits), a.Source), nil
		}},
	}
}

// TestConcurrentCallsAreIndependent is the correctness pin under which the rest
// of this file's measurements are allowed to change anything.
//
// One guest instance is one single-threaded Zig allocator, and two calls
// running through it at once corrupt its heap. That corruption is not a Go data
// race — the detector sees an opaque function call and has nothing to say about
// it — and it does not reliably announce itself either: the failure mode to
// fear is an instance that goes on answering, plausibly and wrongly. So the
// assertion here is not "nothing crashed" but "every answer equals the one that
// call gives in isolation".
//
// The test has teeth. Driven at the raw ABI with no exclusion at all, this
// shape failed 959 of 960 calls; releasing an instance back to the pool one
// line before the call that uses it kills the process outright, with a stack
// overflow raised from inside the guest.
func TestConcurrentCallsAreIndependent(t *testing.T) {
	t.Parallel()

	ctx := t.Context()
	ops := stressOps(t)

	// The answers, one at a time, with nothing else running.
	want := make([]string, len(ops))
	for i, op := range ops {
		got, err := op.run(ctx)
		if err != nil {
			t.Fatalf("%s in isolation: %v", op.name, err)
		}
		want[i] = got
	}

	const (
		goroutines = 12
		rounds     = 16
	)

	var wg sync.WaitGroup
	for g := range goroutines {
		wg.Go(func() {
			for r := range rounds {
				// Start each goroutine at a different op so they interleave
				// different families rather than marching in step through the
				// same one.
				i := (g + r) % len(ops)
				got, err := ops[i].run(ctx)
				if err != nil {
					t.Errorf("goroutine %d round %d: %s: %v", g, r, ops[i].name, err)
					return
				}
				if got != want[i] {
					t.Errorf("goroutine %d round %d: %s answered differently under contention\n got: %s\nwant: %s",
						g, r, ops[i].name, got, want[i])
					return
				}
			}
		})
	}
	wg.Wait()
}

// TestCancelledContextIsRefused pins that the context every call takes is not
// decoration.
//
// A caller whose work has already been abandoned should not reach the engine at
// all: the queue in front of it may be long, and joining that queue to compute
// an answer nobody is waiting for costs the callers who are still there. The
// error has to satisfy errors.Is against the standard causes, because that is
// the only thing callers can usefully branch on.
func TestCancelledContextIsRefused(t *testing.T) {
	t.Parallel()

	for _, tc := range []struct {
		name string
		ctx  func(t *testing.T) context.Context
		want error
	}{
		{
			name: "cancelled",
			ctx: func(t *testing.T) context.Context {
				ctx, cancel := context.WithCancel(t.Context())
				cancel()
				return ctx
			},
			want: context.Canceled,
		},
		{
			name: "deadline passed",
			ctx: func(t *testing.T) context.Context {
				ctx, cancel := context.WithTimeout(t.Context(), -time.Nanosecond)
				t.Cleanup(cancel)
				return ctx
			},
			want: context.DeadlineExceeded,
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			ctx := tc.ctx(t)

			for _, call := range []struct {
				name string
				run  func() error
			}{
				{"Version", func() error { _, err := wgslender.Version(ctx); return err }},
				{"Minify", func() error { _, err := wgslender.Minify(ctx, demoWGSL, nil); return err }},
				{"Validate", func() error { _, err := wgslender.Validate(ctx, demoWGSL, wgslender.DefaultStrictness); return err }},
				{"Compile", func() error { _, err := wgslender.Compile(ctx, demoWGSL, nil); return err }},
				{"Rename", func() error {
					_, err := wgslender.Rename(ctx, demoWGSL, offsetOf(t, demoWGSL, "luminance"), "lum")
					return err
				}},
			} {
				if err := call.run(); !errors.Is(err, tc.want) {
					t.Errorf("%s with a %s context = %v, want one wrapping %v", call.name, tc.name, err, tc.want)
				}
			}
		})
	}
}

// TestCancellingOneCallLeavesTheRestAlone guards the obvious way to get the
// test above wrong: refusing the cancelled caller by retiring the instance, or
// by leaving the lock held, would break every other caller too.
func TestCancellingOneCallLeavesTheRestAlone(t *testing.T) {
	t.Parallel()

	want, err := wgslender.Minify(t.Context(), demoWGSL, nil)
	if err != nil {
		t.Fatalf("Minify before: %v", err)
	}

	dead, cancel := context.WithCancel(t.Context())
	cancel()
	if _, err := wgslender.Minify(dead, demoWGSL, nil); !errors.Is(err, context.Canceled) {
		t.Fatalf("Minify with a cancelled context = %v, want one wrapping context.Canceled", err)
	}

	got, err := wgslender.Minify(t.Context(), demoWGSL, nil)
	if err != nil {
		t.Fatalf("Minify after: %v", err)
	}
	if got.Code != want.Code {
		t.Errorf("a cancelled call disturbed the next one\n got: %s\nwant: %s", got.Code, want.Code)
	}
}
