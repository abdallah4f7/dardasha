// Sends push notifications through Firebase Cloud Messaging.
// The app calls this after sending a message, starting a call, or a friend action;
// it checks the caller is allowed to notify those people, then pushes to their phones.
//
// Secret: FIREBASE_SERVICE_ACCOUNT = the JSON key from Firebase → Project settings → Service accounts.

import { createClient } from 'npm:@supabase/supabase-js@2';

const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
const account = JSON.parse(Deno.env.get('FIREBASE_SERVICE_ACCOUNT') ?? '{}');

type Lang = 'ar' | 'en';
type Push = {
  data: Record<string, string>;
  // Shown by Android when present; calls leave it out so the app can ring instead.
  notification?: (lang: Lang) => { title: string; body: string };
  tag?: string;
  call?: boolean;
};

// ───── Google OAuth token for FCM, cached until shortly before it expires ─────

let cached: { token: string; expires: number } | null = null;

function base64url(data: ArrayBuffer | string) {
  const bytes = typeof data === 'string' ? new TextEncoder().encode(data) : new Uint8Array(data);
  return btoa(String.fromCharCode(...bytes)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

async function accessToken() {
  if (cached && cached.expires > Date.now() + 60_000) return cached.token;
  const now = Math.floor(Date.now() / 1000);
  const header = base64url(JSON.stringify({ alg: 'RS256', typ: 'JWT' }));
  const claims = base64url(
    JSON.stringify({
      iss: account.client_email,
      scope: 'https://www.googleapis.com/auth/firebase.messaging',
      aud: 'https://oauth2.googleapis.com/token',
      iat: now,
      exp: now + 3600,
    }),
  );
  const pem = (account.private_key as string).replace(/-----[^-]+-----/g, '').replace(/\s/g, '');
  const der = Uint8Array.from(atob(pem), (c) => c.charCodeAt(0));
  const key = await crypto.subtle.importKey('pkcs8', der, { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' }, false, [
    'sign',
  ]);
  const signature = await crypto.subtle.sign('RSASSA-PKCS1-v1_5', key, new TextEncoder().encode(`${header}.${claims}`));
  const res = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
      assertion: `${header}.${claims}.${base64url(signature)}`,
    }),
  });
  const json = await res.json();
  cached = { token: json.access_token, expires: Date.now() + json.expires_in * 1000 };
  return cached.token;
}

// ───── Sending ─────

async function sendTo(userIds: string[], push: Push) {
  if (userIds.length === 0) return;
  const { data: rows } = await admin.from('push_tokens').select('token, lang').in('user_id', userIds);
  if (!rows?.length) return;
  const auth = await accessToken();
  await Promise.all(
    rows.map(async ({ token, lang }) => {
      const message: Record<string, unknown> = {
        token,
        data: push.data,
        android: push.call
          ? { priority: 'HIGH', ttl: '45s' }
          : { priority: 'HIGH', notification: { channel_id: 'messages_v2', tag: push.tag } },
      };
      if (push.notification) message.notification = push.notification(lang === 'en' ? 'en' : 'ar');
      const res = await fetch(`https://fcm.googleapis.com/v1/projects/${account.project_id}/messages:send`, {
        method: 'POST',
        headers: { Authorization: `Bearer ${auth}`, 'Content-Type': 'application/json' },
        body: JSON.stringify({ message }),
      });
      // Uninstalled app or expired token: forget it. (A bad message is our fault, not the phone's.)
      if (!res.ok) {
        const err = await res.json().catch(() => ({}));
        const codes = (err?.error?.details ?? []).map((d: { errorCode?: string }) => d.errorCode);
        if (res.status === 404 || codes.includes('UNREGISTERED')) {
          await admin.from('push_tokens').delete().eq('token', token);
        } else {
          console.error('FCM', res.status, JSON.stringify(err));
        }
      }
    }),
  );
}

const labels = {
  ar: { image: '📷 صورة', video: '🎥 فيديو', voice: '🎤 رسالة صوتية', sticker: 'ملصق' },
  en: { image: '📷 Photo', video: '🎥 Video', voice: '🎤 Voice message', sticker: 'Sticker' },
};

function preview(lang: Lang, type: string, content: string | null) {
  if (type === 'text') return (content ?? '').slice(0, 200);
  if (type === 'file') return `📎 ${content ?? ''}`.trim();
  if (type === 'sticker') return `${content ?? ''} ${labels[lang].sticker}`.trim();
  return labels[lang][type as 'image' | 'video' | 'voice'] ?? '';
}

async function profile(id: string) {
  const { data } = await admin.from('profiles').select('display_name, avatar_url').eq('id', id).single();
  return data;
}

async function shareAConversation(a: string, b: string) {
  const { data: mine } = await admin.from('conversation_members').select('conversation_id').eq('user_id', a);
  const ids = (mine ?? []).map((r) => r.conversation_id);
  if (ids.length === 0) return false;
  const { count } = await admin
    .from('conversation_members')
    .select('*', { count: 'exact', head: true })
    .eq('user_id', b)
    .in('conversation_id', ids);
  return (count ?? 0) > 0;
}

// ───── Handlers ─────

async function onMessage(uid: string, messageId: string) {
  const { data: m } = await admin
    .from('messages')
    .select('id, conversation_id, sender_id, type, content, conversations(is_group, name)')
    .eq('id', messageId)
    .eq('sender_id', uid)
    .single();
  if (!m || m.type === 'call') return;
  const conv = m.conversations as unknown as { is_group: boolean; name: string | null };
  const { data: members } = await admin
    .from('conversation_members')
    .select('user_id')
    .eq('conversation_id', m.conversation_id)
    .neq('user_id', uid);
  const sender = (await profile(uid))?.display_name ?? '';
  await sendTo(
    (members ?? []).map((r) => r.user_id),
    {
      data: {
        type: 'message',
        conversation_id: m.conversation_id,
        is_group: String(conv.is_group),
        chat_title: conv.is_group ? (conv.name ?? '') : '',
      },
      tag: m.conversation_id,
      notification: (lang) =>
        conv.is_group
          ? { title: conv.name ?? '', body: `${sender}: ${preview(lang, m.type, m.content)}` }
          : { title: sender, body: preview(lang, m.type, m.content) },
    },
  );
}

// Calls may also ring a friend added into a call, who shares no chat with the caller.
async function mayCall(a: string, b: string) {
  if (await shareAConversation(a, b)) return true;
  const { count } = await admin
    .from('friendships')
    .select('*', { count: 'exact', head: true })
    .eq('status', 'accepted')
    .or(`and(requester.eq.${a},addressee.eq.${b}),and(requester.eq.${b},addressee.eq.${a})`);
  return (count ?? 0) > 0;
}

async function isBanned(id: string) {
  const { data } = await admin.from('bans').select('until').eq('user_id', id).maybeSingle();
  return !!data && (data.until === null || new Date(data.until) > new Date());
}

async function onCall(uid: string, to: string, callId: string, video: boolean) {
  if (await isBanned(uid)) return;
  if (!(await mayCall(uid, to))) return;
  const me = await profile(uid);
  await sendTo([to], {
    call: true,
    // caller/callee let the notification's "Decline" button answer without opening the app.
    // (FCM reserves the data key "from".)
    data: { type: 'call', call_id: callId, video: String(video), from_name: me?.display_name ?? '', caller: uid, callee: to },
  });
}

async function onCallEnd(uid: string, to: string, callId: string) {
  if (!(await mayCall(uid, to))) return;
  await sendTo([to], { call: true, data: { type: 'call_end', call_id: callId } });
}

async function onFriend(uid: string, to: string, accepted: boolean) {
  const { data: f } = await admin
    .from('friendships')
    .select('status')
    .eq('requester', accepted ? to : uid)
    .eq('addressee', accepted ? uid : to)
    .single();
  if (!f || (f.status === 'accepted') !== accepted) return;
  const name = (await profile(uid))?.display_name ?? '';
  await sendTo([to], {
    data: { type: accepted ? 'friend_accept' : 'friend_request' },
    tag: accepted ? `friend_accept:${uid}` : `friend_request:${uid}`,
    notification: (lang) =>
      lang === 'ar'
        ? { title: name, body: accepted ? 'قبل طلب الصداقة' : 'أرسل لك طلب صداقة' }
        : { title: name, body: accepted ? 'Accepted your friend request' : 'Sent you a friend request' },
  });
}

// Tells the moderators about a report; only the person who filed it can trigger this.
async function onReport(uid: string, reportId: string) {
  const { data: r } = await admin
    .from('reports')
    .select('id, note, message_type, message_content, reported_id')
    .eq('id', reportId)
    .eq('reporter_id', uid)
    .eq('status', 'open')
    .single();
  if (!r) return;
  const { data: mods } = await admin.from('moderators').select('user_id');
  const who = r.reported_id ? ((await profile(r.reported_id))?.display_name ?? '') : '';
  await sendTo(
    (mods ?? []).map((m) => m.user_id),
    {
      data: { type: 'report', report_id: r.id },
      tag: `report:${r.id}`,
      notification: (lang) => ({
        title: lang === 'ar' ? `بلاغ جديد على ${who}` : `New report about ${who}`,
        body: r.note ?? preview(lang, r.message_type, r.message_content),
      }),
    },
  );
}

// Tells the reported person the decision and the explanation, never who reported them.
async function onModeration(uid: string, reportId: string) {
  const { data: mod } = await admin.from('moderators').select('user_id').eq('user_id', uid).maybeSingle();
  if (!mod) return;
  const { data: r } = await admin
    .from('reports')
    .select('reported_id, action, reason, ban_until')
    .eq('id', reportId)
    .eq('status', 'resolved')
    .single();
  if (!r?.reported_id || r.action === 'none') return;
  const titles = {
    ar: { delete: 'انحذفت رسالة لك', temp_ban: 'انوقف حسابك مؤقتاً', ban: 'انوقف حسابك نهائياً' },
    en: { delete: 'A message of yours was removed', temp_ban: 'Your account was suspended', ban: 'Your account was banned' },
  };
  await sendTo([r.reported_id], {
    data: { type: 'moderation' },
    tag: `moderation:${reportId}`,
    notification: (lang) => ({
      title: titles[lang][r.action as 'delete' | 'temp_ban' | 'ban'],
      body: r.reason ?? (lang === 'ar' ? 'مخالفة لقوانين التطبيق' : "It went against the app's rules"),
    }),
  });
}

Deno.serve(async (req) => {
  const jwt = (req.headers.get('Authorization') ?? '').replace('Bearer ', '');
  const { data: auth } = await admin.auth.getUser(jwt);
  const uid = auth.user?.id;
  if (!uid) return new Response('Unauthorized', { status: 401 });

  const body = await req.json().catch(() => ({}));
  try {
    switch (body.type) {
      case 'message':
        await onMessage(uid, body.message_id);
        break;
      case 'call':
        await onCall(uid, body.to, body.call_id, body.video === true);
        break;
      case 'call_end':
        await onCallEnd(uid, body.to, body.call_id);
        break;
      case 'friend_request':
        await onFriend(uid, body.to, false);
        break;
      case 'friend_accept':
        await onFriend(uid, body.to, true);
        break;
      case 'report':
        await onReport(uid, body.report_id);
        break;
      case 'moderation':
        await onModeration(uid, body.report_id);
        break;
      default:
        return new Response('Unknown type', { status: 400 });
    }
  } catch (e) {
    console.error(e);
    return new Response('Error', { status: 500 });
  }
  return new Response('ok');
});
