<script lang="ts">
  import { Dialog as DialogPrimitive, type DialogRootProps } from 'bits-ui';

  let { open = $bindable(false), ...restProps }: DialogRootProps = $props();
</script>

<DialogPrimitive.Root bind:open {...restProps} />
