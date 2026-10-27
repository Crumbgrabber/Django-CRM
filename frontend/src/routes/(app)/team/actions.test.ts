import { beforeEach, describe, expect, it, vi } from 'vitest';

const apiRequest = vi.fn();
vi.mock('#lib/api-helpers.js', () => ({ apiRequest: (...args: any[]) => apiRequest(...args) }));
const { actions } = (await import('./+page.server.js')) as any;
const cookies = { get: () => undefined } as any;
function event(fields: [string, string][]) {
  const body = new FormData();
  for (const [key, value] of fields) body.append(key, value);
  return { cookies, request: new Request('http://test/team', { method: 'POST', body }) } as any;
}

describe('team management actions', () => {
  beforeEach(() => {
    apiRequest.mockReset();
  });

  it('creates a team with an optional blank description', async () => {
    expect(await actions.createTeam(event([['name', ' Executive ']]))).toEqual({
      message: 'Team created.'
    });
    expect(apiRequest).toHaveBeenCalledWith(
      '/teams/',
      { method: 'POST', body: { name: 'Executive', description: '', assign_users: [] } },
      { cookies }
    );
  });

  it('deletes the selected team', async () => {
    await actions.deleteTeam(event([['teamId', 'team-1']]));
    expect(apiRequest).toHaveBeenCalledWith('/teams/team-1/', { method: 'DELETE' }, { cookies });
  });

  it.each([{ ids: ['profile-1', 'profile-2'] }, { ids: [] }])(
    'saves Profile ids including an empty selection: $ids',
    async ({ ids }) => {
      const fields: [string, string][] = [
        ['teamId', 'team-1'],
        ['name:team-1', 'Executive'],
        ['original:team-1', 'profile-9']
      ];
      for (const id of ids) fields.push(['member:team-1', id]);
      expect(await actions.setMembers(event(fields))).toEqual({ message: 'Team members saved.' });
      expect(apiRequest).toHaveBeenCalledWith(
        '/teams/team-1/',
        { method: 'PUT', body: { name: 'Executive', assign_users: ids } },
        { cookies }
      );
    }
  );

  it('saves every changed team in one submit and skips unchanged ones', async () => {
    const result = await actions.setMembers(
      event([
        ['teamId', 'team-1'],
        ['name:team-1', 'Sales'],
        ['original:team-1', 'p1'],
        ['member:team-1', 'p1'],
        ['teamId', 'team-2'],
        ['name:team-2', 'Treasury'],
        ['original:team-2', ''],
        ['member:team-2', 'p1'],
        ['teamId', 'team-3'],
        ['name:team-3', 'Design'],
        ['original:team-3', 'p1,p2']
      ])
    );
    expect(result).toEqual({ message: 'Team members saved.' });
    expect(apiRequest).toHaveBeenCalledTimes(2);
    expect(apiRequest).toHaveBeenCalledWith(
      '/teams/team-2/',
      { method: 'PUT', body: { name: 'Treasury', assign_users: ['p1'] } },
      { cookies }
    );
    expect(apiRequest).toHaveBeenCalledWith(
      '/teams/team-3/',
      { method: 'PUT', body: { name: 'Design', assign_users: [] } },
      { cookies }
    );
  });

  it('reports nothing to save when no team changed', async () => {
    const result = await actions.setMembers(
      event([
        ['teamId', 'team-1'],
        ['name:team-1', 'Sales'],
        ['original:team-1', 'p1'],
        ['member:team-1', 'p1']
      ])
    );
    expect(result).toEqual({ message: 'No membership changes to save.' });
    expect(apiRequest).not.toHaveBeenCalled();
  });

  it.each(['createTeam', 'deleteTeam', 'setMembers'])(
    'rejects missing fields for %s',
    async (action) => {
      expect((await actions[action](event([]))).status).toBe(400);
      expect(apiRequest).not.toHaveBeenCalled();
    }
  );

  it.each([
    ['createTeam', 400],
    ['createTeam', 403],
    ['deleteTeam', 400],
    ['deleteTeam', 403],
    ['setMembers', 400],
    ['setMembers', 403]
  ] as const)('returns readable errors for %s with status %s', async (action, status) => {
    apiRequest.mockRejectedValue(
      Object.assign(new Error('failed'), {
        status,
        body: { errors: 'Choose active members.' }
      })
    );
    const result = await actions[action](
      event([
        ['teamId', 'team-1'],
        ['name', 'Executive'],
        ['name:team-1', 'Executive'],
        ['member:team-1', 'p1']
      ])
    );
    expect(result.status).toBe(status);
    expect(result.data.error).toContain('Choose active members.');
  });
});

describe('person edits', () => {
  beforeEach(() => {
    apiRequest.mockReset();
  });
  it('saves phones without resending unchanged account fields or privileges', async () => {
    const result = await actions.edit(
      event([
        ['userId', 'u1'],
        ['email', 'member@test.com'],
        ['originalEmail', 'member@test.com'],
        ['name', 'Member'],
        ['originalName', 'Member'],
        ['phone', ' +15551112222 '],
        ['alternate_phone', ''],
        ['role', 'ADMIN'],
        ['is_staff', 'true'],
        ['org', 'other']
      ])
    );
    expect(result).toEqual({ edited: 'u1' });
    expect(apiRequest).toHaveBeenCalledWith(
      '/user/u1/',
      { method: 'PATCH', body: { phone: '+15551112222', alternate_phone: '' } },
      { cookies }
    );
  });
  it('forwards account changes including a cleared name', async () => {
    await actions.edit(
      event([
        ['userId', 'u1'],
        ['name', ''],
        ['originalName', 'Old'],
        ['email', 'new@test.com'],
        ['password', 'new-password']
      ])
    );
    expect(apiRequest.mock.calls[0][1].body).toEqual({
      name: '',
      email: 'new@test.com',
      password: 'new-password'
    });
  });
  it.each([400, 403, 404])('reports backend refusal %s', async (status) => {
    apiRequest.mockRejectedValue(
      Object.assign(new Error('failed'), { status, body: { errors: 'Refused.' } })
    );
    const result = await actions.edit(
      event([
        ['userId', 'u1'],
        ['phone', '+15551112222']
      ])
    );
    expect(result.status).toBe(status === 403 ? 403 : 400);
    expect(result.data.edit.error).toBeTruthy();
  });
});
