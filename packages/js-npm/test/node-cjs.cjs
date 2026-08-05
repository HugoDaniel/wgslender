#!/usr/bin/env node
'use strict';

const { runSuite } = require('./_suite.cjs');
const wgslender = require('../lib/main.js');

runSuite(wgslender, { variantName: 'node-cjs (lib/main.js)' })
  .then(({ failed }) => process.exit(failed > 0 ? 1 : 0))
  .catch((err) => {
    console.error('Fatal error:', err);
    process.exit(1);
  });
