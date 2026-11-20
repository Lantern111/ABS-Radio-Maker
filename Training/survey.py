"""Reports, for each recording, how much of it is the microphone alone: stretches where left and right are identical
(the mic is mono, background music is stereo) and the voice drops to near silence between phrases."""
import sys, wave, glob, os
import numpy as np

def load(path):
    with wave.open(path, 'rb') as w:
        if w.getsampwidth() != 2 or w.getnchannels() != 2:
            return None, w.getframerate(), (w.getsampwidth(), w.getnchannels())
        data = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).reshape(-1, 2)
        return data, w.getframerate(), None

def clean_mic_seconds(data, rate):
    second = rate
    chunks = len(data) // second
    clean = 0
    mono = 0
    for c in range(chunks):
        block = data[c * second:(c + 1) * second].astype(np.int32)
        if np.any(block[:, 0] != block[:, 1]):
            continue
        mono += 1
        # 20 ms levels: a clean mic has near-silent gaps; a mono music bed doesn't.
        frames = block[:, 0].reshape(-1, rate // 50).astype(np.float64)
        levels = 10 * np.log10(np.mean(frames ** 2, axis=1) + 1)
        if levels.max() - levels.min() > 35:
            clean += 1
    return chunks, mono, clean

for path in sorted(glob.glob(os.path.join(sys.argv[1], '*.wav'))):
    if os.path.getsize(path) < 50_000_000:
        continue
    data, rate, odd = load(path)
    name = os.path.basename(path)
    if data is None:
        print(f'{name}: skipped, format {odd} at {rate} Hz')
        continue
    chunks, mono, clean = clean_mic_seconds(data, rate)
    print(f'{name:32s} {rate} Hz {chunks/60:5.1f} min  mono {mono/60:5.1f} min  clean mic {clean/60:5.1f} min')
