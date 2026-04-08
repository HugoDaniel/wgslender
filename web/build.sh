#!/bin/bash
set -e

# Clean and create dist directory
rm -rf dist
mkdir -p dist

# Copy main files
cp src/styles.css src/main.js dist/

# Copy component JS with fixed imports (flatten the path)
sed 's|from "../../main.js"|from "./main.js"|g' src/components/wgslender-minifier/wgslender-minifier.js > dist/wgslender-minifier.js

# Copy WASM files
cp -r public/* dist/

# Copy boreDOM
cp node_modules/boredom/dist/boreDOM.full.js dist/boreDOM.js

# Read component template and CSS
COMPONENT_TEMPLATE=$(cat src/components/wgslender-minifier/wgslender-minifier.html)
COMPONENT_CSS=$(cat src/components/wgslender-minifier/wgslender-minifier.css)

# Create index.html with everything inlined/linked properly
cat > dist/index.html << HTMLEOF
<!DOCTYPE html>
<html lang="en">
<head>
  <script type="importmap">{ "imports": { "boredom": "./boreDOM.js" } }</script>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>wgslender - WGSL Minifier</title>
  <link rel="stylesheet" href="./styles.css">
  <style>
${COMPONENT_CSS}
  </style>
  <script src="./main.js" type="module"></script>
</head>
<body>
  <header>
    <h1>wgslender</h1>
    <p>WGSL Minifier - Compress your WebGPU shaders</p>
  </header>
  <main>
    <wgslender-minifier></wgslender-minifier>

    <section class="cli-section">
      <h2>Also available on the command line</h2>
      <p>Minify WGSL shaders directly from your terminal with a single command:</p>
      <pre><code>npx wgslender shader.wgsl -o shader.min.wgsl</code></pre>
    </section>
  </main>
  <footer>
    <a href="https://github.com/HugoDaniel/wgslender" target="_blank" rel="noopener">Source</a>
    <span class="separator"></span>
    <p>Made with&nbsp;<a href="https://hugodaniel.com/pages/boreDOM/">boreDOM</a> <span class="sleepy">🥱</span></p>
  </footer>

  ${COMPONENT_TEMPLATE}
  <script src="./wgslender-minifier.js" type="module"></script>
</body>
</html>
HTMLEOF

# Ensure all files are readable
chmod -R a+r dist/

echo "Build complete: dist/"
