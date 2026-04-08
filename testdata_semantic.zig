// Generated bridge file for semantic test data.
// This file lives at the project root so @embedFile can access testdata/.

// Top-level testdata shaders
pub const example = @embedFile("testdata/example.wgsl");
pub const basic_vert = @embedFile("testdata/basic_vert.wgsl");
pub const sceneW = @embedFile("testdata/sceneW.wgsl");
pub const sceneE = @embedFile("testdata/sceneE.wgsl");
pub const sceneY = @embedFile("testdata/sceneY.wgsl");
pub const starsParticlesModule = @embedFile("testdata/starsParticlesModule.wgsl");
pub const trailing_comma_fn_params = @embedFile("testdata/trailing_comma_fn_params.wgsl");
pub const blur = @embedFile("testdata/blur.wgsl");
pub const cornell_common = @embedFile("testdata/cornell_common.wgsl");
pub const fullscreen_quad = @embedFile("testdata/fullscreen_quad.wgsl");
pub const shadow_fragment = @embedFile("testdata/shadow_fragment.wgsl");

// compute.toys shaders
pub const ct_circle_sample = @embedFile("testdata/compute.toys/circle_sample.wgsl");
pub const ct_bridge = @embedFile("testdata/compute.toys/bridge.wgsl");
pub const ct_cubes_in_space = @embedFile("testdata/compute.toys/cubes_in_space.wgsl");
pub const ct_jitter_starfield = @embedFile("testdata/compute.toys/jitter_starfield.wgsl");
pub const ct_mouse_draw = @embedFile("testdata/compute.toys/mouse_draw.wgsl");
pub const ct_prelude = @embedFile("testdata/compute.toys/prelude.wgsl");
pub const ct_spaced = @embedFile("testdata/compute.toys/spaced.wgsl");
