package wasmabi

import (
	"context"
	"testing"
)

// leakShader is small on purpose: this test is counting allocator balance, not
// timing anything, and a smaller shader means more iterations per second.
const leakShader = `@compute @workgroup_size(1)
fn main() {
	let x = 1.0 + 2.0;
	_ = x;
}
`

// TestGuestMemoryStabilises is the unbalanced-free detector.
//
// Every call allocates inside the guest — the input buffers and the result
// envelope — and hands all of it back through wgslender_dealloc. A length this
// package gets wrong there is not a reported error but undefined behaviour
// inside the Zig allocator, and the visible symptom of the benign half of that
// undefined behaviour is linear memory that never stops growing.
//
// So the assertion is exact rather than a threshold. Growth here means a real
// imbalance, not noise: once the allocator has reached its high-water mark the
// same call repeated cannot need more room, and 10,000 repetitions moved it by
// zero bytes when this was written.
func TestGuestMemoryStabilises(t *testing.T) {
	const (
		warmup     = 200
		iterations = 10000
	)

	// One borrowed instance for the whole run, so what is measured is that
	// instance's memory rather than whichever instance a later change hands
	// out per call.
	_, err := exec(t.Context(), func(ctx context.Context, inst *instance) (struct{}, error) {
		minify := func() error {
			_, err := invoke(ctx, inst, "wgslender_minify_json", PackLenPrefixed,
				[]Arg{Buffer([]byte(leakShader)), Buffer(nil)})
			return err
		}

		// The first calls legitimately grow memory: the allocator is reaching
		// its high-water mark for this shape of work. Only what happens after
		// that is evidence of anything.
		for range warmup {
			if err := minify(); err != nil {
				return struct{}{}, err
			}
		}
		before := inst.mod.Memory().Size()

		for i := range iterations {
			if err := minify(); err != nil {
				return struct{}{}, err
			}
			if got := inst.mod.Memory().Size(); got != before {
				t.Errorf("guest memory grew from %d to %d bytes on iteration %d of %d\n"+
					"a repeated call cannot need more room once it has run once: "+
					"some allocation is being freed with the wrong length, or not at all",
					before, got, i+1, iterations)
				return struct{}{}, nil
			}
		}
		return struct{}{}, nil
	})
	if err != nil {
		t.Fatalf("minifying: %v", err)
	}
}
