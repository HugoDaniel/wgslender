package wgslender

import "encoding/json"

// The diagnostic vocabulary, shared by [Validate], [Lint] and [LintFix]. The
// engine writes one diagnostic shape for all of them (src/Diagnostic.zig), so
// there is one Go type for all of them too.

// A Severity says how seriously to take a [Diagnostic].
//
// It is deliberately an open enum: the constants below are what the engine
// spells today, but a severity this package has never heard of arrives verbatim
// rather than being flattened into one of them. Compare against the constants,
// and expect the default branch to be reachable.
type Severity string

const (
	// SeverityError rejects the shader.
	SeverityError Severity = "error"
	// SeverityWarning is legal, but almost certainly not what the author meant.
	SeverityWarning Severity = "warning"
	// SeverityInfo is neutral commentary.
	SeverityInfo Severity = "info"
	// SeverityNote is extra context attached to another diagnostic.
	SeverityNote Severity = "note"
	// SeverityHint is a suggestion an editor can act on.
	SeverityHint Severity = "hint"
	// SeverityUnknown is what the engine falls back to when it has no better
	// word. It is a real wire value, not this package's fallback.
	SeverityUnknown Severity = "unknown"
)

// A Diagnostic is one thing the engine has to say about a shader.
//
// Positions are 1-based, the way every editor and compiler prints them.
type Diagnostic struct {
	// Severity is how serious it is.
	Severity Severity
	// Message is human-readable text, with no position prefix.
	Message string
	// Code is the stable identifier, such as E0100 or W0001. Parse errors
	// often have none, so this is empty more than rarely.
	Code string
	// Line is the 1-based line of the first offending byte.
	Line int
	// Column is the 1-based column of the first offending byte.
	Column int
	// SpecRef points at the section of the WGSL specification this rests on,
	// when there is one.
	SpecRef string
	// Source names what produced the diagnostic. Lint rules say
	// "wgslender-lint"; the parser and validator leave it empty, which is how
	// [LintReport.Diagnostics] can be told apart despite arriving in one array.
	Source string
	// Related is context elsewhere in the file — the earlier declaration a
	// name shadows, say.
	Related []RelatedInfo
	// Fix is the rewrite that resolves this diagnostic, present only on the
	// ones [LintFix] can apply. It describes a splice: replace Range with Text.
	Fix *Fix
}

// A RelatedInfo is a second place in the source that explains a [Diagnostic].
type RelatedInfo struct {
	// Line is the 1-based line.
	Line int
	// Column is the 1-based column.
	Column int
	// Message says why this place is relevant.
	Message string
}

// A Fix is a rewrite that resolves a [Diagnostic]: replace the source in Range
// with Text.
type Fix struct {
	// Range is the span to replace.
	Range Range
	// Text is what to put there. Empty means a deletion.
	Text string
}

// A Range is a half-open span of source, from Start up to but not including
// End.
type Range struct {
	// Start is where the span begins.
	Start Position
	// End is the first position after it.
	End Position
}

// A Position is one place in a source file, given three ways because different
// callers want different ones: editors want line and column, splicing wants the
// offset.
type Position struct {
	// Line is 1-based.
	Line int
	// Column is 1-based.
	Column int
	// Offset is a 0-based UTF-8 byte offset from the start of the source.
	Offset int
}

// wireDiagnostic is the engine's diagnostic object (src/Diagnostic.zig,
// entryToJson). Absent keys — code, specRef, source, related, fix — are omitted
// when empty rather than sent as null, so a zero value is the right default for
// every one of them.
type wireDiagnostic struct {
	Severity Severity      `json:"severity"`
	Message  string        `json:"message"`
	Code     string        `json:"code"`
	Line     int           `json:"line"`
	Column   int           `json:"column"`
	SpecRef  string        `json:"specRef"`
	Source   string        `json:"source"`
	Related  []wireRelated `json:"related"`
	Fix      *wireFix      `json:"fix"`
}

type wireRelated struct {
	Line    int    `json:"line"`
	Column  int    `json:"column"`
	Message string `json:"message"`
}

// wireFix is the one place the wire and the Go shape genuinely differ: the
// engine flattens the range into six sibling keys, where a Range reads better
// as two positions.
type wireFix struct {
	Range struct {
		StartLine   int `json:"startLine"`
		StartColumn int `json:"startColumn"`
		StartOffset int `json:"startOffset"`
		EndLine     int `json:"endLine"`
		EndColumn   int `json:"endColumn"`
		EndOffset   int `json:"endOffset"`
	} `json:"range"`
	Text string `json:"text"`
}

func (w wireDiagnostic) result() Diagnostic {
	d := Diagnostic{
		Severity: w.Severity,
		Message:  w.Message,
		Code:     w.Code,
		Line:     w.Line,
		Column:   w.Column,
		SpecRef:  w.SpecRef,
		Source:   w.Source,
	}
	if len(w.Related) > 0 {
		d.Related = make([]RelatedInfo, len(w.Related))
		for i, r := range w.Related {
			d.Related[i] = RelatedInfo(r)
		}
	}
	if w.Fix != nil {
		r := w.Fix.Range
		d.Fix = &Fix{
			Range: Range{
				Start: Position{Line: r.StartLine, Column: r.StartColumn, Offset: r.StartOffset},
				End:   Position{Line: r.EndLine, Column: r.EndColumn, Offset: r.EndOffset},
			},
			Text: w.Fix.Text,
		}
	}
	return d
}

// diagnostics converts a wire array, leaving an empty one nil so that callers
// can range over it either way.
func diagnostics(ws []wireDiagnostic) []Diagnostic {
	if len(ws) == 0 {
		return nil
	}
	out := make([]Diagnostic, len(ws))
	for i, w := range ws {
		out[i] = w.result()
	}
	return out
}

// Two ways of pointing at something, shared by reflection and the refactor
// operations. Reflection hands them out; the refactor operations take them
// back.

// A StableID names a symbol in a way that survives reparsing, such as
// "v1:fn:main/block#0/let:y". It is what the refactor operations take instead
// of a byte offset, which moves the moment anyone edits the file.
type StableID string

// A Span is a half-open byte range of source, from Start up to but not
// including End. Offsets are UTF-8 bytes, which is what Go's own string
// indexing uses, so source[s.Start:s.End] is the text it covers.
//
// In reflection the zero Span means the engine did not record one: it omits a
// span it could not determine, and its own test for presence is End > Start,
// so no real span is ever zero. Elsewhere absence is reported some other way —
// the locate operations use a second return — and a zero Span is not
// meaningful on its own.
type Span struct {
	Start int `json:"start"`
	End   int `json:"end"`
}

// The reflection vocabulary, produced by [Reflect] and [MinifyAndReflect].
//
// These types are decoded straight out of the engine's document, which is why
// they carry JSON tags instead of being copied out of a hidden mirror of
// themselves. The reflect envelope's shape *is* the shape a Go caller wants,
// key for key, so a mirror would be forty fields of pure transcription and
// forty chances to misspell one. The single place the wire and Go genuinely
// differ is [TypeInfo], which decodes itself. ([Edit] and [Reference] are
// tagged for the same reason; [Diagnostic] is mirrored because its wire shape
// is not the shape a caller wants.)
//
// Two conventions run through all of it:
//
//   - A pointer field is one the engine can send as JSON null or leave out,
//     and nil means it did. Nothing else is a pointer, so a non-pointer field
//     is always a real value the engine computed.
//   - The string-shaped types below — [AddressSpace], [ShaderStage] and their
//     kin — are open enums, exactly as [Severity] is. A value this package has
//     never heard of arrives verbatim rather than being flattened.
//
// Decoding is faithful; re-encoding is not promised. Use [ReflectJSON] when you
// want the engine's own bytes.

// An AddressSpace is where a variable lives (WGSL §7.3). Bindings are in
// uniform, storage, or — for textures and samplers — handle.
type AddressSpace string

const (
	// AddressSpaceFunction holds a variable local to one function call.
	AddressSpaceFunction AddressSpace = "function"
	// AddressSpacePrivate holds module-scope state private to one invocation.
	AddressSpacePrivate AddressSpace = "private"
	// AddressSpaceWorkgroup holds state shared by a compute workgroup.
	AddressSpaceWorkgroup AddressSpace = "workgroup"
	// AddressSpaceUniform holds a read-only binding uploaded by the host.
	AddressSpaceUniform AddressSpace = "uniform"
	// AddressSpaceStorage holds a buffer binding, writable when its
	// [AccessMode] says so.
	AddressSpaceStorage AddressSpace = "storage"
	// AddressSpaceHandle holds textures and samplers. WGSL leaves it
	// unspellable in source; the engine infers it from the type.
	AddressSpaceHandle AddressSpace = "handle"
)

// An AccessMode is how a variable may be used (WGSL §7.3). It is spelled only
// where WGSL spells it — a storage binding and a pointer — and is empty
// elsewhere.
type AccessMode string

const (
	// AccessRead lets the shader only read.
	AccessRead AccessMode = "read"
	// AccessWrite lets the shader only write.
	AccessWrite AccessMode = "write"
	// AccessReadWrite lets the shader do both.
	AccessReadWrite AccessMode = "read_write"
)

// A ShaderStage is the pipeline stage an entry point belongs to.
type ShaderStage string

const (
	// StageCompute runs over a workgroup grid the host dispatches.
	StageCompute ShaderStage = "compute"
	// StageVertex runs once per vertex.
	StageVertex ShaderStage = "vertex"
	// StageFragment runs once per rasterised fragment.
	StageFragment ShaderStage = "fragment"
)

// A TypeKind discriminates a [TypeInfo]. It says which of that struct's fields
// mean anything.
type TypeKind string

const (
	// KindScalar is a lone numeric or boolean value.
	KindScalar TypeKind = "scalar"
	// KindVec is a vector of scalars.
	KindVec TypeKind = "vec"
	// KindMat is a matrix of column vectors.
	KindMat TypeKind = "mat"
	// KindArray is an array, sized or runtime-sized.
	KindArray TypeKind = "array"
	// KindStruct is a structure the shader declares.
	KindStruct TypeKind = "struct"
	// KindAtomic is an atomic wrapper over an integer scalar.
	KindAtomic TypeKind = "atomic"
	// KindSampler is a sampler, which has no memory layout at all.
	KindSampler TypeKind = "sampler"
	// KindTexture is a texture; [TextureKind] and [TextureDimension] say more.
	KindTexture TypeKind = "texture"
	// KindPtr is a pointer, which never crosses the host boundary.
	KindPtr TypeKind = "ptr"
)

// A TextureDimension is a texture's shape.
type TextureDimension string

const (
	// Dim1D is a one-dimensional texture.
	Dim1D TextureDimension = "1d"
	// Dim2D is a two-dimensional texture.
	Dim2D TextureDimension = "2d"
	// Dim2DArray is an array of two-dimensional layers.
	Dim2DArray TextureDimension = "2d_array"
	// Dim3D is a volume texture.
	Dim3D TextureDimension = "3d"
	// DimCube is a cube of six square faces.
	DimCube TextureDimension = "cube"
	// DimCubeArray is an array of cubes.
	DimCubeArray TextureDimension = "cube_array"
)

// A TextureKind is what a texture is for, which decides how it may be sampled
// and which bind-group layout entry it needs.
type TextureKind string

const (
	// TextureSampled is read through a sampler.
	TextureSampled TextureKind = "sampled"
	// TextureMultisampled holds several samples per texel.
	TextureMultisampled TextureKind = "multisampled"
	// TextureStorage is read and written directly, no sampler involved.
	TextureStorage TextureKind = "storage"
	// TextureDepth holds depth values for comparison sampling.
	TextureDepth TextureKind = "depth"
	// TextureDepthMultisampled is a depth texture with several samples per
	// texel.
	TextureDepthMultisampled TextureKind = "depth_multisampled"
	// TextureExternal wraps a video frame the host imports.
	TextureExternal TextureKind = "external"
)

// A Reflection is everything the engine can say about a shader's interface:
// what it binds, what it declares and how it is laid out in memory.
//
// Every collection is present whether or not it holds anything. Errors is the
// exception and the useful one — it is non-empty exactly when the source did
// not parse.
type Reflection struct {
	// Version is the schema version of the engine's document. It is 2.
	Version int `json:"version"`
	// Bindings is every @group/@binding variable, in declaration order.
	Bindings []Binding `json:"bindings"`
	// Uniforms, Storage, Textures and Samplers are views of Bindings by kind.
	// They hold whole copies, not indices, so a binding read out of one of
	// them is complete.
	Uniforms []Binding `json:"uniforms"`
	Storage  []Binding `json:"storage"`
	Textures []Binding `json:"textures"`
	Samplers []Binding `json:"samplers"`
	// Structs maps each declared struct's name to its memory layout.
	Structs map[string]StructLayout `json:"structs"`
	// EntryPoints is every @compute, @vertex and @fragment function.
	EntryPoints []EntryPoint `json:"entryPoints"`
	// Overrides is every pipeline-overridable constant.
	Overrides []Override `json:"overrides"`
	// Functions is the call graph — every function including the entry
	// points. It is populated even for source that did not parse, which is
	// what lets an editor keep showing an outline of a broken file.
	Functions []Function `json:"functions"`
	// Aliases is every type alias.
	Aliases []Alias `json:"aliases"`
	// Errors is what stopped the parser, and is empty for anything that
	// parsed. A shader that parses but does not type-check reflects cleanly
	// and reports nothing here; use [Validate] to find out whether it is
	// correct.
	Errors []string `json:"errors,omitempty"`
}

// A Binding is one @group/@binding variable — a resource the host has to
// supply.
type Binding struct {
	// Group is the @group index and Binding the @binding index.
	Group   uint32 `json:"group"`
	Binding uint32 `json:"binding"`
	// Name is the identifier as written in the source.
	Name string `json:"name"`
	// NameMapped is what that identifier became after minification. It equals
	// Name unless the reflection came from [MinifyAndReflect], and even then
	// only handle-space bindings are renamed by default — the host binds
	// against uniform and storage names, so those are left alone.
	NameMapped string `json:"nameMapped"`
	// NameOffset is the byte offset of the name in the original source.
	NameOffset int `json:"nameOffset"`
	// StableID names this variable across reparses.
	StableID StableID `json:"stableId,omitempty"`
	// DeclSpan covers the whole declaration, attributes through semicolon;
	// TypeSpan covers just the type.
	DeclSpan Span `json:"declSpan,omitzero"`
	TypeSpan Span `json:"typeSpan,omitzero"`
	// AddressSpace is where the resource lives.
	AddressSpace AddressSpace `json:"addressSpace"`
	// AccessMode is empty unless the declaration spells one, which in
	// practice means storage bindings.
	AccessMode AccessMode `json:"accessMode,omitempty"`
	// Type is the type as written and TypeMapped what it became after
	// minification.
	Type       string `json:"type"`
	TypeMapped string `json:"typeMapped"`
	// Layout is the memory layout, present when the type is a struct. The
	// same layout is in [Reflection.Structs] under the type's name.
	Layout *StructLayout `json:"layout,omitempty"`
	// Array describes the array, present when the type is one. It is a
	// different view from TypeInfo's — this one counts dimensions and
	// strides, that one describes the element type.
	Array *ArrayInfo `json:"array,omitempty"`
	// TypeInfo is the structured type, nil when the engine could not resolve
	// it.
	TypeInfo *TypeInfo `json:"typeInfo,omitempty"`
	// Relations names other bindings used together with this one — the
	// samplers a texture is sampled with, and back again.
	Relations []string `json:"relations,omitempty"`
}

// A StructLayout is a struct's size and field placement under WGSL's
// host-shareable layout rules (§6.2.10). It is what a host needs to write the
// buffer.
type StructLayout struct {
	// Size is the struct's byte size, padding included.
	Size int `json:"size"`
	// Alignment is its byte alignment.
	Alignment int `json:"alignment"`
	// Fields is its members in declaration order.
	Fields []Field `json:"fields"`
}

// A Field is one member of a [StructLayout].
type Field struct {
	// Name is the member as written and NameMapped what it became after
	// minification.
	Name       string `json:"name"`
	NameMapped string `json:"nameMapped"`
	// NameOffset is the byte offset of the name in the original source.
	NameOffset int `json:"nameOffset"`
	// StableID names this member across reparses.
	StableID StableID `json:"stableId,omitempty"`
	// TypeSpan covers the member's type in the original source.
	TypeSpan Span `json:"typeSpan,omitzero"`
	// Type is the type as written and TypeMapped what it became.
	Type       string `json:"type"`
	TypeMapped string `json:"typeMapped"`
	// Offset is the member's byte offset within the struct. It is not the
	// running sum of the preceding sizes: alignment inserts padding.
	Offset int `json:"offset"`
	// Size and Alignment are the member's own.
	Size      int `json:"size"`
	Alignment int `json:"alignment"`
	// Layout is the nested layout, present when this member is itself a
	// struct.
	Layout *StructLayout `json:"layout,omitempty"`
	// TypeInfo is the structured type.
	TypeInfo *TypeInfo `json:"typeInfo,omitempty"`
}

// An ArrayInfo describes one dimension of an array-typed binding, counting
// outward-in.
type ArrayInfo struct {
	// Depth is which dimension this is, starting at 1 for the outermost.
	Depth int `json:"depth"`
	// ElementCount is how many elements this dimension holds, nil for a
	// runtime-sized array — one whose length the host decides when it binds a
	// buffer.
	ElementCount *int `json:"elementCount"`
	// ElementStride is the byte distance between elements. It is known even
	// when the count is not.
	ElementStride int `json:"elementStride"`
	// TotalSize is the dimension's byte size, nil for a runtime-sized array.
	TotalSize *int `json:"totalSize"`
	// ElementType is the element type as written — an alias is not resolved
	// away here — and ElementTypeMapped what it became after minification.
	ElementType       string `json:"elementType"`
	ElementTypeMapped string `json:"elementTypeMapped"`
	// ElementLayout is the element's layout, present when the elements are
	// structs.
	ElementLayout *StructLayout `json:"elementLayout,omitempty"`
	// Array is the next dimension in, present for an array of arrays.
	Array *ArrayInfo `json:"array,omitempty"`
}

// An EntryPoint is one @compute, @vertex or @fragment function — a pipeline
// stage the host can name.
type EntryPoint struct {
	// Name is the function name. It is never renamed by minification, because
	// the host names this function when it builds a pipeline.
	Name string `json:"name"`
	// NameOffset is the byte offset of the name in the original source.
	NameOffset int `json:"nameOffset"`
	// StableID names this function across reparses.
	StableID StableID `json:"stableId,omitempty"`
	// DeclSpan covers the whole function.
	DeclSpan Span `json:"declSpan,omitzero"`
	// Stage is which pipeline stage this is.
	Stage ShaderStage `json:"stage"`
	// WorkgroupSize is the @workgroup_size, nil on a vertex or fragment entry
	// point. A dimension given by an override reads as 0, since its value is
	// not known until the pipeline is created.
	WorkgroupSize *[3]int `json:"workgroupSize"`
	// Overrides names the pipeline-overridable constants this entry point
	// depends on.
	Overrides []string `json:"overrides,omitempty"`
	// Inputs and Outputs are the stage's IO, with struct parameters and
	// returns flattened to their members.
	Inputs  []IOVar `json:"inputs"`
	Outputs []IOVar `json:"outputs"`
	// Resources names the bindings this entry point reaches, directly or
	// through the functions it calls.
	Resources []string `json:"resources"`
}

// An IOVar is one input to or output from an entry point: a parameter, a
// return value, or one member of a struct standing in for either.
type IOVar struct {
	// Name is the identifier, empty for a return value — WGSL gives those an
	// attribute rather than a name.
	Name string `json:"name"`
	// Location is the @location index, nil when this is a builtin.
	Location *int `json:"location,omitempty"`
	// Builtin is the @builtin name, empty when this has a location. Exactly
	// one of the two is set.
	Builtin string `json:"builtin,omitempty"`
	// Interpolate is the @interpolate attribute, nil when there is none.
	Interpolate *Interpolation `json:"interpolate,omitempty"`
	// Type is the type as written.
	Type string `json:"type,omitempty"`
	// TypeInfo is the structured type.
	TypeInfo *TypeInfo `json:"typeInfo,omitempty"`
}

// An Interpolation is a @interpolate attribute: how a value is interpolated
// across a primitive, and where it is sampled.
type Interpolation struct {
	// Type is "perspective", "linear" or "flat".
	Type string `json:"type"`
	// Sampling is "center", "centroid", "sample", "first" or "either", and is
	// empty when the attribute did not give one.
	Sampling string `json:"sampling,omitempty"`
}

// An Override is a pipeline-overridable constant — a value the host may
// replace at pipeline-creation time.
type Override struct {
	// Name is the identifier as written and NameMapped what it became.
	Name       string `json:"name"`
	NameMapped string `json:"nameMapped"`
	// NameOffset is the byte offset of the name in the original source.
	NameOffset int `json:"nameOffset"`
	// StableID names this constant across reparses.
	StableID StableID `json:"stableId,omitempty"`
	// DeclSpan covers the whole declaration.
	DeclSpan Span `json:"declSpan,omitzero"`
	// ID is the @id, nil when the declaration has none. @id(0) is legal and
	// means something different from no @id at all, which is why this is a
	// pointer.
	ID *int `json:"id"`
	// Type is the declared type.
	Type string `json:"type,omitempty"`
	// TypeInfo is the structured type.
	TypeInfo *TypeInfo `json:"typeInfo,omitempty"`
	// Default is the default value as an *expression*, not a number: an
	// override declared `= 8u` reads back as "8u", suffix and all.
	Default string `json:"default,omitempty"`
}

// An Alias is a type alias declaration.
type Alias struct {
	// Name is the alias as written and NameMapped what it became.
	Name       string `json:"name"`
	NameMapped string `json:"nameMapped"`
	// NameOffset is the byte offset of the name in the original source.
	NameOffset int `json:"nameOffset"`
	// StableID names this alias across reparses.
	StableID StableID `json:"stableId,omitempty"`
	// DeclSpan covers the whole declaration.
	DeclSpan Span `json:"declSpan,omitzero"`
	// Type is the aliased type as written and TypeMapped what it became.
	Type       string `json:"type"`
	TypeMapped string `json:"typeMapped"`
	// TypeInfo is the structured type it resolves to.
	TypeInfo *TypeInfo `json:"typeInfo,omitempty"`
}

// A Function is one node of the call graph. Entry points appear here too.
type Function struct {
	// Name is the function as written and NameMapped what it became. The
	// latter is empty unless there was a renaming pass.
	Name       string `json:"name"`
	NameMapped string `json:"nameMapped,omitempty"`
	// NameOffset is the byte offset of the name in the original source.
	NameOffset int `json:"nameOffset"`
	// StableID names this function across reparses.
	StableID StableID `json:"stableId,omitempty"`
	// DeclSpan covers the whole function.
	DeclSpan Span `json:"declSpan,omitzero"`
	// InUse reports whether some entry point can reach this function. It is
	// false for everything in a source that did not parse, since nothing was
	// resolved.
	InUse bool `json:"inUse"`
	// Calls names the functions this one calls directly.
	Calls []string `json:"calls"`
	// DirectResources and DirectOverrides name what this function's own body
	// touches, without following calls. [EntryPoint.Resources] is the
	// transitive version.
	DirectResources []string `json:"directResources"`
	DirectOverrides []string `json:"directOverrides"`
	// Params are the declared parameters, in declaration order. Entry
	// points have them too: their attributed pipeline I/O is the separate
	// [EntryPoint.Inputs] and [EntryPoint.Outputs].
	Params []Param `json:"params"`
	// ReturnType is the return type as written and ReturnTypeMapped what it
	// became. ReturnType is empty when the function returns nothing.
	ReturnType       string `json:"returnType"`
	ReturnTypeMapped string `json:"returnTypeMapped,omitempty"`
	// ReturnTypeInfo is the structured form of ReturnType.
	ReturnTypeInfo *TypeInfo `json:"returnTypeInfo,omitempty"`
}

// A Param is one declared parameter of a [Function].
//
// Types here are spelled from the AST, so they read as the author wrote
// them: "vec2f", not "vec2<f32>". Reflection does not run the validator, so
// a name that does not resolve is reported as written. Use Validate to find
// out whether a signature is true, and this to find out what it says.
type Param struct {
	// Name is the parameter as written and NameMapped what it became. The
	// latter is empty unless there was a renaming pass.
	Name       string `json:"name"`
	NameMapped string `json:"nameMapped,omitempty"`
	// Type is the type as written and TypeMapped what it became.
	Type       string `json:"type"`
	TypeMapped string `json:"typeMapped,omitempty"`
	// TypeInfo is the structured form of Type.
	TypeInfo *TypeInfo `json:"typeInfo,omitempty"`
}

// A TypeInfo is a WGSL type, taken apart.
//
// It is one struct for nine kinds of type, and [TypeInfo.Kind] says which
// fields mean anything — switch on it rather than testing fields for
// emptiness. The fields are grouped below by the kinds that use them.
type TypeInfo struct {
	// Kind discriminates everything else here.
	Kind TypeKind `json:"kind"`

	// Name is the type's name, on a scalar ("f32") or a struct ("Params").
	// A struct's members are not here — look the name up in
	// [Reflection.Structs].
	Name string `json:"name,omitempty"`

	// Width is a vector's component count; Cols and Rows are a matrix's
	// shape.
	Width int `json:"width,omitempty"`
	Cols  int `json:"cols,omitempty"`
	Rows  int `json:"rows,omitempty"`

	// Format is the element type of a vector, matrix, array, atomic or
	// pointer. A texture's format is a plain string and lives in TexFormat
	// instead, even though the engine sends both under the same key.
	Format *TypeInfo `json:"-"`

	// Count is an array's element count, nil for a runtime-sized array.
	Count *int `json:"count,omitempty"`
	// Size is the byte size, nil only for a runtime-sized array. Samplers and
	// textures have none.
	Size *int `json:"size,omitempty"`
	// Alignment is the byte alignment.
	Alignment int `json:"alignment,omitempty"`
	// Stride is the byte distance between a matrix's columns or an array's
	// elements.
	Stride int `json:"stride,omitempty"`

	// Comparison distinguishes a sampler_comparison from a plain sampler.
	Comparison bool `json:"comparison,omitempty"`

	// Dim, TexKind, TexFormat and SampleType describe a texture. TexFormat is
	// the storage format ("rgba8unorm") and is set only on storage textures;
	// SampleType ("f32", "u32", …) is set only on sampled ones.
	Dim        TextureDimension `json:"dim,omitempty"`
	TexKind    TextureKind      `json:"texKind,omitempty"`
	TexFormat  string           `json:"-"`
	SampleType string           `json:"sampleType,omitempty"`

	// Access is a storage texture's or a pointer's access mode.
	Access AccessMode `json:"access,omitempty"`
	// AddressSpace is a pointer's address space.
	AddressSpace AddressSpace `json:"addressSpace,omitempty"`
}

// typeInfoWire is TypeInfo with the one key that arrives as two different
// types left undecoded.
type typeInfoWire struct {
	Kind         TypeKind         `json:"kind"`
	Name         string           `json:"name"`
	Width        int              `json:"width"`
	Cols         int              `json:"cols"`
	Rows         int              `json:"rows"`
	Format       json.RawMessage  `json:"format"`
	Count        *int             `json:"count"`
	Size         *int             `json:"size"`
	Alignment    int              `json:"alignment"`
	Stride       int              `json:"stride"`
	Comparison   bool             `json:"comparison"`
	Dim          TextureDimension `json:"dim"`
	TexKind      TextureKind      `json:"texKind"`
	SampleType   string           `json:"sampleType"`
	Access       AccessMode       `json:"access"`
	AddressSpace AddressSpace     `json:"addressSpace"`
}

// UnmarshalJSON decodes a type, resolving the one place the engine's document
// is ambiguous: "format" is a nested type on a vector, matrix, array, atomic or
// pointer, and a plain format name on a texture. Kind says which, so this
// dispatches on it rather than guessing from the JSON.
func (t *TypeInfo) UnmarshalJSON(b []byte) error {
	var w typeInfoWire
	if err := json.Unmarshal(b, &w); err != nil {
		return err
	}
	*t = TypeInfo{
		Kind:         w.Kind,
		Name:         w.Name,
		Width:        w.Width,
		Cols:         w.Cols,
		Rows:         w.Rows,
		Count:        w.Count,
		Size:         w.Size,
		Alignment:    w.Alignment,
		Stride:       w.Stride,
		Comparison:   w.Comparison,
		Dim:          w.Dim,
		TexKind:      w.TexKind,
		SampleType:   w.SampleType,
		Access:       w.Access,
		AddressSpace: w.AddressSpace,
	}
	if len(w.Format) == 0 || string(w.Format) == "null" {
		return nil
	}
	if w.Kind == KindTexture {
		return json.Unmarshal(w.Format, &t.TexFormat)
	}
	var nested TypeInfo
	if err := json.Unmarshal(w.Format, &nested); err != nil {
		return err
	}
	t.Format = &nested
	return nil
}
