<script>
  import MergeCompare from '#lib/v2/components/MergeCompare.svelte';

  /** @type {import('./$types').PageProps} */
  let { data, form } = $props();
</script>

<svelte:head>
  <title>Merge {data.singular}s</title>
</svelte:head>

<MergeCompare {data} {form} />
