#!/usr/bin/env node
/**
 * Benchmark comparing wgslender WASM vs shaderkit (both pure JS)
 * This gives a fairer speed comparison without subprocess overhead
 */

const fs = require('fs');
const path = require('path');

// Set up globals required by wasm_exec.js
globalThis.require = require;
globalThis.fs = require('fs');
globalThis.path = require('path');
globalThis.TextEncoder = require('util').TextEncoder;
globalThis.TextDecoder = require('util').TextDecoder;
globalThis.performance ??= require('perf_hooks').performance;
globalThis.crypto ??= require('crypto');

// Load wasm_exec.js
require('../packages/js-npm/wasm_exec.js');

const { minify: shaderkitMinify } = require('shaderkit');

// Configuration
const ITERATIONS = 100;
const TESTDATA_DIR = process.env.TESTDATA_DIR || 'tests/testdata';

// Colors
const GREEN = '\x1b[32m';
const BLUE = '\x1b[34m';
const NC = '\x1b[0m';

function findWgslFiles(dir) {
    const files = [];
    if (!fs.existsSync(dir)) return files;
    for (const entry of fs.readdirSync(dir)) {
        const fullPath = path.join(dir, entry);
        if (fs.statSync(fullPath).isFile() && entry.endsWith('.wgsl')) {
            files.push(fullPath);
        }
    }
    return files.sort();
}

function measureTime(fn, iterations) {
    // Warm up
    for (let i = 0; i < 3; i++) fn();

    const start = performance.now();
    for (let i = 0; i < iterations; i++) {
        fn();
    }
    const end = performance.now();
    return (end - start) / iterations;
}

async function loadWgslenderWasm() {
    const go = new Go();
    const wasmPath = path.join(__dirname, '..', 'npm', 'wgslender', 'wgslender.wasm');
    const wasmBuffer = fs.readFileSync(wasmPath);
    const result = await WebAssembly.instantiate(wasmBuffer, go.importObject);
    go.run(result.instance);

    // Wait for initialization
    for (let i = 0; i < 50; i++) {
        if (globalThis.__wgslender) return globalThis.__wgslender;
        await new Promise(r => setTimeout(r, 10));
    }
    throw new Error('WASM init failed');
}

async function main() {
    console.log(`\n${BLUE}=== WASM Speed Benchmark: wgslender vs shaderkit ===${NC}`);
    console.log(`iterations per file: ${ITERATIONS}\n`);

    // Load wgslender WASM
    console.log('Loading wgslender WASM...');
    const wgslender = await loadWgslenderWasm();
    console.log(`wgslender version: ${wgslender.version}`);

    const shaderkitPkg = JSON.parse(fs.readFileSync(path.join(__dirname, '..', 'node_modules', 'shaderkit', 'package.json'), 'utf8'));
    console.log(`shaderkit version: ${shaderkitPkg.version}\n`);

    // Find test files
    let files = findWgslFiles(TESTDATA_DIR);
    files = [...files, ...findWgslFiles(path.join(TESTDATA_DIR, 'compute.toys'))];

    console.log('| File                         | Original | wgslender | shaderkit | wgslender | shaderkit |  wgslender | shaderkit |');
    console.log('|                              |    bytes |   bytes |     bytes |       % |         % |     time |      time |');
    console.log('|------------------------------|----------|---------|-----------|---------|-----------|----------|-----------|');

    let totalOrig = 0, totalWgslender = 0, totalShaderkit = 0;
    let totalWgslenderTime = 0, totalShaderkitTime = 0;

    for (const file of files) {
        const filename = path.basename(file);
        const code = fs.readFileSync(file, 'utf8');
        const origSize = Buffer.byteLength(code, 'utf8');

        // Benchmark wgslender WASM (with tree-shaking enabled by default)
        let wgslenderSize, wgslenderTime;
        try {
            const wgslenderResult = wgslender.minify(code);  // defaults: all optimizations + tree-shaking
            wgslenderSize = Buffer.byteLength(wgslenderResult.code, 'utf8');
            wgslenderTime = measureTime(() => {
                wgslender.minify(code);
            }, ITERATIONS);
        } catch (e) {
            wgslenderSize = null;
            wgslenderTime = null;
        }

        // Benchmark shaderkit
        let shaderkitSize, shaderkitTime;
        try {
            const shaderkitResult = shaderkitMinify(code, { mangle: true });
            shaderkitSize = Buffer.byteLength(shaderkitResult, 'utf8');
            shaderkitTime = measureTime(() => {
                shaderkitMinify(code, { mangle: true });
            }, ITERATIONS);
        } catch (e) {
            shaderkitSize = null;
            shaderkitTime = null;
        }

        totalOrig += origSize;
        if (wgslenderSize) { totalWgslender += wgslenderSize; totalWgslenderTime += wgslenderTime; }
        if (shaderkitSize) { totalShaderkit += shaderkitSize; totalShaderkitTime += shaderkitTime; }

        const fmtSize = (s) => s === null ? 'ERR' : s.toString();
        const fmtPct = (o, m) => m === null ? '-' : Math.round(100 - (m * 100 / o)) + '%';
        const fmtTime = (t) => t === null ? '-' : t.toFixed(3) + 'ms';

        console.log(`| ${filename.padEnd(28)} | ${origSize.toString().padStart(8)} | ${fmtSize(wgslenderSize).padStart(7)} | ${fmtSize(shaderkitSize).padStart(9)} | ${fmtPct(origSize, wgslenderSize).padStart(7)} | ${fmtPct(origSize, shaderkitSize).padStart(9)} | ${fmtTime(wgslenderTime).padStart(8)} | ${fmtTime(shaderkitTime).padStart(9)} |`);
    }

    console.log(`\n${BLUE}=== Summary ===${NC}\n`);
    console.log(`${GREEN}wgslender (WASM):${NC}`);
    console.log(`  Total: ${totalOrig} -> ${totalWgslender} bytes (${(100 - totalWgslender * 100 / totalOrig).toFixed(1)}% reduction)`);
    console.log(`  Avg time per file: ${(totalWgslenderTime / files.length).toFixed(3)}ms`);

    console.log(`${GREEN}shaderkit (JS):${NC}`);
    console.log(`  Total: ${totalOrig} -> ${totalShaderkit} bytes (${(100 - totalShaderkit * 100 / totalOrig).toFixed(1)}% reduction)`);
    console.log(`  Avg time per file: ${(totalShaderkitTime / files.length).toFixed(3)}ms`);

    console.log(`\n${GREEN}Comparison:${NC}`);
    console.log(`  Size: wgslender produces ${((1 - totalWgslender / totalShaderkit) * 100).toFixed(1)}% smaller output`);
    console.log(`  Speed: ${totalWgslenderTime < totalShaderkitTime ? 'wgslender' : 'shaderkit'} is ${Math.abs(totalShaderkitTime / totalWgslenderTime).toFixed(1)}x ${totalWgslenderTime < totalShaderkitTime ? 'faster' : 'slower'}`);
}

main().catch(console.error);
