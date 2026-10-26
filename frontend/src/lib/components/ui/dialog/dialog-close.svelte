<script lang="ts">
  import { Dialog as DialogPrimitive, type DialogCloseProps } from 'bits-ui';

  let { ref = $bindable(null), ...restProps }: DialogCloseProps = $props();
</script>

<DialogPrimitive.Close bind:ref data-slot="dialog-close" {...restProps} />
