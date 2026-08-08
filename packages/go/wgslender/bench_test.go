package wgslender_test

import (
	"context"
	"fmt"
	"strings"
	"testing"

	"github.com/HugoDaniel/wgslender/packages/go/wgslender"
)

// largeWGSL is a synthetic shader two orders of magnitude bigger than the
// fixtures, so that a benchmark over it measures the engine rather than the
// per-call overhead of crossing into it.
//
// It is generated rather than checked in because the only thing that matters
// about it is its size and its shape: many small functions, all reachable from
// the entry point so that tree shaking cannot delete the work.
var largeWGSL = buildLargeWGSL(200)

func buildLargeWGSL(helpers int) string {
	var b strings.Builder
	for i := range helpers {
		fmt.Fprintf(&b, "fn helper%[1]d(x: f32) -> f32 {\n"+
			"    let scaled = x * %[1]d.0 + 1.5;\n"+
			"    return scaled / (abs(scaled) + 1.0);\n"+
			"}\n\n", i)
	}
	b.WriteString("@compute @workgroup_size(64)\n" +
		"fn main(@builtin(global_invocation_id) gid: vec3<u32>) {\n" +
		"    var acc = f32(gid.x);\n")
	for i := range helpers {
		fmt.Fprintf(&b, "    acc = helper%d(acc);\n", i)
	}
	b.WriteString("    _ = acc;\n}\n")
	return b.String()
}

// benchShaders are the two sizes every serial benchmark runs at. The small one
// is a hand-written fixture under a kilobyte; the large one is generated above
// at roughly twenty.
var benchShaders = []struct {
	name string
	src  string
}{
	{"Small", demoWGSL},
	{"Large", largeWGSL},
}

// warm makes the call once before it is timed.
//
// Without this the first iteration would carry the ~130 ms one-time compilation
// of the embedded module, which at any realistic benchtime swamps everything
// being measured — a 57 µs call reported as 867 µs, all of it setup. b.Loop
// resets the timer when the loop starts, so in the serial benchmarks the
// warm-up costs nothing; b.RunParallel never resets, so the parallel ones
// call b.ResetTimer themselves after warming.
func warm(b *testing.B, call func(context.Context) error) {
	b.Helper()
	if err := call(b.Context()); err != nil {
		b.Fatal(err)
	}
}

// serial runs one call at both fixture sizes.
func serial(b *testing.B, call func(context.Context, string) error) {
	for _, s := range benchShaders {
		b.Run(s.name, func(b *testing.B) {
			ctx := b.Context()
			warm(b, func(ctx context.Context) error { return call(ctx, s.src) })
			b.ReportAllocs()
			b.SetBytes(int64(len(s.src)))
			for b.Loop() {
				if err := call(ctx, s.src); err != nil {
					b.Fatal(err)
				}
			}
		})
	}
}

func BenchmarkMinify(b *testing.B) {
	serial(b, func(ctx context.Context, src string) error {
		_, err := wgslender.Minify(ctx, src, nil)
		return err
	})
}

func BenchmarkValidate(b *testing.B) {
	serial(b, func(ctx context.Context, src string) error {
		_, err := wgslender.Validate(ctx, src, wgslender.DefaultStrictness)
		return err
	})
}

func BenchmarkReflect(b *testing.B) {
	serial(b, func(ctx context.Context, src string) error {
		_, err := wgslender.Reflect(ctx, src)
		return err
	})
}

func BenchmarkCompile(b *testing.B) {
	serial(b, func(ctx context.Context, src string) error {
		_, err := wgslender.Compile(ctx, src, nil)
		return err
	})
}

// BenchmarkParallelMinify is the one that decides how the engine is shared.
//
// Run it across -cpu 1,2,4,8: with a single instance behind a lock the
// per-operation cost can only stay flat at best, because the work is serialised
// however many goroutines ask for it. Anything that improves here has bought
// real parallelism; anything that does not has bought memory and complexity for
// nothing.
func BenchmarkParallelMinify(b *testing.B) {
	ctx := b.Context()
	minify := func(ctx context.Context) error {
		_, err := wgslender.Minify(ctx, demoWGSL, nil)
		return err
	}
	warm(b, minify)
	b.ReportAllocs()
	b.SetBytes(int64(len(demoWGSL)))
	b.ResetTimer()
	b.RunParallel(func(pb *testing.PB) {
		for pb.Next() {
			if err := minify(ctx); err != nil {
				b.Error(err)
				return
			}
		}
	})
}

// BenchmarkParallelMixed asks the same question of a realistic workload:
// several families at once, with different envelope shapes and different peak
// allocations inside the guest.
func BenchmarkParallelMixed(b *testing.B) {
	ctx := b.Context()
	calls := []func(context.Context) error{
		func(ctx context.Context) error { _, err := wgslender.Minify(ctx, demoWGSL, nil); return err },
		func(ctx context.Context) error {
			_, err := wgslender.Validate(ctx, renderWGSL, wgslender.DefaultStrictness)
			return err
		},
		func(ctx context.Context) error { _, err := wgslender.Reflect(ctx, demoWGSL); return err },
		func(ctx context.Context) error {
			_, err := wgslender.Lint(ctx, warningWGSL, &wgslender.LintConfig{
				Extends: []wgslender.Pack{wgslender.PackRecommended},
			})
			return err
		},
	}
	for _, call := range calls {
		warm(b, call)
	}
	b.ReportAllocs()
	b.ResetTimer()
	b.RunParallel(func(pb *testing.PB) {
		i := 0
		for pb.Next() {
			if err := calls[i%len(calls)](ctx); err != nil {
				b.Error(err)
				return
			}
			i++
		}
	})
}
