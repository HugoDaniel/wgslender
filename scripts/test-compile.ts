#!/usr/bin/env -S deno run --unstable-webgpu --allow-read --allow-run

/**
 * Test WGSL shader compilation using WebGPU.
 *
 * Usage:
 *   deno run --unstable-webgpu --allow-read scripts/test-compile.ts shader.wgsl
 *   deno run --unstable-webgpu --allow-read --allow-run scripts/test-compile.ts --minify shader.wgsl
 *   deno run --unstable-webgpu --allow-read --allow-run scripts/test-compile.ts --minify --config configs/compute.toys.json shader.wgsl
 *
 * Options:
 *   --minify           Minify the shader before compiling
 *   --config <file>    Config file to pass to wgslender (requires --minify)
 *   --compare          Compare original and minified (implies --minify)
 *   --verbose          Show shader source on error
 */

interface CompileResult {
  file: string;
  variant: "original" | "minified";
  success: boolean;
  error?: string;
  size?: number;
}

async function initWebGPU(): Promise<GPUDevice> {
  const adapter = await navigator.gpu?.requestAdapter();
  if (!adapter) {
    console.error("WebGPU not supported - no adapter found");
    Deno.exit(1);
  }

  const device = await adapter.requestDevice();
  if (!device) {
    console.error("WebGPU not supported - could not get device");
    Deno.exit(1);
  }

  return device;
}

async function compileShader(
  device: GPUDevice,
  code: string,
  file: string,
  variant: "original" | "minified"
): Promise<CompileResult> {
  // Capture errors from the device
  let capturedError: string | undefined;

  const errorHandler = (event: GPUUncapturedErrorEvent) => {
    capturedError = event.error.message;
  };

  device.addEventListener("uncapturederror", errorHandler);

  try {
    // Create shader module - this validates the WGSL
    const module = device.createShaderModule({ code });

    // Try to get compilation info if available (some implementations have it)
    if ("getCompilationInfo" in module) {
      try {
        const info = await (module as any).getCompilationInfo();
        for (const msg of info.messages) {
          if (msg.type === "error") {
            capturedError = msg.message;
            break;
          }
        }
      } catch {
        // getCompilationInfo not fully supported, continue
      }
    }

    // Push an empty command to flush any pending errors
    device.queue.submit([]);

    // Small delay to allow error events to fire
    await new Promise((resolve) => setTimeout(resolve, 10));

    return {
      file,
      variant,
      success: !capturedError,
      error: capturedError,
      size: code.length,
    };
  } finally {
    device.removeEventListener("uncapturederror", errorHandler);
  }
}

async function minifyShader(
  source: string,
  configFile?: string
): Promise<string> {
  const args = ["./build/wgslender"];
  if (configFile) {
    args.push("--config", configFile);
  }

  const cmd = new Deno.Command(args[0], {
    args: args.slice(1),
    stdin: "piped",
    stdout: "piped",
    stderr: "piped",
  });

  const process = cmd.spawn();

  const writer = process.stdin.getWriter();
  await writer.write(new TextEncoder().encode(source));
  await writer.close();

  const { code, stdout, stderr } = await process.output();

  if (code !== 0) {
    const errorText = new TextDecoder().decode(stderr);
    throw new Error(`Minification failed: ${errorText}`);
  }

  return new TextDecoder().decode(stdout);
}

function printResult(result: CompileResult, verbose: boolean, source?: string) {
  const icon = result.success ? "\x1b[32m✓\x1b[0m" : "\x1b[31m✗\x1b[0m";
  const sizeInfo = result.size ? ` (${result.size} bytes)` : "";
  const variantInfo = result.variant === "minified" ? " [minified]" : "";

  console.log(`${icon} ${result.file}${variantInfo}${sizeInfo}`);

  if (result.error) {
    console.log(`  \x1b[31merror:\x1b[0m ${result.error}`);
  }

  if (!result.success && verbose && source) {
    console.log("\n  Source:");
    const lines = source.split("\n");
    const maxLines = Math.min(lines.length, 50); // Limit output
    for (let i = 0; i < maxLines; i++) {
      console.log(`  ${String(i + 1).padStart(4)}: ${lines[i]}`);
    }
    if (lines.length > maxLines) {
      console.log(`  ... (${lines.length - maxLines} more lines)`);
    }
    console.log();
  }
}

async function main() {
  const args = Deno.args;
  const files: string[] = [];
  let minify = false;
  let compare = false;
  let verbose = false;
  let configFile: string | undefined;

  // Parse arguments
  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    if (arg === "--minify") {
      minify = true;
    } else if (arg === "--compare") {
      compare = true;
      minify = true;
    } else if (arg === "--verbose") {
      verbose = true;
    } else if (arg === "--config") {
      configFile = args[++i];
    } else if (arg.startsWith("-")) {
      console.error(`Unknown option: ${arg}`);
      Deno.exit(1);
    } else {
      files.push(arg);
    }
  }

  if (files.length === 0) {
    console.log(`Usage: test-compile.ts [options] <shader.wgsl> [...]

Options:
  --minify           Minify the shader before compiling
  --config <file>    Config file to pass to wgslender (requires --minify)
  --compare          Compare original and minified compilation
  --verbose          Show shader source on error

Examples:
  test-compile.ts shader.wgsl
  test-compile.ts --minify shader.wgsl
  test-compile.ts --compare --config configs/compute.toys.json testdata/*.wgsl`);
    Deno.exit(0);
  }

  console.log("Initializing WebGPU...");
  const device = await initWebGPU();
  console.log("WebGPU initialized\n");

  let totalPassed = 0;
  let totalFailed = 0;

  for (const file of files) {
    try {
      const source = await Deno.readTextFile(file);

      // Test original if comparing
      if (compare) {
        const result = await compileShader(device, source, file, "original");
        printResult(result, verbose, source);
        if (result.success) totalPassed++;
        else totalFailed++;
      }

      // Test minified (or original if not minifying)
      if (minify) {
        try {
          const minified = await minifyShader(source, configFile);
          const result = await compileShader(device, minified, file, "minified");
          printResult(result, verbose, minified);
          if (result.success) totalPassed++;
          else totalFailed++;

          // Show size reduction in compare mode
          if (compare && result.success) {
            const originalSize = source.length;
            const minifiedSize = minified.length;
            const reduction = ((1 - minifiedSize / originalSize) * 100).toFixed(1);
            console.log(
              `  \x1b[36mSize: ${originalSize} -> ${minifiedSize} bytes (${reduction}% reduction)\x1b[0m`
            );
          }
        } catch (e) {
          console.log(`\x1b[31m✗\x1b[0m ${file} [minified]`);
          console.log(`  \x1b[31merror:\x1b[0m ${(e as Error).message}`);
          totalFailed++;
        }
      } else {
        const result = await compileShader(device, source, file, "original");
        printResult(result, verbose, source);
        if (result.success) totalPassed++;
        else totalFailed++;
      }
    } catch (e) {
      console.log(`\x1b[31m✗\x1b[0m ${file}`);
      console.log(`  \x1b[31merror:\x1b[0m ${(e as Error).message}`);
      totalFailed++;
    }
  }

  // Summary
  console.log();
  if (totalFailed === 0) {
    console.log(`\x1b[32mAll ${totalPassed} shader(s) compiled successfully\x1b[0m`);
  } else {
    console.log(
      `\x1b[31m${totalFailed} failed\x1b[0m, \x1b[32m${totalPassed} passed\x1b[0m`
    );
    Deno.exit(1);
  }
}

main();
