<script lang="ts">
  import VendorForm from '../VendorForm.svelte';
  import type { PageProps } from './$types';
  let { data, form }: PageProps = $props();
</script>

<VendorForm {data} {form} />
