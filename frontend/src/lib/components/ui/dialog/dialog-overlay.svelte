<script lang="ts">
  import { Dialog as DialogPrimitive, type DialogOverlayProps } from 'bits-ui';
  import { cn } from '#lib/utils.js';

  let { ref = $bindable(null), class: className, ...restProps }: DialogOverlayProps = $props();
</script>

<DialogPrimitive.Overlay
  bind:ref
  data-slot="dialog-overlay"
  class={cn(
    'data-[state=open]:animate-in data-[state=closed]:animate-out data-[state=closed]:fade-out-0 data-[state=open]:fade-in-0 fixed inset-0 z-50 bg-black/50',
    className
  )}
  {...restProps}
/>
