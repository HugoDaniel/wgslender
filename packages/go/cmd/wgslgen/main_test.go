package main

import (
	"errors"
	"flag"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// update rewrites testdata/golden instead of comparing against it:
//
//	go test ./cmd/wgslgen -update
//
// Read the diff before committing it. A golden file is only a record of what
// the tool did last time; the tests around it are what say the output is right.
var update = flag.Bool("update", false, "rewrite the files in testdata/golden")

// generate runs the tool in this process, which is what makes a table of cases
// affordable. The one thing it cannot pin is the exit status, and
// TestExitStatus builds the real binary for that.
func generate(t *testing.T, args ...string) (stdout, stderr string, err error) {
	t.Helper()
	var out, errs strings.Builder
	err = run(t.Context(), args, &out, &errs)
	return out.String(), errs.String(), err
}

// The golden cases share one input and one package name so that
// TestGeneratedCodeBuildsAndRoundTrips can compile all three together and
// compare them against each other. Their variable names differ for the same
// reason.
var goldenCases = []struct {
	name string
	args []string
}{
	{"plain", []string{"-var", "Blur", "-pkg", "shaders", "testdata/blur.wgsl"}},
	{"compressed", []string{"-compress", "-var", "BlurCompressed", "-pkg", "shaders", "testdata/blur.wgsl"}},
	{"named", []string{"-minify-identifiers=false", "-var", "BlurNamed", "-pkg", "shaders", "testdata/blur.wgsl"}},
}

func goldenPath(name string) string { return filepath.Join("testdata", "golden", name+".golden") }

func TestGolden(t *testing.T) {
	for _, tc := range goldenCases {
		t.Run(tc.name, func(t *testing.T) {
			got, stderr, err := generate(t, tc.args...)
			if err != nil {
				t.Fatalf("run: %v\nstderr:\n%s", err, stderr)
			}
			if stderr != "" {
				t.Errorf("a shader with nothing wrong with it wrote to stderr:\n%s", stderr)
			}
			if *update {
				if err := os.WriteFile(goldenPath(tc.name), []byte(got), 0o644); err != nil {
					t.Fatalf("writing the golden file: %v", err)
				}
				return
			}
			want, err := os.ReadFile(goldenPath(tc.name))
			if err != nil {
				t.Fatalf("reading the golden file: %v\nrerun with -update to create it", err)
			}
			if got != string(want) {
				t.Errorf("generated output differs from %s\n got:\n%s\nwant:\n%s\nrerun with -update if the new output is right",
					goldenPath(tc.name), got, want)
			}
		})
	}
}

// TestGoldenHeaderIsRecognisable pins the one line other tools read. `go
// generate`'s convention is a first line matching
// ^// Code generated .* DO NOT EDIT\.$ — diff tools, vet's copylocks exemption
// and every "is this generated?" heuristic key off it, so it is not free text.
func TestGoldenHeaderIsRecognisable(t *testing.T) {
	for _, tc := range goldenCases {
		t.Run(tc.name, func(t *testing.T) {
			b, err := os.ReadFile(goldenPath(tc.name))
			if err != nil {
				t.Fatalf("reading the golden file: %v", err)
			}
			first, _, _ := strings.Cut(string(b), "\n")
			if !strings.HasPrefix(first, "// Code generated ") || !strings.HasSuffix(first, " DO NOT EDIT.") {
				t.Errorf("first line does not match go's generated-file convention:\n%s", first)
			}
			if !strings.Contains(first, "testdata/blur.wgsl") {
				t.Errorf("first line does not name the input it came from:\n%s", first)
			}
		})
	}
}

// TestGeneratedCodeBuildsAndRoundTrips is the test that makes the golden files
// mean something. A golden file only says the bytes have not changed; this one
// says the bytes are a Go package that compiles, and that the compressed
// variant hands back exactly what the plain one holds.
//
// It compiles them for real rather than type-checking them, because the
// round-trip is a run-time claim: sync.OnceValue has to be wired up correctly
// and the DEFLATE stream has to inflate.
func TestGeneratedCodeBuildsAndRoundTrips(t *testing.T) {
	goBin, err := exec.LookPath("go")
	if err != nil {
		t.Fatalf("go is not on PATH, so the generated code cannot be compiled: %v", err)
	}

	dir := t.TempDir()
	write := func(name, content string) {
		t.Helper()
		if err := os.WriteFile(filepath.Join(dir, name), []byte(content), 0o644); err != nil {
			t.Fatalf("writing %s: %v", name, err)
		}
	}

	// The generated files import nothing but the standard library, so a module
	// with no requirements builds offline.
	write("go.mod", "module wgslgengolden\n\ngo 1.26\n")
	for _, tc := range goldenCases {
		b, err := os.ReadFile(goldenPath(tc.name))
		if err != nil {
			t.Fatalf("reading the golden file: %v", err)
		}
		write(tc.name+".go", string(b))
	}
	write("golden_test.go", `package shaders

import (
	"strings"
	"testing"
)

func TestRoundTrip(t *testing.T) {
	if Blur == "" {
		t.Fatal("the embedded shader is empty")
	}
	if got := BlurCompressed(); got != Blur {
		t.Errorf("the compressed shader inflated to something else\n got: %q\nwant: %q", got, Blur)
	}
	if !strings.Contains(Blur, "@compute") {
		t.Errorf("the embedded shader does not look like WGSL: %q", Blur)
	}
	if strings.Contains(Blur, "luminance") {
		t.Errorf("identifiers were not minified: %q", Blur)
	}
	if !strings.Contains(BlurNamed, "luminance") {
		t.Errorf("-minify-identifiers=false did not reach the engine: %q", BlurNamed)
	}
}
`)

	cmd := exec.CommandContext(t.Context(), goBin, "test", "-count=1", ".")
	cmd.Dir = dir
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("the generated package did not build and pass: %v\n%s", err, out)
	}
}

// TestExitStatus is the one case that has to leave this process: `go generate`
// stops on a non-zero status, so refusing a bad shader is only useful if the
// status says so.
func TestExitStatus(t *testing.T) {
	goBin, err := exec.LookPath("go")
	if err != nil {
		t.Fatalf("go is not on PATH, so the tool cannot be built: %v", err)
	}

	bin := filepath.Join(t.TempDir(), "wgslgen")
	build := exec.CommandContext(t.Context(), goBin, "build", "-o", bin, ".")
	if out, err := build.CombinedOutput(); err != nil {
		t.Fatalf("building the tool: %v\n%s", err, out)
	}

	for _, tc := range []struct {
		name string
		args []string
		want int
	}{
		{"a shader with nothing wrong with it", []string{"-var", "Blur", "-pkg", "shaders", "testdata/blur.wgsl"}, 0},
		{"a shader that does not type-check", []string{"-var", "Blur", "-pkg", "shaders", "testdata/broken.wgsl"}, 1},
		{"a command line that makes no sense", []string{"-var", "Blur", "-pkg", "shaders"}, 2},
	} {
		t.Run(tc.name, func(t *testing.T) {
			cmd := exec.CommandContext(t.Context(), bin, tc.args...)
			var stdout, stderr strings.Builder
			cmd.Stdout = &stdout
			cmd.Stderr = &stderr
			err := cmd.Run()

			got := 0
			var exit *exec.ExitError
			if errors.As(err, &exit) {
				got = exit.ExitCode()
			} else if err != nil {
				t.Fatalf("running the tool: %v", err)
			}
			if got != tc.want {
				t.Errorf("exit status = %d, want %d\nstderr:\n%s", got, tc.want, stderr.String())
			}
			if tc.want != 0 && stdout.String() != "" {
				t.Errorf("a refusal still wrote a Go file to stdout:\n%s", stdout.String())
			}
		})
	}
}

// TestRefusesBadShaders covers the reason the tool validates at all: a shader
// that is wrong should stop the build that embeds it, on the machine where the
// mistake was made.
func TestRefusesBadShaders(t *testing.T) {
	for _, tc := range []struct {
		name string
		args []string
		want []string
	}{
		{
			name: "does not type-check",
			args: []string{"-var", "Blur", "-pkg", "shaders", "testdata/broken.wgsl"},
			want: []string{"testdata/broken.wgsl:7:18: error[E0100]:", "undeclared_variable"},
		},
		{
			name: "does not parse",
			args: []string{"-var", "Blur", "-pkg", "shaders", "testdata/unparseable.wgsl"},
			want: []string{"testdata/unparseable.wgsl:1:10: error:", "expected ')'"},
		},
		{
			// With validation off the parser is still the last word: there is
			// no minified shader to embed, only the source read back.
			name: "does not parse, with validation off",
			args: []string{"-validate=false", "-var", "Blur", "-pkg", "shaders", "testdata/unparseable.wgsl"},
			want: []string{"testdata/unparseable.wgsl:", "expected ')'"},
		},
		{
			name: "warnings under -strict",
			args: []string{"-strict", "-var", "Blur", "-pkg", "shaders", "testdata/warns.wgsl"},
			want: []string{"testdata/warns.wgsl:9:19: error[W0101]:", "redundant cast"},
		},
		{
			name: "no such file",
			args: []string{"-var", "Blur", "-pkg", "shaders", "testdata/absent.wgsl"},
			want: []string{"testdata/absent.wgsl"},
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			stdout, stderr, err := generate(t, tc.args...)
			if err == nil {
				t.Fatalf("the tool accepted it\nstdout:\n%s", stdout)
			}
			if stdout != "" {
				t.Errorf("a refusal still wrote a Go file:\n%s", stdout)
			}
			said := stderr + err.Error()
			for _, want := range tc.want {
				if !strings.Contains(said, want) {
					t.Errorf("nothing said %q\nstderr:\n%s\nerror: %v", want, stderr, err)
				}
			}
		})
	}
}

// TestWarningsAreNotRefusals pins the other half of that decision. A warning is
// the engine's opinion, not a verdict, so it is reported and the file is still
// generated — asking for the stricter reading is what -strict is for.
func TestWarningsAreNotRefusals(t *testing.T) {
	stdout, stderr, err := generate(t, "-var", "Warns", "-pkg", "shaders", "testdata/warns.wgsl")
	if err != nil {
		t.Fatalf("run: %v\nstderr:\n%s", err, stderr)
	}
	if !strings.Contains(stdout, "const Warns = ") {
		t.Errorf("no shader was generated:\n%s", stdout)
	}
	for _, want := range []string{"testdata/warns.wgsl:9:19: warning[W0101]:", "W0103"} {
		if !strings.Contains(stderr, want) {
			t.Errorf("the warnings went unreported, so nobody would ever see them\nwanted %q, stderr:\n%s", want, stderr)
		}
	}
}

// TestUsageErrors pins the command lines that cannot mean anything. Each one is
// refused rather than guessed at, and each refusal says which flag is at fault.
func TestUsageErrors(t *testing.T) {
	for _, tc := range []struct {
		name string
		args []string
		want string
	}{
		{"no input file", []string{"-var", "Blur", "-pkg", "shaders"}, "exactly one"},
		{"two input files", []string{"-var", "Blur", "-pkg", "shaders", "a.wgsl", "b.wgsl"}, "exactly one"},
		{"no -var", []string{"-pkg", "shaders", "testdata/blur.wgsl"}, "-var"},
		{"-var is not an identifier", []string{"-var", "3d", "-pkg", "shaders", "testdata/blur.wgsl"}, "3d"},
		{"-var is a keyword", []string{"-var", "range", "-pkg", "shaders", "testdata/blur.wgsl"}, "range"},
		// go/token calls the blank identifier a valid one, and it is, but a
		// shader embedded as _ is one nothing can ever read.
		{"-var is blank", []string{"-var", "_", "-pkg", "shaders", "testdata/blur.wgsl"}, "_"},
		{"-pkg is not an identifier", []string{"-var", "Blur", "-pkg", "go-shaders", "testdata/blur.wgsl"}, "go-shaders"},
		{"-strict without validation", []string{"-strict", "-validate=false", "-var", "Blur", "-pkg", "shaders", "testdata/blur.wgsl"}, "-strict"},
		{"a flag that does not exist", []string{"-colour", "-var", "Blur", "-pkg", "shaders", "testdata/blur.wgsl"}, "colour"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			stdout, stderr, err := generate(t, tc.args...)
			if err == nil {
				t.Fatalf("the tool accepted it\nstdout:\n%s", stdout)
			}
			if stdout != "" {
				t.Errorf("a refusal still wrote a Go file:\n%s", stdout)
			}
			if said := stderr + err.Error(); !strings.Contains(said, tc.want) {
				t.Errorf("nothing said %q\nstderr:\n%s\nerror: %v", tc.want, stderr, err)
			}
		})
	}
}

// TestMissingVarSuggestsOne: -var is required because a generated identifier
// should be the caller's choice rather than a transformation of a filename they
// have to predict. Saying so is more useful when the message also says what a
// reasonable choice would be.
func TestMissingVarSuggestsOne(t *testing.T) {
	_, stderr, err := generate(t, "-pkg", "shaders", "testdata/blur.wgsl")
	if err == nil {
		t.Fatal("the tool generated a file with no name for it")
	}
	if said := stderr + err.Error(); !strings.Contains(said, "Blur") {
		t.Errorf("the message does not suggest a name for testdata/blur.wgsl:\nstderr:\n%s\nerror: %v", stderr, err)
	}
}

// TestPackageDefaultsToGOPACKAGE keeps the go:generate line short: the go tool
// already sets GOPACKAGE to the package it is generating into, so -pkg is only
// needed when running the tool by hand.
func TestPackageDefaultsToGOPACKAGE(t *testing.T) {
	t.Setenv("GOPACKAGE", "shadersfromenv")
	stdout, stderr, err := generate(t, "-var", "Blur", "testdata/blur.wgsl")
	if err != nil {
		t.Fatalf("run: %v\nstderr:\n%s", err, stderr)
	}
	if !strings.Contains(stdout, "package shadersfromenv\n") {
		t.Errorf("GOPACKAGE was ignored:\n%s", stdout)
	}
}

// TestNoPackageAtAllIsRefused: without the flag and without the environment
// there is nothing to guess from, and guessing from the output directory's name
// would produce a package clause that is often not a Go identifier.
func TestNoPackageAtAllIsRefused(t *testing.T) {
	t.Setenv("GOPACKAGE", "")
	stdout, stderr, err := generate(t, "-var", "Blur", "testdata/blur.wgsl")
	if err == nil {
		t.Fatalf("the tool guessed a package name:\n%s", stdout)
	}
	if said := stderr + err.Error(); !strings.Contains(said, "-pkg") {
		t.Errorf("the message does not name the flag that would fix it:\nstderr:\n%s\nerror: %v", stderr, err)
	}
}

// TestOutputFileMatchesStdout pins that -o is a destination and nothing else:
// the same bytes either way, and nothing on stdout when a file was named.
func TestOutputFileMatchesStdout(t *testing.T) {
	want, stderr, err := generate(t, "-var", "Blur", "-pkg", "shaders", "testdata/blur.wgsl")
	if err != nil {
		t.Fatalf("run: %v\nstderr:\n%s", err, stderr)
	}

	out := filepath.Join(t.TempDir(), "blur_shader.go")
	stdout, stderr, err := generate(t, "-o", out, "-var", "Blur", "-pkg", "shaders", "testdata/blur.wgsl")
	if err != nil {
		t.Fatalf("run: %v\nstderr:\n%s", err, stderr)
	}
	if stdout != "" {
		t.Errorf("-o was given and the file still went to stdout:\n%s", stdout)
	}

	got, err := os.ReadFile(out)
	if err != nil {
		t.Fatalf("reading the generated file: %v", err)
	}
	// The header records the command line, and -o is part of it, so compare
	// everything after the first line.
	_, gotBody, _ := strings.Cut(string(got), "\n")
	_, wantBody, _ := strings.Cut(want, "\n")
	if gotBody != wantBody {
		t.Errorf("-o produced a different file\n got:\n%s\nwant:\n%s", gotBody, wantBody)
	}
}

// TestFormatGoFormats pins the step between the templates and the file.
//
// The templates happen to be written out gofmt-clean, which means the golden
// files look the same whether or not anything formats them — so this asks
// formatGo directly. What it protects is a template edit: aligning a generated
// file by hand is not a thing anyone should have to get right, and getting it
// wrong should not reach the golden files.
func TestFormatGoFormats(t *testing.T) {
	got, err := formatGo([]byte("package p\n\nconst   X =    1\n"))
	if err != nil {
		t.Fatalf("formatGo: %v", err)
	}
	if want := "package p\n\nconst X = 1\n"; string(got) != want {
		t.Errorf("formatGo left the source alone\n got: %q\nwant: %q", got, want)
	}
}

// TestFormatGoRejectsNonGo pins the other half: the templates are the one place
// this tool can produce something that is not a Go file at all, and it should
// say so rather than write it out.
func TestFormatGoRejectsNonGo(t *testing.T) {
	if _, err := formatGo([]byte("package p\n\nconst X = \n")); err == nil {
		t.Error("formatGo accepted source that is not Go")
	}
}

// TestGeneratedFileIsFormatted pins that the tool runs its own output through
// go/format. A generator whose output needs gofmt afterwards makes every
// consumer's gate depend on running gofmt after go generate.
func TestGeneratedFileIsFormatted(t *testing.T) {
	for _, tc := range goldenCases {
		t.Run(tc.name, func(t *testing.T) {
			b, err := os.ReadFile(goldenPath(tc.name))
			if err != nil {
				t.Fatalf("reading the golden file: %v", err)
			}
			want, err := formatGo(b)
			if err != nil {
				t.Fatalf("the golden file is not valid Go: %v", err)
			}
			if string(b) != string(want) {
				t.Errorf("%s is not gofmt-clean", goldenPath(tc.name))
			}
		})
	}
}

// TestHelpIsNotAnError: -h is a request that was answered, so it goes to
// standard output and succeeds. Everything else this tool refuses goes to
// stderr and does not.
func TestHelpIsNotAnError(t *testing.T) {
	stdout, stderr, err := generate(t, "-h")
	if err != nil {
		t.Fatalf("-h failed: %v\nstderr:\n%s", err, stderr)
	}
	if stderr != "" {
		t.Errorf("help was written to stderr:\n%s", stderr)
	}
	for _, want := range []string{"Usage:", "-var", "-compress", "go:generate"} {
		if !strings.Contains(stdout, want) {
			t.Errorf("the usage does not mention %q:\n%s", want, stdout)
		}
	}
}

// TestKeepNamesReachesTheEngine covers the flag with the most say over whether
// the embedded shader still works: a name the host binds against must survive
// minification.
func TestKeepNamesReachesTheEngine(t *testing.T) {
	stdout, stderr, err := generate(t, "-keep-names", "luminance", "-var", "Blur", "-pkg", "shaders", "testdata/blur.wgsl")
	if err != nil {
		t.Fatalf("run: %v\nstderr:\n%s", err, stderr)
	}
	if !strings.Contains(stdout, "luminance") {
		t.Errorf("-keep-names did not reach the engine:\n%s", stdout)
	}
}
