package wgslender_test

// Examples for the four calls a program is most likely to make. They are named
// after the functions they demonstrate rather than after the package, so that
// each one appears beside its function in the documentation.
//
// Every one of them prints something the engine decided, which is what makes
// them worth running: `go test` checks the output against what is written here,
// so an engine that starts answering differently fails the package's own tests
// instead of quietly changing what the documentation claims.

import (
	"context"
	"errors"
	"fmt"
	"log"
	"maps"
	"slices"
	"strings"

	"git.hugodaniel.com/hugo/wgslender/packages/go/wgslender"
)

// exampleShader is what the examples work on: two resources, a helper the
// minifier is free to rename, and one compute entry point.
const exampleShader = `struct Params {
    resolution: vec2f,
    time: f32,
}

@group(0) @binding(0) var<uniform> params: Params;
@group(1) @binding(2) var<storage, read_write> data: array<vec4f>;

fn luminance(color: vec3f) -> f32 {
    return dot(color, vec3f(0.2126, 0.7152, 0.0722));
}

@compute @workgroup_size(8, 8, 1)
fn main(@builtin(global_invocation_id) id: vec3u) {
    let uv = vec2f(id.xy) / params.resolution;
    let lum = luminance(vec3f(uv, params.time));
    data[id.x] = vec4f(lum, lum, lum, 1.0);
}
`

// ExampleMinify shortens a shader with wgslender's own default pipeline,
// which a nil *MinifyOptions asks for.
func ExampleMinify() {
	result, err := wgslender.Minify(context.Background(), exampleShader, nil)
	if err != nil {
		log.Fatal(err)
	}
	fmt.Println(result.OriginalSize, "bytes ->", result.MinifiedSize)
	fmt.Println(result.Code)
	// The @group/@binding variables keep their names: the host binds against
	// them, so renaming them would break the pipeline that uses this shader.
	// Everything else is fair game.
	//
	// Output:
	// 497 bytes -> 375
	// struct f{resolution:vec2f,time:f32}@group(0) @binding(0) var<uniform> params:f;@group(1) @binding(2) var<storage,read_write> data:array<vec4f>;fn c(d:vec3f)->f32{return dot(d,vec3f(.2126,.7152,.0722));}@compute @workgroup_size(8,8,1) fn main(@builtin(global_invocation_id) b:vec3u){let e=vec2f(b.xy)/params.resolution;let a=c(vec3f(e,params.time));data[b.x]=vec4f(a,a,a,1.);}
}

// ExampleMinify_options overrides the defaults where a caller most often
// needs to: KeepNames pins an identifier a host looks up by name, and the two
// compression flags reorder and rename for DEFLATE's benefit — the output is
// no shorter, but it compresses better on the wire. The fields are Opt[bool],
// so anything not Set stays whatever wgslender decides.
func ExampleMinify_options() {
	opts := &wgslender.MinifyOptions{
		KeepNames:        []string{"luminance"},
		SortDeclarations: wgslender.Set(true),
		ScopeLocalRename: wgslender.Set(true),
	}
	result, err := wgslender.Minify(context.Background(), exampleShader, opts)
	if err != nil {
		log.Fatal(err)
	}
	fmt.Println(result.Code)
	// luminance kept its name, and the short names restart in every scope —
	// both functions open with a — which is ScopeLocalRename making the bytes
	// repeat for the compressor.
	//
	// Output:
	// struct e{resolution:vec2f,time:f32}@group(0) @binding(0) var<uniform> params:e;@group(1) @binding(2) var<storage,read_write> data:array<vec4f>;fn luminance(a:vec3f)->f32{return dot(a,vec3f(.2126,.7152,.0722));}@compute @workgroup_size(8,8,1) fn main(@builtin(global_invocation_id) a:vec3u){let b=vec2f(a.xy)/params.resolution;let c=luminance(vec3f(b,params.time));data[a.x]=vec4f(c,c,c,1.);}
}

// ExampleValidate type-checks a shader that does not.
func ExampleValidate() {
	// A shader's own problems are data, not errors: the call succeeds and the
	// verdict is in the result. A returned error means the call could not be
	// made at all.
	const broken = `@compute @workgroup_size(1)
fn main() {
    let x: f32 = undeclared;
}
`
	v, err := wgslender.Validate(context.Background(), broken, wgslender.DefaultStrictness)
	if err != nil {
		log.Fatal(err)
	}
	fmt.Println("valid:", v.Valid)
	for _, d := range v.Diagnostics {
		fmt.Printf("%d:%d %s[%s]: %s\n", d.Line, d.Column, d.Severity, d.Code, d.Message)
	}
	// Output:
	// valid: false
	// 3:18 error[E0100]: use of undeclared identifier 'undeclared'
}

// ExampleReflect reads a shader's interface: what it binds, what stages it
// offers, and how a struct is laid out in memory.
func ExampleReflect() {
	r, err := wgslender.Reflect(context.Background(), exampleShader)
	if err != nil {
		log.Fatal(err)
	}
	for _, b := range r.Bindings {
		fmt.Printf("@group(%d) @binding(%d) %s: %s\n", b.Group, b.Binding, b.Name, b.Type)
	}
	for _, e := range r.EntryPoints {
		fmt.Printf("%s entry point %q, workgroup %v\n", e.Stage, e.Name, *e.WorkgroupSize)
	}
	// A struct's layout is what a host needs in order to write its buffer:
	// where each member begins, and how long the whole thing is.
	params := r.Structs["Params"]
	fmt.Printf("struct Params is %d bytes\n", params.Size)
	for _, f := range params.Fields {
		fmt.Printf("  %s: %s at %d\n", f.Name, f.Type, f.Offset)
	}
	// Output:
	// @group(0) @binding(0) params: Params
	// @group(1) @binding(2) data: array<vec4f>
	// compute entry point "main", workgroup [8 8 1]
	// struct Params is 16 bytes
	//   resolution: vec2f at 0
	//   time: f32 at 8
}

// ExampleLint runs wgslender's recommended rules. The config is spelled out
// because a nil *LintConfig runs no rules at all — the engine has no default
// rule set, so wgslender's opinion has to be asked for by name.
func ExampleLint() {
	const shader = `@group(0) @binding(0) var<storage, read_write> data: array<f32>;

@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) id: vec3u) {
    let unused = 3.14159;
    data[id.x] = f32(id.x) * 2.0;
}
`
	report, err := wgslender.Lint(context.Background(), shader, &wgslender.LintConfig{
		Extends: []wgslender.Pack{wgslender.PackRecommended},
	})
	if err != nil {
		log.Fatal(err)
	}
	fmt.Println("errors:", report.ErrorCount, "warnings:", report.WarningCount)
	for _, d := range report.Diagnostics {
		fmt.Printf("%d:%d %s: %s\n", d.Line, d.Column, d.Code, d.Message)
	}
	// Output:
	// errors: 0 warnings: 1
	// 5:9 W0001: 'unused' is declared but never used
}

// ExampleCompile turns a shader into a binary module, and shows the one place
// in this package where a shader's own problem is a Go error: a compiler with
// nothing to compile has no module to hand back.
func ExampleCompile() {
	shader, err := wgslender.Compile(context.Background(), exampleShader, nil)
	if err != nil {
		log.Fatal(err)
	}
	fmt.Println("input:", shader.OriginalSize, "bytes; module:", len(shader.WASM), "bytes")

	_, err = wgslender.Compile(context.Background(), "fn broken( {}", nil)
	if cerr, ok := errors.AsType[*wgslender.CompileError](err); ok {
		for _, d := range cerr.Diagnostics {
			fmt.Printf("%d:%d %s\n", d.Line, d.Column, d.Message)
		}
	}
	// Output:
	// input: 497 bytes; module: 546 bytes
	// 1:12 expected ')'
}

// ExampleLintFix applies every available autofix in one pass. The report it
// returns describes the source **as it was handed in**, not the fixed one —
// run Lint on the result to see what is left.
func ExampleLintFix() {
	// The cast is redundant — i * 2u is already a u32 — and the rule that says
	// so carries an autofix.
	const shader = `@group(0) @binding(0) var<storage, read_write> counters: array<u32>;

@compute @workgroup_size(64)
fn main(@builtin(local_invocation_index) i: u32) {
    let doubled = u32(i * 2u);
    counters[i] = doubled;
}
`
	cfg := &wgslender.LintConfig{Extends: []wgslender.Pack{wgslender.PackRecommended}}
	outcome, err := wgslender.LintFix(context.Background(), shader, cfg)
	if err != nil {
		log.Fatal(err)
	}
	fmt.Println("fixable:", outcome.Report.FixableCount)
	fmt.Print(outcome.Fixed)
	// Output:
	// fixable: 1
	// @group(0) @binding(0) var<storage, read_write> counters: array<u32>;
	//
	// @compute @workgroup_size(64)
	// fn main(@builtin(local_invocation_index) i: u32) {
	//     let doubled = i * 2u;
	//     counters[i] = doubled;
	// }
}

// ExampleFindReferences lists every mention of a symbol, given any byte
// offset inside one of them. Offsets are plain string indexes, so
// strings.Index is all it takes to point at a name.
func ExampleFindReferences() {
	off := strings.Index(exampleShader, "luminance")
	refs, err := wgslender.FindReferences(context.Background(), exampleShader, off, wgslender.WithDeclaration)
	if err != nil {
		log.Fatal(err)
	}
	for _, r := range refs {
		kind := "read"
		if r.IsWrite {
			kind = "write"
		}
		fmt.Printf("%s at %d..%d (%s)\n", exampleShader[r.Start:r.End], r.Start, r.End, kind)
	}
	// The declaration comes first and is the write; the call site is the read.
	//
	// Output:
	// luminance at 179..188 (write)
	// luminance at 416..425 (read)
}

// ExampleRenameApply renames a symbol and hands back the rewritten shader.
// The edits alongside it are at offsets into the *original* source — they are
// for showing a diff, not for splicing, because the splicing already happened.
func ExampleRenameApply() {
	const shader = `fn scale(v: f32) -> f32 { return v * 2.0; }

@fragment
fn main() -> @location(0) vec4f {
    let s = scale(0.5);
    return vec4f(s);
}
`
	applied, err := wgslender.RenameApply(context.Background(),
		shader, strings.Index(shader, "scale"), "double")
	if err != nil {
		log.Fatal(err)
	}
	fmt.Printf("%d edits\n", len(applied.Edits))
	fmt.Print(applied.Source)
	// Output:
	// 2 edits
	// fn double(v: f32) -> f32 { return v * 2.0; }
	//
	// @fragment
	// fn main() -> @location(0) vec4f {
	//     let s = double(0.5);
	//     return vec4f(s);
	// }
}

// ExampleStableIDAtOffset shows what a StableID is for. A byte offset names a
// symbol only until the next edit moves it; the ID keeps naming it across any
// edit that leaves the declaration in place.
func ExampleStableIDAtOffset() {
	ctx := context.Background()

	id, ok, err := wgslender.StableIDAtOffset(ctx, exampleShader, strings.Index(exampleShader, "luminance"))
	if err != nil {
		log.Fatal(err)
	}
	if !ok {
		log.Fatal("no symbol at that offset")
	}
	fmt.Println(id)

	// A leading comment moves every byte in the file. The offset the ID was
	// taken at now points into the comment; the ID still finds the symbol.
	edited := "// tone mapping helpers\n" + exampleShader
	span, ok, err := wgslender.LocateStableID(ctx, edited, id)
	if err != nil {
		log.Fatal(err)
	}
	if !ok {
		log.Fatal("the symbol is gone")
	}
	fmt.Printf("%s at %d..%d\n", edited[span.Start:span.End], span.Start, span.End)
	// The span is the FindReferences declaration span from the example above,
	// moved by exactly the length of the comment.
	//
	// Output:
	// v1:fn:luminance
	// luminance at 203..212
}

// ExampleBindGroups arranges the bindings the way a WebGPU host consumes
// them, by group and then by slot.
func ExampleBindGroups() {
	r, err := wgslender.Reflect(context.Background(), exampleShader)
	if err != nil {
		log.Fatal(err)
	}
	groups := wgslender.BindGroups(r.Bindings)

	// The map is a map because bind groups are sparse — a shader may use
	// @group(0) and @group(1) and nothing between — so ranging over it needs
	// the keys sorted to print in a fixed order.
	for _, group := range slices.Sorted(maps.Keys(groups)) {
		for _, slot := range slices.Sorted(maps.Keys(groups[group])) {
			b := groups[group][slot]
			fmt.Printf("group %d slot %d: %s (%s)\n", group, slot, b.Name, b.AddressSpace)
		}
	}
	// Output:
	// group 0 slot 0: params (uniform)
	// group 1 slot 2: data (storage)
}
