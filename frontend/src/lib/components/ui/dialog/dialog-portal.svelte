<script lang="ts">
  import { Dialog as DialogPrimitive, type DialogPortalProps } from 'bits-ui';

  let { ...restProps }: DialogPortalProps = $props();
</script>

<DialogPrimitive.Portal {...restProps} />
