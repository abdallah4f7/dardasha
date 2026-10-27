// Fill these from Supabase Dashboard → Project Settings → API.
const supabaseUrl = 'https://ltoemjqnzpivziwmxpjk.supabase.co';
const supabasePublishableKey = 'sb_publishable_HavSYRclIqO0V8R_dAtnZQ_UjlO75JW';

// Public STUN server for calls. Add a TURN server here if calls fail
// between some networks (e.g. strict mobile carriers).
const iceServers = <Map<String, dynamic>>[
  {
    'urls': ['stun:stun.l.google.com:19302', 'stun:stun1.l.google.com:19302'],
  },
];
