// @ts-check
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';

// https://astro.build/config
export default defineConfig({
	integrations: [
		starlight({
			title: 'WGSLender',
			social: [{ icon: 'github', label: 'GitHub', href: 'https://github.com/HugoDaniel/wgslender' }],
			sidebar: [
				{ label: 'Playground', slug: 'playground' },
			],
		}),
	],
});
