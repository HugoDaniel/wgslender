// @test: errors/declarations/const-without-init
// @expect-error E0001 "expected ="
// Const declarations require an initializer (parse error)

const x : i32;  // Error: const requires initializer
