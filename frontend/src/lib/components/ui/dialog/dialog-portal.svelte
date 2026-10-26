<script>
  import { Dialog as DialogPrimitive } from 'bits-ui';

  /** @type {import('bits-ui').DialogPortalProps} */
  let { ...restProps } = $props();
</script>

<DialogPrimitive.Portal {...restProps} />
