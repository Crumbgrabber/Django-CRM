<script>
  import { Dialog as DialogPrimitive } from 'bits-ui';

  /** @type {import('bits-ui').DialogTriggerProps} */
  let { ref = $bindable(null), ...restProps } = $props();
</script>

<DialogPrimitive.Trigger bind:ref data-slot="dialog-trigger" {...restProps} />
