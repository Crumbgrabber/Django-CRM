<script>
  import { Dialog as DialogPrimitive } from 'bits-ui';

  /** @type {import('bits-ui').DialogRootProps} */
  let { open = $bindable(false), ...restProps } = $props();
</script>

<DialogPrimitive.Root bind:open {...restProps} />
