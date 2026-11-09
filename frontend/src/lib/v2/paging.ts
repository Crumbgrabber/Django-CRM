/** Range text and Previous/Next/size links for a list page. Pure, so it is testable. */
export function pageLinks(
  pathname: string,
  search: string,
  { offset, limit, count, shown }: { offset: number; limit: number; count: number; shown: number }
) {
  const href = (changes: Record<string, string | null>) => {
    const next = new URLSearchParams(search);
    for (const [key, value] of Object.entries(changes)) {
      if (value === null) next.delete(key);
      else next.set(key, value);
    }
    const query = next.toString();
    return `${pathname}${query ? `?${query}` : ''}`;
  };
  const to = offset + shown;
  return {
    from: shown ? offset + 1 : 0,
    to,
    prev: offset > 0 ? href({ offset: offset - limit > 0 ? String(offset - limit) : null }) : null,
    next: to < count ? href({ offset: String(offset + limit) }) : null,
    size: (n: number) => href({ limit: String(n), offset: null })
  };
}
