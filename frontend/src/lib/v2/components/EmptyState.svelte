<script lang="ts">
  import type { Snippet } from 'svelte';

  /**
   * Empty and error states. Both say what happened and what to do next.
   * No apologies, no "Something went wrong", no dead ends.
   */
  let {
    title,
    body,
    icon,
    actions
  }: {
    title: string;
    body: string;
    icon?: Snippet;
    actions?: Snippet;
  } = $props();
</script>

<div class="v2-state">
  {#if icon}<div class="v2-state-icon">{@render icon()}</div>{/if}
  <h3>{title}</h3>
  <p>{body}</p>
  {#if actions}
    <div style="display:flex;gap:8px;justify-content:center">{@render actions()}</div>
  {/if}
</div>
