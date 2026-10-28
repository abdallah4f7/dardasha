import 'package:firebase_core/firebase_core.dart';

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

// Firebase project for push notifications (values from android/app/google-services.json).
// Set to null to turn notifications off.
const FirebaseOptions? firebaseOptions = FirebaseOptions(
  apiKey: 'AIzaSyC3iDw7fHEhnWBA2CPUwvxstvYEXgsPCC8',
  appId: '1:1066556632145:android:7780d9f410b84b92585c70',
  messagingSenderId: '1066556632145',
  projectId: 'dardasha-e9d10',
  storageBucket: 'dardasha-e9d10.firebasestorage.app',
);
