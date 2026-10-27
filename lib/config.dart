// Fill these from Supabase Dashboard → Project Settings → API.
const supabaseUrl = 'https://YOUR-PROJECT.supabase.co';
const supabasePublishableKey = 'YOUR-PUBLISHABLE-KEY';

// Public STUN server for calls. Add a TURN server here if calls fail
// between some networks (e.g. strict mobile carriers).
const iceServers = <Map<String, dynamic>>[
  {
    'urls': ['stun:stun.l.google.com:19302', 'stun:stun1.l.google.com:19302'],
  },
];
