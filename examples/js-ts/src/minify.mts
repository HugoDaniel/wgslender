import { initialize, minify, validate, getVersion } from 'wgslender';

await initialize();
console.log(minify('fn main() {}').code);
console.log(validate('fn main() {}', { strict: true }).valid);
console.log(getVersion());
