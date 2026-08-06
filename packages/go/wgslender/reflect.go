package wgslender

import (
	"context"
	"encoding/json"
	"fmt"

	"git.hugodaniel.com/hugo/wgslender/packages/go/internal/wasmabi"
)

// reflectFn is the guest export behind [Reflect] and [ReflectJSON].
const reflectFn = "wgslender_reflect"

// Reflect describes a shader's interface: its bindings, structs, entry points,
// overrides, aliases and call graph. See [Reflection].
//
// A shader that does not parse is not a Go error: what the parser managed to
// read comes back, with the complaints in [Reflection.Errors]. The returned
// error is reserved for a call that could not be made or trusted — see
// [ErrInvalidUTF8], [ErrSourceTooLarge] and [ErrInternal].
func Reflect(ctx context.Context, source string) (Reflection, error) {
	raw, err := ReflectJSON(ctx, source)
	if err != nil {
		return Reflection{}, err
	}
	var r Reflection
	if err := json.Unmarshal(raw, &r); err != nil {
		return Reflection{}, fmt.Errorf("wgslender: decoding the reflect envelope: %w", err)
	}
	return r, nil
}

// ReflectJSON is [Reflect] without the decoding: the engine's own schema-v2
// document, verbatim.
//
// Reach for it when you want to forward the reflection somewhere else — a build
// manifest, a generator, another language — or when you need a key that
// [Reflection] does not model. The bytes are a fresh copy and yours to keep.
func ReflectJSON(ctx context.Context, source string) ([]byte, error) {
	if err := checkUTF8("source", source); err != nil {
		return nil, err
	}
	res, err := wasmabi.Call(ctx, reflectFn, wasmabi.PackLenPrefixed, wasmabi.Buffer([]byte(source)))
	if err != nil {
		return nil, err
	}
	return res.Payloads[0], nil
}

// BindGroups arranges bindings the way a WebGPU host consumes them: by group,
// then by slot within the group.
//
// It is a map of maps rather than slices because bind groups are sparse. A
// shader may bind @group(0) @binding(0) and @group(0) @binding(2) and nothing
// between them, and may skip a whole group; indexing a slice would invent the
// gaps as zero values. The returned map is never nil, so an empty grid is still
// safe to index.
//
//	for group, slots := range wgslender.BindGroups(r.Bindings) {
//		for slot, b := range slots {
//			fmt.Println(group, slot, b.Name, b.AddressSpace)
//		}
//	}
func BindGroups(bindings []Binding) map[uint32]map[uint32]Binding {
	groups := make(map[uint32]map[uint32]Binding)
	for _, b := range bindings {
		slots, ok := groups[b.Group]
		if !ok {
			slots = make(map[uint32]Binding)
			groups[b.Group] = slots
		}
		slots[b.Binding] = b
	}
	return groups
}
