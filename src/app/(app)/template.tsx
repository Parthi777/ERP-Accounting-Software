/**
 * Page transition — spec §8.
 *
 * A `template` rather than a `layout`: Next re-mounts a template on every
 * navigation, so the animation replays each time. A layout persists, which is
 * exactly why the sidebar and header live there — they should not flicker when
 * the page beneath them changes.
 *
 * No JavaScript and no animation library. The entrance is a CSS keyframe that
 * runs once on mount, which means navigation stays as fast as it was and there
 * is nothing to hydrate.
 *
 * Deliberately shorter and smaller than the panel entrance (180ms, 4px, against
 * 260ms and 6px). A page transition is felt on every single click, and anything
 * longer starts to feel like latency rather than polish — particularly on the
 * dense list screens where someone is moving quickly between records.
 */
export default function Template({ children }: { children: React.ReactNode }) {
  return <div className="animate-page">{children}</div>;
}
