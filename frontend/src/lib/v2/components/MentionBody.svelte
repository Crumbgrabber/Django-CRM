<script lang="ts">
  import { mentionTokens, type MentionPerson } from '#lib/v2/mentions.js';

  /**
   * A comment body with each `@handle` that names a member drawn as a chip.
   * An unknown handle stays plain text: the backend notified nobody for it.
   */
  let { body = '', people = [] }: { body: string; people?: MentionPerson[] } = $props();

  const tokens = $derived(mentionTokens(body, people));
</script>

<!-- Hugged on purpose: the parent is white-space: pre-wrap, so any gap is shown. -->
{#each tokens as token, i (i)}{#if token.type === 'mention'}<span
      class="mention-chip"
      title={token.person.name}>{token.value}</span
    >{:else}{token.value}{/if}{/each}

<style>
  .mention-chip {
    padding: 0 4px;
    border-radius: 4px;
    /* Not --v2-line-soft: that is the background of our own replies. */
    background: var(--v2-line);
    color: var(--v2-ink);
    font-weight: 600;
  }
</style>
