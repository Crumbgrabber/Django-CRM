<script lang="ts">
  import BillForm from '../../../BillForm.svelte';
  import type { PageProps } from './$types';
  let { data, form }: PageProps = $props();
</script>

<BillForm {data} {form} />
