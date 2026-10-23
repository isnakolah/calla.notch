#!/usr/bin/env python3
"""Encode frames exported by the actual demo app, retaining its native timing."""
import argparse
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--frames', type=Path, default=Path('/private/tmp/calla-landing-frames'))
parser.add_argument('--name', default='weekly-check-in')
parser.add_argument('--mobile', action='store_true')
parser.add_argument('--zen', action='store_true', help='Crop the native ambient summary to its slim 4:1 canvas.')
parser.add_argument('--stem', help='Unique alpha asset stem; also names the opaque poster to preserve original exports.')
args = parser.parse_args()
metadata = json.loads((args.frames / 'frames.json').read_text())
frames = metadata['frames']
concat = []
for index, frame in enumerate(frames):
    # Paths in the exporter are generated filenames, never user input.
    path = (args.frames / frame['file']).resolve()
    if "'" in str(path):
        raise SystemExit('Export path must not contain a quote.')
    end = frames[index + 1]['at'] if index + 1 < len(frames) else metadata['duration']
    concat.extend([f"file '{path}'", f'duration {max(.01, end - frame["at"]):.6f}'])
concat.append(f"file '{(args.frames / frames[-1]['file']).resolve()}'")
listing = args.frames / 'frames.ffconcat'
listing.write_text('\n'.join(concat) + '\n')
output = ROOT / 'public/demo'
movie = output / f'{args.name}.mp4'
dimensions = '1200x300' if args.zen else ('1200x560' if args.mobile else '1600x880')
width, height = dimensions.split('x')
subprocess.run([
    'ffmpeg', '-hide_banner', '-loglevel', 'error', '-y', '-f', 'concat', '-safe', '0', '-i', str(listing),
    '-filter_complex', f'color=c=0x03070d:s={dimensions}:r=30[bg];[0:v]crop={width}:{height}:(iw-{width})/2:0[fg];[bg][fg]overlay=shortest=1,format=yuv420p[out]',
    '-map', '[out]', '-r', '30', '-t', '45', '-c:v', 'libx264', '-preset', 'slow', '-crf', '19', '-movflags', '+faststart', str(movie),
], check=True)
poster = f'{args.stem}-fallback-poster.jpg' if args.stem else ('mobile-poster.jpg' if args.mobile else 'poster.jpg')
subprocess.run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y', '-ss', '22', '-i', str(movie), '-frames:v', '1', '-q:v', '2', str(output / poster)], check=True)
print(f'Encoded {len(frames)} actual native app frames → {movie.name}')

# Alpha footage lets the genuine native notch blend into the browser scene.
stem = args.stem or ('notch-mobile' if args.mobile else 'notch')
alpha_width, alpha_height = (1200, 300) if args.zen else ((1200, 560) if args.mobile else (1440, 820))
alpha_crop = f'crop={alpha_width}:{alpha_height}:(iw-{alpha_width})/2:0,scale=960:-2'
subprocess.run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y', '-f', 'concat', '-safe', '0', '-i', str(listing),
    '-vf', alpha_crop + ',fps=12:start_time=0,tpad=stop_mode=clone:stop_duration=1', '-frames:v', '540', '-c:v', 'libvpx-vp9', '-pix_fmt', 'yuva420p',
    '-b:v', '0', '-crf', '24', '-auto-alt-ref', '0', str(output / f'{stem}.webm')], check=True)
encoders = subprocess.run(['ffmpeg', '-hide_banner', '-encoders'], capture_output=True, text=True, check=True).stdout
if 'hevc_videotoolbox' in encoders:
    subprocess.run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y', '-f', 'concat', '-safe', '0', '-i', str(listing),
        '-vf', alpha_crop + ',fps=12:start_time=0,format=bgra,tpad=stop_mode=clone:stop_duration=1', '-frames:v', '540', '-c:v', 'hevc_videotoolbox',
        '-alpha_quality', '.85', '-b:v', '1200k', '-tag:v', 'hvc1', '-movflags', '+faststart',
        str(output / f'{stem}.mov')], check=True)
preview = min(frames, key=lambda frame: abs(frame['at'] - (10.5 if args.zen else 4)))
subprocess.run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y', '-i', str(args.frames / preview['file']),
    '-vf', alpha_crop, '-frames:v', '1', str(output / f'{stem}-poster.png')], check=True)
print(f'Encoded transparent native playback: {stem}')
