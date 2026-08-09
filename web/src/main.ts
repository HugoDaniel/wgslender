/**
 * The playground's entry point: markup lives in `index.html`, the models in
 * `scripts/playground/panels.ts`, and the DOM rendering in
 * `scripts/playground/render.ts`, where Node can test the first and a
 * browser can check the second.
 */
import './style.css';

import { EditorState } from '@codemirror/state';
import { lintGutter } from '@codemirror/lint';
import { EditorView, lineNumbers } from '@codemirror/view';
import { basicSetup } from 'codemirror';

import { sampleShader, sampleUri } from './scripts/playground/sample-shader';
import { playgroundTheme } from './scripts/playground/editor-theme';
import { createSession } from './scripts/playground/lsp-session';
import { initPlayground } from './scripts/playground/wasm';
import { wgsl } from './scripts/playground/wgsl-language';
import {
	buildMinifyModel,
	buildReflectModel,
	defaultMinifyOptions,
	formatDiagnostics,
	minifyOptions,
	type PanelMinifyOptions,
	type PublishDiagnosticsPayload,
} from './scripts/playground/panels';
import { gzipSize, renderDiagnostics, renderReflect, renderStats } from './scripts/playground/render';
import { minifyInsights, setMinifyHints } from './scripts/playground/insights';
import { initTabs } from './tabs';

/** How long typing has to settle before the expensive half runs. */
const DEBOUNCE_MS = 300;

const host = document.querySelector<HTMLElement>('[data-editor]');
const pillsHost = document.querySelector<HTMLElement>('[data-minify-options]');
const statsHost = document.querySelector<HTMLElement>('[data-minify-stats]');
const errorsHost = document.querySelector<HTMLElement>('[data-minify-errors]');
const outputHost = document.querySelector<HTMLElement>('[data-minify-output]');
const reflectHost = document.querySelector<HTMLElement>('[data-reflect]');
const diagnosticsHost = document.querySelector<HTMLElement>('[data-diagnostics]');
const copyButton = document.querySelector<HTMLButtonElement>('[data-copy]');
const insightsToggle = document.querySelector<HTMLInputElement>('[data-insights]');
const expandButton = document.querySelector<HTMLButtonElement>('[data-expand]');
const playground = document.querySelector<HTMLElement>('.playground');

/** Draw the option pills once, from the same list `readOptions` reads back. */
function renderMinifyOptions() {
	if (!pillsHost) return;
	pillsHost.replaceChildren(
		...minifyOptions.map((option) => {
			const label = document.createElement('label');
			label.className = 'pill';
			label.title = option.help;

			const input = document.createElement('input');
			input.type = 'checkbox';
			input.dataset.option = option.key;
			input.checked = option.default;

			label.append(input, document.createTextNode(option.label));
			return label;
		}),
	);
}

/** Read the pills back out of the DOM, so the checkboxes are the state. */
function readOptions(): PanelMinifyOptions {
	const options = defaultMinifyOptions();
	for (const box of document.querySelectorAll<HTMLInputElement>('[data-option]')) {
		const key = box.dataset.option as keyof PanelMinifyOptions;
		if (key in options) options[key] = box.checked;
	}
	return options;
}

async function boot(mount: HTMLElement) {
	// Both wasm downloads start now; only the language server is on the
	// critical path for showing an editor.
	const { lsp, minifier } = initPlayground();
	await lsp;

	const session = await createSession(sampleUri);
	mount.replaceChildren();

	let scheduled: ReturnType<typeof setTimeout> | undefined;
	const view = new EditorView({
		parent: mount,
		state: EditorState.create({
			doc: sampleShader,
			extensions: [
				basicSetup,
				lintGutter(),
				wgsl(),
				playgroundTheme,
				session.extension,
				minifyInsights,
				EditorView.updateListener.of((update) => {
					if (!update.docChanged) return;
					clearTimeout(scheduled);
					scheduled = setTimeout(settled, DEBOUNCE_MS);
				}),
			],
		}),
	});

	// Independent of the minifier/session — only `view` has to exist, so this
	// is wired as soon as the editor is, rather than waiting on `boot()` to
	// finish.
	if (expandButton && playground) {
		expandButton.disabled = false;
		expandButton.addEventListener('click', () => {
			const expanded = playground.classList.toggle('expanded');
			expandButton.setAttribute('aria-pressed', String(expanded));
			expandButton.textContent = expanded ? 'Collapse' : 'Expand';
			expandButton.title = expanded
				? 'Collapse the editor back to two columns'
				: 'Expand the editor to fill the page width';
			// The grid column change resizes `view`'s DOM outside of any edit it
			// knows about, so it needs to be told to remeasure explicitly — the
			// same reason the tablist click listener below does this for
			// `minified`.
			requestAnimationFrame(() => view.requestMeasure());
		});
	}

	// Diagnostics come straight from the server, so the panel shows the
	// same codes and spec links the squiggles carry.
	session.onDiagnostics((payload) => {
		if (!diagnosticsHost) return;
		// The transport hands back the raw JSON-RPC payload untyped; this is
		// the boundary where the playground chooses to trust its shape.
		const diagnostics = formatDiagnostics(payload as PublishDiagnosticsPayload);
		renderDiagnostics(diagnosticsHost, diagnostics, (position) => {
			const line = view.state.doc.line(position.line + 1);
			const at = Math.min(line.from + position.character, line.to);
			view.dispatch({ selection: { anchor: at }, scrollIntoView: true });
			view.focus();
		});
	});

	// The minified pane is an editor too — same mode and theme, no editing.
	await minifier;
	const minified = new EditorView({
		state: EditorState.create({
			doc: '',
			extensions: [
				lineNumbers(),
				wgsl(),
				playgroundTheme,
				EditorView.lineWrapping,
				EditorState.readOnly.of(true),
				EditorView.editable.of(false),
			],
		}),
	});
	outputHost?.replaceChildren(minified.dom);
	if (copyButton) copyButton.disabled = false;

	// Only the newest run may write the stats bar: gzip is async, and a
	// fast typist can have two passes in flight at once.
	let generation = 0;

	function refreshPanels() {
		const run = ++generation;
		const source = view.state.doc.toString();
		const model = buildMinifyModel(source, readOptions());

		minified.dispatch({
			changes: { from: 0, to: minified.state.doc.length, insert: model.code },
		});

		if (errorsHost) {
			errorsHost.replaceChildren(
				...model.errors.map((message) => {
					const line = document.createElement('p');
					line.textContent = message;
					return line;
				}),
			);
			errorsHost.hidden = model.errors.length === 0;
		}

		if (statsHost) {
			renderStats(statsHost, model.stats, null);
			void gzipSize(model.code).then((bytes) => {
				if (run === generation && statsHost) renderStats(statsHost, model.stats, bytes);
			});
		}
		if (reflectHost) renderReflect(reflectHost, buildReflectModel(source));
	}

	// Inlay hints are gated on a server-side mode, so the toggle is the
	// single source of truth for whether we ask for them at all.
	let hintRun = 0;

	async function refreshHints() {
		if (!insightsToggle?.checked) return setMinifyHints(view, []);

		const run = ++hintRun;
		const doc = view.state.doc;
		const hints = await session.inlayHints({
			start: { line: 0, character: 0 },
			end: { line: doc.lines - 1, character: doc.line(doc.lines).length },
		});
		// A slow reply must not overwrite a newer one, and hints measured
		// against a document two edits ago are worse than none.
		if (run === hintRun) setMinifyHints(view, hints);
	}

	function settled() {
		refreshPanels();
		// The server publishes cheap diagnostics on every keystroke and
		// defers the minify-lint pass to us; this is our half of that.
		session.refreshInsights();
		void refreshHints();
	}

	for (const box of document.querySelectorAll<HTMLInputElement>('[data-option]')) {
		box.addEventListener('change', refreshPanels);
	}

	if (insightsToggle) {
		insightsToggle.disabled = false;
		insightsToggle.addEventListener('change', async () => {
			// `strict`, not `insights`: both modes produce the size hints, but
			// only `strict` also runs the minify lints — and those are the
			// half that pays off here. M0100 names the bindings whose
			// original names ship verbatim, which is exactly what the
			// "Mangle bindings" pill in the next pane controls. The two
			// halves of the page end up talking to each other.
			//
			// Order matters: the mode gates the hints server-side, so it has
			// to land first; `refreshInsights` then recomputes the estimator
			// and republishes diagnostics, which is what makes the lints
			// appear in the Diagnostics panel at the same moment the hints
			// appear in the editor.
			await session.setMinifyMode(insightsToggle.checked ? 'strict' : 'off');
			session.refreshInsights();
			await refreshHints();
		});
	}

	copyButton?.addEventListener('click', async () => {
		await navigator.clipboard.writeText(minified.state.doc.toString());
		copyButton.textContent = 'Copied!';
		setTimeout(() => (copyButton.textContent = 'Copy'), 1500);
	});

	// A tab panel is `hidden` until selected, so the minified editor can be
	// laid out at zero height. Re-measure whenever the tabs are used.
	document
		.querySelector('[role=tablist]')
		?.addEventListener('click', () => requestAnimationFrame(() => minified.requestMeasure()));

	settled();
}

renderMinifyOptions();
initTabs(document.querySelector('.tabs')!);

if (host) {
	// A static fallback so there is no layout jump once boot() replaces it —
	// the pane's fixed height (`style.css`) means this never resizes the page.
	const fallback = document.createElement('pre');
	fallback.className = 'fallback';
	fallback.textContent = sampleShader;
	host.replaceChildren(fallback);

	boot(host).catch((error) => {
		console.error('Language server failed to start:', error);
	});
}
