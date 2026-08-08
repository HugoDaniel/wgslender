package main

import (
	"bytes"
	"fmt"
	"go/token"
	"io"
	"maps"
	"slices"
	"strings"
	"unicode"
	"unicode/utf8"

	"github.com/HugoDaniel/wgslender/packages/go/wgslender"
)

// What -module turns a shader's interface into: constants for the slots and the
// entry points, a struct for every struct the shader declares, and a test that
// the structs are laid out the way the GPU will read them.
//
// The test is the point. A generated struct is a claim about memory — that
// Scene is 112 bytes with material at offset 80 — and a claim nobody checks is
// a wrong-pixels bug found a long way from the mistake that caused it. The Rust
// binding asserts the same thing at compile time; Go cannot constrain a
// struct's layout in the language, so the claim is written out as a test and
// checked whenever the package's tests run.
//
// # Alignment
//
// The generated struct's own alignment is not the shader's. WGSL aligns Scene
// to 16 bytes; Go computes a struct's alignment from its fields and cannot be
// told otherwise, so the Go struct is aligned to 4. Nothing here depends on it.
// Every type this generates is built out of 4-byte scalars, every WGSL offset
// for such a member is a multiple of 4, and so Go never inserts padding of its
// own on top of the padding written here. What it means is that the layout
// proof checks sizes and offsets and says nothing about alignment, because
// there is nothing it could say.

// A module is one shader's interface, being turned into Go.
type module struct {
	cfg config
	// decls is the module's own declarations, proof the test that checks them.
	decls bytes.Buffer
	proof bytes.Buffer
	// taken maps each Go identifier the module has claimed to the WGSL name
	// that claimed it, so that a second claimant can be told who was first.
	taken map[string]string
	// notes are the members that got no Go field, reported to whoever ran the
	// tool. Silence would leave them to notice the gap on their own.
	notes []string
}

// generateModule renders the module declarations and the layout proof for one
// reflected shader.
func generateModule(cfg config, r wgslender.Reflection) (decls, proof []byte, notes []string, err error) {
	m := &module{cfg: cfg, taken: make(map[string]string)}

	fmt.Fprintf(&m.proof, headerFormat, "wgslgen "+strings.Join(cfg.args, " "), cfg.pkgName)
	fmt.Fprint(&m.proof, "import (\n\t\"testing\"\n\t\"unsafe\"\n)\n")

	if err := m.bindings(r.Bindings); err != nil {
		return nil, nil, nil, err
	}
	if err := m.entryPoints(r.EntryPoints); err != nil {
		return nil, nil, nil, err
	}
	if err := m.structs(r.Structs); err != nil {
		return nil, nil, nil, err
	}
	return m.decls.Bytes(), m.proof.Bytes(), m.notes, nil
}

// claim reserves one generated identifier, refusing a name two WGSL
// declarations would both produce.
//
// Letting the collision through would mean the Go compiler complaining about a
// duplicate declaration of a name nobody wrote, in a file nobody edited.
func (m *module) claim(name, wgsl, what string) error {
	if first, ok := m.taken[name]; ok {
		return fmt.Errorf("the %s %q and %q both come out as %s, and one package cannot hold two of those",
			what, first, wgsl, name)
	}
	m.taken[name] = wgsl
	return nil
}

// goName turns a WGSL name into the exported Go one, with the prefix on the
// front.
//
// Exported, because every Go keyword is lower case: a WGSL member called range
// or func is perfectly ordinary, and capitalising it is all it takes for the Go
// declaration to be spellable.
func (m *module) goName(wgsl, what string) (string, error) {
	name := m.cfg.prefix + export(wgsl)
	if !token.IsIdentifier(name) || !token.IsExported(name) {
		return "", fmt.Errorf("the %s %q does not name an exported Go declaration (as %q)", what, wgsl, name)
	}
	return name, nil
}

// export capitalises a name's first rune.
func export(name string) string {
	r, size := utf8.DecodeRuneInString(name)
	return string(unicode.ToUpper(r)) + name[size:]
}

// bindings writes two constants per resource: the group it is in and the slot
// within it.
//
// Two constants rather than one struct value, because the generated file
// imports nothing. A shared BindingSlot type would have to come from the
// wgslender package, and a program that wants these numbers should not have to
// link a WebAssembly runtime to read them.
func (m *module) bindings(bs []wgslender.Binding) error {
	if len(bs) == 0 {
		return nil
	}
	fmt.Fprint(&m.decls, "\n// Where the shader's resources are bound.\nconst (\n")
	for i, b := range bs {
		name, err := m.goName(b.Name, "binding")
		if err != nil {
			return err
		}
		group, slot := name+"Group", name+"Binding"
		for _, claimed := range []string{group, slot} {
			if err := m.claim(claimed, b.Name, "binding"); err != nil {
				return err
			}
		}
		if i > 0 {
			fmt.Fprintln(&m.decls)
		}
		fmt.Fprintf(&m.decls, "\t// %s and %s are where %s is bound —\n\t// a %s %s.\n",
			group, slot, b.Name, b.AddressSpace, b.Type)
		fmt.Fprintf(&m.decls, "\t%s uint32 = %d\n\t%s uint32 = %d\n", group, b.Group, slot, b.Binding)
	}
	fmt.Fprint(&m.decls, ")\n")
	return nil
}

// entryPoints writes each pipeline stage's name, and its workgroup size where
// it has one.
func (m *module) entryPoints(es []wgslender.EntryPoint) error {
	for _, e := range es {
		name, err := m.goName("entry"+export(e.Name), "entry point")
		if err != nil {
			return err
		}
		if err := m.claim(name, e.Name, "entry point"); err != nil {
			return err
		}
		fmt.Fprintf(&m.decls, "\n// %s is %s, the shader's %s entry point.\nconst %s = %q\n",
			name, e.Name, e.Stage, name, e.Name)

		if e.WorkgroupSize == nil {
			continue
		}
		size := name + "WorkgroupSize"
		if err := m.claim(size, e.Name, "entry point"); err != nil {
			return err
		}
		// A dimension given by an override reads as 0, since its value is not
		// settled until the host creates the pipeline.
		fmt.Fprintf(&m.decls, "\n// %s is the @workgroup_size %s is declared with.\n"+
			"// It is a variable because Go has no array constants.\n"+
			"var %s = [3]uint32{%d, %d, %d}\n",
			size, e.Name, size, e.WorkgroupSize[0], e.WorkgroupSize[1], e.WorkgroupSize[2])
	}
	return nil
}

// structs writes one Go struct per struct the shader declares, in the order the
// shader declares them.
//
// Reflection hands them over as a map, which has no order at all, so the order
// is recovered from where each struct's first member was written. Sorting by
// name would be simpler and would put the generated file in an order that
// matches nothing the author can see.
func (m *module) structs(byName map[string]wgslender.StructLayout) error {
	names := slices.SortedFunc(maps.Keys(byName), func(a, b string) int {
		return declaredBefore(byName[a], byName[b], a, b)
	})

	// Every struct's Go name is claimed before any of them is written, because
	// a member of one struct can name another as its type, and the name it
	// names has to be the one that struct will be given.
	for _, name := range names {
		goName, err := m.goName(name, "struct")
		if err != nil {
			return err
		}
		if err := m.claim(goName, name, "struct"); err != nil {
			return err
		}
	}
	for _, name := range names {
		if err := m.oneStruct(name, byName[name]); err != nil {
			return err
		}
	}
	return nil
}

// declaredBefore orders two structs by where they were written, falling back to
// their names for a struct with no members to place it by.
func declaredBefore(a, b wgslender.StructLayout, aName, bName string) int {
	at, bt := 0, 0
	if len(a.Fields) > 0 {
		at = a.Fields[0].NameOffset
	}
	if len(b.Fields) > 0 {
		bt = b.Fields[0].NameOffset
	}
	if at != bt {
		return at - bt
	}
	return strings.Compare(aName, bName)
}

// oneStruct writes a struct, the constants for the members that have no Go
// type, and the test that the whole thing is laid out right.
//
// Every number written here is the shader's, never one this generator worked
// out for itself: the padding advances by the member's reflected size and the
// proof checks the member's reflected size, so a mapping that produced a Go
// type of the wrong width fails the proof rather than quietly shifting
// everything after it.
func (m *module) oneStruct(wgsl string, layout wgslender.StructLayout) error {
	name := m.cfg.prefix + export(wgsl)

	// Members are checked for collisions among themselves rather than against
	// the module: two structs may both have a Count, and one struct may not.
	members := make(map[string]string)

	var fields, checks bytes.Buffer
	fmt.Fprintf(&checks, "\tif got, want := unsafe.Sizeof(%s{}), uintptr(%d); got != want {\n"+
		"\t\tt.Errorf(\"%s is %%d bytes, and the shader's struct %s is %%d\", got, want)\n\t}\n",
		name, layout.Size, name, wgsl)

	// cursor is how far into the struct the fields written so far reach.
	cursor := 0
	pad := func(to int, why string) {
		if to <= cursor {
			return
		}
		fmt.Fprintf(&fields, "\t// %d bytes of padding: %s\n\t_ [%d]byte\n", to-cursor, why, to-cursor)
		cursor = to
	}

	for _, f := range layout.Fields {
		mapped, why := mapType(f.TypeInfo, m.cfg.prefix)
		pad(f.Offset, fmt.Sprintf("the shader puts %s at offset %d.", f.Name, f.Offset))

		if why != "" {
			// A member Go cannot spell is neither guessed at nor dropped. It
			// becomes padding of exactly its size, so every member after it
			// stays where the shader put it, and a constant says where it
			// begins so the caller can write the bytes.
			offset := name + export(f.Name) + "Offset"
			member := wgsl + "." + f.Name
			if err := m.claim(offset, member, "struct member"); err != nil {
				return err
			}
			m.notes = append(m.notes, fmt.Sprintf("%s (%s) has no Go field: %s Write it at %s.",
				member, f.Type, oneLine(why), offset))
			if f.Size > 0 {
				fmt.Fprintf(&fields, "\t// %d bytes for %s (%s), which has no Go type.\n"+
					"\t// Write it at %s.\n\t_ [%d]byte\n", f.Size, f.Name, f.Type, offset, f.Size)
				cursor = f.Offset + f.Size
			}
			fmt.Fprintf(&m.decls, "\n// %s is where %s (%s) begins — %d bytes into %s.\n//\n"+
				"// It has no field of its own:\n// %s\nconst %s = %d\n",
				offset, f.Name, f.Type, f.Offset, name, comment(why), offset, f.Offset)
			continue
		}

		member := export(f.Name)
		if !token.IsIdentifier(member) || !token.IsExported(member) {
			return fmt.Errorf("the struct member %q does not name an exported Go field (as %q)", wgsl+"."+f.Name, member)
		}
		if first, ok := members[member]; ok {
			return fmt.Errorf("the members %q and %q of struct %s both come out as %s, and one struct cannot hold two fields of that name",
				first, f.Name, wgsl, member)
		}
		members[member] = f.Name
		fmt.Fprintf(&fields, "\t// %s is %s: %s — %d bytes at offset %d.\n\t%s %s\n",
			member, f.Name, f.Type, f.Size, f.Offset, member, mapped)
		cursor = f.Offset + f.Size

		fmt.Fprintf(&checks, "\tif got, want := unsafe.Offsetof(%s{}.%s), uintptr(%d); got != want {\n"+
			"\t\tt.Errorf(\"%s.%s is at offset %%d, and the shader puts %s at %%d\", got, want)\n\t}\n",
			name, member, f.Offset, name, member, f.Name)
		fmt.Fprintf(&checks, "\tif got, want := unsafe.Sizeof(%s{}.%s), uintptr(%d); got != want {\n"+
			"\t\tt.Errorf(\"%s.%s is %%d bytes, and the shader's %s is %%d\", got, want)\n\t}\n",
			name, member, f.Size, name, member, f.Name)
	}
	pad(layout.Size, fmt.Sprintf("the shader's struct %s is %d bytes long.", wgsl, layout.Size))

	// A struct whose every member was runtime-sized has nothing to declare, and
	// gofmt spells an empty struct on one line.
	body := "{\n" + fields.String() + "}"
	if fields.Len() == 0 {
		body = "{}"
	}
	fmt.Fprintf(&m.decls, "\n// %s is the shader's struct %s — %d bytes.\n//\n"+
		"// Its own alignment is not the shader's %d: Go computes a struct's alignment\n"+
		"// from its fields and cannot be told otherwise. Only the offsets within it\n"+
		"// have to match the shader, and the padding is what makes them.\ntype %s struct %s\n",
		name, wgsl, layout.Size, layout.Alignment, name, body)

	fmt.Fprintf(&m.proof, "\n// Test%sLayout checks %s against the layout wgslender reflected out of\n"+
		"// %s.\n//\n// Go cannot constrain a struct's layout in the language, so the claim this\n"+
		"// struct makes about memory is checked here instead.\nfunc Test%sLayout(t *testing.T) {\n%s}\n",
		name, name, m.cfg.input, name, checks.String())
	return nil
}

// mapType returns the Go type for a WGSL type, or the reason there is none.
//
// A returned reason is not a failure. It is the answer for every WGSL type Go
// has no shape for, and the caller turns it into padding and an offset rather
// than into a type that would disagree with the GPU. The second return is the
// mapped type's own size, which the caller needs only to check a stride.
func mapType(t *wgslender.TypeInfo, prefix string) (string, string) {
	name, _, why := mapTypeSized(t, prefix)
	return name, why
}

// mapTypeSized is [mapType] with the size the Go type occupies, which is what
// the array and matrix rules compare a stride against.
func mapTypeSized(t *wgslender.TypeInfo, prefix string) (name string, size int, why string) {
	if t == nil {
		return "", 0, "wgslender did not report a type for it, so there is nothing to map."
	}
	switch t.Kind {
	case wgslender.KindScalar:
		switch t.Name {
		case "f32":
			return "float32", 4, ""
		case "u32":
			return "uint32", 4, ""
		case "i32":
			return "int32", 4, ""
		}
		return "", 0, unmapped(t.Name)

	case wgslender.KindVec:
		component, componentSize, why := mapTypeSized(t.Format, prefix)
		if why != "" {
			return "", 0, why
		}
		return fmt.Sprintf("[%d]%s", t.Width, component), t.Width * componentSize, ""

	case wgslender.KindMat:
		component, componentSize, why := mapTypeSized(t.Format, prefix)
		if why != "" {
			return "", 0, why
		}
		// A Go array's stride is its element size, so a column the shader
		// spaces further apart than it is wide has no Go spelling: the column
		// type would have to claim rows the shader does not have.
		if column := t.Rows * componentSize; column != t.Stride {
			return "", 0, fmt.Sprintf(
				"%d columns of %d bytes, %d bytes apart, and a Go array's stride is its\n"+
					"element size. wgslgen generates the matrices whose column stride is\n"+
					"their column size: mat2x2f, mat4x2f, mat2x4f, mat4x4f and the like.",
				t.Cols, column, t.Stride)
		}
		return fmt.Sprintf("[%d][%d]%s", t.Cols, t.Rows, component), t.Cols * t.Stride, ""

	case wgslender.KindArray:
		if t.Count == nil || t.Size == nil {
			return "", 0, "it is runtime-sized, and a Go struct cannot end in a length the\n" +
				"host has not chosen yet."
		}
		element, elementSize, why := mapTypeSized(t.Format, prefix)
		if why != "" {
			return "", 0, why
		}
		if elementSize != t.Stride {
			return "", 0, fmt.Sprintf(
				"%d elements of %d bytes, %d bytes apart, and a Go array's stride is\n"+
					"its element size. wgslgen generates the arrays whose stride is their\n"+
					"element size.",
				*t.Count, elementSize, t.Stride)
		}
		return fmt.Sprintf("[%d]%s", *t.Count, element), *t.Size, ""

	case wgslender.KindStruct:
		if t.Size == nil {
			return "", 0, unmapped(t.Name)
		}
		return prefix + export(t.Name), *t.Size, ""

	// An atomic occupies exactly what it makes atomic, and the atomicity is the
	// GPU's business: the host writes the initial value like any other.
	case wgslender.KindAtomic:
		return mapTypeSized(t.Format, prefix)
	}
	return "", 0, unmapped(string(t.Kind))
}

// unmapped is the reason for a WGSL type this generator has no mapping for.
func unmapped(what string) string {
	return fmt.Sprintf("%s is not a type wgslgen maps. It maps f32, u32 and i32, vectors and\n"+
		"matrices of them, fixed-size arrays, nested structs, and atomics of any\nof those.", what)
}

// comment continues a multi-line reason inside a doc comment.
func comment(why string) string { return strings.ReplaceAll(why, "\n", "\n// ") }

// oneLine flattens a multi-line reason into something to print on stderr.
func oneLine(why string) string { return strings.ReplaceAll(why, "\n", " ") }

// reportNotes says which members got no Go field, and where to write them
// instead. A member that quietly turned into padding would be one the caller
// discovered was missing while wondering why the GPU read nothing.
func reportNotes(w io.Writer, file string, notes []string) {
	for _, n := range notes {
		fmt.Fprintf(w, "%s: note: %s\n", file, n)
	}
}
