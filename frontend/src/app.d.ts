// See https://svelte.dev/docs/kit/types#app.d.ts
// for information about these interfaces
import type { ModuleRow } from '#lib/v2/modules.js';

declare global {
  namespace App {
    interface Error {
      message: string;
      code?: string;
      module?: string;
      label?: string;
    }
    interface Locals {
      user?: { id?: string; name: string; email: string; profilePhoto: string };
      org?: { id: string; name: string };
      org_name?: string;
      org_settings?: {
        default_currency?: string;
        currency_symbol?: string;
        default_country?: string | null;
        timezone?: string;
      };
      profile?: {
        org?: { id: string; name: string };
        role?: string;
        is_organization_admin?: boolean;
      };
    }
    /** What the `(app)` layout gives every page, which shared components read from `page.data`. */
    interface PageData {
      counts?: Record<string, number>;
      modules?: ModuleRow[] | null;
    }
    // interface PageState {}
    // interface Platform {}
  }
}

export {};
