<script lang="ts">
  import MergeCompare from '#lib/v2/components/MergeCompare.svelte';
  import type { PageProps } from './$types';

  let { data, form }: PageProps = $props();
</script>

<svelte:head>
  <title>Merge {data.singular}s</title>
</svelte:head>

<MergeCompare {data} {form} />
