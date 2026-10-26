import type { Path } from '$app/types';

/**
 * What `asInternalPath` returns, typed as one pathname (the app root) because
 * `resolve()` checks its argument against each path separately and so cannot
 * take the union of every path. The runtime value is the caller's built path.
 */
export type InternalPath = Extract<Path, ''>;

/**
 * Mark a dynamically assembled string as an internal pathname, in the form
 * `resolve()` from `$app/paths` takes one.
 *
 * SvelteKit 3 reads an argument that starts with `/` as a route ID and runs it
 * through route-ID parsing, so `/leads?tag=x` would be treated as a route. A
 * pathname goes in without the leading slash, which this strips.
 *
 * The cast is this function's job: a built string cannot be proven one of the
 * app's paths, so callers vouch for it by calling this.
 *
 * @param path an app-relative pathname such as `/leads?tag=x`
 */
export function asInternalPath(path: string): InternalPath {
  return path.replace(/^\//, '') as InternalPath;
}
