<script lang="ts">
  import { page } from '$app/state';
  import { pageLinks } from '#lib/v2/paging.js';

  /**
   * Previous / Next and a rows-per-page choice for a list page. Links are built
   * from the current URL, so search and filters survive every click.
   * `count` is the whole filtered set, `shown` the rows on this page.
   */
  let {
    offset,
    limit,
    count,
    shown,
    label = 'Pages'
  }: { offset: number; limit: number; count: number; shown: number; label?: string } = $props();

  const sizes = [25, 50, 100];
  const fmt = (n: number) => n.toLocaleString('en-US');
  let links = $derived(
    pageLinks(page.url.pathname, page.url.search, { offset, limit, count, shown })
  );
</script>

<nav class="pagination" aria-label={label}>
  <span class="v2-sub range">
    <span class="v2-num">{fmt(links.from)}–{fmt(links.to)}</span> of
    <span class="v2-num">{fmt(count)}</span>
  </span>
  {#if links.prev}
    <!-- eslint-disable-next-line svelte/no-navigation-without-resolve -->
    <a class="v2-btn" href={links.prev}>Previous</a>
  {/if}
  {#if links.next}
    <!-- eslint-disable-next-line svelte/no-navigation-without-resolve -->
    <a class="v2-btn" href={links.next}>Next</a>
  {/if}
  <span class="sizes v2-sub">
    Rows:
    {#each sizes as size (size)}
      {#if size === limit}
        <strong aria-current="true">{size}</strong>
      {:else}
        <!-- eslint-disable-next-line svelte/no-navigation-without-resolve -->
        <a href={links.size(size)}>{size}</a>
      {/if}
    {/each}
  </span>
</nav>

<style>
  .pagination {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    gap: 12px;
    padding: 12px 0 24px;
  }
  .sizes {
    margin-left: auto;
    display: inline-flex;
    gap: 10px;
    align-items: center;
    font-size: 12px;
  }
  .range {
    font-size: 12px;
  }
</style>
