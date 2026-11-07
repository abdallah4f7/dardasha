// Checks a photo or video before it is sent, as the app's owner set it up: a
// woman's face and hair are blurred, and so is bare skin between the navel and
// the knees (anyone's). A video with music loses its sound. What the models
// aren't sure of goes to the owner for a quick look, see lib/services/moderation.dart.
//
// Runs on the sender's device only. People are found by MediaPipe tasks-vision
// 1.0.0 (a person detector, then the pose of each one), faces and whether they
// are a woman's by face-api 1.7.15 (MIT), music by MediaPipe tasks-audio 1.0.0
// (Apache-2.0), and videos are rewritten by mediabunny 1.61.6 (MPL-2.0). All of
// it lives in fx/ and downloads the first time something is sent.
//
// On Android this page runs inside a hidden WebView that sets DARDASHA_FX to
// the published fx/ folder.
window.dardashaModerate = (() => {
  const FEMALE_SURE = 0.8;
  const FEMALE_UNSURE = 0.25; // a woman's face in profile can score as low as 0.3
  const FEMALE_UNSURE_SMALL = 0.5; // faces in a crowd are a guess, so only likely ones are asked about
  const SMALL_FACE = 48;
  const EXPOSED_SURE = 0.12; // covered legs measured 0–0.03, shorts above the knee 0.14 and up
  const EXPOSED_UNSURE = 0.06;
  const MIN_PERSON = 0.12; // of the picture's height; anyone smaller is too far away to show anything
  const MAX_PEOPLE = 5;
  // A second of sound is music only with an instrument in it: YAMNet also calls
  // Quran recitation "vocal music", "chant" or "classical music".
  const MUSIC_SCORE = 0.3;
  const INSTRUMENT_SCORE = 0.15;
  const MUSIC_SURE = 0.4; // share of the seconds that are music; below it nothing is muted or asked
  const MIN_FACE = 18; // pixels; a smaller face is too far away to tell
  const PREVIEW = 640;
  const COUNT_SIZE = 320; // skin is counted on a picture this big
  const POSE_SIZE = 512;
  const VIDEO_WIDTH = 960;
  const VIDEO_SAMPLES = 20;
  const VIDEO_SAMPLE_EVERY = 3; // seconds between the frames looked at before sending
  const SAMPLE_WIDTH = 640;
  const VIDEO_LOOK_EVERY = 0.5; // seconds; the frames in between reuse the last look, a little wider
  // Instruments, and kinds of music that are never a voice alone.
  const INSTRUMENTS = /instrument|guitar|piano|drum|bass|synth|violin|fiddle|cello|orchestra|keyboard|trumpet|flute|saxophone|organ|ukulele|banjo|harp|accordion|cymbal|tabla|sitar|oud|zither|mandolin|harmonica|brass|string section|percussion|plucked|bowed|beat|pop music|rock|electronic|techno|house music|disco|dance music|hip hop|jazz|funk|reggae|heavy metal|trance|dubstep/i;

  const fx = window.DARDASHA_FX ?? new URL('fx/', document.baseURI).href;
  const sessions = new Map();
  let nextId = 1;

  // ───── Models ─────

  let vision = null;
  let audio = null;
  let media = null;

  // A failed download is tried again next time instead of being remembered.
  function once(get, set, make) {
    return get() ?? set(make().catch((e) => {
      set(null);
      throw e;
    }));
  }

  const loadVision = () => once(() => vision, (v) => (vision = v), async () => {
    const [{ ObjectDetector, PoseLandmarker, ImageSegmenter }, faceapi] = await Promise.all([
      import(`${fx}vision_bundle.mjs`),
      import(`${fx}face-api.esm.js`),
    ]);
    const files = { wasmLoaderPath: `${fx}vision_wasm_internal.js`, wasmBinaryPath: `${fx}vision_wasm_internal.wasm` };
    const faces = faceapi.tf.ready().then(() => Promise.all([
      faceapi.nets.ssdMobilenetv1.loadFromUri(fx),
      faceapi.nets.faceLandmark68Net.loadFromUri(fx),
      faceapi.nets.ageGenderNet.loadFromUri(fx),
    ]));
    // One after the other: MediaPipe tasks made at the same time get their wasm mixed up.
    const pose = await PoseLandmarker.createFromOptions(files, {
      baseOptions: { modelAssetPath: `${fx}pose_landmarker_full.task`, delegate: 'CPU' },
      runningMode: 'IMAGE',
      numPoses: 1,
    });
    // Tells hair, skin and clothes apart; color alone takes a beige thobe for skin.
    const parts = await ImageSegmenter.createFromOptions(files, {
      baseOptions: { modelAssetPath: `${fx}selfie_multiclass_256x256.tflite`, delegate: 'CPU' },
      runningMode: 'IMAGE',
      outputCategoryMask: true,
      outputConfidenceMasks: false,
    });
    const bodies = await ObjectDetector.createFromOptions(files, {
      baseOptions: { modelAssetPath: `${fx}efficientdet_lite0.tflite`, delegate: 'CPU' },
      runningMode: 'IMAGE',
      categoryAllowlist: ['person'],
      scoreThreshold: 0.25, // a crop with nobody in it finds no pose, so a loose bar costs only time
      maxResults: 15,
    });
    await faces;
    return { bodies, pose, parts, faceapi, faceOptions: new faceapi.SsdMobilenetv1Options({ minConfidence: 0.3, maxResults: 20 }) };
  });

  const loadAudio = () => once(() => audio, (v) => (audio = v), async () => {
    const { AudioClassifier } = await import(`${fx}audio_bundle.mjs`);
    return AudioClassifier.createFromOptions(
      { wasmLoaderPath: `${fx}audio_wasm_internal.js`, wasmBinaryPath: `${fx}audio_wasm_internal.wasm` },
      { baseOptions: { modelAssetPath: `${fx}yamnet.tflite` }, maxResults: 15 },
    );
  });

  const loadMedia = () => once(() => media, (v) => (media = v), () => import(`${fx}mediabunny.min.mjs`));

  // ───── Looking at one picture ─────

  const canvas = (w, h) => {
    const c = document.createElement('canvas');
    c.width = Math.max(1, Math.round(w));
    c.height = Math.max(1, Math.round(h));
    return c;
  };

  const visible = (p) => p && (p.visibility ?? 1) > 0.5;

  /** Where the head is, from the face landmarks of the pose. */
  function headFromPose(lm, w, h) {
    const pts = lm.slice(0, 11).filter((p) => (p.visibility ?? 1) > 0.3).map((p) => [p.x * w, p.y * h]);
    if (pts.length < 3) return null;
    const xs = pts.map((p) => p[0]);
    const ys = pts.map((p) => p[1]);
    const cx = xs.reduce((a, b) => a + b) / xs.length;
    const cy = ys.reduce((a, b) => a + b) / ys.length;
    let size = (Math.max(...xs) - Math.min(...xs)) * 1.15;
    if (visible(lm[11]) && visible(lm[12])) {
      size = Math.max(size, Math.hypot((lm[11].x - lm[12].x) * w, (lm[11].y - lm[12].y) * h) * 0.42);
    }
    return { x: cx - size * 0.6, y: cy - size * 0.75, w: size * 1.2, h: size * 1.35 };
  }

  /**
   * The part between the navel and the knees, as thick lines: the belly down
   * to the hips, then each thigh down to its knee. Lines follow the body, so a
   * leaning or lying person is covered too.
   */
  function zoneFromPose(lm, w, h) {
    if (!visible(lm[23]) || !visible(lm[24])) return null;
    const at = (i) => ({ x: lm[i].x * w, y: lm[i].y * h });
    const hipL = at(23);
    const hipR = at(24);
    const hip = { x: (hipL.x + hipR.x) / 2, y: (hipL.y + hipR.y) / 2 };
    const hipW = Math.hypot(hipL.x - hipR.x, hipL.y - hipR.y);
    let up = { x: 0, y: -hipW * 2.5 }; // from the hips toward the shoulders
    if (visible(lm[11]) && visible(lm[12])) {
      up = { x: (lm[11].x + lm[12].x) / 2 * w - hip.x, y: (lm[11].y + lm[12].y) / 2 * h - hip.y };
    }
    const torso = Math.hypot(up.x, up.y);
    if (torso < 4) return null;
    const navel = { x: hip.x + up.x * 0.35, y: hip.y + up.y * 0.35 };
    const knee = (k, from) => (visible(lm[k]) ? at(k) : { x: from.x - up.x * 0.9, y: from.y - up.y * 0.9 });
    return [
      { from: navel, to: hip, width: torso * 0.75 },
      { from: hipL, to: knee(25, hipL), width: torso * 0.42 },
      { from: hipR, to: knee(26, hipR), width: torso * 0.42 },
    ];
  }

  function drawZone(ctx, zone, scale) {
    ctx.lineCap = 'round';
    ctx.strokeStyle = '#000';
    for (const s of zone) {
      ctx.lineWidth = s.width * scale;
      ctx.beginPath();
      ctx.moveTo(s.from.x * scale, s.from.y * scale);
      ctx.lineTo(s.to.x * scale, s.to.y * scale);
      ctx.stroke();
    }
  }

  function zoneBox(zone) {
    let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
    for (const s of zone) {
      for (const p of [s.from, s.to]) {
        x0 = Math.min(x0, p.x - s.width / 2);
        y0 = Math.min(y0, p.y - s.width / 2);
        x1 = Math.max(x1, p.x + s.width / 2);
        y1 = Math.max(y1, p.y + s.width / 2);
      }
    }
    return { x: x0, y: y0, w: x1 - x0, h: y1 - y0 };
  }

  // The segmenter's categories.
  const HAIR = 1;
  const BODY_SKIN = 2;
  const FACE_SKIN = 3;

  /**
   * For one person, on a small copy of the picture: their skin and their hair
   * (as mask canvases the size of the copy), and how much of their
   * navel-to-knee zone is bare.
   */
  function skinOf(sw, sh, person, w) {
    const k = sw / w;
    // Each part in its own color channel, counted on its own: a covered belly
    // shouldn't hide bare thighs. Thighs stop short of the knee, which may show.
    const zoneCanvas = person.zone && canvas(sw, sh);
    if (zoneCanvas) {
      const z = zoneCanvas.getContext('2d');
      z.globalCompositeOperation = 'lighter';
      z.lineCap = 'butt';
      person.zone.forEach((s, i) => {
        const end = i === 0 ? 1 : 0.9;
        z.strokeStyle = ['#f00', '#0f0', '#00f'][i];
        z.lineWidth = s.width * k;
        z.beginPath();
        z.moveTo(s.from.x * k, s.from.y * k);
        z.lineTo((s.from.x + (s.to.x - s.from.x) * end) * k, (s.from.y + (s.to.y - s.from.y) * end) * k);
        z.stroke();
      });
      // An arm or hand in front of the belly is bare skin, but not what we look for.
      z.globalCompositeOperation = 'destination-out';
      z.lineCap = 'round';
      z.strokeStyle = '#000';
      z.lineWidth = person.zone[1].width * 0.55 * k;
      for (const arm of [[11, 13, 15, 19], [12, 14, 16, 20]]) {
        const pts = arm.filter((i) => (person.lm[i].visibility ?? 1) > 0.3).map((i) => person.lm[i]);
        if (pts.length < 2) continue;
        z.beginPath();
        z.moveTo(pts[0].x * sw, pts[0].y * sh);
        for (const p of pts.slice(1)) z.lineTo(p.x * sw, p.y * sh);
        z.stroke();
      }
    }
    const zonePx = zoneCanvas?.getContext('2d').getImageData(0, 0, sw, sh).data;
    const skin = canvas(sw, sh);
    const skinData = skin.getContext('2d').createImageData(sw, sh);
    const hair = canvas(sw, sh);
    const hairData = hair.getContext('2d').createImageData(sw, sh);
    const { cat, cw, ch, rect } = person;
    const inZone = [0, 0, 0];
    const bare = [0, 0, 0];
    const y0 = Math.max(0, Math.floor(rect.y * k));
    const y1 = Math.min(sh, Math.ceil((rect.y + rect.h) * k));
    const x0 = Math.max(0, Math.floor(rect.x * k));
    const x1 = Math.min(sw, Math.ceil((rect.x + rect.w) * k));
    for (let y = y0; y < y1; y++) {
      const cy = Math.floor(((y + 0.5) / k - rect.y) / rect.h * ch);
      if (cy < 0 || cy >= ch) continue;
      for (let x = x0; x < x1; x++) {
        const cx = Math.floor(((x + 0.5) / k - rect.x) / rect.w * cw);
        if (cx < 0 || cx >= cw) continue;
        const c = cat[cy * cw + cx];
        if (c === 0) continue; // background
        const i = (y * sw + x) * 4;
        if (c === BODY_SKIN || c === FACE_SKIN) skinData.data[i + 3] = 255;
        else if (c === HAIR) hairData.data[i + 3] = 255;
        if (!zonePx) continue;
        for (let z = 0; z < 3; z++) {
          if (zonePx[i + z] < 128) continue;
          inZone[z]++;
          if (c === BODY_SKIN) bare[z]++;
        }
      }
    }
    skin.getContext('2d').putImageData(skinData, 0, 0);
    hair.getContext('2d').putImageData(hairData, 0, 0);
    const parts = inZone.map((n, z) => (n > 15 ? bare[z] / n : null)).filter((r) => r != null);
    return { skin, hair, exposed: parts.length > 0 ? Math.max(...parts) : null };
  }

  const centerIn = (a, b) => {
    const cx = a.x + a.w / 2;
    const cy = a.y + a.h / 2;
    return cx >= b.x && cx <= b.x + b.w && cy >= b.y && cy <= b.y + b.h;
  };

  const grow = (b, by) => ({ x: b.x - b.w * (by - 1) / 2, y: b.y - b.h * (by - 1) / 2, w: b.w * by, h: b.h * by });

  /** The pose of the one person inside [rect], with landmarks in the whole picture's terms. */
  function poseIn(source, rect, w, h, m) {
    const s = Math.min(1, POSE_SIZE / Math.max(rect.w, rect.h));
    // MediaPipe aborts the whole module on some masks of an odd width.
    const crop = canvas(Math.max(4, Math.round(rect.w * s / 4) * 4), rect.h * s);
    crop.getContext('2d').drawImage(source, rect.x, rect.y, rect.w, rect.h, 0, 0, crop.width, crop.height);
    let lm = null;
    m.pose.detect(crop, (r) => {
      lm = r.landmarks[0]?.map((p) => ({ x: (rect.x + p.x * rect.w) / w, y: (rect.y + p.y * rect.h) / h, visibility: p.visibility }));
    });
    return lm ? { lm, rect, crop } : null;
  }

  /** Which of the person's pixels are hair, skin or clothes. */
  function partsOf(p, m) {
    m.parts.segment(p.crop, (r) => {
      const mask = r.categoryMask;
      if (!mask) return;
      p.cat = mask.getAsUint8Array().slice();
      p.cw = mask.width;
      p.ch = mask.height;
    });
    return !!p.cat;
  }

  /**
   * Everyone in the picture: where their head is, how sure we are it is a
   * woman, how much of their navel-to-knee zone is bare, and their skin.
   * [cache] smooths a video's answers about who is a woman over its frames.
   * [everyone] also reads the skin of people we have no reason to look at,
   * for when the owner asked for skin or bodies.
   */
  async function look(source, w, h, m, cache, everyone = false) {
    const found = await m.faceapi.detectAllFaces(source, m.faceOptions).withFaceLandmarks().withAgeAndGender();
    const faces = found.map((f) => {
      const b = f.detection.box;
      const box = { x: b.x, y: b.y, w: b.width, h: b.height };
      const size = Math.min(box.w, box.h);
      let female = size >= MIN_FACE ? (f.gender === 'female' ? f.genderProbability : 1 - f.genderProbability) : null;
      if (female != null && cache) female = cache.smooth(box, female);
      return { box, female, floor: size < SMALL_FACE ? FEMALE_UNSURE_SMALL : FEMALE_UNSURE };
    });

    // The biggest few; anyone further back shows too little to matter.
    const bodies = m.bodies.detect(source).detections
      .map((d) => d.boundingBox)
      .filter((b) => b.width >= 8 && b.height >= h * MIN_PERSON)
      .sort((a, b) => b.width * b.height - a.width * a.height)
      .slice(0, MAX_PEOPLE);

    const scale = Math.min(1, COUNT_SIZE / Math.max(w, h));
    const sw = Math.max(1, Math.round(w * scale));
    const sh = Math.max(1, Math.round(h * scale));
    const people = [];
    const used = new Set();
    for (const b of bodies) {
      const pad = Math.max(b.width, b.height) * 0.1;
      const x = Math.max(0, b.originX - pad);
      const y = Math.max(0, b.originY - pad);
      const rect = { x, y, w: Math.min(w, b.originX + b.width + pad) - x, h: Math.min(h, b.originY + b.height + pad) - y };
      const p = poseIn(source, rect, w, h, m);
      if (!p) continue;
      p.head = headFromPose(p.lm, w, h);
      p.zone = zoneFromPose(p.lm, w, h);
      const near = p.head ? grow(p.head, 1.6) : { ...rect, h: rect.h * 0.4 };
      const fi = faces.findIndex((f, i) => !used.has(i) && centerIn(f.box, near));
      if (fi >= 0) {
        used.add(fi);
        p.face = faces[fi];
        p.head = p.head ? union(p.head, p.face.box) : p.face.box;
      }
      // Reading skin is the slow part: only where it can matter.
      const maybeWoman = p.face?.female != null && p.face.female >= p.face.floor;
      if ((p.zone || maybeWoman || everyone) && partsOf(p, m)) Object.assign(p, skinOf(sw, sh, p, w));
      p.crop = null;
      people.push(p);
    }
    // A face with no body found around it, like a close-up.
    faces.forEach((f, i) => {
      if (!used.has(i)) people.push({ head: f.box, face: f });
    });

    for (const p of people) {
      p.female = p.face?.female ?? null;
      p.femaleFloor = p.face?.floor ?? FEMALE_UNSURE;
      p.exposed ??= null;
    }
    return people;
  }

  const union = (a, b) => {
    const x = Math.min(a.x, b.x);
    const y = Math.min(a.y, b.y);
    return { x, y, w: Math.max(a.x + a.w, b.x + b.w) - x, h: Math.max(a.y + a.h, b.y + b.h) - y };
  };

  /** Averages each video face's answers, so whether it is a woman doesn't flicker. */
  function faceCache() {
    let tracks = [];
    let frame = 0;
    return {
      next() {
        frame++;
        tracks = tracks.filter((t) => frame - t.seen < 30);
      },
      smooth(box, female) {
        let t = tracks.find((t) => overlap(t.box, box) > 0.3);
        if (!t) tracks.push((t = { sum: 0, n: 0 }));
        t.box = box;
        t.seen = frame;
        t.sum += female;
        t.n++;
        return t.sum / t.n;
      },
    };
  }

  function overlap(a, b) {
    const x = Math.max(0, Math.min(a.x + a.w, b.x + b.w) - Math.max(a.x, b.x));
    const y = Math.max(0, Math.min(a.y + a.h, b.y + b.h) - Math.max(a.y, b.y));
    const i = x * y;
    return i / (a.w * a.h + b.w * b.h - i);
  }

  // ───── What gets blurred ─────

  const normalize = (s) => s
    .toLowerCase()
    .replace(/[ً-ْـ]/g, '')
    .replace(/[أإآ]/g, 'ا')
    .replace(/ة/g, 'ه')
    .replace(/ى/g, 'ي');

  const WORDS = {
    none: ['لا', 'لاشي', 'خلها', 'خله', 'عادي', 'none', 'nothing', 'no'],
    all: ['كامل', 'كلها', 'كله', 'الكل', 'all', 'everything', 'whole'],
    face: ['وجه', 'وجوه', 'face', 'faces'],
    hair: ['شعر', 'hair'],
    women: ['مرا', 'مره', 'امراه', 'نساء', 'نسوان', 'حريم', 'حرمه', 'بنت', 'بنات', 'woman', 'women', 'girl', 'female'],
    awrah: ['عوره', 'فخذ', 'افخاذ', 'ركبه', 'ركب', 'شورت', 'ساق', 'سيقان', 'بطن', 'سره', 'awrah', 'thigh', 'thighs', 'leg', 'legs', 'shorts', 'knee', 'knees'],
    skin: ['جلد', 'ذراع', 'اذرع', 'ايدي', 'يدين', 'skin', 'arm', 'arms'],
    body: ['جسم', 'جسد', 'body'],
    mute: ['موسيقي', 'اغنيه', 'اغاني', 'صوت', 'اكتم', 'كتم', 'music', 'song', 'mute', 'sound'],
  };

  /** What the owner wrote, as the parts it names. "الوجه والشعر" → face, hair. */
  function readWords(text) {
    const found = new Set();
    // Each word as written and without a leading "and"/"the" (و، ال…), since وجه starts with و too.
    const tokens = normalize(text ?? '').split(/[\s،,.؛;:!؟?\-]+/).filter(Boolean)
      .flatMap((t) => [t, t.replace(/^(وال|بال|لل|فال|ال|و)(?=..)/, '')]);
    for (const [part, words] of Object.entries(WORDS)) {
      if (tokens.some((t) => words.some((w) => t === w || (w.length >= 3 && t.startsWith(w))))) found.add(part);
    }
    if (found.size > 1) found.delete('none');
    return found;
  }

  /**
   * The owner's answer (or none, when nobody answered in time) as what to do:
   * blur the unsure ones too? which parts did they name? what did they draw?
   */
  function readDecision(d) {
    const words = readWords(d?.text);
    const said = words.size > 0 && !words.has('none');
    return {
      unsure: !!d?.unsure || (!!d?.text?.trim() && !said && !words.has('none')),
      words,
      strokes: Array.isArray(d?.strokes) ? d.strokes : [],
    };
  }

  /** What to cover in one picture: heads (with the hair around them), zones, skin, or all of it. */
  function planFor(people, decision, w, h, femaleAt = FEMALE_SURE, exposedAt = EXPOSED_SURE) {
    const plan = { heads: [], zones: [], skins: [], masks: [], all: decision.words.has('all') };
    const { words } = decision;
    for (const p of people) {
      const woman = p.female != null && (
        p.female >= femaleAt || (p.female >= p.femaleFloor && (decision.unsure || words.has('women'))));
      const bare = p.exposed != null && (
        p.exposed >= exposedAt || (p.exposed >= EXPOSED_UNSURE && (decision.unsure || words.has('awrah'))));
      if (p.head && (woman || words.has('face') || words.has('hair'))) plan.heads.push(p.head);
      if (p.zone && (woman || bare || words.has('awrah'))) plan.zones.push(p.zone);
      if (p.skin && (woman || words.has('skin'))) plan.skins.push(p.skin);
      if (p.hair && (woman || words.has('hair'))) plan.skins.push(p.hair);
      if (p.cat && words.has('body')) plan.masks.push(p);
    }
    return plan;
  }

  /** A video's plan stays on for the next few frames, so it covers a little more in case they move. */
  function widen(plan) {
    return {
      ...plan,
      heads: plan.heads.map((b) => grow(b, 1.4)),
      zones: plan.zones.map((z) => z.map((s) => ({ ...s, width: s.width * 1.4 }))),
    };
  }

  const hasWork = (plan, strokes) =>
    plan.all || strokes.length > 0 || plan.heads.length + plan.zones.length + plan.skins.length + plan.masks.length > 0;

  /** Draws [source] with the plan's parts blurred, so strongly nothing shows through. */
  function render(source, w, h, plan, strokes, out = canvas(w, h)) {
    const ctx = out.getContext('2d');
    ctx.drawImage(source, 0, 0, w, h);
    if (!hasWork(plan, strokes)) return out;

    const cover = canvas(w, h);
    const c = cover.getContext('2d');
    c.fillStyle = '#000';
    c.strokeStyle = '#000';
    if (plan.all) c.fillRect(0, 0, w, h);
    for (const b of plan.heads) {
      // The face and the hair around it, down past the neck for long hair.
      c.beginPath();
      c.ellipse(b.x + b.w / 2, b.y + b.h * 0.45, b.w * 0.85, b.h * 0.8, 0, 0, Math.PI * 2);
      c.fill();
      c.fillRect(b.x - b.w * 0.35, b.y + b.h * 0.45, b.w * 1.7, b.h * 1.25);
    }
    for (const z of plan.zones) drawZone(c, z, 1);
    for (const s of plan.skins) {
      // A little wider than the skin or hair, so its edges don't show.
      for (const [dx, dy] of [[0, 0], [-1, 0], [1, 0], [0, -1], [0, 1]]) {
        const step = w / s.width;
        c.drawImage(s, dx * step, dy * step, w, h);
      }
    }
    for (const p of plan.masks) {
      const m = canvas(p.cw, p.ch);
      const data = m.getContext('2d').createImageData(p.cw, p.ch);
      for (let i = 0; i < p.cat.length; i++) data.data[i * 4 + 3] = p.cat[i] !== 0 ? 255 : 0;
      m.getContext('2d').putImageData(data, 0, 0);
      c.drawImage(m, p.rect.x, p.rect.y, p.rect.w, p.rect.h);
    }
    const side = Math.max(w, h);
    c.lineCap = 'round';
    c.lineJoin = 'round';
    for (const s of strokes) {
      const pts = s.points ?? [];
      if (pts.length < 2) continue;
      c.lineWidth = (s.width ?? 0.05) * side;
      c.beginPath();
      c.moveTo(pts[0] * w, pts[1] * h);
      for (let i = 2; i + 1 < pts.length; i += 2) c.lineTo(pts[i] * w, pts[i + 1] * h);
      if (pts.length === 2) c.lineTo(pts[0] * w + 0.1, pts[1] * h);
      c.stroke();
    }

    const blurred = canvas(w, h);
    const bctx = blurred.getContext('2d');
    const tiny = canvas(Math.max(2, w * 24 / side), Math.max(2, h * 24 / side));
    const tctx = tiny.getContext('2d');
    tctx.imageSmoothingQuality = 'high';
    tctx.drawImage(out, 0, 0, tiny.width, tiny.height);
    bctx.imageSmoothingQuality = 'high';
    bctx.drawImage(tiny, 0, 0, w, h);
    bctx.globalCompositeOperation = 'destination-in';
    bctx.drawImage(cover, 0, 0);
    ctx.drawImage(blurred, 0, 0);
    return out;
  }

  // ───── For the owner's look ─────

  const norm = (b, w, h) => ({ x: b.x / w, y: b.y / h, w: b.w / w, h: b.h / h });

  /** Why the owner is asked, and boxes around what to look at. */
  function findings(people, w, h, femaleSure = FEMALE_SURE, exposedSure = EXPOSED_SURE) {
    const reasons = new Set();
    const marks = [];
    let changes = false;
    for (const p of people) {
      const woman = p.female != null && p.female >= femaleSure;
      if (p.female != null && p.female >= p.femaleFloor && p.head) {
        if (!woman) reasons.add('gender');
        else changes = true;
        marks.push({ ...norm(p.head, w, h), kind: 'gender', sure: woman });
      }
      if (p.exposed != null && p.exposed >= EXPOSED_UNSURE && p.zone) {
        const sure = p.exposed >= exposedSure;
        if (sure) changes = true;
        else if (!woman) reasons.add('awrah');
        marks.push({ ...norm(zoneBox(p.zone), w, h), kind: 'awrah', sure: sure || woman });
      }
    }
    return { reasons, marks, changes };
  }

  function preview(source, w, h, plan) {
    const s = Math.min(1, PREVIEW / Math.max(w, h));
    const full = render(source, w, h, plan, []);
    const small = canvas(w * s, h * s);
    small.getContext('2d').drawImage(full, 0, 0, small.width, small.height);
    return small.toDataURL('image/jpeg', 0.8);
  }

  const toBytes = (c, type, quality) => new Promise((resolve, reject) => c.toBlob(async (b) => {
    if (!b) return reject(new Error('encode failed'));
    resolve(new Uint8Array(await b.arrayBuffer()));
  }, type, quality));

  // ───── Photos ─────

  async function analyzeImage(bytes) {
    const m = await loadVision();
    const decoded = await createImageBitmap(new Blob([bytes]), { imageOrientation: 'from-image' });
    const w = decoded.width;
    const h = decoded.height;
    const bitmap = canvas(w, h);
    bitmap.getContext('2d').drawImage(decoded, 0, 0);
    decoded.close();
    // Everyone's skin too, in case the owner asks for it.
    const people = await look(bitmap, w, h, m, null, true);
    const { reasons, marks, changes } = findings(people, w, h);
    const id = nextId++;
    sessions.set(id, { kind: 'image', bitmap, people, w, h });
    const sure = planFor(people, readDecision(null), w, h);
    return {
      id,
      kind: 'image',
      reasons: [...reasons],
      marks,
      changes,
      preview: reasons.size > 0 ? preview(bitmap, w, h, sure) : null,
    };
  }

  async function finishImage(s, d) {
    const decision = readDecision(d);
    const plan = planFor(s.people, decision, s.w, s.h);
    if (!hasWork(plan, decision.strokes)) return null;
    return toBytes(render(s.bitmap, s.w, s.h, plan, decision.strokes), 'image/jpeg', 0.88);
  }

  // ───── Videos ─────

  async function analyzeVideo(bytes, progress) {
    const mb = await loadMedia();
    const input = new mb.Input({ source: new mb.BufferSource(bytes), formats: mb.ALL_FORMATS });
    const track = await input.getPrimaryVideoTrack();
    const sound = await input.getPrimaryAudioTrack();
    const duration = await input.computeDuration();

    const reasons = new Set();
    const marks = [];
    let previewUrl = null;
    let womenFound = false;
    let bareFound = false;

    if (track) {
      if (!(await track.canDecode())) throw new Error('video cannot be read here');
      const m = await loadVision();
      const sink = new mb.CanvasSink(track, { width: Math.min(track.displayWidth, SAMPLE_WIDTH), poolSize: 1 });
      const n = Math.max(1, Math.min(VIDEO_SAMPLES, Math.ceil(duration / VIDEO_SAMPLE_EVERY)));
      const times = Array.from({ length: n }, (_, i) => (i + 0.5) * duration / n);
      // One odd frame proves little: a finding counts once it shows up in two.
      const enough = Math.min(2, n);
      const seen = { gender: 0, awrah: 0, women: 0, bare: 0 };
      let i = 0;
      let bestScore = 0;
      for await (const frame of sink.canvasesAtTimestamps(times)) {
        progress?.(0.7 * ++i / n);
        if (!frame) continue;
        const c = frame.canvas;
        const people = await look(c, c.width, c.height, m);
        const f = findings(people, c.width, c.height);
        f.reasons.forEach((r) => seen[r]++);
        if (people.some((p) => p.female != null && p.female >= FEMALE_SURE)) seen.women++;
        if (people.some((p) => p.exposed != null && p.exposed >= EXPOSED_SURE)) seen.bare++;
        // The owner sees the frame that raised the most doubt, else the most found.
        const score = f.reasons.size * 10 + f.marks.length;
        if (score > bestScore) {
          bestScore = score;
          marks.splice(0, marks.length, ...f.marks);
          previewUrl = preview(c, c.width, c.height, planFor(people, readDecision(null), c.width, c.height));
        }
      }
      womenFound = seen.women >= enough;
      bareFound = seen.bare >= enough;
      if (seen.gender + seen.women >= enough && !womenFound) reasons.add('gender');
      if (seen.awrah + seen.bare >= enough && !bareFound) reasons.add('awrah');
    }

    let music = 0;
    if (sound && (await sound.canDecode())) music = await musicShare(mb, sound, duration, (p) => progress?.(0.7 + 0.3 * p));
    const changes = womenFound || bareFound || music >= MUSIC_SURE;

    if (reasons.size > 0 && !previewUrl && track) {
      const sink = new mb.CanvasSink(track, { width: Math.min(track.displayWidth, PREVIEW), poolSize: 1 });
      const first = await sink.getCanvas(Math.min(1, duration / 2));
      if (first) previewUrl = first.canvas.toDataURL('image/jpeg', 0.8);
    }

    const id = nextId++;
    sessions.set(id, { kind: 'video', bytes, music, womenFound, bareFound, blurFound: womenFound || bareFound });
    return { id, kind: 'video', reasons: [...reasons], marks, changes, preview: reasons.size > 0 ? previewUrl : null };
  }

  /** Share of the sound's seconds that YAMNet hears as music. */
  async function musicShare(mb, sound, duration, progress) {
    const classifier = await loadAudio();
    const sink = new mb.AudioSampleSink(sound);
    let rate = 0;
    let chunk = [];
    let length = 0;
    let windows = 0;
    let musical = 0;
    const flush = () => {
      if (length === 0) return;
      const data = new Float32Array(length);
      let at = 0;
      for (const part of chunk) {
        data.set(part, at);
        at += part.length;
      }
      chunk = [];
      length = 0;
      for (const r of classifier.classify(data, rate)) {
        windows++;
        const top = r.classifications[0]?.categories ?? [];
        const music = top.find((c) => c.categoryName === 'Music')?.score ?? 0;
        const instrument = Math.max(0, ...top.filter((c) => INSTRUMENTS.test(c.categoryName)).map((c) => c.score));
        if (music >= MUSIC_SCORE && instrument >= INSTRUMENT_SCORE) musical++;
      }
    };
    for await (const sample of sink.samples()) {
      if (rate && sample.sampleRate !== rate) flush();
      rate = sample.sampleRate;
      const mono = new Float32Array(sample.numberOfFrames);
      const part = new Float32Array(sample.numberOfFrames);
      for (let ch = 0; ch < sample.numberOfChannels; ch++) {
        sample.copyTo(part, { planeIndex: ch, format: 'f32-planar' });
        for (let i = 0; i < part.length; i++) mono[i] += part[i] / sample.numberOfChannels;
      }
      const end = sample.timestamp + sample.duration;
      sample.close();
      chunk.push(mono);
      length += mono.length;
      if (length >= rate * 10) {
        flush();
        if (duration > 0) progress?.(Math.min(1, end / duration));
      }
    }
    flush();
    return windows > 0 ? musical / windows : 0;
  }

  async function finishVideo(s, d, progress) {
    const decision = readDecision(d);
    const mute = s.music >= MUSIC_SURE || decision.words.has('mute');
    const blur = s.blurFound || decision.unsure || decision.strokes.length > 0
      || ['all', 'face', 'hair', 'women', 'awrah', 'skin', 'body'].some((p) => decision.words.has(p));
    if (!mute && !blur) return null;

    const mb = await loadMedia();
    const input = new mb.Input({ source: new mb.BufferSource(s.bytes), formats: mb.ALL_FORMATS });
    const output = new mb.Output({ format: new mb.Mp4OutputFormat({ fastStart: 'in-memory' }), target: new mb.BufferTarget() });
    // Once a woman or bare skin was seen, the bar drops for the rest of the video,
    // so one doubtful frame doesn't show her.
    const femaleAt = s.womenFound || decision.unsure ? FEMALE_UNSURE : FEMALE_SURE;
    const exposedAt = s.bareFound || decision.unsure ? EXPOSED_UNSURE : EXPOSED_SURE;
    let video = {};
    if (blur) {
      const m = await loadVision();
      const cache = faceCache();
      let frame = null;
      let out = null;
      let plan = null;
      let lookedAt = -Infinity;
      video = {
        forceTranscode: true,
        codec: 'avc',
        process: async (sample) => {
          const w = sample.displayWidth;
          const h = sample.displayHeight;
          if (frame?.width !== w || frame?.height !== h) {
            frame = canvas(w, h);
            out = canvas(w, h);
            plan = null;
          }
          sample.draw(frame.getContext('2d'), 0, 0, w, h);
          if (!plan || Math.abs(sample.timestamp - lookedAt) >= VIDEO_LOOK_EVERY) {
            lookedAt = sample.timestamp;
            cache.next();
            const people = await look(frame, w, h, m, cache, decision.words.has('skin') || decision.words.has('body'));
            plan = widen(planFor(people, decision, w, h, femaleAt, exposedAt));
          }
          return render(frame, w, h, plan, decision.strokes, out);
        },
      };
      const track = await input.getPrimaryVideoTrack();
      if (track && track.displayWidth > VIDEO_WIDTH) video.width = VIDEO_WIDTH;
      // H.264 plays everywhere; without an encoder for it, whatever this device can make.
      if (!(await mb.canEncodeVideo('avc', { width: Math.min(track?.displayWidth ?? 640, VIDEO_WIDTH), height: 720 }))) delete video.codec;
    }
    const conversion = await mb.Conversion.init({ input, output, video, audio: mute ? { discard: true } : {} });
    if (!conversion.isValid || conversion.discardedTracks.some((t) => t.track.type === 'video')) {
      const why = conversion.discardedTracks.map((t) => `${t.track.type}: ${t.reason}`).join(', ');
      throw new Error(`video cannot be converted here (${why})`);
    }
    conversion.onProgress = (p) => progress?.(p);
    await conversion.execute();
    return new Uint8Array(output.target.buffer);
  }

  // ───── For the app ─────

  return {
    /** Looks at a photo or video; resolves to what was found, as JSON. */
    async analyze(kind, bytes, progress) {
      const result = kind === 'video' ? await analyzeVideo(bytes, progress) : await analyzeImage(bytes);
      return JSON.stringify(result);
    },

    /**
     * The file to send after [decision] (JSON, or empty when nobody answered),
     * or null when the original can go as it is.
     */
    async finish(id, decision, progress) {
      const s = sessions.get(id);
      if (!s) throw new Error('unknown check');
      const d = decision ? JSON.parse(decision) : null;
      return s.kind === 'video' ? finishVideo(s, d, progress) : finishImage(s, d);
    },

    drop(id) {
      const s = sessions.get(id);
      s?.bitmap?.close?.();
      sessions.delete(id);
    },

    /** What the owner's words turn into, for checking new ones. */
    readWords: (text) => [...readWords(text)],

    /** The raw scores of a checked photo, for tuning the bars. */
    scores: (id) => sessions.get(id)?.people?.map((p) => ({
      female: p.female == null ? null : +p.female.toFixed(2),
      exposed: p.exposed == null ? null : +p.exposed.toFixed(2),
      face: p.face ? Math.round(p.face.box.w) : null,
      body: !!p.zone,
    })),
  };
})();
