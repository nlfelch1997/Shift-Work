#!/usr/bin/env python3
"""Builds every file in res://audio/ from its sources (see audio/CREDITS.md).

Two kinds of file:
- SOURCED: trimmed / mixed / normalized from CC0 packs (Kenney, Freesound via
  the Godot demo projects) and one CC-BY music track (Kevin MacLeod). The raw
  packs aren't checked in; clone them (commits pinned in CREDITS.md) under
  SRC_ROOT and re-run this to regenerate.
- SYNTHESIZED: made from scratch here (oscillators + filtered noise), for the
  effects no free pack had a good match for. Original work, CC0 like the rest.

    pip install numpy scipy        # plus ffmpeg with libvorbis on PATH
    SRC_ROOT=/path/to/clones python3 tools/build_audio.py

Every SFX comes out mono 44.1kHz Ogg Vorbis, peak-normalized; how loud each
one plays in game is set in Sfx.gd, not baked in here.
"""
import os
import subprocess
import sys

import numpy as np
from scipy import signal

SR = 44100
HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "audio")
SRC = os.environ.get("SRC_ROOT", "/home/user")

KENNEY_IFACE = SRC + "/ext/Calinou_kenney-interface-sounds/addons/kenney_interface_sounds/"
KENNEY_UI = SRC + "/ext/Calinou_kenney-ui-audio/addons/kenney_ui_audio/"
KIT_PLATFORMER = SRC + "/kenneynl/starter-kit-3d-platformer/sounds/"
KIT_FPS = SRC + "/kenneynl/starter-kit-fps/sounds/"
KIT_RACING = SRC + "/kenneynl/starter-kit-racing/audio/"
KIT_CITY = SRC + "/kenneynl/starter-kit-city-builder/sounds/"
GDP_SFX = SRC + "/ext/gdp/audio/audio_effects/sfx/"
GDP_RAGDOLL = SRC + "/ext/gdp/3d/ragdoll_physics/sounds/"

rng = np.random.default_rng(7) # fixed: the synthesized files rebuild identically


# --- I/O ----------------------------------------------------------------------

def load(path, start=0.0, end=None):
	raw = subprocess.run(["ffmpeg", "-v", "error", "-i", path, "-f", "f32le", "-ac", "1", "-ar", str(SR), "-"], capture_output=True, check=True).stdout
	x = np.frombuffer(raw, dtype=np.float32).astype(np.float64)
	a = int(start * SR)
	b = len(x) if end is None else int(end * SR)
	return x[a:b].copy()


def write(name, x, peak=0.7, quality=4, stereo=None):
	"""Peak-normalizes and encodes res://audio/<name>.ogg."""
	path = os.path.join(OUT, name + ".ogg")
	os.makedirs(os.path.dirname(path), exist_ok=True)
	data = x if stereo is None else stereo
	m = np.abs(data).max()
	if m > 0:
		data = data * (peak / m)
	channels = 1 if stereo is None else 2
	pcm = data.astype(np.float32).tobytes() if stereo is None else data.T.astype(np.float32).tobytes()
	subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "f32le", "-ar", str(SR), "-ac", str(channels), "-i", "-", "-c:a", "libvorbis", "-q:a", str(quality), path], input=pcm, check=True)
	print("%-32s %5.2fs %6.1f KB" % (name, len(data if stereo is None else data[0]) / SR, os.path.getsize(path) / 1024.0))


# --- helpers ------------------------------------------------------------------

def t_axis(seconds):
	return np.arange(int(seconds * SR)) / SR


def fade(x, fin=0.003, fout=0.02):
	x = x.copy()
	a = min(len(x), int(fin * SR))
	b = min(len(x), int(fout * SR))
	if a:
		x[:a] *= np.linspace(0, 1, a)
	if b:
		x[-b:] *= np.linspace(1, 0, b)
	return x


def trim_silence(x, thresh=0.01):
	idx = np.where(np.abs(x) > thresh * np.abs(x).max())[0]
	return x[idx[0]:idx[-1] + 1] if len(idx) else x


def mix(parts, length=None):
	"""parts: [(signal, start_seconds, gain)]"""
	end = max(int(s * SR) + len(p) for p, s, g in parts)
	out = np.zeros(max(end, int((length or 0) * SR)))
	for p, s, g in parts:
		a = int(s * SR)
		out[a:a + len(p)] += p * g
	return out


def resample(x, factor):
	"""Plays x `factor` times faster (pitch up for factor > 1)."""
	n = int(len(x) / factor)
	return np.interp(np.arange(n) * factor, np.arange(len(x)), x)


def noise(seconds):
	return rng.standard_normal(int(seconds * SR))


def sweep_lowpass(x, cutoffs):
	"""One-pole lowpass whose cutoff (Hz) follows `cutoffs` sample by sample."""
	y = np.zeros_like(x)
	state = 0.0
	alpha = 1.0 - np.exp(-2.0 * np.pi * cutoffs / SR)
	for i in range(len(x)):
		state += alpha[i] * (x[i] - state)
		y[i] = state
	return y


def highpass(x, hz, order=2):
	return signal.sosfilt(signal.butter(order, hz, "highpass", fs=SR, output="sos"), x)


def lowpass(x, hz, order=2):
	return signal.sosfilt(signal.butter(order, hz, "lowpass", fs=SR, output="sos"), x)


def osc(freq, seconds, harmonics=((1, 1.0),), phase_freq=None):
	"""Additive oscillator; freq may be a scalar or a per-sample array (glides)."""
	t = t_axis(seconds)
	f = np.full(len(t), float(freq)) if np.isscalar(freq) else freq[:len(t)]
	ph = 2.0 * np.pi * np.cumsum(f) / SR
	out = np.zeros(len(t))
	for n, a in harmonics:
		out += a * np.sin(n * ph)
	return out


def env_ar(seconds, attack, tau):
	t = t_axis(seconds)
	return np.minimum(t / max(attack, 1e-4), 1.0) * np.exp(-np.maximum(t - attack, 0.0) / tau)


def midi(n):
	return 440.0 * 2.0 ** ((n - 69) / 12.0)


# --- synthesized SFX ------------------------------------------------------------

def forklift_beep():
	# A real backup beeper: ~1kHz, squarish, hard on/off.
	s = osc(1050.0, 0.24, ((1, 1.0), (3, 0.28), (5, 0.12)))
	return fade(s, 0.006, 0.02)


def forklift_alert():
	# The ram telegraph ("!!"): two quick higher chirps.
	b = fade(osc(1480.0, 0.07, ((1, 1.0), (3, 0.25))), 0.004, 0.012)
	return mix([(b, 0.0, 1.0), (b, 0.11, 1.0)])


def throw_whoosh():
	d = 0.3
	t = t_axis(d)
	cut = 500.0 + 2600.0 * np.sin(np.pi * t / d) ** 2
	amp = np.sin(np.pi * t / d) ** 1.5
	return highpass(sweep_lowpass(noise(d), cut) * amp, 250.0)


def spill_splat():
	d = 0.42
	t = t_axis(d)
	burst = lowpass(noise(d), 1600.0) * np.exp(-t / 0.05)
	blorp = osc(80.0 + 220.0 * np.exp(-t / 0.06), d) * np.exp(-t / 0.13)
	drop = fade(osc(1600.0 + 9000.0 * t_axis(0.03), 0.03), 0.002, 0.01)
	return mix([(burst, 0.0, 0.8), (blorp, 0.005, 1.0), (drop, 0.14, 0.18), (resample(drop, 1.3), 0.23, 0.12)])


def mop_swish(variant):
	d = 0.42 if variant == 0 else 0.36
	t = t_axis(d)
	cut = 350.0 + (1300.0 if variant == 0 else 1000.0) * np.sin(np.pi * t / d)
	wet = 1.0 + 0.35 * np.sin(2 * np.pi * (17.0 if variant == 0 else 21.0) * t) # the squelch
	return highpass(sweep_lowpass(noise(d), cut) * np.sin(np.pi * t / d) * wet, 150.0)


def bonk():
	# Cartoon "BONK" + a little spring "boing" — a forklift bumping a person
	# is slapstick, not injury.
	block = osc(700.0, 0.12, ((1, 1.0), (2.76, 0.4))) * env_ar(0.12, 0.001, 0.035)
	t = t_axis(0.55)
	f = 230.0 * (1.0 + 0.22 * np.sin(2 * np.pi * 13.0 * t) * np.exp(-t / 0.3))
	boing = osc(f, 0.55, ((1, 1.0), (2, 0.2))) * env_ar(0.55, 0.004, 0.2)
	return fade(mix([(block, 0.0, 1.0), (boing, 0.02, 0.55)]), 0.001, 0.05)


def bell(freq, seconds, decay=1.0):
	t = t_axis(seconds)
	out = np.zeros(len(t))
	for ratio, amp, d in ((1.0, 1.0, decay), (2.0, 0.45, decay * 0.5), (2.76, 0.22, decay * 0.35), (5.4, 0.08, decay * 0.18)):
		out += amp * np.sin(2 * np.pi * freq * ratio * t) * np.exp(-t / d)
	return out * np.minimum(t / 0.002, 1.0)


def pa_chime():
	# "Attention shoppers": a bright three-tone up-chime (C E G), unmistakably
	# a store announcement, not an alarm.
	return fade(mix([(bell(midi(72), 1.2, 0.7), 0.0, 1.0), (bell(midi(76), 1.2, 0.7), 0.16, 0.9), (bell(midi(79), 1.4, 0.9), 0.32, 1.0)]), 0.001, 0.15)


def brass(freq, seconds, bright=1.0):
	"""Additive brass-ish tone: harmonics open up during the attack."""
	t = t_axis(seconds)
	f = np.full(len(t), float(freq)) if np.isscalar(freq) else freq[:len(t)]
	ph = 2.0 * np.pi * np.cumsum(f) / SR
	opening = np.minimum(t / 0.06, 1.0) * bright
	out = np.zeros(len(t))
	for n in range(1, 16):
		out += np.sin(n * ph) / n * np.exp(-(n - 1) * (1.15 - opening) * 0.9)
	return out * np.minimum(t / 0.012, 1.0)


def final_shift_fanfare():
	# "Ta-ta-ta TAAA!" in C major: game-show big, not ominous.
	trip = 0.115
	notes = []
	for i in range(3):
		n = brass(midi(67), trip * 0.9) * np.exp(-t_axis(trip * 0.9) / 0.2)
		notes.append((fade(n, 0.002, 0.015), i * trip, 0.8))
	long = 1.25
	t = t_axis(long)
	vib = 1.0 + 0.006 * np.sin(2 * np.pi * 5.5 * t) * np.minimum(t / 0.4, 1.0)
	held = np.zeros(len(t))
	for m, g in ((72, 1.0), (76, 0.6), (79, 0.55), (60, 0.45)):
		held += g * brass(midi(m) * vib, long)
	held *= np.exp(-t / 0.9) * 0.9 + 0.1
	held = fade(held, 0.005, 0.35)
	roll = highpass(noise(3 * trip), 1800.0) * (0.5 + 0.5 * np.sin(2 * np.pi * 26.0 * t_axis(3 * trip)) ** 2) * np.linspace(0.3, 1.0, int(3 * trip * SR))
	crash = highpass(noise(1.2), 4000.0) * np.exp(-t_axis(1.2) / 0.35)
	return mix(notes + [(held, 3 * trip, 0.8), (roll, 0.0, 0.18), (crash, 3 * trip, 0.25)])


def flicker_sting():
	# The lights cut: the fluorescent hum dies with a "bwoop", then a
	# startled cartoon "boo-WOMP" on a goofy low reed. Comedy, never horror —
	# a major-ish fall, short, nothing sustained or droning.
	hum_d = 0.32
	th = t_axis(hum_d)
	hum_f = np.where(th < 0.2, 120.0, 120.0 * np.exp(-(th - 0.2) / 0.06))
	hum = osc(hum_f, hum_d, ((1, 0.6), (2, 1.0), (3, 0.5), (4, 0.3))) * np.where(th < 0.2, 1.0, np.exp(-(th - 0.2) / 0.05))
	reed_h = ((1, 1.0), (3, 0.45), (5, 0.25), (7, 0.12))
	boo_d = 0.17
	boo = osc(midi(57), boo_d, reed_h) * env_ar(boo_d, 0.01, 0.4)
	womp_d = 0.55
	tw = t_axis(womp_d)
	womp_f = midi(50) * (1.0 - 0.18 * np.clip((tw - 0.12) / 0.4, 0, 1)) * (1.0 + 0.02 * np.sin(2 * np.pi * 6.0 * tw))
	womp = osc(womp_f, womp_d, reed_h) * env_ar(womp_d, 0.012, 0.5)
	return fade(mix([(hum, 0.0, 0.35), (fade(boo, 0.005, 0.03), 0.3, 1.0), (fade(womp, 0.005, 0.12), 0.49, 1.0)]), 0.002, 0.05)


# --- synthesized music: the calm prep/cleanup loop -------------------------------

def epiano(freq, seconds, vel=1.0):
	t = t_axis(seconds)
	index = 1.6 * np.exp(-t / 0.35) + 0.25
	mod = np.sin(2 * np.pi * freq * t) * index
	car = np.sin(2 * np.pi * freq * t + mod) + 0.15 * np.sin(4 * np.pi * freq * t)
	return car * env_ar(seconds, 0.004, 0.9) * vel


def bass(freq, seconds):
	t = t_axis(seconds)
	return (np.sin(2 * np.pi * freq * t) + 0.25 * np.sin(4 * np.pi * freq * t)) * env_ar(seconds, 0.006, 0.35)


def vibes(freq, seconds):
	t = t_axis(seconds)
	trem = 1.0 + 0.25 * np.sin(2 * np.pi * 5.0 * t)
	return (np.sin(2 * np.pi * freq * t) + 0.12 * np.sin(2 * np.pi * 4.0 * freq * t) * np.exp(-t / 0.08)) * env_ar(seconds, 0.003, 0.7) * trem


def prep_loop():
	"""40s of lazy supermarket muzak, 96 BPM, loops seamlessly."""
	bpm = 96.0
	beat = 60.0 / bpm
	bar = 4 * beat
	bars = 16
	length = bars * bar
	# (root midi, chord tones)
	prog = [(53, [57, 60, 64]), (52, [55, 59, 62]), (50, [53, 57, 60]), (48, [52, 55, 59]),
			(53, [57, 60, 64]), (52, [55, 59, 62]), (50, [53, 57, 60]), (43, [53, 59, 62]),
			(53, [57, 60, 64]), (52, [55, 59, 62]), (50, [53, 57, 60]), (48, [52, 55, 59]),
			(45, [52, 55, 60]), (50, [53, 57, 60]), (43, [53, 59, 62]), (48, [52, 55, 59])]
	melody = {8: [(0, 76), (1.5, 74), (2, 72)], 9: [(0, 71), (2, 74)], 10: [(0, 72), (1.5, 69), (2.5, 72)], 11: [(0, 71), (2, 67)],
			  12: [(0, 72), (1, 76), (2, 79)], 13: [(0, 77), (1.5, 76), (2.5, 74)], 14: [(0, 74), (2, 71)], 15: [(0, 72)]}
	parts = []
	for b, (root, chord) in enumerate(prog):
		t0 = b * bar
		for hit, vel in ((0.0, 0.55), (1.5, 0.35), (2.5, 0.4)):
			for m in chord:
				parts.append((epiano(midi(m), 1.4, vel), t0 + hit * beat, 0.22))
		parts.append((bass(midi(root - 12), 1.0), t0, 0.55))
		parts.append((bass(midi(root - 12 + 7), 0.8), t0 + 2 * beat, 0.4))
		for k in range(4):
			hat = highpass(noise(0.05), 6000.0) * np.exp(-t_axis(0.05) / 0.012)
			parts.append((hat, t0 + (k + 0.5) * beat, 0.05))
		for off, m in melody.get(b, []):
			parts.append((vibes(midi(m), 1.6), t0 + off * beat, 0.28))
	full = mix(parts)
	n = int(length * SR)
	loop = full[:n].copy()
	tail = full[n:]
	loop[:len(tail)] += tail # wrap the reverb-less tails onto the start: seamless loop
	# A little width: a tiny delay on one side.
	left = loop
	right = np.roll(loop, int(0.011 * SR))
	return np.vstack([left, right])


# --- the build ------------------------------------------------------------------

def build():
	K = KENNEY_IFACE
	# Movement / interaction (Kenney, CC0).
	steps = load(KIT_FPS + "walking.ogg")
	env = np.convolve(np.abs(steps), np.ones(441) / 441, mode="same")
	onsets = []
	i = 0
	while i < len(env) and len(onsets) < 6:
		if env[i] > 0.25 * env.max():
			onsets.append(max(0, i - int(0.01 * SR)))
			i += int(0.3 * SR)
		i += 1
	for n, a in enumerate(onsets):
		write("sfx/footstep_%d" % (n + 1), fade(steps[a:a + int(0.2 * SR)], 0.002, 0.06), peak=0.6)
	write("sfx/pickup", fade(trim_silence(load(K + "pluck_002.wav")), 0.001, 0.02))
	write("sfx/drop", fade(trim_silence(load(K + "drop_002.wav")), 0.001, 0.02))
	write("sfx/place_shelf", fade(trim_silence(load(KIT_CITY + "placement-a.ogg")), 0.001, 0.02))
	write("sfx/throw_whoosh", throw_whoosh())
	# Impacts (Freesound CC0 via the Godot demos, Kenney CC0).
	write("sfx/impact_light", fade(trim_silence(load(GDP_RAGDOLL + "impact_small.wav"))[:int(0.45 * SR)], 0.001, 0.12))
	write("sfx/impact_heavy", fade(trim_silence(load(GDP_RAGDOLL + "impact_big.wav"))[:int(0.5 * SR)], 0.001, 0.15))
	write("sfx/box_thud", fade(trim_silence(load(KIT_PLATFORMER + "land.ogg")), 0.001, 0.01))
	land = trim_silence(load(KIT_PLATFORMER + "land.ogg"))
	big = trim_silence(load(GDP_RAGDOLL + "impact_big.wav"))[:int(0.5 * SR)]
	small = trim_silence(load(GDP_RAGDOLL + "impact_small.wav"))[:int(0.35 * SR)]
	brk = trim_silence(load(KIT_PLATFORMER + "break.ogg"))
	collapse = mix([(big, 0.0, 0.8), (brk, 0.04, 0.7), (land, 0.17, 0.9), (resample(land, 0.8), 0.26, 0.8), (small, 0.31, 0.6), (resample(land, 1.15), 0.42, 0.6), (resample(land, 0.9), 0.55, 0.45)])
	write("sfx/stack_collapse", fade(collapse, 0.001, 0.1))
	crunch = trim_silence(load(KIT_RACING + "impact.ogg"))
	write("sfx/forklift_ram", fade(mix([(crunch, 0.0, 1.0), (big, 0.01, 0.6)]), 0.001, 0.15))
	write("sfx/glass_break", fade(trim_silence(load(GDP_SFX + "glass_breaking.wav"), 0.05)[:int(1.2 * SR)], 0.001, 0.3))
	# Forklift.
	engine = load(KIT_RACING + "engine.ogg")
	write("sfx/forklift_engine_loop", engine, peak=0.6, quality=2) # Kenney's own seamless loop, untrimmed
	write("sfx/forklift_beep", forklift_beep())
	write("sfx/forklift_alert", forklift_alert())
	write("sfx/forklift_bonk", bonk())
	# Manager (Freesound CC0 via the Godot demos).
	whistle = load(GDP_SFX + "Whistle.wav")
	write("sfx/manager_whistle", fade(whistle[int(0.4 * SR):int(1.3 * SR)], 0.002, 0.12))
	write("sfx/manager_tweet", fade(whistle[int(0.43 * SR):int(0.62 * SR)], 0.002, 0.04))
	write("sfx/writeup_trombone", fade(load(GDP_SFX + "sad_trombone.wav", 0.18, 4.85), 0.005, 0.4))
	# Priority orders.
	write("sfx/order_chime", pa_chime())
	write("sfx/order_filled", fade(trim_silence(load(K + "confirmation_002.wav")), 0.001, 0.05))
	write("sfx/order_missed", fade(trim_silence(load(GDP_SFX + "negative_beeps.wav"))[:int(0.95 * SR)], 0.002, 0.08))
	# Floor spills, lights, finale.
	write("sfx/spill_splat", spill_splat())
	write("sfx/flicker_sting", flicker_sting())
	write("final_shift", final_shift_fanfare(), peak=0.75)
	# Register, store, report.
	ding = load(GDP_SFX + "Ding.wav")
	write("sfx/register_ding", fade(trim_silence(ding)[:int(0.55 * SR)], 0.001, 0.25))
	write("sfx/store_open_bell", fade(trim_silence(ding)[:int(1.6 * SR)], 0.001, 0.6))
	coin = trim_silence(load(KIT_PLATFORMER + "coin.ogg"))
	drawer = trim_silence(load(KENNEY_UI + "switch7.wav"))
	write("sfx/paycheck_chaching", fade(mix([(drawer, 0.0, 0.7), (coin, 0.07, 0.8), (trim_silence(ding)[:int(1.0 * SR)], 0.1, 0.55)]), 0.001, 0.3))
	# Cleanup.
	write("sfx/mop_swish_1", mop_swish(0))
	write("sfx/mop_swish_2", mop_swish(1))
	write("sfx/broom_sweep_1", fade(trim_silence(load(K + "scratch_001.wav")), 0.002, 0.03))
	write("sfx/broom_sweep_2", fade(trim_silence(load(K + "scratch_002.wav")), 0.002, 0.03))
	write("sfx/clean_chime", fade(trim_silence(load(K + "confirmation_003.wav")), 0.001, 0.05))
	write("sfx/all_clean", fade(mix([(trim_silence(load(K + "confirmation_004.wav")), 0.0, 1.0), (trim_silence(load(K + "glass_003.wav")), 0.18, 0.6)]), 0.001, 0.1))
	write("sfx/pan_dump", fade(trim_silence(load(KIT_CITY + "removal-a.ogg")), 0.001, 0.08))
	write("sfx/clock_out", fade(mix([(trim_silence(load(KENNEY_UI + "switch2.wav")), 0.0, 0.8), (trim_silence(load(K + "bong_001.wav")), 0.06, 1.0)]), 0.001, 0.05))
	# UI.
	write("sfx/ui_click", fade(trim_silence(load(KENNEY_UI + "click1.wav")), 0.001, 0.01))
	write("sfx/ui_buy", fade(trim_silence(load(K + "confirmation_001.wav")), 0.001, 0.05))
	# Music.
	write("music/prep_loop", None, peak=0.6, quality=3, stereo=prep_loop())
	subprocess.run(["cp", GDP_SFX + "music_monkeys_spinning_monkeys.ogg", os.path.join(OUT, "music", "selling_loop.ogg")], check=True) # untouched: already a compact Ogg
	print("music/selling_loop (copied as-is)")


if __name__ == "__main__":
	build()
