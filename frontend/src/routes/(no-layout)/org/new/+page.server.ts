/**
 * Create an organization: `POST /api/org/`, which answers 201 with the new
 * org, then an optional industry app installed on it.
 */

import * as env from '$app/env/private';
import * as publicEnv from '$app/env/public';
import axios from 'axios';
import { describeError } from '#lib/server/log-safe.js';
import { relayHeaders } from '#lib/server/relay.js';
import { listPacks, applyPack } from '#lib/server/packs.js';
import { installApp } from '#lib/server/v2/apps.js';
import { SIGNUP_SOURCE_COOKIE, readSignupSource } from '#lib/server/signup-source.js';
import { listTimezones } from '#lib/server/v2/organization.js';
import type { components } from '#lib/api-schema.js';
import type { Actions, PageServerLoad } from './$types';

type Schemas = components['schemas'];

export const load: PageServerLoad = async ({ cookies }) => {
  // GET /api/packs/ needs IsAuthenticated only, no org context, but a
  // brand-new user creating their very first org must never have this call
  // break the page. Fall back to an empty list, which renders as just the
  // "Skip for now" option.
  const [packs, timezones] = await Promise.all([
    listPacks(cookies).catch((err) => {
      const e = err as { message?: unknown; status?: unknown } | null | undefined;
      console.error('Could not load vertical packs:', e?.message, e?.status);
      return [];
    }),
    // The zone list comes from the API rather than the browser's own
    // `Intl.supportedValuesOf`, because the two vocabularies disagree: a
    // browser answers "Asia/Calcutta" where the server also knows
    // "Asia/Kolkata", and a select that cannot find the stored value submits
    // its first option instead. Falling back to just UTC keeps the form
    // usable; the org can be corrected in settings.
    listTimezones(cookies).catch((err) => {
      const e = err as { message?: unknown; status?: unknown } | null | undefined;
      console.error('Could not load timezones:', e?.message, e?.status);
      return [{ name: 'UTC', label: 'UTC' }];
    })
  ]);
  return { packs, timezones };
};

/**
 * Install the chosen app with its sample records, as applying a pack did. An
 * API without apps answers 404, and then the pack is applied the old way.
 */
async function installAtSignup(
  bearerOnly: { get: (name: string) => string | undefined },
  appId: string
) {
  try {
    await installApp(bearerOnly, appId, true);
  } catch (err) {
    if ((err as { status?: unknown } | null | undefined)?.status !== 404) throw err;
    await applyPack(bearerOnly, appId);
  }
}

export const actions: Actions = {
  default: async ({ request, cookies, locals, getClientAddress }) => {
    // Get the user from locals
    const user = locals.user;

    if (!user) {
      return {
        error: {
          name: 'You must be logged in to create an organization'
        }
      };
    }

    // Get the submitted form data
    const formData = await request.formData();
    const orgName = formData.get('org_name')?.toString();
    // Optional end to end: the field is a select with a value, but the API
    // treats a missing timezone as UTC so a submission without one still works.
    const timezone = formData.get('timezone')?.toString().trim();

    if (!orgName || orgName.trim().length === 0) {
      return {
        error: {
          name: 'Organization name is required'
        }
      };
    }

    try {
      const jwtAccess = cookies.get('jwt_access');
      if (!jwtAccess) {
        return {
          error: {
            name: 'Authentication required'
          }
        };
      }

      const apiUrl = publicEnv.PUBLIC_DJANGO_API_URL;

      // Create organization and profile via Django API
      // Django's OrgProfileCreateView creates both org and profile
      const signupSource = readSignupSource(cookies);
      const response = await axios.post<Schemas['OrgCreateResponse']>(
        `${apiUrl}/api/org/`,
        {
          name: orgName.trim(),
          ...(timezone ? { timezone } : {}),
          ...(signupSource ? { signup_source: signupSource } : {})
        } satisfies Schemas['OrgCreateBodyRequest'],
        {
          headers: {
            Authorization: `Bearer ${jwtAccess}`,
            'Content-Type': 'application/json'
          }
        }
      );

      const newOrg = response.data.org;

      // Spent: a second org this person creates did not come from that visit.
      cookies.delete(SIGNUP_SOURCE_COOKIE, { path: '/' });

      // Set org cookie for the newly created org
      await cookies.set('org', newOrg.id, {
        path: '/',
        httpOnly: true,
        sameSite: 'strict',
        secure: env.NODE_ENV === 'production'
      });

      // Optional industry app, chosen in the "What kind of business is this?"
      // group below. Empty string. The "Skip for now" option, and the
      // default when nothing is submitted. Means do nothing.
      const vertical = formData.get('vertical')?.toString();
      if (vertical) {
        // POST /api/apps/<id>/install/ is ADMIN-only and derives its org from
        // request.profile.org, i.e. from the org_id claim on the JWT, never
        // from a body field. /api/org/ does not mint new tokens, so the
        // access token we are holding here still carries the PREVIOUS org's
        // claim (or no org claim at all, for a brand-new user's first org).
        // Mint one scoped to the org we just created, the same way `/org`'s
        // `selectOrg` action and the shell's own hooks.server.ts do it, so
        // the install lands on the right org as its ADMIN.
        //
        // This token is used ONLY as the bearer credential for the one
        // install below. It is never written to the jwt_access /
        // jwt_refresh cookies. Doing so would silently rotate the caller's
        // session to the new org mid-request (e.g. a user already in org A
        // creating org B would suddenly be sitting in org B everywhere else
        // too), which is a change to the session/org-claim contract the
        // brief says must not move. The Skip path never touches these
        // cookies at all, and this path must behave identically apart from
        // the install itself. The existing `org` cookie + the
        // shell's own hooks.server.ts switch-org-on-mismatch logic already
        // handle rotating the *browser's* session correctly if and when the
        // user actually navigates into the new org.
        try {
          // Deliberately do NOT send `refresh` here. OrgSwitchView's
          // `_retire_presented_refresh_token` blacklists whatever refresh
          // token is presented. That is correct for every other switch-org
          // caller (hooks.server.ts, /org, /settings/profile), which all
          // write the replacement token back to the jwt_access/jwt_refresh
          // cookies in the same request. This call mints a token used ONLY
          // as the bearer credential for the install below (see
          // the comment above) and never persists it, so blacklisting the
          // caller's real refresh token here would leave the browser holding
          // a dead one with nothing to replace it, and the user is signed
          // out the next time the access token expires and a refresh is
          // attempted. `refresh` is optional on this endpoint precisely for
          // callers like this one that only need the org-scoped access
          // token and must not touch the caller's session.
          const switchResponse = await axios.post<Schemas['OrgSwitchResponse']>(
            `${apiUrl}/api/auth/switch-org/`,
            { org_id: newOrg.id } satisfies Schemas['OrgSwitchRequestRequest'],
            {
              headers: {
                Authorization: `Bearer ${jwtAccess}`,
                'Content-Type': 'application/json',
                // The org-switch audit row records who switched.
                ...relayHeaders({ getClientAddress, request })
              }
            }
          );

          const { access_token } = switchResponse.data;

          // A minimal cookies-shaped shim: the install and apiRequest only ever
          // call `.get('jwt_access')` on what they're given. Handing them
          // this instead of the real `cookies` object means the org-scoped
          // token is used for exactly this one outgoing request and never
          // reaches `cookies.set()`, so nothing is queued onto the response.
          const bearerOnly = {
            get: (name: string) => (name === 'jwt_access' ? access_token : undefined)
          };
          await installAtSignup(bearerOnly, vertical);
        } catch (packErr) {
          // An install failing must never fail org creation: the org
          // and its admin profile already exist, already committed by the
          // /api/org/ call above. Log it and let signup succeed anyway.
          //
          // Do NOT log packErr itself: it may be an AxiosError carrying
          // `.config.headers.Authorization` with the bearer token in it, and
          // Node's default error formatting prints that in full. Log only
          // the message and status.
          const e = packErr as
            | { message?: unknown; status?: unknown; response?: { status?: unknown } }
            | null
            | undefined;
          console.error(
            `Industry app "${vertical}" did not install on new org ${newOrg.id} (org creation still succeeded):`,
            e?.message,
            e?.response?.status ?? e?.status
          );
        }
      }

      // Return success
      return {
        data: {
          name: orgName
        }
      };
    } catch (err) {
      // Never log the raw error: its axios `config.headers` carries the JWT.
      console.error('Error creating organization:', describeError(err));

      // A refused name or timezone. The API answers
      // `{"error": true, "errors": {"name": ["..."]}}`, so the sentences are
      // under `errors`; the top-level `error` is only the boolean flag.
      const failure = err as {
        response?: {
          status?: number;
          data?: { errors?: { name?: string[]; timezone?: string[] } };
        };
      };
      if (failure.response?.status === 400) {
        const errors = failure.response.data?.errors;
        return {
          error: {
            name:
              errors?.name?.[0] ||
              errors?.timezone?.[0] ||
              'Organization with this name may already exist'
          }
        };
      }

      return {
        error: {
          name: 'An unexpected error occurred while creating the organization.'
        }
      };
    }
  }
};
