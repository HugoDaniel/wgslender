/**
 * A minimal ARIA tabs controller — click or Left/Right arrow switches which
 * `[role=tabpanel]` is visible. There is exactly one tab group on the page,
 * so this does not need to support more than one `root` at a time syncing
 * with another.
 */
export function initTabs(root: HTMLElement): void {
	const tablist = root.querySelector<HTMLElement>('[role=tablist]');
	const tabs = [...root.querySelectorAll<HTMLButtonElement>('[role=tab]')];
	if (!tablist || tabs.length === 0) return;

	const panelOf = (tab: HTMLButtonElement) =>
		document.getElementById(tab.getAttribute('aria-controls') ?? '');

	function select(tab: HTMLButtonElement, focus: boolean) {
		for (const t of tabs) {
			const active = t === tab;
			t.setAttribute('aria-selected', String(active));
			t.tabIndex = active ? 0 : -1;
			panelOf(t)?.toggleAttribute('hidden', !active);
		}
		if (focus) tab.focus();
	}

	tablist.addEventListener('click', (event) => {
		const tab = (event.target as HTMLElement).closest<HTMLButtonElement>('[role=tab]');
		if (tab) select(tab, false);
	});

	tablist.addEventListener('keydown', (event) => {
		const step = event.key === 'ArrowRight' ? 1 : event.key === 'ArrowLeft' ? -1 : 0;
		if (step === 0) return;
		const at = tabs.indexOf(document.activeElement as HTMLButtonElement);
		if (at < 0) return;
		event.preventDefault();
		select(tabs[(at + step + tabs.length) % tabs.length]!, true);
	});
}
