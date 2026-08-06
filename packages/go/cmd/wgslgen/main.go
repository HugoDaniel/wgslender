// Command wgslgen embeds a WGSL shader in a Go source file, minified and
// checked while the surrounding Go code is generated rather than when the
// pipeline is created.
//
// A shader loaded at run time is checked on the machine that runs it, which is
// usually not the machine the mistake was made on, and usually well after the
// build that would have been the place to say so. wgslgen moves both the
// checking and the minifying to `go generate`: a shader that does not
// type-check fails there, with the diagnostics on stderr and a non-zero status,
// and the bytes that reach the binary are already minified.
//
// # Usage
//
//	wgslgen [flags] -var Name shader.wgsl
//
// Normally from a directive in the package the shader belongs to, where the go
// tool supplies the package name through GOPACKAGE:
//
//	//go:generate wgslgen -var Blur -o blur_shader.go blur.wgsl
//
// That writes blur_shader.go holding the minified shader as a constant:
//
//	const Blur = "struct e{radius:f32,…"
//
// With -compress the same file holds a DEFLATE stream and a function that
// inflates it once, on the first call:
//
//	var Blur = sync.OnceValue(func() string { … })
//
// # Flags
//
//	-var name     the Go identifier to embed the shader as. Required.
//	-pkg name     the package clause to write. Defaults to $GOPACKAGE.
//	-o file       where to write. Defaults to standard output.
//	-compress     store a DEFLATE stream inflated on first use.
//	-validate     type-check the shader, refusing one that does not. Default true.
//	-strict       treat warnings as errors while validating.
//	-keep-names   comma-separated identifiers minification must not rename.
//
// Every one of wgslender's minification switches has a flag of its own —
// -minify-whitespace, -minify-identifiers, -minify-syntax, -tree-shaking,
// -mangle-external-bindings, -preserve-uniform-struct-types,
// -sort-declarations, -scope-local-rename. One that is not given is left to
// wgslender to decide.
//
// # Not minifying
//
// There is no flag for embedding a shader as written: Go has //go:embed for
// that. wgslgen is for what //go:embed cannot do, which is to look at the
// shader.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"go/token"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"unicode"
	"unicode/utf8"

	"git.hugodaniel.com/hugo/wgslender/packages/go/wgslender"
)

// The exit statuses. Two for a command line that could not be read, one for
// everything else, which follows the go tool and matters because `go generate`
// stops at the first non-zero status either way.
const (
	exitFailure = 1
	exitUsage   = 2
)

// errUsage reports a command line that cannot mean anything. Whatever returns
// it has already written the problem and the usage, so main exits on it without
// printing anything more.
var errUsage = errors.New("the command line could not be read")

func main() {
	err := run(context.Background(), os.Args[1:], os.Stdout, os.Stderr)
	switch {
	case err == nil:
	case errors.Is(err, errUsage):
		os.Exit(exitUsage)
	default:
		fmt.Fprintf(os.Stderr, "wgslgen: %v\n", err)
		os.Exit(exitFailure)
	}
}

// A config is one settled command line.
type config struct {
	// args is the command line as given, recorded verbatim in the generated
	// file's header so that whoever reads it can regenerate the file.
	args []string
	// input is the shader to read; output is where the Go file goes, empty for
	// standard output.
	input  string
	output string
	// varName is the identifier to embed the shader as, pkgName the package
	// clause to write.
	varName string
	pkgName string
	// compress stores the shader as a DEFLATE stream instead of a string
	// constant.
	compress bool
	// validate type-checks the shader; strict promotes its warnings to errors.
	validate bool
	strict   bool
	// opts is what minification was asked to do differently. An absent field
	// means wgslender's own default, not off.
	opts wgslender.MinifyOptions
}

// strictness is the mode to validate in.
func (c config) strictness() wgslender.Strictness {
	if c.strict {
		return wgslender.Strict
	}
	return wgslender.DefaultStrictness
}

// An optBool is a boolean flag that remembers whether it was given.
//
// The engine's minification options are an override set: absent means "keep
// wgslender's default", which is not the same as false, and flag.Bool has no
// way to say the first thing. Writing the defaults into this tool instead would
// pin a copy of them that goes stale the moment the engine changes its mind.
type optBool struct{ opt *wgslender.Opt[bool] }

// Set records the value, marking the option given.
func (o optBool) Set(s string) error {
	v, err := strconv.ParseBool(s)
	if err != nil {
		return fmt.Errorf("%q is not true or false", s)
	}
	*o.opt = wgslender.Set(v)
	return nil
}

// String reports the value for -h. An option nobody gave has nothing to report,
// and the flag package calls this on a zero value of the type to decide whether
// to print a default at all, so it tolerates a nil target.
func (o optBool) String() string {
	if o.opt == nil {
		return ""
	}
	if v, ok := o.opt.Get(); ok {
		return strconv.FormatBool(v)
	}
	return ""
}

// IsBoolFlag lets -minify-syntax stand alone, the way a flag.Bool does.
func (o optBool) IsBoolFlag() bool { return true }

// minifyOptionFlags are wgslender's own minification switches, one flag each.
//
// [wgslender.MinifyOptions.SourceMap] and its companion are deliberately
// absent: a source map is a second file, and a generator whose whole output is
// one Go constant has nowhere to put it. KeepNames is absent too because a list
// is not a boolean; it has -keep-names.
var minifyOptionFlags = []struct {
	name string
	doc  string
	// field points at the option this flag sets, which is the only thing that
	// can vary between rows.
	field func(*wgslender.MinifyOptions) *wgslender.Opt[bool]
}{
	{"minify-whitespace", "strip whitespace and comments",
		func(o *wgslender.MinifyOptions) *wgslender.Opt[bool] { return &o.MinifyWhitespace }},
	{"minify-identifiers", "rename identifiers to short names",
		func(o *wgslender.MinifyOptions) *wgslender.Opt[bool] { return &o.MinifyIdentifiers }},
	{"minify-syntax", "rewrite syntax into shorter equivalent forms",
		func(o *wgslender.MinifyOptions) *wgslender.Opt[bool] { return &o.MinifySyntax }},
	{"tree-shaking", "drop declarations no entry point can reach",
		func(o *wgslender.MinifyOptions) *wgslender.Opt[bool] { return &o.TreeShaking }},
	{"mangle-external-bindings", "rename @group/@binding variables too, which changes the names a host binds against",
		func(o *wgslender.MinifyOptions) *wgslender.Opt[bool] { return &o.MangleExternalBindings }},
	{"preserve-uniform-struct-types", "keep the type names of uniform and storage structs",
		func(o *wgslender.MinifyOptions) *wgslender.Opt[bool] { return &o.PreserveUniformStructTypes }},
	{"sort-declarations", "group similar declarations together, which compresses better",
		func(o *wgslender.MinifyOptions) *wgslender.Opt[bool] { return &o.SortDeclarations }},
	{"scope-local-rename", "reuse short names across sibling scopes, which compresses better",
		func(o *wgslender.MinifyOptions) *wgslender.Opt[bool] { return &o.ScopeLocalRename }},
}

const usageText = `wgslgen embeds a WGSL shader in a Go source file, minified and checked while
the surrounding Go code is generated rather than when the pipeline is created.

Usage:
	wgslgen [flags] -var Name shader.wgsl

Normally from a directive in the package the shader belongs to, where the go
tool supplies the package name through GOPACKAGE:

	//go:generate wgslgen -var Blur -o blur_shader.go blur.wgsl

Flags:
`

// usage writes the synopsis and the flags.
func usage(w io.Writer, fs *flag.FlagSet) {
	fmt.Fprint(w, usageText)
	fs.SetOutput(w)
	fs.PrintDefaults()
}

// usageError reports a command line that cannot mean anything, writing the
// problem and the usage before returning the sentinel main exits on.
func usageError(w io.Writer, fs *flag.FlagSet, format string, a ...any) error {
	fmt.Fprintf(w, "wgslgen: "+format+"\n", a...)
	usage(w, fs)
	return errUsage
}

// run is the whole tool, with its output injected so that the tests can run it
// without leaving the process.
func run(ctx context.Context, args []string, stdout, stderr io.Writer) error {
	cfg := config{args: args}

	fs := flag.NewFlagSet("wgslgen", flag.ContinueOnError)
	// The flag package's own reporting is turned off so that every message
	// this tool produces goes through the writers it was handed.
	fs.SetOutput(io.Discard)
	fs.Usage = func() {}

	fs.StringVar(&cfg.varName, "var", "", "the Go identifier to embed the shader as (required)")
	fs.StringVar(&cfg.pkgName, "pkg", os.Getenv("GOPACKAGE"), "the package clause to write (default $GOPACKAGE)")
	fs.StringVar(&cfg.output, "o", "", "where to write the Go file (default standard output)")
	fs.BoolVar(&cfg.compress, "compress", false, "store a DEFLATE stream, inflated on first use")
	fs.BoolVar(&cfg.validate, "validate", true, "type-check the shader, refusing one that does not")
	fs.BoolVar(&cfg.strict, "strict", false, "treat warnings as errors while validating")
	keepNames := fs.String("keep-names", "", "comma-separated identifiers minification must not rename")
	for _, f := range minifyOptionFlags {
		fs.Var(optBool{f.field(&cfg.opts)}, f.name, f.doc+" (wgslender decides when not given)")
	}

	if err := fs.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			usage(stdout, fs)
			return nil
		}
		return usageError(stderr, fs, "%v", err)
	}

	if fs.NArg() != 1 {
		return usageError(stderr, fs, "needs exactly one shader to embed, and was given %d", fs.NArg())
	}
	cfg.input = fs.Arg(0)

	switch {
	case cfg.varName == "":
		msg := "-var is required: it names the constant the shader is embedded as"
		if s := suggestVar(cfg.input); s != "" {
			msg += fmt.Sprintf(" (-var %s would suit %s)", s, cfg.input)
		}
		return usageError(stderr, fs, "%s", msg)
	case !isGoName(cfg.varName):
		return usageError(stderr, fs, "-var %s is not a Go identifier", cfg.varName)
	case cfg.pkgName == "":
		return usageError(stderr, fs, "-pkg is required when GOPACKAGE is not set, which the go tool sets for a go:generate directive")
	case !isGoName(cfg.pkgName):
		return usageError(stderr, fs, "-pkg %s is not a Go identifier", cfg.pkgName)
	case cfg.strict && !cfg.validate:
		return usageError(stderr, fs, "-strict says how to validate and -validate=false says not to")
	}
	cfg.opts.KeepNames = splitNames(*keepNames)

	file, err := embed(ctx, cfg, stderr)
	if err != nil {
		return err
	}
	if cfg.output == "" {
		_, err := stdout.Write(file)
		return err
	}
	return os.WriteFile(cfg.output, file, 0o644)
}

// embed reads the shader, decides whether to accept it, and renders the Go file
// to write. Nothing is written anywhere until it has returned.
func embed(ctx context.Context, cfg config, stderr io.Writer) ([]byte, error) {
	b, err := os.ReadFile(cfg.input)
	if err != nil {
		return nil, err
	}
	source := string(b)

	if cfg.validate {
		v, err := wgslender.Validate(ctx, source, cfg.strictness())
		if err != nil {
			return nil, err
		}
		// Warnings are reported whether or not they are fatal. Under -strict
		// they arrive as errors and this is the refusal; otherwise they are the
		// engine's opinion, and one nobody ever sees is worth nothing.
		reportDiagnostics(stderr, cfg.input, v.Diagnostics)
		if !v.Valid {
			return nil, fmt.Errorf("%s: %s", cfg.input, plural(v.ErrorCount, "error"))
		}
	}

	m, err := wgslender.Minify(ctx, source, &cfg.opts)
	if err != nil {
		return nil, err
	}
	if len(m.Errors) > 0 {
		// Reachable only under -validate=false: the validator reports these
		// first, and with positions. A shader that did not parse comes back
		// from the minifier verbatim, so there is nothing here worth embedding.
		for _, e := range m.Errors {
			fmt.Fprintf(stderr, "%s: error: %s\n", cfg.input, e)
		}
		return nil, fmt.Errorf("%s: %s", cfg.input, plural(len(m.Errors), "error"))
	}
	return render(cfg, m)
}

// reportDiagnostics writes what the validator said, in the file:line:column
// shape every editor and build log knows how to jump to.
func reportDiagnostics(w io.Writer, file string, ds []wgslender.Diagnostic) {
	for _, d := range ds {
		code := ""
		if d.Code != "" {
			code = "[" + d.Code + "]"
		}
		fmt.Fprintf(w, "%s:%d:%d: %s%s: %s\n", file, d.Line, d.Column, d.Severity, code, d.Message)
		for _, r := range d.Related {
			fmt.Fprintf(w, "%s:%d:%d: note: %s\n", file, r.Line, r.Column, r.Message)
		}
	}
}

// plural counts things in a sentence.
func plural(n int, thing string) string {
	if n == 1 {
		return "1 " + thing
	}
	return fmt.Sprintf("%d %ss", n, thing)
}

// splitNames reads a comma-separated flag value, ignoring the empty entries a
// trailing comma or an unset flag leaves behind.
func splitNames(s string) []string {
	var out []string
	for name := range strings.SplitSeq(s, ",") {
		if name = strings.TrimSpace(name); name != "" {
			out = append(out, name)
		}
	}
	return out
}

// isGoName reports whether name can be written where the generated file puts
// it. The blank identifier passes go/token's test and is rejected here, since a
// shader embedded as _ is one nothing can reach.
func isGoName(name string) bool { return name != "_" && token.IsIdentifier(name) }

// suggestVar turns a shader's filename into a name worth suggesting, or an
// empty string when nothing usable comes out of it.
//
// It is only ever a suggestion. Deriving -var rather than requiring it would
// mean every caller had to predict this function, and predicting it is harder
// than typing the name they wanted.
func suggestVar(input string) string {
	base := strings.TrimSuffix(filepath.Base(input), filepath.Ext(input))
	var name strings.Builder
	for _, part := range strings.FieldsFunc(base, func(r rune) bool {
		return !unicode.IsLetter(r) && !unicode.IsDigit(r) && r != '_'
	}) {
		r, size := utf8.DecodeRuneInString(part)
		name.WriteRune(unicode.ToUpper(r))
		name.WriteString(part[size:])
	}
	if s := name.String(); isGoName(s) {
		return s
	}
	return ""
}
