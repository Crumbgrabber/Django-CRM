<script lang="ts">
  import { resolve } from '$app/paths';
  import { asInternalPath } from '#lib/utils/paths.js';
  import { relativeTime } from '#lib/v2/format.js';
  import { Paperclip } from '@lucide/svelte';

  /**
   * A record's files, newest first, each opening through the download proxy
   * (`attachmentHref`), never a storage URL. A file with no link is named
   * as plain text.
   */
  let {
    files = [],
    empty = 'No files yet.'
  }: {
    files: { id: string; name: string; at: string | null; href: string | null }[];
    empty?: string;
  } = $props();
</script>

{#if files.length === 0}
  <p class="v2-sub fl-empty">{empty}</p>
{:else}
  <ul class="fl">
    {#each files as f (f.id)}
      <li class="fl-row">
        <Paperclip size={13} style="flex:none;color:var(--v2-slate)" />
        <div class="fl-body">
          {#if f.href}
            <a
              class="fl-name"
              href={resolve(asInternalPath(f.href))}
              target="_blank"
              rel="noreferrer noopener"
              data-sveltekit-reload>{f.name}</a
            >
          {:else}
            <span class="fl-name">{f.name}</span>
          {/if}
          {#if f.at}<span class="v2-sub fl-meta">{relativeTime(f.at)}</span>{/if}
        </div>
      </li>
    {/each}
  </ul>
{/if}

<style>
  .fl {
    list-style: none;
    margin: 0;
    padding: 0;
  }
  .fl-row {
    display: flex;
    align-items: center;
    gap: 9px;
    padding: 8px 0;
    border-bottom: 1px solid var(--v2-line-soft);
    min-height: 44px;
  }
  .fl-row:last-child {
    border-bottom: 0;
  }
  .fl-body {
    min-width: 0;
    display: flex;
    flex-wrap: wrap;
    align-items: baseline;
    gap: 4px 10px;
  }
  .fl-name {
    font-size: 13px;
    font-weight: 550;
    color: var(--v2-ink);
    text-decoration: none;
    overflow-wrap: anywhere;
  }
  a.fl-name:hover {
    text-decoration: underline;
  }
  .fl-meta {
    font-size: 11.5px;
  }
  .fl-empty {
    font-size: 12.5px;
    margin: 0;
  }
</style>
