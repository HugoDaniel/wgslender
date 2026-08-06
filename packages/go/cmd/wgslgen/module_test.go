package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// The -module golden cases. Each runs in a directory of its own with the shader
// copied in beside it, so that every path on the command line is a short
// relative one — the header records the command verbatim, and a header naming
// somebody's temporary directory would be a golden file that never matched
// twice.
//
// The two files a case produces are pinned separately: the module is what the
// caller reads, and the layout proof is what makes the module trustworthy.
var moduleCases = []struct {
	name string
	// shader is the fixture to copy in, out the file to generate, and args the
	// command line to run in that directory.
	shader string
	out    string
	args   []string
	// notes are what the tool must say about the fields it could not type.
	notes []string
}{
	{
		name:   "module",
		shader: "layouts.wgsl",
		out:    "layouts_gen.go",
		args:   []string{"-module", "-var", "Layouts", "-pkg", "shaders", "-o", "layouts_gen.go", "layouts.wgsl"},
		notes:  []string{"Instances.items", "Trail.points", "runtime-sized"},
	},
	{
		name:   "module_padded",
		shader: "padded_matrix.wgsl",
		out:    "transform_gen.go",
		args:   []string{"-module", "-var", "PaddedMatrix", "-pkg", "shaders", "-o", "transform_gen.go", "padded_matrix.wgsl"},
		notes:  []string{"Transform.basis", "mat3x3f", "16 bytes apart"},
	},
	{
		name:   "module_padded_array",
		shader: "padded_array.wgsl",
		out:    "points_gen.go",
		args:   []string{"-module", "-var", "PaddedArray", "-pkg", "shaders", "-o", "points_gen.go", "padded_array.wgsl"},
		notes:  []string{"Points.at", "array<vec3f, 4>", "16 bytes apart"},
	},
}

// runModule runs one -module case and hands back the two files it wrote.
//
// It changes the working directory rather than passing absolute paths, which is
// what keeps the generated header — and so the golden files — the same on every
// machine.
func runModule(t *testing.T, tc int) (module, proof, stderr string) {
	t.Helper()
	c := moduleCases[tc]

	shader, err := os.ReadFile(filepath.Join("testdata", c.shader))
	if err != nil {
		t.Fatalf("reading the fixture: %v", err)
	}
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, c.shader), shader, 0o644); err != nil {
		t.Fatalf("copying the fixture: %v", err)
	}

	t.Chdir(dir)
	stdout, stderr, err := generate(t, c.args...)
	if err != nil {
		t.Fatalf("run: %v\nstderr:\n%s", err, stderr)
	}
	if stdout != "" {
		t.Errorf("-o was given and something still went to stdout:\n%s", stdout)
	}

	read := func(name string) string {
		t.Helper()
		b, err := os.ReadFile(filepath.Join(dir, name))
		if err != nil {
			t.Fatalf("the tool did not write %s: %v", name, err)
		}
		return string(b)
	}
	return read(c.out), read(proofPath(c.out)), stderr
}

func TestModuleGolden(t *testing.T) {
	for i, c := range moduleCases {
		t.Run(c.name, func(t *testing.T) {
			// The golden paths are resolved before the working directory moves.
			modulePath, err := filepath.Abs(goldenPath(c.name))
			if err != nil {
				t.Fatalf("resolving the golden path: %v", err)
			}
			proofGolden := proofPath(modulePath)

			module, proof, stderr := runModule(t, i)
			for _, note := range c.notes {
				if !strings.Contains(stderr, note) {
					t.Errorf("a field with no Go type went unmentioned: wanted %q on stderr, got:\n%s", note, stderr)
				}
			}

			for _, f := range []struct{ path, got string }{
				{modulePath, module},
				{proofGolden, proof},
			} {
				if *update {
					if err := os.WriteFile(f.path, []byte(f.got), 0o644); err != nil {
						t.Fatalf("writing the golden file: %v", err)
					}
					continue
				}
				want, err := os.ReadFile(f.path)
				if err != nil {
					t.Fatalf("reading the golden file: %v\nrerun with -update to create it", err)
				}
				if f.got != string(want) {
					t.Errorf("generated output differs from %s\n got:\n%s\nwant:\n%s\nrerun with -update if the new output is right",
						f.path, f.got, want)
				}
			}
		})
	}
}

// goTestModule compiles files as a package of their own and runs its tests,
// which is what makes a generated layout proof a proof of anything.
func goTestModule(t *testing.T, files map[string]string) ([]byte, error) {
	t.Helper()
	goBin, err := exec.LookPath("go")
	if err != nil {
		t.Fatalf("go is not on PATH, so the generated code cannot be compiled: %v", err)
	}

	dir := t.TempDir()
	// Nothing generated imports anything outside the standard library, so a
	// module with no requirements builds offline.
	files["go.mod"] = "module wgslgenmodule\n\ngo 1.26\n"
	for name, content := range files {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(content), 0o644); err != nil {
			t.Fatalf("writing %s: %v", name, err)
		}
	}

	cmd := exec.CommandContext(t.Context(), goBin, "test", "-count=1", ".")
	cmd.Dir = dir
	return cmd.CombinedOutput()
}

// TestGeneratedModuleProvesItsLayout is the point of the whole -module flag.
//
// A generated struct is a claim about memory — that Scene is 112 bytes with
// material at offset 80 — and the generated test is that claim checked against
// what the Go compiler actually did. Running it here says the claim is true for
// this reflection, on this platform, with this compiler.
func TestGeneratedModuleProvesItsLayout(t *testing.T) {
	for i, c := range moduleCases {
		t.Run(c.name, func(t *testing.T) {
			module, proof, _ := runModule(t, i)
			out, err := goTestModule(t, map[string]string{
				c.out:            module,
				proofPath(c.out): proof,
			})
			if err != nil {
				t.Fatalf("the generated package did not build and pass: %v\n%s", err, out)
			}
		})
	}
}

// TestLayoutProofCatchesAWrongLayout is the mutation the other test cannot
// perform on itself: it corrupts the generated struct and insists the generated
// proof notices.
//
// Without this, a proof that asserted nothing would pass exactly as loudly as
// one that asserted everything.
func TestLayoutProofCatchesAWrongLayout(t *testing.T) {
	c := moduleCases[0]
	module, proof, _ := runModule(t, 0)

	// One extra byte of padding moves every field after it, which is the shape
	// of the mistake this whole file exists to catch.
	const pad = "_ [4]byte"
	if !strings.Contains(module, pad) {
		t.Fatalf("the generated module has no padding to corrupt:\n%s", module)
	}
	wrong := strings.Replace(module, pad, "_ [8]byte", 1)

	out, err := goTestModule(t, map[string]string{
		c.out:            wrong,
		proofPath(c.out): proof,
	})
	if err == nil {
		t.Fatalf("the layout proof passed against a struct with the wrong layout:\n%s", out)
	}
	if !strings.Contains(string(out), "the shader") {
		t.Errorf("the failure does not explain itself:\n%s", out)
	}
}

// TestModuleUntypableFieldsBecomeOffsets pins the decision at the centre of the
// mapping: a WGSL type Go cannot spell is never guessed at, and never dropped
// either. It becomes padding of exactly its size, so everything after it stays
// where the shader put it, plus a constant saying where it begins.
func TestModuleUntypableFieldsBecomeOffsets(t *testing.T) {
	module, _, stderr := runModule(t, 1)
	for _, want := range []string{
		"type Transform struct",
		"_ [48]byte",
		"TransformBasisOffset = 0",
	} {
		if !strings.Contains(module, want) {
			t.Errorf("the generated module does not contain %q:\n%s", want, module)
		}
	}
	if strings.Contains(module, "Basis [") {
		t.Errorf("a mat3x3f was given a Go type after all:\n%s", module)
	}
	if !strings.Contains(stderr, "mat3x3f") {
		t.Errorf("nothing said why basis has no field:\n%s", stderr)
	}
}

// TestModuleRuntimeArrayIsAnOffset covers the other field with no Go type, and
// the one every storage buffer has: how many elements follow is the host's
// decision, so a Go struct cannot end in it.
func TestModuleRuntimeArrayIsAnOffset(t *testing.T) {
	module, _, _ := runModule(t, 0)
	for _, want := range []string{
		"TrailPointsOffset = 0",
		"InstancesItemsOffset = 32",
	} {
		if !strings.Contains(module, want) {
			t.Errorf("the generated module does not contain %q:\n%s", want, module)
		}
	}
}

// TestModuleDescribesBindingsAndEntryPoints: the numbers a host needs to build
// a pipeline are in the shader, and copying them into Go by hand is how they
// drift apart.
func TestModuleDescribesBindingsAndEntryPoints(t *testing.T) {
	module, _, _ := runModule(t, 0)
	for _, want := range []string{
		"SceneGroup   uint32 = 0",
		"SceneBinding uint32 = 0",
		"InstancesGroup   uint32 = 2",
		"InstancesBinding uint32 = 3",
		`EntryTick = "tick"`,
		"EntryTickWorkgroupSize = [3]uint32{16, 1, 1}",
	} {
		if !strings.Contains(module, want) {
			t.Errorf("the generated module does not contain %q:\n%s", want, module)
		}
	}
}

// TestModuleExportsWGSLNames: a WGSL member called range or func is ordinary,
// and the Go field it becomes cannot be. Exporting the name is what settles it
// — every Go keyword is lower case, so a capitalised one is never a keyword.
func TestModuleExportsWGSLNames(t *testing.T) {
	module, _, _ := runModule(t, 0)
	for _, want := range []string{"Range float32", "Map [2]float32", "Func uint32"} {
		if !strings.Contains(module, want) {
			t.Errorf("the generated module does not contain %q:\n%s", want, module)
		}
	}
}

// TestModulePrefixSeparatesShaders: the generated names come from the shader,
// so two shaders generated into one package can collide on a struct they both
// call Params. -prefix is the way out that does not involve renaming anything
// in the shader.
func TestModulePrefixSeparatesShaders(t *testing.T) {
	shader, err := os.ReadFile(filepath.Join("testdata", "layouts.wgsl"))
	if err != nil {
		t.Fatalf("reading the fixture: %v", err)
	}
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "layouts.wgsl"), shader, 0o644); err != nil {
		t.Fatalf("copying the fixture: %v", err)
	}
	t.Chdir(dir)

	_, stderr, err := generate(t, "-module", "-prefix", "Demo", "-var", "DemoShader", "-pkg", "shaders", "-o", "gen.go", "layouts.wgsl")
	if err != nil {
		t.Fatalf("run: %v\nstderr:\n%s", err, stderr)
	}
	b, err := os.ReadFile(filepath.Join(dir, "gen.go"))
	if err != nil {
		t.Fatalf("reading the generated file: %v", err)
	}
	module := string(b)
	for _, want := range []string{"type DemoScene struct", "DemoSceneGroup", "DemoEntryTick", "DemoTrailPointsOffset"} {
		if !strings.Contains(module, want) {
			t.Errorf("-prefix did not reach %q:\n%s", want, module)
		}
	}
	// The nested struct's field has to name the prefixed type, or the file does
	// not compile.
	if !strings.Contains(module, "Material DemoMaterial") {
		t.Errorf("a nested struct field kept the unprefixed type name:\n%s", module)
	}
}

// TestModuleUsageErrors pins the command lines -module cannot honour.
func TestModuleUsageErrors(t *testing.T) {
	for _, tc := range []struct {
		name string
		args []string
		want string
	}{
		// -module writes two files, and standard output is one destination.
		{"no -o", []string{"-module", "-var", "Layouts", "-pkg", "shaders", "testdata/layouts.wgsl"}, "-o"},
		{"-prefix is not an identifier", []string{"-module", "-prefix", "my-shader", "-var", "Layouts", "-pkg", "shaders", "-o", "gen.go", "testdata/layouts.wgsl"}, "my-shader"},
		// A prefix that is not exported produces unexported types, which is not
		// what anyone asking for a prefix wanted.
		{"-prefix is not exported", []string{"-module", "-prefix", "demo", "-var", "Layouts", "-pkg", "shaders", "-o", "gen.go", "testdata/layouts.wgsl"}, "demo"},
		{"-prefix without -module", []string{"-prefix", "Demo", "-var", "Layouts", "-pkg", "shaders", "testdata/layouts.wgsl"}, "-prefix"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			stdout, stderr, err := generate(t, tc.args...)
			if err == nil {
				t.Fatalf("the tool accepted it\nstdout:\n%s", stdout)
			}
			if said := stderr + err.Error(); !strings.Contains(said, tc.want) {
				t.Errorf("nothing said %q\nstderr:\n%s\nerror: %v", tc.want, stderr, err)
			}
		})
	}
}

// TestModuleRefusesCollidingNames: two WGSL names that come out as one Go name
// would generate the same declaration twice, and the compiler's complaint would
// be about a name nobody wrote.
//
// The two cases are checked separately because they are checked separately in
// the generator: declarations share one namespace across the whole module,
// while members share one only with the struct they are in — two structs may
// each have a count, and one struct may not.
func TestModuleRefusesCollidingNames(t *testing.T) {
	for _, tc := range []struct {
		name   string
		shader string
		want   []string
	}{
		{
			name: "two structs",
			shader: `struct params { a: f32 }
struct Params { b: f32 }
@group(0) @binding(0) var<uniform> one: params;
@group(0) @binding(1) var<uniform> two: Params;
@compute @workgroup_size(1) fn main() { _ = one; _ = two; }
`,
			want: []string{"params", "Params"},
		},
		{
			name: "two members of one struct",
			shader: `struct Params { count: u32, Count: u32 }
@group(0) @binding(0) var<uniform> p: Params;
@compute @workgroup_size(1) fn main() { _ = p; }
`,
			want: []string{"count", "Count", "Params"},
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			dir := t.TempDir()
			if err := os.WriteFile(filepath.Join(dir, "collide.wgsl"), []byte(tc.shader), 0o644); err != nil {
				t.Fatalf("writing the fixture: %v", err)
			}
			t.Chdir(dir)

			stdout, stderr, err := generate(t, "-module", "-var", "Collide", "-pkg", "shaders", "-o", "gen.go", "collide.wgsl")
			if err == nil {
				t.Fatalf("the tool generated two declarations of one name\nstdout:\n%s", stdout)
			}
			said := stderr + err.Error()
			for _, want := range tc.want {
				if !strings.Contains(said, want) {
					t.Errorf("the message does not name both sides of the collision: wanted %q\nstderr:\n%s\nerror: %v", want, stderr, err)
				}
			}
			if _, err := os.Stat(filepath.Join(dir, "gen.go")); err == nil {
				t.Error("a refusal still wrote the file")
			}
		})
	}
}

// TestModuleLeavesNoHalfWrittenPair: the module and its proof are written
// together or not at all. A module without its proof is a claim nothing checks.
func TestModuleLeavesNoHalfWrittenPair(t *testing.T) {
	module, proof, _ := runModule(t, 0)
	if !strings.Contains(proof, "func TestSceneLayout(t *testing.T)") {
		t.Errorf("the proof does not test the struct the module declares:\n%s", proof)
	}
	if !strings.Contains(proof, "package shaders") {
		t.Errorf("the proof is not in the module's package:\n%s", proof)
	}
	first, _, _ := strings.Cut(proof, "\n")
	if !strings.HasPrefix(first, "// Code generated ") || !strings.HasSuffix(first, " DO NOT EDIT.") {
		t.Errorf("the proof does not carry the generated-file line:\n%s", first)
	}
	if !strings.Contains(module, "const Layouts = ") {
		t.Errorf("-module dropped the shader itself:\n%s", module)
	}
}

// TestModuleIsFormatted: both generated files go through go/format, so a
// package that generates them does not need a gofmt pass afterwards.
func TestModuleIsFormatted(t *testing.T) {
	for i, c := range moduleCases {
		t.Run(c.name, func(t *testing.T) {
			module, proof, _ := runModule(t, i)
			for name, got := range map[string]string{c.out: module, proofPath(c.out): proof} {
				want, err := formatGo([]byte(got))
				if err != nil {
					t.Fatalf("%s is not valid Go: %v", name, err)
				}
				if got != string(want) {
					t.Errorf("%s is not gofmt-clean", name)
				}
			}
		})
	}
}
