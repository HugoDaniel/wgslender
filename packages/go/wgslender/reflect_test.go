package wgslender_test

import (
	"encoding/json"
	"errors"
	"maps"
	"slices"
	"testing"

	"git.hugodaniel.com/hugo/wgslender/packages/go/wgslender"
)

// TestReflect is the behaviour table. Every expectation was read off the live
// engine rather than off a type declaration: the reflect envelope is the
// richest thing this package decodes, and the two places its shape is written
// down elsewhere — the npm .d.ts and the plan's own inventory — were both found
// to be wrong about parts of it.
func TestReflect(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name   string
		source string
		check  func(t *testing.T, got wgslender.Reflection)
	}{
		{
			name:   "the envelope announces its schema version",
			source: demoWGSL,
			check: func(t *testing.T, got wgslender.Reflection) {
				if got.Version != 2 {
					t.Errorf("Version = %d, want 2", got.Version)
				}
			},
		},
		{
			name:   "every binding is found, in declaration order",
			source: demoWGSL,
			check: func(t *testing.T, got wgslender.Reflection) {
				want := []string{"params", "data", "tex", "samp"}
				if names := bindingNames(got.Bindings); !slices.Equal(names, want) {
					t.Errorf("binding names = %q, want %q", names, want)
				}
			},
		},
		{
			name:   "bindings carry their group, slot and address space",
			source: demoWGSL,
			check: func(t *testing.T, got wgslender.Reflection) {
				type slot struct {
					group, binding uint32
					space          wgslender.AddressSpace
					access         wgslender.AccessMode
				}
				want := map[string]slot{
					"params": {0, 0, wgslender.AddressSpaceUniform, ""},
					"data":   {0, 1, wgslender.AddressSpaceStorage, wgslender.AccessReadWrite},
					"tex":    {1, 0, wgslender.AddressSpaceHandle, ""},
					"samp":   {1, 1, wgslender.AddressSpaceHandle, ""},
				}
				for _, b := range got.Bindings {
					w, ok := want[b.Name]
					if !ok {
						t.Errorf("unexpected binding %q", b.Name)
						continue
					}
					if b.Group != w.group || b.Binding != w.binding {
						t.Errorf("%s is at @group(%d) @binding(%d), want @group(%d) @binding(%d)",
							b.Name, b.Group, b.Binding, w.group, w.binding)
					}
					if b.AddressSpace != w.space {
						t.Errorf("%s AddressSpace = %q, want %q", b.Name, b.AddressSpace, w.space)
					}
					// AccessMode is spelled only where WGSL spells it: a
					// storage binding has one, a uniform or handle binding
					// does not.
					if b.AccessMode != w.access {
						t.Errorf("%s AccessMode = %q, want %q", b.Name, b.AccessMode, w.access)
					}
				}
			},
		},
		{
			name:   "a struct-typed binding carries its whole layout",
			source: demoWGSL,
			check: func(t *testing.T, got wgslender.Reflection) {
				b := bindingByName(t, got, "params")
				if b.Layout == nil {
					t.Fatal("a uniform struct binding must carry its layout")
				}
				var fields []string
				for _, f := range b.Layout.Fields {
					fields = append(fields, f.Name)
				}
				if want := []string{"resolution", "time", "frame"}; !slices.Equal(fields, want) {
					t.Errorf("field names = %q, want %q", fields, want)
				}
				// Offsets are the whole point of a layout: a host writing this
				// buffer needs them, and they are not the running sum of the
				// field sizes.
				if got, want := b.Layout.Fields[1].Offset, 8; got != want {
					t.Errorf("time is at offset %d, want %d", got, want)
				}
			},
		},
		{
			name:   "an array-typed binding carries ArrayInfo instead of a layout",
			source: demoWGSL,
			check: func(t *testing.T, got wgslender.Reflection) {
				b := bindingByName(t, got, "data")
				if b.Layout != nil {
					t.Errorf("Layout = %+v, want none on an array binding", b.Layout)
				}
				if b.Array == nil {
					t.Fatal("an array binding must carry its ArrayInfo")
				}
				if b.Array.ElementCount != nil {
					t.Errorf("ElementCount = %d, want nil: array<vec4f> is runtime-sized",
						*b.Array.ElementCount)
				}
				if b.Array.TotalSize != nil {
					t.Errorf("TotalSize = %d, want nil for a runtime-sized array", *b.Array.TotalSize)
				}
				if b.Array.ElementStride != 16 {
					t.Errorf("ElementStride = %d, want 16", b.Array.ElementStride)
				}
			},
		},
		{
			name:   "a sampler is handle-space with neither layout nor array",
			source: demoWGSL,
			check: func(t *testing.T, got wgslender.Reflection) {
				b := bindingByName(t, got, "samp")
				if b.AddressSpace != wgslender.AddressSpaceHandle {
					t.Errorf("AddressSpace = %q, want %q", b.AddressSpace, wgslender.AddressSpaceHandle)
				}
				if b.Layout != nil || b.Array != nil {
					t.Errorf("a sampler has no memory layout, got Layout=%+v Array=%+v", b.Layout, b.Array)
				}
				if b.TypeInfo == nil || b.TypeInfo.Kind != wgslender.KindSampler {
					t.Fatalf("TypeInfo = %+v, want kind %q", b.TypeInfo, wgslender.KindSampler)
				}
				if b.TypeInfo.Comparison {
					t.Error("a plain sampler is not a comparison sampler")
				}
			},
		},
		{
			name:   "a texture and the sampler used with it name each other",
			source: demoWGSL,
			check: func(t *testing.T, got wgslender.Reflection) {
				tex := bindingByName(t, got, "tex")
				if !slices.Contains(tex.Relations, "samp") {
					t.Errorf("tex.Relations = %q, want it to name samp", tex.Relations)
				}
				samp := bindingByName(t, got, "samp")
				if !slices.Contains(samp.Relations, "tex") {
					t.Errorf("samp.Relations = %q, want it to name tex", samp.Relations)
				}
			},
		},
		{
			name:   "the subset views hold whole bindings, not indices",
			source: demoWGSL,
			check: func(t *testing.T, got wgslender.Reflection) {
				for _, v := range []struct {
					name string
					give []wgslender.Binding
					want string
				}{
					{"Uniforms", got.Uniforms, "params"},
					{"Storage", got.Storage, "data"},
					{"Textures", got.Textures, "tex"},
					{"Samplers", got.Samplers, "samp"},
				} {
					if len(v.give) != 1 {
						t.Errorf("%s holds %d bindings, want 1", v.name, len(v.give))
						continue
					}
					if v.give[0].Name != v.want {
						t.Errorf("%s[0].Name = %q, want %q", v.name, v.give[0].Name, v.want)
					}
					// The engine duplicates the binding object into each
					// subset rather than indexing back into Bindings, so the
					// copy has to be complete.
					full := bindingByName(t, got, v.want)
					if v.give[0].Type != full.Type || v.give[0].StableID != full.StableID {
						t.Errorf("%s[0] is not the whole binding:\n got %+v\nwant %+v",
							v.name, v.give[0], full)
					}
				}
			},
		},
		{
			name:   "a compute entry point reports its stage, size and resources",
			source: demoWGSL,
			check: func(t *testing.T, got wgslender.Reflection) {
				if len(got.EntryPoints) != 1 {
					t.Fatalf("got %d entry points, want 1", len(got.EntryPoints))
				}
				ep := got.EntryPoints[0]
				if ep.Name != "main" {
					t.Errorf("Name = %q, want main", ep.Name)
				}
				if ep.Stage != wgslender.StageCompute {
					t.Errorf("Stage = %q, want %q", ep.Stage, wgslender.StageCompute)
				}
				if ep.WorkgroupSize == nil {
					t.Fatal("a compute entry point has a workgroup size")
				}
				if want := [3]int{8, 8, 1}; *ep.WorkgroupSize != want {
					t.Errorf("WorkgroupSize = %v, want %v", *ep.WorkgroupSize, want)
				}
				// Resources are attributed transitively: luminance is called by
				// main and neither of them touches a binding directly except
				// through main's own body.
				for _, want := range []string{"params", "data", "tex", "samp"} {
					if !slices.Contains(ep.Resources, want) {
						t.Errorf("Resources = %q, want it to include %q", ep.Resources, want)
					}
				}
			},
		},
		{
			name:   "an entry point's inputs carry their builtin",
			source: demoWGSL,
			check: func(t *testing.T, got wgslender.Reflection) {
				ep := got.EntryPoints[0]
				if len(ep.Inputs) != 1 {
					t.Fatalf("got %d inputs, want 1", len(ep.Inputs))
				}
				in := ep.Inputs[0]
				if in.Name != "id" || in.Builtin != "global_invocation_id" {
					t.Errorf("input = %+v, want id/global_invocation_id", in)
				}
				if in.Location != nil {
					t.Errorf("Location = %d, want nil: a builtin has no location", *in.Location)
				}
			},
		},
		{
			name:   "the call graph records who calls whom",
			source: demoWGSL,
			check: func(t *testing.T, got wgslender.Reflection) {
				main := functionByName(t, got, "main")
				if !slices.Contains(main.Calls, "luminance") {
					t.Errorf("main.Calls = %q, want it to include luminance", main.Calls)
				}
				if !main.InUse {
					t.Error("an entry point is in use by definition")
				}
				if lum := functionByName(t, got, "luminance"); !lum.InUse {
					t.Error("luminance is called by main, so it is in use")
				}
			},
		},
		{
			name:   "a vertex/fragment pair has no workgroup size",
			source: renderWGSL,
			check: func(t *testing.T, got wgslender.Reflection) {
				if len(got.EntryPoints) != 2 {
					t.Fatalf("got %d entry points, want 2", len(got.EntryPoints))
				}
				for _, ep := range got.EntryPoints {
					if ep.WorkgroupSize != nil {
						t.Errorf("%s (%s) has WorkgroupSize %v, want nil",
							ep.Name, ep.Stage, *ep.WorkgroupSize)
					}
				}
				if got.EntryPoints[0].Stage != wgslender.StageVertex {
					t.Errorf("Stage = %q, want %q", got.EntryPoints[0].Stage, wgslender.StageVertex)
				}
				if got.EntryPoints[1].Stage != wgslender.StageFragment {
					t.Errorf("Stage = %q, want %q", got.EntryPoints[1].Stage, wgslender.StageFragment)
				}
			},
		},
		{
			name:   "a fragment return value has a location but no name",
			source: renderWGSL,
			check: func(t *testing.T, got wgslender.Reflection) {
				fs := entryPointByName(t, got, "fs_main")
				if len(fs.Outputs) != 1 {
					t.Fatalf("got %d outputs, want 1", len(fs.Outputs))
				}
				out := fs.Outputs[0]
				// WGSL gives the return value an attribute, not an identifier,
				// so there is genuinely nothing to call it.
				if out.Name != "" {
					t.Errorf("Name = %q, want empty for a return value", out.Name)
				}
				if out.Location == nil || *out.Location != 0 {
					t.Errorf("Location = %v, want 0", out.Location)
				}
			},
		},
		{
			name:   "a struct-typed entry point IO is flattened to its members",
			source: renderWGSL,
			check: func(t *testing.T, got wgslender.Reflection) {
				vs := entryPointByName(t, got, "vs_main")
				var outs []string
				for _, o := range vs.Outputs {
					outs = append(outs, o.Name)
				}
				if want := []string{"position", "uv"}; !slices.Equal(outs, want) {
					t.Errorf("vs_main outputs = %q, want %q — VertexOut is flattened", outs, want)
				}
			},
		},
		{
			name:   "an override-driven workgroup size folds to a placeholder",
			source: overridesWGSL,
			check: func(t *testing.T, got wgslender.Reflection) {
				ep := got.EntryPoints[0]
				if ep.WorkgroupSize == nil {
					t.Fatal("the attribute is present, so the field is not null")
				}
				// grid is not known until pipeline creation, so the engine
				// reports 0 rather than guessing the default.
				if want := [3]int{0, 1, 1}; *ep.WorkgroupSize != want {
					t.Errorf("WorkgroupSize = %v, want %v", *ep.WorkgroupSize, want)
				}
				if !slices.Contains(ep.Overrides, "grid") {
					t.Errorf("Overrides = %q, want it to name grid", ep.Overrides)
				}
			},
		},
		{
			name:   "overrides report their id, type and default expression",
			source: overridesWGSL,
			check: func(t *testing.T, got wgslender.Reflection) {
				if len(got.Overrides) != 2 {
					t.Fatalf("got %d overrides, want 2", len(got.Overrides))
				}
				grid, scale := got.Overrides[0], got.Overrides[1]
				if grid.ID != nil {
					t.Errorf("grid.ID = %d, want nil: it has no @id", *grid.ID)
				}
				if scale.ID == nil || *scale.ID != 42 {
					t.Errorf("scale.ID = %v, want 42", scale.ID)
				}
				// Default is the expression as written, not an evaluated
				// number — "8u" keeps the suffix that says what type it is.
				if grid.Default != "8u" {
					t.Errorf("grid.Default = %q, want %q", grid.Default, "8u")
				}
				if scale.Default != "1.5" {
					t.Errorf("scale.Default = %q, want %q", scale.Default, "1.5")
				}
			},
		},
		{
			name:   "a type alias is reported with the type it resolves to",
			source: overridesWGSL,
			check: func(t *testing.T, got wgslender.Reflection) {
				if len(got.Aliases) != 1 {
					t.Fatalf("got %d aliases, want 1", len(got.Aliases))
				}
				a := got.Aliases[0]
				if a.Name != "Index" || a.Type != "u32" {
					t.Errorf("alias = %+v, want Index -> u32", a)
				}
			},
		},
		{
			name:   "a storage texture names its format as a string",
			source: overridesWGSL,
			check: func(t *testing.T, got wgslender.Reflection) {
				b := bindingByName(t, got, "out_tex")
				ti := b.TypeInfo
				if ti == nil || ti.Kind != wgslender.KindTexture {
					t.Fatalf("TypeInfo = %+v, want kind %q", ti, wgslender.KindTexture)
				}
				if ti.Dim != wgslender.Dim2D || ti.TexKind != wgslender.TextureStorage {
					t.Errorf("Dim/TexKind = %q/%q, want %q/%q",
						ti.Dim, ti.TexKind, wgslender.Dim2D, wgslender.TextureStorage)
				}
				// The wire calls this "format", the same key a vec uses for its
				// element TypeInfo. A texture's is a plain string.
				if ti.TexFormat != "rgba8unorm" {
					t.Errorf("TexFormat = %q, want rgba8unorm", ti.TexFormat)
				}
				if ti.Format != nil {
					t.Errorf("Format = %+v, want nil: a texture format is not a TypeInfo", ti.Format)
				}
				if ti.Access != wgslender.AccessWrite {
					t.Errorf("Access = %q, want %q", ti.Access, wgslender.AccessWrite)
				}
			},
		},
		{
			name:   "a sized array reports its count and total size",
			source: overridesWGSL,
			check: func(t *testing.T, got wgslender.Reflection) {
				b := bindingByName(t, got, "idx")
				if b.Array == nil {
					t.Fatal("want ArrayInfo")
				}
				if b.Array.ElementCount == nil || *b.Array.ElementCount != 4 {
					t.Errorf("ElementCount = %v, want 4", b.Array.ElementCount)
				}
				if b.Array.TotalSize == nil || *b.Array.TotalSize != 16 {
					t.Errorf("TotalSize = %v, want 16", b.Array.TotalSize)
				}
				// ElementType is the type as written; the alias is not resolved
				// away here, though the TypeInfo underneath it is.
				if b.Array.ElementType != "Index" {
					t.Errorf("ElementType = %q, want Index", b.Array.ElementType)
				}
				if ti := b.TypeInfo; ti == nil || ti.Format == nil || ti.Format.Name != "u32" {
					t.Errorf("TypeInfo.Format = %+v, want the resolved u32", ti)
				}
			},
		},
		{
			name:   "empty source reflects to an envelope of empties",
			source: "",
			check: func(t *testing.T, got wgslender.Reflection) {
				if got.Version != 2 {
					t.Errorf("Version = %d, want 2 even with nothing to report", got.Version)
				}
				for name, n := range map[string]int{
					"Bindings":    len(got.Bindings),
					"Uniforms":    len(got.Uniforms),
					"Storage":     len(got.Storage),
					"Textures":    len(got.Textures),
					"Samplers":    len(got.Samplers),
					"Structs":     len(got.Structs),
					"EntryPoints": len(got.EntryPoints),
					"Overrides":   len(got.Overrides),
					"Functions":   len(got.Functions),
					"Aliases":     len(got.Aliases),
					"Errors":      len(got.Errors),
				} {
					if n != 0 {
						t.Errorf("%s holds %d, want 0", name, n)
					}
				}
			},
		},
		{
			name:   "unparseable source reports errors and still lists functions",
			source: unparseableWGSL,
			check: func(t *testing.T, got wgslender.Reflection) {
				if len(got.Errors) == 0 {
					t.Fatal("the parser's complaints belong in Errors")
				}
				// The call graph is built from whatever the parser recovered,
				// which is what makes reflection useful in an editor: the file
				// is broken but the outline still works.
				fn := functionByName(t, got, "main")
				if fn.InUse {
					t.Error("nothing was resolved, so nothing can be in use")
				}
			},
		},
		{
			name: "a semantic error does not stop reflection",
			// Written out rather than reused from invalidWGSL, which has no
			// entry point and so could not show that the interface still
			// comes through.
			source: "@group(0) @binding(0) var<uniform> u: f32;\n" +
				"@compute @workgroup_size(1) fn main() { _ = undeclared_variable; }",
			check: func(t *testing.T, got wgslender.Reflection) {
				// Errors is the parser's, and the parser was happy. Reflection
				// describes an interface; whether the body type-checks is
				// [Validate]'s question.
				if len(got.Errors) != 0 {
					t.Errorf("Errors = %q, want none: only the parser reports here", got.Errors)
				}
				if len(got.Bindings) != 1 || len(got.EntryPoints) != 1 {
					t.Errorf("got %d bindings and %d entry points, want 1 of each",
						len(got.Bindings), len(got.EntryPoints))
				}
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			got, err := wgslender.Reflect(t.Context(), tt.source)
			if err != nil {
				t.Fatalf("Reflect: %v", err)
			}
			tt.check(t, got)
		})
	}
}

// TestReflectStructLayouts pins the byte layouts against the two fixtures that
// produce them, in one table, because the failure mode this guards is crossing
// them: 24 is layoutWGSL's Inputs and 16 is demoWGSL's Params, and either
// number looks perfectly plausible under the other shader's name.
func TestReflectStructLayouts(t *testing.T) {
	t.Parallel()

	type field struct {
		name           string
		offset, size   int
		alignmentBytes int
	}
	tests := []struct {
		name       string
		source     string
		structName string
		binding    string
		size       int
		alignment  int
		fields     []field
	}{
		{
			name:       "Inputs packs a vec2<u32> between two f32s",
			source:     layoutWGSL,
			structName: "Inputs",
			binding:    "inputs",
			size:       24,
			alignment:  8,
			fields: []field{
				{"time", 0, 4, 4},
				// resolution needs 8-byte alignment, so 4 bytes of padding go
				// in ahead of it. That padding is why the struct is 24 and not
				// 16.
				{"resolution", 8, 8, 8},
				{"brightness", 16, 4, 4},
			},
		},
		{
			name:       "Params leads with its vec2f and needs no padding",
			source:     demoWGSL,
			structName: "Params",
			binding:    "params",
			size:       16,
			alignment:  8,
			fields: []field{
				{"resolution", 0, 8, 8},
				{"time", 8, 4, 4},
				{"frame", 12, 4, 4},
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			got, err := wgslender.Reflect(t.Context(), tt.source)
			if err != nil {
				t.Fatalf("Reflect: %v", err)
			}

			layout, ok := got.Structs[tt.structName]
			if !ok {
				t.Fatalf("Structs has no %q, only %v", tt.structName, structNames(got))
			}
			// The same layout reaches the caller two ways — through the
			// top-level Structs map and hung off the binding that uses it —
			// and they have to agree.
			b := bindingByName(t, got, tt.binding)
			if b.Layout == nil {
				t.Fatalf("binding %q carries no layout", tt.binding)
			}
			for _, l := range []struct {
				via string
				wgslender.StructLayout
			}{{"Structs", layout}, {"Binding.Layout", *b.Layout}} {
				if l.Size != tt.size {
					t.Errorf("%s: Size = %d, want %d", l.via, l.Size, tt.size)
				}
				if l.Alignment != tt.alignment {
					t.Errorf("%s: Alignment = %d, want %d", l.via, l.Alignment, tt.alignment)
				}
				if len(l.Fields) != len(tt.fields) {
					t.Fatalf("%s: %d fields, want %d", l.via, len(l.Fields), len(tt.fields))
				}
				for i, want := range tt.fields {
					f := l.Fields[i]
					if f.Name != want.name || f.Offset != want.offset ||
						f.Size != want.size || f.Alignment != want.alignmentBytes {
						t.Errorf("%s: field %d = %s@%d (%d bytes, align %d), want %s@%d (%d bytes, align %d)",
							l.via, i, f.Name, f.Offset, f.Size, f.Alignment,
							want.name, want.offset, want.size, want.alignmentBytes)
					}
				}
			}
		})
	}
}

// TestReflectWireFacts decodes hand-written envelopes rather than shaders.
//
// Every fact here is about the *shape* of the wire — a null where a value could
// have been, a key that is present-but-empty rather than absent, one key name
// carrying two different types — and each is a shape a change to the fixture
// shaders could stop producing without anyone noticing. Written out by hand,
// they keep saying what they mean whatever the shaders do. The live engine
// still has to produce these shapes, which is what TestReflect is for.
func TestReflectWireFacts(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name  string
		json  string
		check func(t *testing.T, got wgslender.Reflection)
	}{
		{
			name: "a null workgroupSize is nil, not a zero array",
			json: `{"version":2,"entryPoints":[
				{"name":"fs","stage":"fragment","workgroupSize":null,
				 "inputs":[],"outputs":[],"resources":[]}]}`,
			check: func(t *testing.T, got wgslender.Reflection) {
				if got.EntryPoints[0].WorkgroupSize != nil {
					t.Errorf("WorkgroupSize = %v, want nil", *got.EntryPoints[0].WorkgroupSize)
				}
			},
		},
		{
			name: "a workgroup size of all zeroes is still a size",
			json: `{"version":2,"entryPoints":[
				{"name":"cs","stage":"compute","workgroupSize":[0,1,1],
				 "inputs":[],"outputs":[],"resources":[]}]}`,
			check: func(t *testing.T, got wgslender.Reflection) {
				ws := got.EntryPoints[0].WorkgroupSize
				if ws == nil {
					t.Fatal("want a size, got nil — 0 is a value, not an absence")
				}
				if want := [3]int{0, 1, 1}; *ws != want {
					t.Errorf("WorkgroupSize = %v, want %v", *ws, want)
				}
			},
		},
		{
			name: "empty inputs and outputs are present, not absent",
			json: `{"version":2,"entryPoints":[
				{"name":"cs","stage":"compute","workgroupSize":[1,1,1],
				 "inputs":[],"outputs":[],"resources":[]}]}`,
			check: func(t *testing.T, got wgslender.Reflection) {
				ep := got.EntryPoints[0]
				if ep.Inputs == nil || ep.Outputs == nil {
					t.Errorf("Inputs=%v Outputs=%v, want empty slices from an empty array",
						ep.Inputs, ep.Outputs)
				}
			},
		},
		{
			name: "a null override id is nil, not zero",
			json: `{"version":2,"overrides":[
				{"name":"grid","id":null,"type":"u32","default":"8u"},
				{"name":"scale","id":0,"type":"f32","default":"1.5"}]}`,
			check: func(t *testing.T, got wgslender.Reflection) {
				if got.Overrides[0].ID != nil {
					t.Errorf("grid.ID = %d, want nil", *got.Overrides[0].ID)
				}
				// @id(0) is legal and means something different from no @id,
				// which is the whole reason this is a pointer.
				if got.Overrides[1].ID == nil || *got.Overrides[1].ID != 0 {
					t.Errorf("scale.ID = %v, want 0", got.Overrides[1].ID)
				}
			},
		},
		{
			name: "a nested format decodes to a TypeInfo",
			json: `{"version":2,"bindings":[{"group":0,"binding":0,"name":"v",
				"addressSpace":"uniform","type":"vec2<f32>","typeInfo":
				{"kind":"vec","width":2,"size":8,"alignment":8,
				 "format":{"kind":"scalar","name":"f32","size":4,"alignment":4}}}]}`,
			check: func(t *testing.T, got wgslender.Reflection) {
				ti := got.Bindings[0].TypeInfo
				if ti == nil || ti.Format == nil {
					t.Fatalf("TypeInfo = %+v, want a nested Format", ti)
				}
				if ti.Format.Kind != wgslender.KindScalar || ti.Format.Name != "f32" {
					t.Errorf("Format = %+v, want scalar f32", ti.Format)
				}
				if ti.TexFormat != "" {
					t.Errorf("TexFormat = %q, want empty on a vec", ti.TexFormat)
				}
			},
		},
		{
			name: "a texture format decodes to a string under the same key",
			json: `{"version":2,"bindings":[{"group":0,"binding":0,"name":"t",
				"addressSpace":"handle","type":"texture_storage_2d<rgba8unorm, write>",
				"typeInfo":{"kind":"texture","dim":"2d","texKind":"storage",
				 "format":"rgba8unorm","access":"write"}}]}`,
			check: func(t *testing.T, got wgslender.Reflection) {
				ti := got.Bindings[0].TypeInfo
				if ti == nil {
					t.Fatal("want a TypeInfo")
				}
				if ti.TexFormat != "rgba8unorm" {
					t.Errorf("TexFormat = %q, want rgba8unorm", ti.TexFormat)
				}
				if ti.Format != nil {
					t.Errorf("Format = %+v, want nil", ti.Format)
				}
			},
		},
		{
			name: "a runtime-sized array leaves count and size null",
			json: `{"version":2,"bindings":[{"group":0,"binding":0,"name":"d",
				"addressSpace":"storage","accessMode":"read_write","type":"array<u32>",
				"array":{"depth":1,"elementCount":null,"elementStride":4,"totalSize":null,
				 "elementType":"u32","elementTypeMapped":"u32"},
				"typeInfo":{"kind":"array","count":null,"size":null,"stride":4,"alignment":4,
				 "format":{"kind":"scalar","name":"u32","size":4,"alignment":4}}}]}`,
			check: func(t *testing.T, got wgslender.Reflection) {
				b := got.Bindings[0]
				if b.Array == nil || b.Array.ElementCount != nil || b.Array.TotalSize != nil {
					t.Errorf("Array = %+v, want both nullable fields nil", b.Array)
				}
				// The binding-level "array" key and the TypeInfo's own view of
				// the same array are two different objects that both arrive.
				if b.TypeInfo == nil || b.TypeInfo.Count != nil || b.TypeInfo.Size != nil {
					t.Errorf("TypeInfo = %+v, want Count and Size nil", b.TypeInfo)
				}
				if b.TypeInfo.Stride != 4 {
					t.Errorf("Stride = %d, want 4 — a stride is known without a count",
						b.TypeInfo.Stride)
				}
			},
		},
		{
			name: "nested arrays nest through both views",
			json: `{"version":2,"bindings":[{"group":0,"binding":0,"name":"c",
				"addressSpace":"storage","type":"array<array<f32, 2>, 3>",
				"array":{"depth":1,"elementCount":3,"elementStride":8,"totalSize":24,
				 "elementType":"array<f32, 2>","elementTypeMapped":"array<f32, 2>",
				 "array":{"depth":2,"elementCount":2,"elementStride":4,"totalSize":8,
				  "elementType":"f32","elementTypeMapped":"f32"}},
				"typeInfo":{"kind":"array","count":3,"size":24,"stride":8,"alignment":4,
				 "format":{"kind":"array","count":2,"size":8,"stride":4,"alignment":4,
				  "format":{"kind":"scalar","name":"f32","size":4,"alignment":4}}}}]}`,
			check: func(t *testing.T, got wgslender.Reflection) {
				b := got.Bindings[0]
				inner := b.Array.Array
				if inner == nil {
					t.Fatal("want a nested ArrayInfo")
				}
				if inner.Depth != 2 || *inner.ElementCount != 2 {
					t.Errorf("inner = %+v, want depth 2 and count 2", inner)
				}
				ti := b.TypeInfo.Format
				if ti == nil || ti.Kind != wgslender.KindArray || *ti.Count != 2 {
					t.Errorf("TypeInfo.Format = %+v, want an array of 2", ti)
				}
			},
		},
		{
			name: "a struct field can carry a layout of its own",
			json: `{"version":2,"structs":{"Outer":{"size":8,"alignment":4,"fields":[
				{"name":"inner","type":"Inner","offset":0,"size":8,"alignment":4,
				 "layout":{"size":8,"alignment":4,"fields":[
				  {"name":"a","type":"f32","offset":0,"size":4,"alignment":4},
				  {"name":"b","type":"f32","offset":4,"size":4,"alignment":4}]}}]}}}`,
			check: func(t *testing.T, got wgslender.Reflection) {
				f := got.Structs["Outer"].Fields[0]
				if f.Layout == nil {
					t.Fatal("a struct-typed field carries the nested layout")
				}
				if len(f.Layout.Fields) != 2 {
					t.Errorf("nested layout has %d fields, want 2", len(f.Layout.Fields))
				}
			},
		},
		{
			name: "an IO variable can carry an interpolation",
			json: `{"version":2,"entryPoints":[{"name":"vs","stage":"vertex","workgroupSize":null,
				"inputs":[],"resources":[],"outputs":[
				 {"name":"id","location":0,"interpolate":{"type":"flat"},"type":"u32"},
				 {"name":"uv","location":1,"interpolate":{"type":"perspective","sampling":"centroid"},
				  "type":"vec2f"},
				 {"name":"pos","builtin":"position","type":"vec4f"}]}]}`,
			check: func(t *testing.T, got wgslender.Reflection) {
				outs := got.EntryPoints[0].Outputs
				if outs[0].Interpolate == nil || outs[0].Interpolate.Type != "flat" {
					t.Errorf("id.Interpolate = %+v, want flat", outs[0].Interpolate)
				}
				if outs[0].Interpolate.Sampling != "" {
					t.Errorf("Sampling = %q, want empty when unspecified", outs[0].Interpolate.Sampling)
				}
				if outs[1].Interpolate == nil || outs[1].Interpolate.Sampling != "centroid" {
					t.Errorf("uv.Interpolate = %+v, want perspective/centroid", outs[1].Interpolate)
				}
				if outs[2].Interpolate != nil {
					t.Errorf("pos.Interpolate = %+v, want nil", outs[2].Interpolate)
				}
			},
		},
		{
			name: "an absent span reads as a zero span",
			json: `{"version":2,"bindings":[{"group":0,"binding":0,"name":"a",
				"addressSpace":"uniform","type":"f32"}]}`,
			check: func(t *testing.T, got wgslender.Reflection) {
				b := got.Bindings[0]
				// The engine omits a span it could not determine, and its own
				// presence test is end > start, so a zero Span is exactly the
				// absent one.
				if (b.DeclSpan != wgslender.Span{}) {
					t.Errorf("DeclSpan = %+v, want the zero span", b.DeclSpan)
				}
			},
		},
		{
			name: "an unknown severity of type kind survives verbatim",
			json: `{"version":2,"bindings":[{"group":0,"binding":0,"name":"x",
				"addressSpace":"cluster","type":"quaternion",
				"typeInfo":{"kind":"quaternion","name":"quat"}}]}`,
			check: func(t *testing.T, got wgslender.Reflection) {
				b := got.Bindings[0]
				// These are open enums. A wgslender that learns a new address
				// space should not have to ship a new Go package first.
				if b.AddressSpace != "cluster" {
					t.Errorf("AddressSpace = %q, want it passed through", b.AddressSpace)
				}
				if b.TypeInfo == nil || b.TypeInfo.Kind != "quaternion" {
					t.Errorf("TypeInfo = %+v, want kind passed through", b.TypeInfo)
				}
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			var got wgslender.Reflection
			if err := json.Unmarshal([]byte(tt.json), &got); err != nil {
				t.Fatalf("decoding the fixture: %v", err)
			}
			tt.check(t, got)
		})
	}
}

// TestReflectJSON pins the escape hatch: the engine's own document, unread.
func TestReflectJSON(t *testing.T) {
	t.Parallel()

	t.Run("it decodes to the same thing Reflect returns", func(t *testing.T) {
		t.Parallel()
		raw, err := wgslender.ReflectJSON(t.Context(), demoWGSL)
		if err != nil {
			t.Fatalf("ReflectJSON: %v", err)
		}
		var viaJSON wgslender.Reflection
		if err := json.Unmarshal(raw, &viaJSON); err != nil {
			t.Fatalf("decoding ReflectJSON output: %v", err)
		}
		typed, err := wgslender.Reflect(t.Context(), demoWGSL)
		if err != nil {
			t.Fatalf("Reflect: %v", err)
		}
		if len(viaJSON.Bindings) != len(typed.Bindings) {
			t.Fatalf("%d bindings via JSON, %d via Reflect", len(viaJSON.Bindings), len(typed.Bindings))
		}
		for i := range typed.Bindings {
			if viaJSON.Bindings[i].Name != typed.Bindings[i].Name {
				t.Errorf("binding %d: %q via JSON, %q via Reflect",
					i, viaJSON.Bindings[i].Name, typed.Bindings[i].Name)
			}
		}
	})

	t.Run("every collection key is present even when empty", func(t *testing.T) {
		t.Parallel()
		raw, err := wgslender.ReflectJSON(t.Context(), "")
		if err != nil {
			t.Fatalf("ReflectJSON: %v", err)
		}
		var keys map[string]json.RawMessage
		if err := json.Unmarshal(raw, &keys); err != nil {
			t.Fatalf("decoding: %v", err)
		}
		want := []string{
			"version", "bindings", "uniforms", "storage", "textures", "samplers",
			"structs", "entryPoints", "overrides", "functions", "aliases",
		}
		for _, k := range want {
			if _, ok := keys[k]; !ok {
				t.Errorf("key %q is missing; got %v", k, slices.Sorted(maps.Keys(keys)))
			}
		}
		// errors is the one key that comes and goes, which is what makes it
		// safe to read "has errors" as "did not parse".
		if _, ok := keys["errors"]; ok {
			t.Error(`"errors" is present on a shader that parsed`)
		}
		if len(keys) != len(want) {
			t.Errorf("got %d keys, want exactly %d: %v", len(keys), len(want), slices.Sorted(maps.Keys(keys)))
		}
	})

	t.Run("a parse failure adds the errors key", func(t *testing.T) {
		t.Parallel()
		raw, err := wgslender.ReflectJSON(t.Context(), unparseableWGSL)
		if err != nil {
			t.Fatalf("ReflectJSON: %v", err)
		}
		var keys map[string]json.RawMessage
		if err := json.Unmarshal(raw, &keys); err != nil {
			t.Fatalf("decoding: %v", err)
		}
		if _, ok := keys["errors"]; !ok {
			t.Error(`"errors" should be present on a shader that did not parse`)
		}
	})
}

// TestMinifyAndReflect pins the one thing the combined call gives that calling
// both separately does not: a reflection whose Name/NameMapped pairs bridge the
// original source and the minified one.
func TestMinifyAndReflect(t *testing.T) {
	t.Parallel()

	t.Run("Name is the original and NameMapped is the minified one", func(t *testing.T) {
		t.Parallel()
		got, err := wgslender.MinifyAndReflect(t.Context(), demoWGSL, nil)
		if err != nil {
			t.Fatalf("MinifyAndReflect: %v", err)
		}
		tex := bindingByName(t, got.Reflection, "tex")
		if tex.NameMapped == "tex" {
			t.Fatal("a handle binding is renamed by default, so NameMapped should differ")
		}
		// The direction matters and is easy to get backwards: Name is what the
		// author wrote, NameMapped is what came out.
		if !containsIdent(got.Code, tex.NameMapped) {
			t.Errorf("NameMapped %q is not in the minified code:\n%s", tex.NameMapped, got.Code)
		}
		if containsIdent(got.Code, tex.Name) {
			t.Errorf("Name %q should be gone from the minified code:\n%s", tex.Name, got.Code)
		}
	})

	t.Run("NameMapped names what a re-Reflect of Code finds", func(t *testing.T) {
		t.Parallel()
		got, err := wgslender.MinifyAndReflect(t.Context(), demoWGSL, nil)
		if err != nil {
			t.Fatalf("MinifyAndReflect: %v", err)
		}
		again, err := wgslender.Reflect(t.Context(), got.Code)
		if err != nil {
			t.Fatalf("Reflect: %v", err)
		}
		var mapped, found []string
		for _, b := range got.Reflection.Bindings {
			mapped = append(mapped, b.NameMapped)
		}
		for _, b := range again.Bindings {
			found = append(found, b.Name)
		}
		if !slices.Equal(mapped, found) {
			t.Errorf("mapped names %q, re-reflected names %q", mapped, found)
		}
	})

	t.Run("an external binding keeps the name the host binds against", func(t *testing.T) {
		t.Parallel()
		got, err := wgslender.MinifyAndReflect(t.Context(), demoWGSL, nil)
		if err != nil {
			t.Fatalf("MinifyAndReflect: %v", err)
		}
		params := bindingByName(t, got.Reflection, "params")
		if params.NameMapped != "params" {
			t.Errorf("NameMapped = %q, want params unchanged", params.NameMapped)
		}
		// Its *type* has no such protection, though, which is why
		// PreserveUniformStructTypes exists.
		if params.TypeMapped == params.Type {
			t.Errorf("TypeMapped = %q, want the struct type renamed", params.TypeMapped)
		}
	})

	t.Run("the embedded MinifyResult is the same one Minify returns", func(t *testing.T) {
		t.Parallel()
		got, err := wgslender.MinifyAndReflect(t.Context(), demoWGSL, nil)
		if err != nil {
			t.Fatalf("MinifyAndReflect: %v", err)
		}
		alone, err := wgslender.Minify(t.Context(), demoWGSL, nil)
		if err != nil {
			t.Fatalf("Minify: %v", err)
		}
		if got.Code != alone.Code {
			t.Errorf("Code differs from Minify's:\n%s\n%s", got.Code, alone.Code)
		}
		if got.OriginalSize != alone.OriginalSize || got.MinifiedSize != alone.MinifiedSize {
			t.Errorf("sizes %d/%d, want %d/%d",
				got.OriginalSize, got.MinifiedSize, alone.OriginalSize, alone.MinifiedSize)
		}
	})

	t.Run("options reach the minifier", func(t *testing.T) {
		t.Parallel()
		got, err := wgslender.MinifyAndReflect(t.Context(), demoWGSL,
			&wgslender.MinifyOptions{MangleExternalBindings: wgslender.Set(true)})
		if err != nil {
			t.Fatalf("MinifyAndReflect: %v", err)
		}
		params := bindingByName(t, got.Reflection, "params")
		if params.NameMapped == "params" {
			t.Error("MangleExternalBindings should have renamed it")
		}
	})

	t.Run("a parse failure is reported on both halves", func(t *testing.T) {
		t.Parallel()
		got, err := wgslender.MinifyAndReflect(t.Context(), unparseableWGSL, nil)
		if err != nil {
			t.Fatalf("MinifyAndReflect: %v", err)
		}
		// The engine spells these two lists differently on the wire — objects
		// on one side, bare strings on the other — for the very same parse
		// errors. Both arrive here as []string.
		if len(got.Errors) == 0 {
			t.Error("MinifyResult.Errors is empty")
		}
		if len(got.Reflection.Errors) == 0 {
			t.Error("Reflection.Errors is empty")
		}
		if !slices.Equal(got.Errors, got.Reflection.Errors) {
			t.Errorf("the two halves disagree:\nminify:  %q\nreflect: %q",
				got.Errors, got.Reflection.Errors)
		}
	})
}

// TestBindGroups pins the grid a WebGPU host actually needs, holes and all.
func TestBindGroups(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name   string
		source string
		want   map[uint32][]uint32
	}{
		{
			name:   "two full groups",
			source: demoWGSL,
			want:   map[uint32][]uint32{0: {0, 1}, 1: {0, 1}},
		},
		{
			name:   "gaps in both dimensions",
			source: holesWGSL,
			want:   map[uint32][]uint32{0: {0, 2}, 2: {5}},
		},
		{
			name:   "a shader with no bindings has no groups",
			source: renderWGSL,
			want:   map[uint32][]uint32{},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			r, err := wgslender.Reflect(t.Context(), tt.source)
			if err != nil {
				t.Fatalf("Reflect: %v", err)
			}
			groups := wgslender.BindGroups(r.Bindings)

			if len(groups) != len(tt.want) {
				t.Errorf("got %d groups, want %d", len(groups), len(tt.want))
			}
			for group, slots := range tt.want {
				g, ok := groups[group]
				if !ok {
					t.Errorf("group %d is missing", group)
					continue
				}
				if len(g) != len(slots) {
					t.Errorf("group %d holds %d bindings, want %d", group, len(g), len(slots))
				}
				for _, slot := range slots {
					b, ok := g[slot]
					if !ok {
						t.Errorf("group %d has no binding %d", group, slot)
						continue
					}
					if b.Group != group || b.Binding != slot {
						t.Errorf("groups[%d][%d] holds %s at @group(%d) @binding(%d)",
							group, slot, b.Name, b.Group, b.Binding)
					}
				}
			}
			// The gaps are the point: a dense model would invent a binding 1.
			if g, ok := groups[0]; ok && tt.name == "gaps in both dimensions" {
				if _, present := g[1]; present {
					t.Error("groups[0][1] should not exist")
				}
			}
		})
	}
}

// TestBindGroupsOfNothing pins the empty case as a usable map rather than nil,
// so that a caller can index it without checking first.
func TestBindGroupsOfNothing(t *testing.T) {
	t.Parallel()
	groups := wgslender.BindGroups(nil)
	if groups == nil {
		t.Fatal("BindGroups(nil) = nil, want an empty map")
	}
	if _, ok := groups[0][0]; ok {
		t.Error("an empty grid has no entries")
	}
}

// TestReflectRejectsInvalidUTF8 holds the same line the rest of the package
// does; see [wgslender.ErrInvalidUTF8].
func TestReflectRejectsInvalidUTF8(t *testing.T) {
	t.Parallel()

	for _, call := range []struct {
		name string
		run  func(string) error
	}{
		{"Reflect", func(s string) error {
			_, err := wgslender.Reflect(t.Context(), s)
			return err
		}},
		{"ReflectJSON", func(s string) error {
			_, err := wgslender.ReflectJSON(t.Context(), s)
			return err
		}},
		{"MinifyAndReflect", func(s string) error {
			_, err := wgslender.MinifyAndReflect(t.Context(), s, nil)
			return err
		}},
	} {
		t.Run(call.name, func(t *testing.T) {
			t.Parallel()
			if err := call.run("// 🎨 palette\nfn main() {}"); err != nil {
				t.Errorf("a valid non-ASCII shader: %v", err)
			}
			if err := call.run("let\x95"); !errors.Is(err, wgslender.ErrInvalidUTF8) {
				t.Errorf("err = %v, want ErrInvalidUTF8", err)
			}
		})
	}
}

// bindingNames lists bindings in the order they arrived.
func bindingNames(bs []wgslender.Binding) []string {
	out := make([]string, len(bs))
	for i, b := range bs {
		out[i] = b.Name
	}
	return out
}

func bindingByName(t *testing.T, r wgslender.Reflection, name string) wgslender.Binding {
	t.Helper()
	for _, b := range r.Bindings {
		if b.Name == name {
			return b
		}
	}
	t.Fatalf("no binding named %q, only %q", name, bindingNames(r.Bindings))
	return wgslender.Binding{}
}

func functionByName(t *testing.T, r wgslender.Reflection, name string) wgslender.Function {
	t.Helper()
	for _, f := range r.Functions {
		if f.Name == name {
			return f
		}
	}
	t.Fatalf("no function named %q", name)
	return wgslender.Function{}
}

func entryPointByName(t *testing.T, r wgslender.Reflection, name string) wgslender.EntryPoint {
	t.Helper()
	for _, ep := range r.EntryPoints {
		if ep.Name == name {
			return ep
		}
	}
	t.Fatalf("no entry point named %q", name)
	return wgslender.EntryPoint{}
}

func structNames(r wgslender.Reflection) []string {
	return slices.Sorted(maps.Keys(r.Structs))
}

// containsIdent reports whether src uses name as a whole identifier, so that
// looking for "d" does not match the d in "id".
func containsIdent(src, name string) bool {
	for i := 0; i+len(name) <= len(src); i++ {
		if src[i:i+len(name)] != name {
			continue
		}
		if i > 0 && isIdentByte(src[i-1]) {
			continue
		}
		if i+len(name) < len(src) && isIdentByte(src[i+len(name)]) {
			continue
		}
		return true
	}
	return false
}

func isIdentByte(c byte) bool {
	return c == '_' || ('0' <= c && c <= '9') || ('a' <= c && c <= 'z') || ('A' <= c && c <= 'Z')
}
