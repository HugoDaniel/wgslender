//! Snapshot tests — all 44 test cases from the Go minifier_test.go.
//! Each test minifies a WGSL input and compares against the expected
//! output from the Go snapshot files (byte-identical matching).

const std = @import("std");
const wgslender = @import("wgslender");

// =========================================================================
// Helpers
// =========================================================================

fn ws(allocator: std.mem.Allocator, input: [:0]const u8) ![]const u8 {
    const r = try wgslender.minifyWithOptions(allocator, input, .{
        .minify_whitespace = true,
        .minify_identifiers = false,
        .minify_syntax = false,
        .tree_shaking = false,
    });
    return r.code;
}

fn full(allocator: std.mem.Allocator, input: [:0]const u8) ![]const u8 {
    const r = try wgslender.minifyWithOptions(allocator, input, .{
        .minify_whitespace = true,
        .minify_identifiers = true,
        .minify_syntax = true,
        .tree_shaking = false,
    });
    return r.code;
}

fn mangleExt(allocator: std.mem.Allocator, input: [:0]const u8) ![]const u8 {
    const r = try wgslender.minifyWithOptions(allocator, input, .{
        .minify_whitespace = true,
        .minify_identifiers = true,
        .minify_syntax = true,
        .mangle_external_bindings = true,
        .tree_shaking = false,
    });
    return r.code;
}

// =========================================================================
// snapshots_basic.txt (whitespace-only)
// =========================================================================

test "ConstSimple" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings(
        "const x=1;const y=2;const z=x+y;",
        try ws(arena.allocator(), "const x = 1;\nconst y = 2;\nconst z = x + y;\n"),
    );
}

test "VarDeclarations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings(
        "var<private> counter:i32;var<workgroup> flag:bool;",
        try ws(arena.allocator(), "var<private> counter: i32;\nvar<workgroup> flag: bool;\n"),
    );
}

test "FunctionSimple" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings(
        "fn add(a:i32,b:i32)->i32{return a+b;}",
        try ws(arena.allocator(), "fn add(a: i32, b: i32) -> i32 {\n    return a + b;\n}\n"),
    );
}

test "StructSimple" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings(
        "struct Point{x:f32,y:f32,z:f32}",
        try ws(arena.allocator(), "struct Point {\n    x: f32,\n    y: f32,\n    z: f32,\n}\n"),
    );
}

// =========================================================================
// snapshots_whitespace.txt
// =========================================================================

test "RemoveNewlines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings(
        "const a=1;const b=2;const c=3;",
        try ws(arena.allocator(), "const a = 1;\n\nconst b = 2;\n\nconst c = 3;\n"),
    );
}

test "RemoveIndentation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings(
        "fn foo(){if true{return;}}",
        try ws(arena.allocator(), "fn foo() {\n    if true {\n        return;\n    }\n}\n"),
    );
}

test "CompactOperators" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings(
        "const x=1+2*3-4/5;",
        try ws(arena.allocator(), "const x = 1 + 2 * 3 - 4 / 5;\n"),
    );
}

test "CompactFunction" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings(
        "fn compute(a:f32,b:f32,c:f32)->f32{let temp=a+b;return temp*c;}",
        try ws(arena.allocator(), "fn compute(a: f32, b: f32, c: f32) -> f32 {\n    let temp = a + b;\n    return temp * c;\n}\n"),
    );
}

// =========================================================================
// snapshots_expressions.txt (whitespace-only)
// =========================================================================

test "Arithmetic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings(
        "const a=1+2*3-4/5%6;const b=(1+2)*(3-4);const c=-1+-2;",
        try ws(arena.allocator(), "const a = 1 + 2 * 3 - 4 / 5 % 6;\nconst b = (1 + 2) * (3 - 4);\nconst c = -1 + -2;\n"),
    );
}

test "Logical" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings(
        "const a=true&&false;const b=true||false;const c=!true;const d=true&&(false||true);",
        try ws(arena.allocator(), "const a = true && false;\nconst b = true || false;\nconst c = !true;\nconst d = true && (false || true);\n"),
    );
}

test "Bitwise" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings(
        "const a=1&2;const b=1|2;const c=1^2;const d=~1;const e=1<<2;const f=8>>2;",
        try ws(arena.allocator(), "const a = 1 & 2;\nconst b = 1 | 2;\nconst c = 1 ^ 2;\nconst d = ~1;\nconst e = 1 << 2;\nconst f = 8 >> 2;\n"),
    );
}

test "Comparison" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings(
        "const a=1==2;const b=1!=2;const c=1<2;const d=1<=2;const e=1>2;const f=1>=2;",
        try ws(arena.allocator(), "const a = 1 == 2;\nconst b = 1 != 2;\nconst c = 1 < 2;\nconst d = 1 <= 2;\nconst e = 1 > 2;\nconst f = 1 >= 2;\n"),
    );
}

test "MemberAccess" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings(
        "const a=v.x;const b=v.xyz;const c=m[0][1];const d=arr[i].field;",
        try ws(arena.allocator(), "const a = v.x;\nconst b = v.xyz;\nconst c = m[0][1];\nconst d = arr[i].field;\n"),
    );
}

test "FunctionCalls" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings(
        "const a=sin(1.0);const b=max(1.0,2.0);const c=clamp(x,0.0,1.0);const d=dot(v1,v2);",
        try ws(arena.allocator(), "const a = sin(1.0);\nconst b = max(1.0, 2.0);\nconst c = clamp(x, 0.0, 1.0);\nconst d = dot(v1, v2);\n"),
    );
}

test "TypeConstructors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings(
        "const a=vec3f(1.0);const b=vec3f(1.0,2.0,3.0);const c=vec4f(v.xyz,1.0);const d=mat4x4f();",
        try ws(arena.allocator(), "const a = vec3f(1.0);\nconst b = vec3f(1.0, 2.0, 3.0);\nconst c = vec4f(v.xyz, 1.0);\nconst d = mat4x4f();\n"),
    );
}

// =========================================================================
// snapshots_controlflow.txt (whitespace-only)
// =========================================================================

test "IfElse" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings(
        "fn test(x:i32)->i32{if x>0{return 1;} else if x<0{return -1;} else{return 0;}}",
        try ws(arena.allocator(), "fn test(x: i32) -> i32 {\n    if x > 0 {\n        return 1;\n    } else if x < 0 {\n        return -1;\n    } else {\n        return 0;\n    }\n}\n"),
    );
}

test "WhileLoop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings(
        "fn countdown(n:i32){var x=n;while x>0{x--;}}",
        try ws(arena.allocator(), "fn countdown(n: i32) {\n    var x = n;\n    while x > 0 {\n        x--;\n    }\n}\n"),
    );
}

test "LoopSimple" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings(
        "fn loopTest(){var i=0;loop{if i>=10{break;}i++;}}",
        try ws(arena.allocator(), "fn loopTest() {\n    var i = 0;\n    loop {\n        if i >= 10 {\n            break;\n        }\n        i++;\n    }\n}\n"),
    );
}

test "Switch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings(
        "fn getColor(index:i32)->vec3f{switch index{case 0:{return vec3f(1.0,0.0,0.0);}case 1:{return vec3f(0.0,1.0,0.0);}case 2:{return vec3f(0.0,0.0,1.0);}default:{return vec3f(0.0,0.0,0.0);}}}",
        try ws(arena.allocator(), "fn getColor(index: i32) -> vec3f {\n    switch index {\n        case 0: {\n            return vec3f(1.0, 0.0, 0.0);\n        }\n        case 1: {\n            return vec3f(0.0, 1.0, 0.0);\n        }\n        case 2: {\n            return vec3f(0.0, 0.0, 1.0);\n        }\n        default: {\n            return vec3f(0.0, 0.0, 0.0);\n        }\n    }\n}\n"),
    );
}

// =========================================================================
// snapshots_types.txt (whitespace-only)
// =========================================================================

test "ScalarTypes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings(
        "var a:bool;var b:i32;var c:u32;var d:f32;var e:f16;",
        try ws(arena.allocator(), "var a: bool;\nvar b: i32;\nvar c: u32;\nvar d: f32;\nvar e: f16;\n"),
    );
}

test "VectorTypes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings(
        "var a:vec2f;var b:vec3f;var c:vec4f;var d:vec2<f32>;var e:vec3<i32>;var f:vec4<u32>;",
        try ws(arena.allocator(), "var a: vec2f;\nvar b: vec3f;\nvar c: vec4f;\nvar d: vec2<f32>;\nvar e: vec3<i32>;\nvar f: vec4<u32>;\n"),
    );
}

test "MatrixTypes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings(
        "var a:mat2x2f;var b:mat3x3f;var c:mat4x4f;var d:mat2x3<f32>;var e:mat3x4<f32>;",
        try ws(arena.allocator(), "var a: mat2x2f;\nvar b: mat3x3f;\nvar c: mat4x4f;\nvar d: mat2x3<f32>;\nvar e: mat3x4<f32>;\n"),
    );
}

test "ArrayTypes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings(
        "var a:array<f32>;var b:array<vec3f>;",
        try ws(arena.allocator(), "var a: array<f32>;\nvar b: array<vec3f>;\n"),
    );
}

test "TextureTypes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings(
        "var a:texture_2d<f32>;var b:texture_3d<f32>;var c:texture_cube<f32>;var d:texture_2d_array<f32>;var e:texture_storage_2d<rgba8unorm,write>;",
        try ws(arena.allocator(), "var a: texture_2d<f32>;\nvar b: texture_3d<f32>;\nvar c: texture_cube<f32>;\nvar d: texture_2d_array<f32>;\nvar e: texture_storage_2d<rgba8unorm, write>;\n"),
    );
}

test "SamplerTypes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings(
        "var a:sampler;var b:sampler_comparison;",
        try ws(arena.allocator(), "var a: sampler;\nvar b: sampler_comparison;\n"),
    );
}

// =========================================================================
// snapshots_directives.txt (whitespace-only)
// =========================================================================

test "EnableDirective" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings(
        "enable f16;enable chromium_experimental_dp4a;",
        try ws(arena.allocator(), "enable f16;\nenable chromium_experimental_dp4a;\n"),
    );
}

test "DiagnosticDirective" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings(
        "diagnostic(off,derivative_uniformity);",
        try ws(arena.allocator(), "diagnostic(off, derivative_uniformity);\n"),
    );
}

test "ConstAssert" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings(
        "const SIZE=64;const_assert SIZE>0;const_assert SIZE<=256;",
        try ws(arena.allocator(), "const SIZE = 64;\nconst_assert SIZE > 0;\nconst_assert SIZE <= 256;\n"),
    );
}

// =========================================================================
// snapshots_attributes.txt (whitespace-only)
// =========================================================================

test "BindingAttributes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings(
        "@group(0) @binding(0) var<uniform> uniforms:Uniforms;@group(0) @binding(1) var textureSampler:sampler;@group(0) @binding(2) var texture:texture_2d<f32>;",
        try ws(arena.allocator(), "@group(0) @binding(0) var<uniform> uniforms: Uniforms;\n@group(0) @binding(1) var textureSampler: sampler;\n@group(0) @binding(2) var texture: texture_2d<f32>;\n"),
    );
}

test "BuiltinAttributes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings(
        "struct VertexOutput{@builtin(position) position:vec4f,@location(0) color:vec3f}",
        try ws(arena.allocator(), "struct VertexOutput {\n    @builtin(position) position: vec4f,\n    @location(0) color: vec3f,\n}\n"),
    );
}

test "WorkgroupSize" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings(
        "@compute @workgroup_size(8,8,1) fn main(){}",
        try ws(arena.allocator(), "@compute @workgroup_size(8, 8, 1)\nfn main() {}\n"),
    );
}

// =========================================================================
// snapshots_complex.txt (whitespace-only)
// =========================================================================

test "VertexShaderWithStructs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings(
        "struct Uniforms{modelViewProjection:mat4x4f}struct VertexInput{@location(0) position:vec4f,@location(1) uv:vec2f}struct VertexOutput{@builtin(position) position:vec4f,@location(0) uv:vec2f}@group(0) @binding(0) var<uniform> uniforms:Uniforms;@vertex fn main(input:VertexInput)->VertexOutput{var output:VertexOutput;output.position=uniforms.modelViewProjection*input.position;output.uv=input.uv;return output;}",
        try ws(arena.allocator(), "struct Uniforms {\n    modelViewProjection: mat4x4f,\n}\n\nstruct VertexInput {\n    @location(0) position: vec4f,\n    @location(1) uv: vec2f,\n}\n\nstruct VertexOutput {\n    @builtin(position) position: vec4f,\n    @location(0) uv: vec2f,\n}\n\n@group(0) @binding(0) var<uniform> uniforms: Uniforms;\n\n@vertex\nfn main(input: VertexInput) -> VertexOutput {\n    var output: VertexOutput;\n    output.position = uniforms.modelViewProjection * input.position;\n    output.uv = input.uv;\n    return output;\n}\n"),
    );
}

test "FragmentShaderWithTexture" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings(
        "@group(0) @binding(1) var textureSampler:sampler;@group(0) @binding(2) var texture:texture_2d<f32>;@fragment fn main(@location(0) uv:vec2f)->@location(0) vec4f{return textureSample(texture,textureSampler,uv);}",
        try ws(arena.allocator(), "@group(0) @binding(1) var textureSampler: sampler;\n@group(0) @binding(2) var texture: texture_2d<f32>;\n\n@fragment\nfn main(@location(0) uv: vec2f) -> @location(0) vec4f {\n    return textureSample(texture, textureSampler, uv);\n}\n"),
    );
}

test "ComputeShaderSimple" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings(
        "@group(0) @binding(0) var<storage,read_write> data:array<f32>;@compute @workgroup_size(64) fn main(@builtin(global_invocation_id) id:vec3u){let idx=id.x;data[idx]=data[idx]*2.0;}",
        try ws(arena.allocator(), "@group(0) @binding(0) var<storage, read_write> data: array<f32>;\n\n@compute @workgroup_size(64)\nfn main(@builtin(global_invocation_id) id: vec3u) {\n    let idx = id.x;\n    data[idx] = data[idx] * 2.0;\n}\n"),
    );
}

// =========================================================================
// snapshots_entrypoints.txt (full minification)
// =========================================================================

test "VertexEntryPoint" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings(
        "@vertex fn vertexMain(@location(0) a:vec4f)->@builtin(position) vec4f{return a;}",
        try full(arena.allocator(), "@vertex\nfn vertexMain(@location(0) position: vec4f) -> @builtin(position) vec4f {\n    return position;\n}\n"),
    );
}

test "FragmentEntryPoint" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings(
        "@fragment fn fragmentMain()->@location(0) vec4f{return vec4f(1.,0.,0.,1.);}",
        try full(arena.allocator(), "@fragment\nfn fragmentMain() -> @location(0) vec4f {\n    return vec4f(1.0, 0.0, 0.0, 1.0);\n}\n"),
    );
}

test "ComputeEntryPoint" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings(
        "@compute @workgroup_size(64) fn computeMain(@builtin(global_invocation_id) id:vec3u){}",
        try full(arena.allocator(), "@compute @workgroup_size(64)\nfn computeMain(@builtin(global_invocation_id) id: vec3u) {\n    // compute work\n}\n"),
    );
}

// =========================================================================
// snapshots_identifiers.txt (full minification)
// =========================================================================

test "LocalVariables" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings(
        "fn d()->f32{let a=1.;let b=2.;let c=a+b;return c;}",
        try full(arena.allocator(), "fn compute() -> f32 {\n    let firstValue = 1.0;\n    let secondValue = 2.0;\n    let result = firstValue + secondValue;\n    return result;\n}\n"),
    );
}

test "FunctionParameters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings(
        "fn c(a:f32,b:f32)->f32{return a+b;}",
        try full(arena.allocator(), "fn add(firstNumber: f32, secondNumber: f32) -> f32 {\n    return firstNumber + secondNumber;\n}\n"),
    );
}

test "HelperFunctions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings(
        "fn a(b:f32)->f32{return b*2.;}fn d(c:f32)->f32{return a(c)+1.;}",
        try full(arena.allocator(), "fn helperFunction(value: f32) -> f32 {\n    return value * 2.0;\n}\n\nfn anotherHelper(input: f32) -> f32 {\n    return helperFunction(input) + 1.0;\n}\n"),
    );
}

test "EntryPointPreserved" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings(
        "fn c(a:f32)->f32{return a*2.;}@vertex fn vertexMain(@location(0) b:vec4f)->@builtin(position) vec4f{return b;}",
        try full(arena.allocator(), "fn helperFunc(x: f32) -> f32 {\n    return x * 2.0;\n}\n\n@vertex\nfn vertexMain(@location(0) pos: vec4f) -> @builtin(position) vec4f {\n    return pos;\n}\n"),
    );
}

test "StructRenaming" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings(
        "struct b{fieldOne:f32,fieldTwo:f32}fn c()->f32{var a:b;a.fieldOne=1.;a.fieldTwo=2.;return a.fieldOne+a.fieldTwo;}",
        try full(arena.allocator(), "struct MyCustomStruct {\n    fieldOne: f32,\n    fieldTwo: f32,\n}\n\nfn useStruct() -> f32 {\n    var instance: MyCustomStruct;\n    instance.fieldOne = 1.0;\n    instance.fieldTwo = 2.0;\n    return instance.fieldOne + instance.fieldTwo;\n}\n"),
    );
}

test "ConstRenaming" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings(
        "const a=42;const b=a*2;fn c()->i32{return a+b;}",
        try full(arena.allocator(), "const MY_CONSTANT = 42;\nconst ANOTHER_CONST = MY_CONSTANT * 2;\n\nfn useConsts() -> i32 {\n    return MY_CONSTANT + ANOTHER_CONST;\n}\n"),
    );
}

test "SameScopedNames" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings(
        "fn c()->f32{let a=1.;return a;}fn d()->f32{let b=2.;return b;}",
        try full(arena.allocator(), "fn funcOne() -> f32 {\n    let temp = 1.0;\n    return temp;\n}\n\nfn funcTwo() -> f32 {\n    let temp = 2.0;\n    return temp;\n}\n"),
    );
}

test "NestedScopes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings(
        "fn c()->f32{let a=1.;if true{let b=2.;return a+b;}return a;}",
        try full(arena.allocator(), "fn outer() -> f32 {\n    let outerVar = 1.0;\n    if true {\n        let innerVar = 2.0;\n        return outerVar + innerVar;\n    }\n    return outerVar;\n}\n"),
    );
}

// =========================================================================
// snapshots_combined.txt (full minification)
// =========================================================================

test "FullVertexShader" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings(
        "struct f{transform:mat4x4f}struct g{@location(0) position:vec4f,@location(1) texcoord:vec2f}struct d{@builtin(position) position:vec4f,@location(0) texcoord:vec2f}@group(0) @binding(0) var<uniform> uniforms:f;fn c(e:vec4f)->vec4f{return uniforms.transform*e;}@vertex fn vertexMain(b:g)->d{var a:d;a.position=c(b.position);a.texcoord=b.texcoord;return a;}",
        try full(arena.allocator(), "struct Uniforms {\n    transform: mat4x4f,\n}\n\nstruct VertexInput {\n    @location(0) position: vec4f,\n    @location(1) texcoord: vec2f,\n}\n\nstruct VertexOutput {\n    @builtin(position) position: vec4f,\n    @location(0) texcoord: vec2f,\n}\n\n@group(0) @binding(0) var<uniform> uniforms: Uniforms;\n\nfn transformPosition(pos: vec4f) -> vec4f {\n    return uniforms.transform * pos;\n}\n\n@vertex\nfn vertexMain(input: VertexInput) -> VertexOutput {\n    var output: VertexOutput;\n    output.position = transformPosition(input.position);\n    output.texcoord = input.texcoord;\n    return output;\n}\n"),
    );
}

test "FullFragmentShader" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings(
        "@group(0) @binding(1) var d:sampler;@group(0) @binding(2) var e:texture_2d<f32>;fn b(f:vec2f)->vec4f{return textureSample(e,d,f);}fn c(a:vec4f,g:f32)->vec4f{return vec4f(a.rgb*g,a.a);}@fragment fn fragmentMain(@location(0) h:vec2f)->@location(0) vec4f{let i=b(h);let j=c(i,1.2);return j;}",
        try full(arena.allocator(), "@group(0) @binding(1) var texSampler: sampler;\n@group(0) @binding(2) var tex: texture_2d<f32>;\n\nfn sampleTexture(uv: vec2f) -> vec4f {\n    return textureSample(tex, texSampler, uv);\n}\n\nfn adjustColor(color: vec4f, brightness: f32) -> vec4f {\n    return vec4f(color.rgb * brightness, color.a);\n}\n\n@fragment\nfn fragmentMain(@location(0) texcoord: vec2f) -> @location(0) vec4f {\n    let baseColor = sampleTexture(texcoord);\n    let adjustedColor = adjustColor(baseColor, 1.2);\n    return adjustedColor;\n}\n"),
    );
}

// =========================================================================
// snapshots_external_bindings.txt (full minification)
// =========================================================================

test "SingleUniformBinding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings(
        "@group(0) @binding(0) var<uniform> uniforms:f32;fn a()->f32{return uniforms*2.;}",
        try full(arena.allocator(), "@group(0) @binding(0) var<uniform> uniforms: f32;\n\nfn useUniform() -> f32 {\n    return uniforms * 2.0;\n}\n"),
    );
}

test "StorageBinding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings(
        "@group(0) @binding(0) var<storage,read_write> data:array<f32>;fn b(a:u32)->f32{return data[a];}",
        try full(arena.allocator(), "@group(0) @binding(0) var<storage, read_write> data: array<f32>;\n\nfn readData(idx: u32) -> f32 {\n    return data[idx];\n}\n"),
    );
}

// =========================================================================
// snapshots_mangle_external.txt (mangle external bindings)
// =========================================================================

test "MangledUniform" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings(
        "@group(0) @binding(0) var<uniform> a:f32;fn b()->f32{return a*2.;}",
        try mangleExt(arena.allocator(), "@group(0) @binding(0) var<uniform> uniforms: f32;\n\nfn useUniform() -> f32 {\n    return uniforms * 2.0;\n}\n"),
    );
}

test "MangledStorage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings(
        "@group(0) @binding(0) var<storage,read_write> a:array<f32>;fn c(b:u32)->f32{return a[b];}",
        try mangleExt(arena.allocator(), "@group(0) @binding(0) var<storage, read_write> data: array<f32>;\n\nfn readData(idx: u32) -> f32 {\n    return data[idx];\n}\n"),
    );
}

test "MangledVsAliased" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings(
        "@group(0) @binding(0) var<uniform> a:f32;fn b()->f32{return a;}fn c()->f32{return a;}fn d()->f32{return a;}",
        try mangleExt(arena.allocator(), "@group(0) @binding(0) var<uniform> uniforms: f32;\n\nfn a() -> f32 { return uniforms; }\nfn b() -> f32 { return uniforms; }\nfn c() -> f32 { return uniforms; }\n"),
    );
}

// =========================================================================
// Remaining external bindings snapshot tests
// =========================================================================

test "MultipleUniformBindings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings(
        "@group(0) @binding(0) var<uniform> modelMatrix:mat4x4f;@group(0) @binding(1) var<uniform> viewMatrix:mat4x4f;fn b(a:vec4f)->vec4f{return viewMatrix*modelMatrix*a;}",
        try full(arena.allocator(), "@group(0) @binding(0) var<uniform> modelMatrix: mat4x4f;\n@group(0) @binding(1) var<uniform> viewMatrix: mat4x4f;\n\nfn transform(pos: vec4f) -> vec4f {\n    return viewMatrix * modelMatrix * pos;\n}\n"),
    );
}

test "MixedUniformStorage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings(
        "@group(0) @binding(0) var<uniform> params:vec4f;@group(0) @binding(1) var<storage> buffer:array<f32>;fn b(a:u32)->f32{return buffer[a]*params.x;}",
        try full(arena.allocator(), "@group(0) @binding(0) var<uniform> params: vec4f;\n@group(0) @binding(1) var<storage> buffer: array<f32>;\n\nfn process(idx: u32) -> f32 {\n    return buffer[idx] * params.x;\n}\n"),
    );
}

test "UniformWithTextures" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings(
        "@group(0) @binding(0) var<uniform> scale:f32;@group(0) @binding(1) var a:texture_2d<f32>;@group(0) @binding(2) var b:sampler;@fragment fn main(@location(0) c:vec2f)->@location(0) vec4f{return textureSample(a,b,c)*scale;}",
        try full(arena.allocator(), "@group(0) @binding(0) var<uniform> scale: f32;\n@group(0) @binding(1) var tex: texture_2d<f32>;\n@group(0) @binding(2) var samp: sampler;\n\n@fragment\nfn main(@location(0) uv: vec2f) -> @location(0) vec4f {\n    return textureSample(tex, samp, uv) * scale;\n}\n"),
    );
}

test "UniformMultipleUses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings(
        "@group(0) @binding(0) var<uniform> multiplier:f32;fn g(a:f32,b:f32,c:f32)->f32{let d=a*multiplier;let e=b*multiplier;let f=c*multiplier;return d+e+f;}",
        try full(arena.allocator(), "@group(0) @binding(0) var<uniform> multiplier: f32;\n\nfn calculate(a: f32, b: f32, c: f32) -> f32 {\n    let x = a * multiplier;\n    let y = b * multiplier;\n    let z = c * multiplier;\n    return x + y + z;\n}\n"),
    );
}

test "StructUniform" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings(
        "struct b{time:f32,resolution:vec2f}@group(0) @binding(0) var<uniform> u:b;fn c()->f32{return u.resolution.x/u.resolution.y;}fn d(a:vec2f)->vec2f{return a+vec2f(sin(u.time),cos(u.time));}",
        try full(arena.allocator(), "struct Uniforms {\n    time: f32,\n    resolution: vec2f,\n}\n\n@group(0) @binding(0) var<uniform> u: Uniforms;\n\nfn getAspect() -> f32 {\n    return u.resolution.x / u.resolution.y;\n}\n\nfn animate(pos: vec2f) -> vec2f {\n    return pos + vec2f(sin(u.time), cos(u.time));\n}\n"),
    );
}

test "UnusedUniform" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings(
        "@group(0) @binding(0) var<uniform> unused:f32;fn a()->f32{return 1.;}",
        try full(arena.allocator(), "@group(0) @binding(0) var<uniform> unused: f32;\n\nfn constant() -> f32 {\n    return 1.0;\n}\n"),
    );
}

test "LongBindingName" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings(
        "@group(0) @binding(0) var<uniform> veryLongUniformBindingName:f32;fn a()->f32{return veryLongUniformBindingName+veryLongUniformBindingName;}",
        try full(arena.allocator(), "@group(0) @binding(0) var<uniform> veryLongUniformBindingName: f32;\n\nfn getValue() -> f32 {\n    return veryLongUniformBindingName + veryLongUniformBindingName;\n}\n"),
    );
}

test "MangledMultipleUniforms" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings(
        "@group(0) @binding(0) var<uniform> a:mat4x4f;@group(0) @binding(1) var<uniform> b:mat4x4f;fn d(c:vec4f)->vec4f{return b*a*c;}",
        try mangleExt(arena.allocator(), "@group(0) @binding(0) var<uniform> modelMatrix: mat4x4f;\n@group(0) @binding(1) var<uniform> viewMatrix: mat4x4f;\n\nfn transform(pos: vec4f) -> vec4f {\n    return viewMatrix * modelMatrix * pos;\n}\n"),
    );
}

// =========================================================================
// For-loop tests
// =========================================================================

test "ForLoopBasic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings(
        "fn f(){for(var i=0;i<10;i++){}}",
        try ws(arena.allocator(), "fn f() {\n    for (var i = 0; i < 10; i++) {\n    }\n}\n"),
    );
}

test "ForLoopWithBody" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings(
        "fn sum()->i32{var s=0;for(var i=0;i<10;i++){s+=i;}return s;}",
        try ws(arena.allocator(), "fn sum() -> i32 {\n    var s = 0;\n    for (var i = 0; i < 10; i++) {\n        s += i;\n    }\n    return s;\n}\n"),
    );
}

test "ForLoopLetInit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings(
        "fn f(){for(let i=0;i<10;i++){}}",
        try ws(arena.allocator(), "fn f() {\n    for (let i = 0; i < 10; i++) {\n    }\n}\n"),
    );
}

test "ForLoopAssignUpdate" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings(
        "fn f(){var i=0;for(;i<10;i+=2){}}",
        try ws(arena.allocator(), "fn f() {\n    var i = 0;\n    for (; i < 10; i += 2) {\n    }\n}\n"),
    );
}

test "ForLoopNoInit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings(
        "fn f(){var i=0;for(;i<10;i++){}}",
        try ws(arena.allocator(), "fn f() {\n    var i = 0;\n    for (; i < 10; i++) {\n    }\n}\n"),
    );
}

test "ForLoopRenamed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings(
        "fn b(){for(var a=0;a<10;a++){}}",
        try full(arena.allocator(), "fn loopFunc() {\n    for (var index = 0; index < 10; index++) {\n    }\n}\n"),
    );
}

// =========================================================================
// DCE tests (from dce_test.go)
// =========================================================================

fn dce(allocator: std.mem.Allocator, input: [:0]const u8) ![]const u8 {
    const r = try wgslender.minifyWithOptions(allocator, input, .{
        .minify_whitespace = true,
        .minify_identifiers = false,
        .minify_syntax = false,
        .tree_shaking = true,
    });
    return r.code;
}

fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    var count: usize = 0;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) {
        if (std.mem.eql(u8, haystack[i..][0..needle.len], needle)) {
            count += 1;
            i += needle.len;
        } else {
            i += 1;
        }
    }
    return count;
}

test "DCE: unused function removed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try dce(arena.allocator(), "fn unused() {}\n@fragment fn main() -> @location(0) vec4f {\n    return vec4f(1.0);\n}\n");
    // "unused" should not appear
    try std.testing.expect(std.mem.indexOf(u8, result, "unused") == null);
    // "main" should appear
    try std.testing.expect(std.mem.indexOf(u8, result, "main") != null);
}

test "DCE: used function kept" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try dce(arena.allocator(), "fn helper() -> f32 { return 1.0; }\n@fragment fn main() -> @location(0) vec4f {\n    return vec4f(helper());\n}\n");
    try std.testing.expect(countOccurrences(result, "fn ") >= 2);
}

test "DCE: unused const removed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try dce(arena.allocator(), "const UNUSED: f32 = 3.14;\nconst USED: f32 = 2.71;\n@fragment fn main() -> @location(0) vec4f {\n    return vec4f(USED);\n}\n");
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(result, "const "));
}

test "DCE: unused struct removed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try dce(arena.allocator(), "struct Unused { x: f32 }\nstruct Used { y: f32 }\n@fragment fn main() -> @location(0) vec4f {\n    var u: Used;\n    u.y = 1.0;\n    return vec4f(u.y);\n}\n");
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(result, "struct "));
}

test "DCE: transitive dependency" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try dce(arena.allocator(), "const A: f32 = 1.0;\nconst B: f32 = A + 1.0;\nconst C: f32 = B + 1.0;\nconst UNUSED: f32 = 999.0;\n@fragment fn main() -> @location(0) vec4f {\n    return vec4f(C);\n}\n");
    try std.testing.expectEqual(@as(usize, 3), countOccurrences(result, "const "));
}

test "DCE: function call chain" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try dce(arena.allocator(), "fn a() -> f32 { return 1.0; }\nfn b() -> f32 { return a() + 1.0; }\nfn c() -> f32 { return b() + 1.0; }\nfn unused() -> f32 { return 0.0; }\n@fragment fn main() -> @location(0) vec4f {\n    return vec4f(c());\n}\n");
    try std.testing.expectEqual(@as(usize, 4), countOccurrences(result, "fn "));
}

test "DCE: multiple entry points" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try dce(arena.allocator(), "fn used_by_both() -> f32 { return 1.0; }\nfn vertex_only() -> f32 { return 2.0; }\nfn fragment_only() -> f32 { return 3.0; }\nfn unused() -> f32 { return 4.0; }\n\n@vertex fn vs_main(@builtin(vertex_index) idx: u32) -> @builtin(position) vec4f {\n    return vec4f(used_by_both() + vertex_only());\n}\n\n@fragment fn fs_main() -> @location(0) vec4f {\n    return vec4f(used_by_both() + fragment_only());\n}\n");
    try std.testing.expectEqual(@as(usize, 5), countOccurrences(result, "fn "));
}

test "DCE: no entry point keeps everything" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try dce(arena.allocator(), "fn a() -> f32 { return 1.0; }\nfn b() -> f32 { return 2.0; }\n");
    try std.testing.expectEqual(@as(usize, 2), countOccurrences(result, "fn "));
}

test "DCE: unused alias removed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try dce(arena.allocator(), "alias UsedFloat = f32;\nalias UnusedInt = i32;\n\n@fragment fn main() -> @location(0) vec4f {\n    var x: UsedFloat = 1.0;\n    return vec4f(x);\n}\n");
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(result, "alias "));
}

test "DCE: unused override removed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try dce(arena.allocator(), "override USED: f32 = 1.0;\noverride UNUSED: f32 = 2.0;\n\n@fragment fn main() -> @location(0) vec4f {\n    return vec4f(USED);\n}\n");
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(result, "override "));
}

test "DCE: directives kept" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try dce(arena.allocator(), "enable f16;\n\nfn unused() {}\n\n@fragment fn main() -> @location(0) vec4f {\n    return vec4f(1.0);\n}\n");
    try std.testing.expect(std.mem.indexOf(u8, result, "enable") != null);
}

test "DCE: const_assert kept" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try dce(arena.allocator(), "const_assert 1 == 1;\n\nfn unused() {}\n\n@fragment fn main() -> @location(0) vec4f {\n    return vec4f(1.0);\n}\n");
    try std.testing.expect(std.mem.indexOf(u8, result, "const_assert") != null);
}

test "DCE disabled keeps everything" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try wgslender.minifyWithOptions(arena.allocator(), "fn unused() {}\n@fragment fn main() -> @location(0) vec4f {\n    return vec4f(1.0);\n}\n", .{
        .minify_whitespace = true,
        .minify_identifiers = false,
        .minify_syntax = false,
        .tree_shaking = false,
    });
    try std.testing.expectEqual(@as(usize, 2), countOccurrences(r.code, "fn "));
}

test "DCE: struct used in return type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try dce(arena.allocator(),
        \\struct VertexOutput {
        \\    @builtin(position) pos: vec4f,
        \\}
        \\
        \\struct Unused {
        \\    x: f32,
        \\}
        \\
        \\@vertex fn main() -> VertexOutput {
        \\    var out: VertexOutput;
        \\    out.pos = vec4f(0.0);
        \\    return out;
        \\}
    );
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(result, "struct "));
}

test "DCE: compute shader with unused helper" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try dce(arena.allocator(),
        \\struct Particle { pos: vec3f, vel: vec3f }
        \\
        \\fn unused_helper() {}
        \\
        \\fn apply_force(p: ptr<function, Particle>) {
        \\    (*p).vel += vec3f(0.0, -9.8, 0.0);
        \\}
        \\
        \\@group(0) @binding(0) var<storage, read_write> particles: array<Particle>;
        \\
        \\@compute @workgroup_size(64)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    var p = particles[id.x];
        \\    apply_force(&p);
        \\    particles[id.x] = p;
        \\}
    );
    try std.testing.expectEqual(@as(usize, 2), countOccurrences(result, "fn "));
}

test "DCE: array type with const size" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try dce(arena.allocator(),
        \\const SIZE: u32 = 10u;
        \\const UNUSED: u32 = 20u;
        \\
        \\@fragment fn main() -> @location(0) vec4f {
        \\    var arr: array<f32, SIZE>;
        \\    arr[0] = 1.0;
        \\    return vec4f(arr[0]);
        \\}
    );
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(result, "const "));
}

test "DCE: external bindings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try dce(arena.allocator(),
        \\struct Uniforms { time: f32 }
        \\@group(0) @binding(0) var<uniform> uniforms: Uniforms;
        \\@group(0) @binding(1) var<uniform> unused_uniforms: Uniforms;
        \\
        \\@fragment fn main() -> @location(0) vec4f {
        \\    return vec4f(uniforms.time);
        \\}
    );
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(result, "var<uniform>"));
}
